-- Real first-load evidence and read-only COMPLETE common-transaction preflight.
-- No Commit, default restoration or lifecycle/engine claim in this spec.
local M={}
local serial=0
function M.run()
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Evidence=require("SpellHotReload.Adapters.Card.CardReconcile")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Syntax=require("SpellHotReload.Source.SyntaxTree")
    local Compose=require("SpellHotReload.Source.Compose")
    local saved={boss=_G.boss,classes=_G._editor_class,tmp=_G._tmp_sc}
    local build,analyze,lex,create=Source.Build,IR.Analyze,Syntax.Parse,Compose.Create
    local passed=0
    local function eq(a,b,label) assert(rawequal(a,b),label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local defaults={}
    for _,n in ipairs({"before","init","frame","render","beforedel","del","after"}) do defaults[n]=function() end end
    local source=table.concat({"_editor_class['K'].cards={}","_tmp_sc=boss.card.New('A',1,2,3,4)",
        "function _tmp_sc:init() end","function _tmp_sc:frame() return 10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
    -- Unchanged generated class implementations/metadata remain full-file
    -- obligations when one optional callback alone disappears.
    source=table.concat({
        "_editor_class['K'].name='Generated Boss'",
        "_editor_class['K']._bg=nil",
        "_editor_class['K'].difficulty='Normal'",
        "_editor_class['K'].init=function(self) end",
        "_editor_class['K'].render=function(self) end",
        "_editor_class['Other'].render=function(self) end",
        (source:gsub("function _tmp_sc:init", "_tmp_sc.perform=false\nfunction _tmp_sc:init")),
    },"\n")
    local bytes=source:gsub("function _tmp_sc:frame%(%) return 10 end\n","")
    local constructions=0
    local ok,problem=pcall(function()
        _G._editor_class={K={},Other={}}
        _G.boss={card={New=function(name)
            constructions=constructions+1
            local card={name=name,is_combat=true};for k,v in next,defaults do card[k]=v end;return card
        end}}
        local entry=must(Load.Capture(source,{name="Delete_Boss.lua"}))
        entry.file="Delete_Boss.lua";serial=serial+1
        local f=must(Planning.Capture(entry,"deletion:evidence:"..serial,_G._editor_class,defaults))
        local capture=f.capture;local base=capture.snapshot
        local group,initial=Files.GetAdapterRecords(capture,Card);must(group,initial);initial=initial.evidence
        local state=group.state;local key=state.order[1]
        local function live()
            return {capture=capture,snapshot=capture.snapshot,entry=entry,session_id=f.session,
                content=bytes,generation=1,classes=_G._editor_class}
        end
        local facts=must(Source.Build(bytes))
        local discovery=must(Planning.Discover(f,facts,1))
        local prepared,report,operation=Planning.Prepare(f,discovery,{refresh=live});must(prepared,report)
        local fragment=prepared.entries[2].fragment
        eq(prepared.entries[2].owner,Card,"deletion prepared by genuine Card owner")
        local plan=fragment.card_plan;local publication=plan.publications[1]
        eq(#plan.publications,1,"only missing optional callback selected")
        eq(publication.value,state.defaults.frame,"exact saved first-load default")
        eq(publication.value,defaults.frame,"saved identity initially matches supplied default")
        local supplied_default=defaults.frame;defaults.frame=function() end
        eq(publication.value==defaults.frame,false,"later external default changes do not replace saved identity")
        defaults.frame=supplied_default
        local snapshot=discovery.snapshot
        local rows,actual,first=Evidence.Index(capture,snapshot);must(rows,actual)
        eq(actual,group,"deletion rows belong to current actual Card group")
        eq(first,initial,"deletion reuses exact genuine first-load evidence")
        local row=rows[key..":frame"]
        eq(publication.deletion,row.tombstone,"transaction carries exact validated deletion")
        local fragments={}
        for _,item in ipairs(prepared.entries) do fragments[#fragments+1]=item.fragment end
        local sealed=must(Guard.Seal(operation,fragments))
        eq(capture.snapshot,base,"sealing never installs the proposed snapshot")
        -- Every later preflight must consume existing complete facts and proof.
        Source.Build=function() error("deletion guard rebuilt source") end
        IR.Analyze=function() error("deletion guard reparsed source") end
        Syntax.Parse=function() error("deletion guard parsed source") end
        Compose.Create=function() error("deletion guard constructed a callback") end
        eq(Guard.Check(sealed,capture,live()),true,"all-owner sealed preflight without rebuilding or construction")
        local function refused(label)
            local v,e=Guard.Check(sealed,capture,live())
            eq(v,nil,label.." refused");eq(type(e),"table",label.." structured diagnostic")
            eq(type(e.message),"string",label.." diagnostic message")
            eq(capture.snapshot,base,label.." common version unchanged")
            eq(_G._editor_class.K.cards[1].frame,state.units[key].callbacks.frame.fn,label.." live callback unchanged")
        end
        for _,field in ipairs({"owner","owner_id","previous","definition_version"}) do
            local old=row.tombstone[field]
            row.tombstone[field]=field=="definition_version" and 999 or (field=="owner_id" and "foreign" or {})
            refused("foreign "..field)
            row.tombstone[field]=old
        end
        local original_class=_G._editor_class.Other
        _G._editor_class.Other={};refused("unrelated class binding drift");_G._editor_class.Other=original_class
        local first_classes=initial.class_bindings;initial.class_bindings={}
        refused("missing first-load class identities");initial.class_bindings=first_classes
        local class_keys=row.tombstone.class_keys;row.tombstone.class_keys={}
        refused("omitted source class obligations");row.tombstone.class_keys=class_keys
        local exact=publication.deletion;publication.deletion={}
        refused("foreign transaction tombstone");publication.deletion=exact
        local value=publication.value;publication.value=function() end
        refused("substituted default");publication.value=value
        local slot=row.candidate.slot;row.candidate.slot=99
        refused("changed source occurrence");row.candidate.slot=slot
        local version=snapshot.reconciliation.revision;snapshot.reconciliation.revision=99
        refused("stale reconciliation revision");snapshot.reconciliation.revision=version
        local r=snapshot.reconciliation;snapshot.reconciliation=nil
        refused("missing reconciliation");snapshot.reconciliation=r
        eq(Guard.Check(sealed,capture,live()),true,"restored exact evidence valid again")
        eq(constructions,1,"all guard checks preserve specific initial card construction count")
        eq(capture.snapshot,base,"all preflights remain read-only")
        eq(_G._editor_class.K.cards[1].frame,state.units[key].callbacks.frame.fn,"saved default is not installed by preflight")
        Source.Build,IR.Analyze,Syntax.Parse,Compose.Create=build,analyze,lex,create
        local empty=must(Planning.Discover(f,must(Source.Build("")),2))
        local unresolved=must(Evidence.Index(capture,empty.snapshot))
        eq(unresolved[key..":frame"].status,"unresolved","zero-match is not callback deletion")
        eq(unresolved[key..":frame"].tombstone,nil,"zero-match has no default restoration evidence")
    end)
    Source.Build,IR.Analyze,Syntax.Parse,Compose.Create=build,analyze,lex,create
    _G.boss,_G._editor_class,_G._tmp_sc=saved.boss,saved.classes,saved.tmp
    if not ok then error(type(problem)=="table" and problem.message or problem,0) end
    print("CardDeletionEvidenceSpec: "..passed.." passed, 0 failed")
    return {passed=passed,failed=0}
end
return M
