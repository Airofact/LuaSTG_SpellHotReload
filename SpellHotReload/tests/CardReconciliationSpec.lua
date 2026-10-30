-- Real shared analysis/reconciliation and one explicit partial common publication.
-- Intended for the supported LuaJIT runtime; no presence-only capability shims.
local M={}
local serial=0
function M.run()
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Evidence=require("SpellHotReload.Adapters.Card.CardReconcile")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Compose=require("SpellHotReload.Source.Compose")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local passed=0
    local function eq(a,b,label) assert(rawequal(a,b),label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local saved={boss=_G.boss,classes=_G._editor_class,tmp=_G._tmp_sc,effects=_G._reconcile_effect}
    local create,analyze=Compose.Create,IR.Analyze
    local controllers={}
    local source=table.concat({"local state=4","local function helper(n) return state+n end",
        "_reconcile_effect()","_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)","function _tmp_sc:init(n) return helper(n) end",
        "function _tmp_sc:frame(n) return n+1 end","table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)","function _tmp_sc:init(n) return helper(n)+10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
    local effects,constructs=0,0
    local function setup(bytes)
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
        local entry=must(Load.Capture(bytes,{name="Reconcile_Boss.lua"}))
        entry.file="Reconcile_Boss.lua";serial=serial+1
        local f=must(Planning.Capture(entry,"reconcile:S:"..serial,_G._editor_class,defaults))
        f.classes=_G._editor_class;f.content=bytes;f.generation=0
        return f
    end
    local function scan(f,bytes)
        f.content=bytes;f.generation=f.generation+1
        local facts=must(Source.Build(bytes))
        return must(Planning.Discover(f,facts,f.generation))
    end
    local function live(f)
        return {capture=f.capture,snapshot=f.capture.snapshot,entry=f.entry,session_id=f.session,
            content=f.content,generation=f.generation,classes=_G._editor_class}
    end
    local function oldrow(d,key)
        for _,r in ipairs(d.reconciliation.rows) do
            if r.owner==Card and r.result.previous and r.result.previous.key==key then return r.result end
        end
        error("old Card publication row missing: "..key)
    end
    local function card_entries(d)
        local n=0;for _,entry in ipairs(d.snapshot.entries) do if entry.adapter==Card then n=n+1 end end
        return n
    end
    local ok,problem=pcall(function()
        local f=setup(source);local capture=f.capture;local base=capture.snapshot
        local group=must(Files.GetAdapterRecords(capture,Card));local state=group.state;local key=state.order[1]
        local publication=must(Files.Publication(capture))
        eq(#publication.groups,2,"both genuine first-load owners published")
        eq(publication.groups[2].owner,Card,"first-load captured Card owner")
        eq(publication.groups[2].state,state,"actual private Card state identity")
        eq(publication.groups[2].records,group.records,"original Card records retain identity")
        local edits=source:gsub("function _tmp_sc:frame%(n%) return n%+1 end\n","")
        local before_effects,before_constructs=effects,constructs
        local analyses,compiles=0,0
        IR.Analyze=function(...) analyses=analyses+1;return analyze(...) end
        Compose.Create=function() compiles=compiles+1;error("reconcile constructs candidate callback") end
        local d=scan(f,edits)
        eq(analyses,1,"one input analysis shared by all original owners and records")
        eq(compiles,0,"reconciliation does not construct candidate functions")
        eq(oldrow(d,key).status,"corresponding","unique card correspondence")
        local deleted=oldrow(d,key..":frame")
        eq(deleted.status,"deleted","optional callback absence confirmed")
        eq(deleted.tombstone.previous.definition,state.units[key].callbacks.frame,"exact published callback")
        eq(deleted.tombstone.owner,Card,"deletion retains original adapter")
        eq(deleted.tombstone.definition_version,1,"last published callback version")
        eq(capture.snapshot,base,"deletion evidence never installs a snapshot")
        eq(f.classes.K.cards[1].frame,state.units[key].callbacks.frame.fn,"old callback remains live")
        for _,write in ipairs({
            [[_tmp_sc["frame"]=replacement]],
            [[_editor_class["K"].cards[1].frame=replacement]],
            "function _tmp_sc:frame() return 99 end",
        }) do
            local unsafe=scan(f,edits.."\n"..write)
            eq(oldrow(unsafe,key..":frame").status,"unresolved","unmodeled write cannot prove deletion")
            eq(oldrow(unsafe,key..":frame").tombstone,nil,"unmodeled write has no tombstone")
        end
        local empty=scan(f,"")
        eq(#empty.snapshot.units,0,"candidate can match zero units")
        local records=0;for _,owner in ipairs(publication.groups) do records=records+#owner.records end
        eq(#empty.reconciliation.rows,records,"zero-match retains all owners' old records")
        for _,r in ipairs(empty.reconciliation.rows) do
            eq(r.result.status,"unresolved","whole source absence stays unresolved")
            eq(r.result.tombstone,nil,"whole source absence cannot destroy live definitions")
        end
        local never=scan(f,source.."\n_editor_class['NEW'].cards={}")
        eq(card_entries(never),2,"candidate-only class observed independently of Local entries")
        local again=scan(f,source)
        eq(oldrow(again,key..":frame").status,"corresponding","unapplied deletion does not become baseline")
        eq(oldrow(again,key..":frame").previous.definition_version,1,"repeat scan retains publication version")
        eq(effects,before_effects,"no candidate top-level execution")
        eq(constructs,before_constructs,"no candidate card construction")
        IR.Analyze,Compose.Create=analyze,create
        -- Preparation is not installation. Only the explicit common transaction
        -- below establishes v2 before NEW discovery may use it as deletion evidence.
        local changed=source:gsub("return n%+1 end","return n+2 end")
        local changed_discovery=scan(f,changed)
        local prepared=must(Planning.Prepare(f,changed_discovery,{root_ids={key},refresh=function() return live(f) end}))
        eq(capture.snapshot,base,"partial preparation does not install versions")
        eq(prepared.entries[2].owner,Card,"real Card preparation belongs to original owner")
        local fragment=prepared.entries[2].fragment
        eq(fragment.proposed_group.state.units[key].callbacks.frame.definition_version,2,"prepared callback proposes v2")
        local tx=must(Tx.New(f.session));controllers[#controllers+1]=tx
        local receipt=must(Planning.Publish(f,prepared,tx))
        eq(receipt.changed,true,"explicit joint transaction returns changed receipt")
        eq(capture.snapshot,receipt.snapshot,"receipt identifies installed common snapshot")
        eq(receipt.snapshot.revision,1,"partial actual publication advances file once")
        local current=must(Files.GetAdapterRecords(capture,Card));local next_state=current.state
        eq(current.owner,Card,"installed Card contribution retains original owner")
        eq(next_state.units[key].callbacks.frame.definition_version,2,"changed callback version actually advances")
        eq(f.classes.K.cards[1]:frame(5),7,"live callback uses actually published definition")
        local stale,stale_error=Evidence.Index(capture,changed_discovery.snapshot)
        eq(stale,nil,"pre-publication discovery cannot authorize current deletion evidence")
        eq(stale_error.code,"stale","old common revision is explicitly refused")
        local partial=scan(f,edits);local tomb=oldrow(partial,key..":frame")
        eq(tomb.tombstone.definition_version,2,"deletion uses currently published callback version")
        eq(tomb.previous.definition,next_state.units[key].callbacks.frame,"deletion does not use first-load callback")
        local revert=scan(f,source)
        eq(oldrow(revert,key..":frame").previous.definition_version,2,"original bytes compare against actual version")
        eq(oldrow(revert,state.order[2]..":init").previous.definition_version,1,"unselected sibling stays at old version")
        eq(capture.snapshot,receipt.snapshot,"post-publication read-only discovery installs nothing")
        eq(effects,before_effects,"partial publication never replays top-level effects")
        eq(constructs,before_constructs,"partial publication never reconstructs cards")
        -- Duplicate names cannot inherit a removed neighbor's callback identity.
        local duplicate=setup((source:gsub("New%('B'","New('A'")))
        local dd=scan(duplicate,(edits:gsub("New%('B'","New('A'")))
        for _,r in ipairs(dd.reconciliation.rows) do
            if r.owner==Card and r.result.previous and r.result.previous.kind=="callback" then
                eq(r.result.status,"ambiguous","duplicate names never prove callback deletion")
                eq(r.result.tombstone,nil,"ambiguous callback has no tombstone")
            end
        end
        eq(state.units[key].callbacks.frame.definition_version,1,"actual publication preserves original immutable version")
    end)
    Compose.Create,IR.Analyze=create,analyze
    for _,controller in ipairs(controllers) do controller:Release() end
    _G.boss,_G._editor_class,_G._tmp_sc,_G._reconcile_effect=saved.boss,saved.classes,saved.tmp,saved.effects
    if not ok then error(type(problem)=="table" and problem.message or problem,0) end
    print("CardReconciliationSpec: "..passed.." passed, 0 failed")
    return {passed=passed,failed=0}
end
return M
