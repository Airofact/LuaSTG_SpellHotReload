
-- Real first-load records; both runtimes exercise read-only deletion preflight.
-- Presence-only upvaluejoin on Lua51 is never invoked and proves no shared commit.
local M={}
function M.run()
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Evidence=require("SpellHotReload.Adapters.Card.CardReconcile")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Compose=require("SpellHotReload.Source.Compose")
    local saved={boss=_G.boss,classes=_G._editor_class,tmp=_G._tmp_sc}
    local join,analyze,create=debug.upvaluejoin,IR.Analyze,Compose.Create
    local passed=0
    local function eq(a,b,label) assert(a==b,label);passed=passed+1 end
    local defaults={}
    for _,n in ipairs({"before","init","frame","render","beforedel","del","after"}) do defaults[n]=function() end end
    local source=table.concat({"_editor_class['K'].cards={}","_tmp_sc=boss.card.New('A',1,2,3,4)",
        "function _tmp_sc:init() end","function _tmp_sc:frame() return 10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
    local bytes=source:gsub("function _tmp_sc:frame%(%) return 10 end\n","")
    local constructions=0
    local ok,problem=pcall(function()
        _G._editor_class={K={}}
        _G.boss={card={New=function(name)
            constructions=constructions+1
            local card={name=name,is_combat=true};for k,v in next,defaults do card[k]=v end;return card
        end}}
        debug.upvaluejoin=join or function() error("unexpected join") end
        local entry=assert(Load.Capture(source,{name="Delete_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Delete_Boss.lua"
        local capture=assert(Card.SeedVersions(entry,"deletion:evidence",_editor_class,defaults))
        local base=capture.snapshot;local key=base.order[1]
        local report=assert(Planning.Report(capture,bytes))
        local selection=assert(Cards.SelectFile(report))
        local publication=selection.publications[1]
        eq(#selection.publications,1,"only missing optional callback selected")
        eq(publication.value,defaults.frame,"saved default, not current global default")
        local snapshot=selection.discovery
        local rows=assert(Evidence.Index(base,snapshot))
        local row=rows[key..":frame"]
        eq(publication.deletion,row.tombstone,"transaction carries exact validated deletion")
        local live={capture=capture,snapshot=base,entry=entry,session_id=base.session_id,
            content=bytes,classes=_editor_class}
        IR.Analyze=function() error("deletion guard reparsed source") end
        Compose.Create=function() error("deletion guard compiled a callback") end
        eq(Card.CheckCommitInput(selection,capture,live),true,"valid deletion preflight without parsing/compilation")
        local function refused(label)
            local v,e=Card.CheckCommitInput(selection,capture,live)
            eq(v,nil,label.." refused");eq(type(e.message),"string",label.." structured diagnostic")
            eq(capture.snapshot,base,label.." version unchanged")
            eq(_editor_class.K.cards[1].frame,base.units[key].callbacks.frame.fn,label.." live callback unchanged")
        end
        for _,field in ipairs({"owner","owner_id","previous","definition_version"}) do
            local old=row.tombstone[field]
            row.tombstone[field]=field=="definition_version" and 999 or (field=="owner_id" and "foreign" or {})
            refused("foreign "..field)
            row.tombstone[field]=old
        end
        local exact=publication.deletion;publication.deletion={}
        refused("foreign transaction tombstone");publication.deletion=exact
        local value=publication.value;publication.value=function() end
        refused("substituted default");publication.value=value
        local slot=row.candidate.slot;row.candidate.slot=99
        refused("changed source occurrence");row.candidate.slot=slot
        local version=snapshot.reconciliation.revision;snapshot.reconciliation.revision=99
        refused("stale report revision");snapshot.reconciliation.revision=version
        local r=snapshot.reconciliation;snapshot.reconciliation=nil
        refused("missing reconciliation");snapshot.reconciliation=r
        eq(Card.CheckCommitInput(selection,capture,live),true,"restored exact evidence valid again")
        eq(constructions,1,"all guard checks left initial construction count unchanged")
        IR.Analyze,Compose.Create=analyze,create
        local driver=Driver.New();assert(driver:RegisterDiscovery(Card))
        local empty=assert(driver:DiscoverPublished(base.file,"",assert(Cards.Publication(base)),{published_units=base}))
        local unresolved=assert(Evidence.Index(base,empty.snapshot))
        eq(unresolved[key..":frame"].status,"unresolved","zero-match is not callback deletion")
        eq(unresolved[key..":frame"].tombstone,nil,"zero-match has no default restoration evidence")
    end)
    debug.upvaluejoin,IR.Analyze,Compose.Create=join,analyze,create
    _G.boss,_G._editor_class,_G._tmp_sc=saved.boss,saved.classes,saved.tmp
    if not ok then error(type(problem)=="table" and problem.message or problem,0) end
    print("CardDeletionEvidenceSpec: "..passed.." passed, 0 failed")
    return {passed=passed,failed=0}
end
return M
