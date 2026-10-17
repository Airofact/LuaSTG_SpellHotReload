local M={}
function M.run()
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Compose=require("SpellHotReload.Source.Compose")
    local passed=0
    local function eq(a,b,label) assert(a==b,label.." got "..tostring(a));passed=passed+1 end
    local saved={boss=_G.boss,classes=_G._editor_class,tmp=_G._tmp_sc,effects=_G._reconcile_effect}
    local join=debug.upvaluejoin
    local create,analyze=Compose.Create,IR.Analyze
    local source=table.concat({"local state=4","local function helper(n) return state+n end",
        "_reconcile_effect()","_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)","function _tmp_sc:init(n) return helper(n) end",
        "function _tmp_sc:frame(n) return n+1 end","table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)","function _tmp_sc:init(n) return helper(n)+10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
    local effects,constructs=0,0
    local function setup(bytes)
        if not join then debug.upvaluejoin=function() error("presence-only, no join permitted") end end
        _G._reconcile_effect=function() effects=effects+1 end
        _G._editor_class={K={}}
        local defaults={}
        for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
            defaults[name]=function() end
        end
        _G.boss={card={New=function(name)
            constructs=constructs+1
            local card={name=name,is_combat=true};for k,v in next,defaults do card[k]=v end;return card
        end}}
        local entry=assert(Load.Capture(bytes,{name="Reconcile_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Reconcile_Boss.lua"
        return assert(Card.SeedVersions(entry,"reconcile:S",_G._editor_class,defaults))
    end
    local ok,problem=pcall(function()
        local capture=setup(source)
        local base=capture.snapshot
        local key=base.order[1]
        local driver=Driver.New();assert(driver:RegisterDiscovery(Card))
        local publication=assert(Cards.Publication(base))
        eq(publication.groups[1].owner,Card,"first-load captured owner")
        eq(publication.groups[1].state,base,"actual snapshot identity")
        local function scan(bytes,state)
            return assert(driver:DiscoverPublished(base.file,bytes,assert(Cards.Publication(state or base)),
                {candidate_generation=1,published_units=state or base}))
        end
        local function oldrow(d,key)
            for _,r in ipairs(d.reconciliation.rows) do
                if r.result.previous and r.result.previous.key==key then return r.result end
            end
            error("old publication row missing: "..key)
        end
        local edits=source:gsub("function _tmp_sc:frame%(n%) return n%+1 end\n","")
        local before_effects,before_constructs=effects,constructs
        local analyses,compiles=0,0
        IR.Analyze=function(...) analyses=analyses+1;return analyze(...) end
        Compose.Create=function(...) compiles=compiles+1;error("reconcile compiles candidate") end
        local d=scan(edits)
        eq(analyses,1,"one complete candidate analysis for all old records")
        eq(compiles,0,"reconciliation does not compile")
        eq(oldrow(d,key).status,"corresponding","unique card correspondence")
        local deleted=oldrow(d,key..":frame")
        eq(deleted.status,"deleted","optional callback absence confirmed")
        eq(deleted.tombstone.previous.definition,base.units[key].callbacks.frame,"exact published callback")
        eq(deleted.tombstone.owner,Card,"deletion retains original adapter")
        eq(deleted.tombstone.definition_version,1,"last published callback version")
        eq(capture.snapshot,base,"deletion evidence never installs a snapshot")
        eq(_G._editor_class.K.cards[1].frame,base.units[key].callbacks.frame.fn,"old callback remains live")
        for _,write in ipairs({
            [[_tmp_sc["frame"]=replacement]],
            [[_editor_class["K"].cards[1].frame=replacement]],
            "function _tmp_sc:frame() return 99 end",
        }) do
            local unsafe=scan(edits.."\n"..write)
            eq(oldrow(unsafe,key..":frame").status,"unresolved","unmodeled write cannot prove deletion")
            eq(oldrow(unsafe,key..":frame").tombstone,nil,"unmodeled write has no tombstone")
        end
        local empty=scan("")
        eq(#empty.snapshot.units,0,"candidate can match zero classes")
        eq(#empty.reconciliation.rows,#publication.groups[1].records,"zero-match retains all old records")
        for _,r in ipairs(empty.reconciliation.rows) do
            eq(r.result.status,"unresolved","whole class absence stays unresolved")
            eq(r.result.tombstone,nil,"whole class absence cannot destroy live card")
        end
        local never=scan(source.."\n_editor_class['NEW'].cards={}")
        eq(#never.snapshot.units,2,"candidate-only class observed")
        local again=scan(source)
        eq(oldrow(again,key..":frame").status,"corresponding","unapplied deletion does not become baseline")
        eq(oldrow(again,key..":frame").previous.definition_version,1,"repeat scan retains publication version")
        eq(effects,before_effects,"no candidate top-level execution")
        eq(constructs,before_constructs,"no candidate card construction")
        IR.Analyze,Compose.Create=analyze,create
        -- Propose a partial publication through the existing actual version
        -- planner. Next is not installation; explicitly use it as another
        -- publication input, never claim an executed transaction here.
        local changed=source:gsub("return n%+1 end","return n+2 end")
        local report=assert(Planning.Report(capture,changed))
        local selection=assert(Cards.Select(report,{key}))
        local next_state=assert(Cards.Next(selection))
        eq(next_state.revision,1,"candidate proposed partial version")
        eq(next_state.owner,Card,"Next retains original owner")
        eq(next_state.units[key].callbacks.frame.definition_version,2,"changed callback version advances")
        local partial=scan(edits,next_state)
        local tomb=oldrow(partial,key..":frame")
        eq(tomb.tombstone.definition_version,2,"deletion uses current published version input")
        eq(tomb.previous.definition,next_state.units[key].callbacks.frame,"deletion does not use firstload callback")
        local revert=scan(source,next_state)
        eq(oldrow(revert,key..":frame").previous.definition_version,2,"original bytes still compare against actual version")
        eq(oldrow(revert,base.order[2]..":init").previous.definition_version,1,"unselected sibling stays at old version")
        eq(capture.snapshot,base,"read-only planning never installs proposed versions")
        -- Duplicate names cannot inherit a removed neighbor's callback identity.
        local duplicate=setup(source:gsub("New%('B'","New('A'"))
        local dd=assert(driver:DiscoverPublished(base.file,edits:gsub("New%('B'","New('A'"),
            assert(Cards.Publication(duplicate.snapshot))))
        for _,r in ipairs(dd.reconciliation.rows) do
            if r.result.previous and r.result.previous.kind=="callback" then
                eq(r.result.status,"ambiguous","duplicate names never prove callback deletion")
                eq(r.result.tombstone,nil,"ambiguous callback has no tombstone")
            end
        end
        eq(base.units[key].callbacks.frame.definition_version,1,"all proposals preserve original version")
    end)
    Compose.Create,IR.Analyze,debug.upvaluejoin=create,analyze,join
    _G.boss,_G._editor_class,_G._tmp_sc,_G._reconcile_effect=saved.boss,saved.classes,saved.tmp,saved.effects
    if not ok then error(problem,0) end
    print("CardReconciliationSpec: "..passed.." passed, 0 failed")
    return {passed=passed,failed=0}
end
return M
