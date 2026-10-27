-- Real shared-source/capture file correspondence from miniature first loads.
-- Read-only location/recheck; no candidate chunk, common publication or engine.
local M={}
function M.run(opts)
    opts=opts or {}
    local Target=opts.target or require("SpellHotReload.Adapters.Card.CardTarget")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Syntax=require("SpellHotReload.Source.SyntaxTree")
    local Compose=require("SpellHotReload.Source.Compose")
    local Callbacks=require("SpellHotReload.Adapters.Card.CardCallbacks")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local passed,failed,failures=0,0,{}
    local function eq(a,b,label)
        if rawequal(a,b) then passed=passed+1
        else failed=failed+1;failures[#failures+1]=label end
    end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function refuse(fn,code,label)
        local v,e=fn()
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        eq(e and e.phase,"locate",label.." phase");eq(e and e.code,code,label.." code")
    end
    local function copy(v) local r={};for k,x in next,v do r[k]=x end;return r end
    local defaults={}
    for _,n in ipairs({"before","init","frame","render","beforedel","del","after"}) do
        defaults[n]=function() return "default" end
    end
    local saved={}
    for _,n in ipairs({"boss","_editor_class","_tmp_sc","_BOSS_ESCAPE","FILE_TARGET_EFFECT"}) do saved[n]=rawget(_G,n) end
    local saved_apis={read=Callbacks.Read,match=Card.Match,build=Source.Build,analyze=IR.Analyze,
        tokenize=Syntax.Parse,create=Compose.Create}
    local function restore_apis()
        Callbacks.Read,Card.Match=saved_apis.read,saved_apis.match
        Source.Build,IR.Analyze,Syntax.Parse,Compose.Create=
            saved_apis.build,saved_apis.analyze,saved_apis.tokenize,saved_apis.create
    end
    local function card_state(capture)
        return must(Files.Owner(capture,Card)).state
    end
    local function first_card(capture)
        local group,initial=Files.Owner(capture,Card);must(group,initial)
        return initial.evidence
    end
    local serial,effects,constructors,escapes=0,0,0,0
    local function source(classes,opts)
        opts=opts or {}
        local lines={"local state=4","local function helper() return state end","FILE_TARGET_EFFECT()"}
        for _,class in ipairs(classes) do
            local key=string.format("%q",class.key)
            lines[#lines+1]="_editor_class["..key.."].cards={}"
            if class.move then
                lines[#lines+1]="table.insert(_editor_class["..key.."].cards,boss.move.New(0,0,1))"
            end
            for _,label in ipairs(class.labels) do
                lines[#lines+1]="_tmp_sc=boss.card.New("..string.format("%q",label)..",1,2,3,4)"
                lines[#lines+1]="function _tmp_sc:init() return helper()+"..(opts.bump or 0).." end"
                lines[#lines+1]="table.insert(_editor_class["..key.."].cards,_tmp_sc)"
            end
            if class.escape then lines[#lines+1]="_BOSS_ESCAPE("..key..",0,0,1)" end
        end
        return (opts.bom and "\239\187\191" or "")..table.concat(lines,"\n")
    end
    local function fixture(labels,move,escape)
        _editor_class={K={},L={},N={}}
        FILE_TARGET_EFFECT=function() effects=effects+1 end
        boss={card={New=function(label)
            constructors=constructors+1
            local card={name=label,is_combat=true}
            for n,fn in next,defaults do card[n]=fn end
            return card
        end},move={New=function() constructors=constructors+1;return {is_combat=false} end}}
        _BOSS_ESCAPE=function(class_key)
            escapes=escapes+1
            local list=_editor_class[class_key].cards
            constructors=constructors+1
            list[#list+1]={name="",is_combat=false}
            local deletion=boss.card.New("")
            function deletion:init() return "escape deletion" end
            list[#list+1]=deletion
        end
        serial=serial+1
        local bytes=source({{key="K",labels=labels or {"A","B"},move=move,escape=escape},
            {key="L",labels={"Side"}}})
        local entry=must(Load.Capture(bytes,{name="FileTarget_Boss.lua"}))
        entry.file="FileTarget_Boss.lua"
        local f=must(Planning.Capture(entry,"file-target:"..serial,_editor_class,defaults))
        local capture=f.capture
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,
            classes=_editor_class,session_id=f.session,generation=7}
        local function discover(content)
            live.snapshot,live.content=capture.snapshot,content
            return must(Planning.Discover(f,must(Source.Build(content)),7)).snapshot
        end
        local function report(content)
            local discovery=discover(content or bytes)
            return must(Target.LocateFileDiscovery(discovery,capture,live)),discovery
        end
        return {capture=capture,live=live,bytes=bytes,report=report,discover=discover}
    end
    local function key(class,slot) return "card:"..#class..":"..class..":"..slot end
    local function row(report,class,slot) return assert(report.by_key[key(class,slot)],"missing "..key(class,slot)) end
    local function layout(labels,move,side)
        return {{key="K",labels=labels,move=move},{key="L",labels=side or {"Side"}}}
    end
    local ok,problem=pcall(function()
        local f=fixture()
        local before_effect,before_ctor=effects,constructors
        local r,d=f.report(source(layout({"A","B"}),{bump=9,bom=true}))
        eq(r.kind,Target.Kind..".FileDiscovery","file proof kind")
        eq(r.snapshot,f.capture.snapshot,"publication baseline retained")
        eq(r.discovery,d,"complete discovery retained");eq(r.base_revision,0,"revision captured")
        eq(r.generation,7,"generation captured");eq(r.content,f.live.content,"exact bytes")
        eq(#r.order,3,"all captured units");eq(#r.located,3,"all stable units located")
        eq(#r.pending,0,"no unmapped combat");eq(#r.unowned,0,"no unclaimed combat")
        local a=row(r,"K",1)
        eq(a.target.card,f.live.classes.K.cards[1],"actual card identity")
        eq(a.target.list,f.live.classes.K.cards,"actual live list")
        eq(a.target.unit,card_state(f.capture).units[a.key],"actual private Card publication unit")
        eq(r.card_group,must(Files.Owner(f.capture,Card)),"proof retains actual Card contribution")
        eq(d.by_key["local:helper"].adapter.Id,"local","complete discovery retains independent Local owner")
        eq(a.target.slot,1,"live slot");eq(a.candidate_slot,1,"candidate slot")
        eq(a.target.mode,nil,"no invented practice mode")
        eq(a.target.include_previous,nil,"no invented restart flag")
        eq(Target.CheckFileDiscovery(r,f.capture,f.live),true,"fresh file check")
        eq(f.live.classes.K.cards[1].init(),4,"old callback unchanged")
        eq(effects,before_effect,"candidate initializer not executed")
        eq(constructors,before_ctor,"no constructors replayed")
        eq(f.capture.snapshot.revision,0,"no publication")
        -- DiMS escape deletion is a live combat card, but its source descriptor
        -- is a framework placeholder, not a generated callback publication unit.
        f=fixture({"A"},false,true)
        local deletion=f.live.classes.K.cards[3]
        local deletion_init=deletion.init
        before_effect,before_ctor=effects,constructors
        local before_escape=escapes
        r,d=f.report()
        eq(card_state(f.capture).layout.K[3].kind,"other","escape source placeholder")
        eq(deletion.is_combat,true,"escape deletion has runtime combat flag")
        eq(card_state(f.capture).units[key("K",3)],nil,"escape not a publication unit")
        eq(#r.located,2,"generated cards still located with combat placeholder")
        eq(#r.pending,0,"unchanged escape is not an unmapped generated card")
        eq(#r.unowned,0,"escape does not become a new generated owner")
        eq(Target.CheckFileDiscovery(r,f.capture,f.live),true,"escape file recheck")
        eq(deletion.init,deletion_init,"escape callback never replaced")
        eq(escapes,before_escape,"escape registration not replayed")
        eq(constructors,before_ctor,"escape constructors not replayed")
        eq(effects,before_effect,"escape proof does not run top level")
        card_state(f.capture).layout.K[1].kind="other"
        refuse(function() return Target.LocateFileDiscovery(d,f.capture,f.live) end,
            "ownership","published card descriptor changed to placeholder")
        f=fixture({"A"},false,true);r,d=f.report()
        f.live.classes.K.cards[3]={}
        refuse(function() return Target.CheckFileDiscovery(r,f.capture,f.live) end,
            "ownership","combat placeholder replacement")
        -- Source-absent first captured class must not hide another real entry.
        f=fixture();r=f.report(source({{key="L",labels={"Side"}}}))
        eq(first_card(f.capture).ownership[1].class_key,"K","absent class was first captured owner")
        eq(row(r,"K",1).status,"source-absent","absent first source")
        eq(row(r,"K",1).entry,nil,"never forge deleted entry")
        eq(row(r,"L",1).status,"located","other class still mapped")
        eq(#r.pending,2,"absent owners retained");eq(#r.located,1,"only genuine remaining owner")
        eq(#f.live.classes.K.cards,2,"no live deletion")
        r=f.report(source({}));eq(#r.located,0,"no invented Card entry")
        eq(#r.pending,3,"all live owners retained without source")
        -- New class/slot remains unowned, independently of mapped owners.
        f=fixture();local classes=layout({"A","B","Added"})
        classes[#classes+1]={key="N",labels={"New"}}
        r=f.report(source(classes))
        eq(#r.located,3,"safe suffix keeps owners")
        eq(#r.unowned,2,"new slot and class remain unowned")
        eq(r.unowned[1].candidate_slot,3,"new source-only slot")
        eq(r.unowned[2].class_key,"N","new source-only class")
        eq(r.unowned[1].status,"unowned","specific pending source status")
        eq(#f.live.classes.K.cards,2,"no registration/list append")
        -- Existing strict head/tail/rename rules, not arbitrary-name following.
        local cases={
            {{"A","B"},false,{"Prefix","A","B"},false,2,3,"named prefix"},
            {{"A","B"},false,{"A","B","Suffix"},false,1,2,"named suffix"},
            {{"A","B"},false,{"A","Renamed"},false,false,2,"single rename"},
            {{"Same","Same"},false,{"Same","Same"},false,1,2,"duplicate exact slots"},
            {{"A",""},false,{"A","","Suffix"},false,1,2,"unnamed head"},
        }
        for _,case in ipairs(cases) do
            f=fixture(case[1],case[2]);r=f.report(source(layout(case[3],case[4])))
            eq(row(r,"K",1).candidate_slot or false,case[5],case[7].." first")
            eq(row(r,"K",2).candidate_slot,case[6],case[7].." second")
            eq(row(r,"K",2).target.slot,2,case[7].." live slot stable")
            eq(Target.CheckFileDiscovery(r,f.capture,f.live),true,case[7].." recheck")
        end
        f=fixture({""},true);r=f.report(source(layout({"Prefix",""},true)))
        eq(row(r,"K",2).candidate_slot,3,"unnamed reverse")
        eq(row(r,"K",2).target.slot,2,"reverse retains live slot")
        f=fixture({"A","B","C"},true);r=f.report(source(layout({"B"},true)))
        eq(row(r,"K",3).candidate_slot,2,"collapsed prefix correspondence")
        eq(row(r,"K",2).status,"unmapped","cropping not live deletion")
        eq(row(r,"K",4).status,"unmapped","cropped suffix remains pending")
        local refused_layouts={
            {{"A","B"},{"B","A"},"reorder"},
            {{"A","B"},{"A","Middle","B"},"middle insertion"},
            {{"Same","Same"},{"Same"},"surviving duplicate name"},
            {{""},{"",""},"unnamed both-end ambiguity"},
        }
        for _,case in ipairs(refused_layouts) do
            f=fixture(case[1]);r=f.report(source(layout(case[2])))
            eq(row(r,"K",1).status,"unmapped",case[3].." not guessed")
            eq(type(row(r,"K",1).reason),"string",case[3].." reason")
            eq(row(r,"L",1).status,"located",case[3].." unrelated class mapped")
        end
        -- Fresh reads + exact read-set: reject identity, index, bytes and proof drift.
        local mutations={
            {"released",function(_,_,_,l) l.released=true end,"stale"},
            {"poisoned",function(_,_,_,l) l.poisoned=true end,"stale"},
            {"session",function(_,_,_,l) l.session_id="other" end,"stale"},
            {"revision",function(_,_,c) c.snapshot.revision=1 end,"stale"},
            {"snapshot",function(_,_,c,l) c.snapshot=copy(c.snapshot);l.snapshot=c.snapshot end,"stale"},
            {"bytes",function(_,_,_,l) l.content=l.content.."\n" end,"stale"},
            {"generation",function(_,d) d.common.generation=8 end,"stale"},
            {"live name",function(_,_,_,l) l.classes.K.cards[1].name="Other" end,"stale"},
            {"sibling name",function(_,_,_,l) l.classes.K.cards[2].name="Other" end,"stale"},
            {"live slot replacement",function(_,_,_,l) l.classes.K.cards[1]={} end,"ownership"},
            {"other class list",function(_,_,_,l) l.classes.L.cards=copy(l.classes.L.cards) end,"ownership"},
            {"unindexed combat",function(_,_,c) local k=key("K",1);card_state(c).units[k]=nil;table.remove(card_state(c).order,1) end,"ownership"},
            {"unindexed discovery",function(_,d) d.by_key.extra={} end,"ownership"},
            {"filtered discovery",function(_,d) d.adapter_contexts.card.classes=9 end,"unsupported"},
            {"other adapter",function(_,d) local e=d.by_key["card:K"];e.adapter={} end,"ownership"},
            {"source index",function(r) r.by_key[key("K",2)]=r.by_key[key("K",1)] end,"stale"},
            {"candidate slot",function(r) row(r,"K",1).candidate_slot=99 end,"stale"},
            {"live slot",function(r) row(r,"K",1).target.slot=99 end,"stale"},
            {"saved names",function(r) row(r,"K",1).target.names[2]="Else" end,"stale"},
            {"located selection",function(r) table.remove(r.located) end,"stale"},
            {"pending selection",function(r) r.pending[1]=key("K",1) end,"stale"},
        }
        for _,case in ipairs(mutations) do
            f=fixture();r,d=f.report()
            case[2](r,d,f.capture,f.live)
            refuse(function() return Target.CheckFileDiscovery(r,f.capture,f.live) end,case[3],case[1])
        end
        f=fixture({"A","B"},true);r,d=f.report()
        f.live.classes.K.cards[1]={}
        refuse(function() return Target.CheckFileDiscovery(r,f.capture,f.live) end,"ownership","placeholder replacement")
        f=fixture();r=f.report(source(layout({"A","B","Added"})))
        r.unowned[1].reason="swallowed"
        refuse(function() return Target.CheckFileDiscovery(r,f.capture,f.live) end,"stale","unowned tamper")
        -- Global one-to-one invariants: malformed duplicate live ownership is
        -- refused before mapping; valid located rows never share source slots.
        f=fixture();r,d=f.report()
        local claimed={}
        for _,k in ipairs(r.located) do
            local item=r.by_key[k];local coordinate=item.source_key..":"..item.candidate_slot
            eq(claimed[coordinate],nil,"unique source claim");claimed[coordinate]=k
        end
        card_state(f.capture).units[key("K",2)].slot=1
        refuse(function() return Target.LocateFileDiscovery(d,f.capture,f.live) end,"ownership","duplicate live slot")
        -- Real parser-produced alias: a reset can reuse the same _tmp_sc twice.
        -- Both live owners must be rejected, not first-claim wins by slot order.
        f=fixture({"Same","Same"})
        local alias=source(layout({"Same","Same"})):gsub(
            '(_editor_class%["L"%]%.cards={})',
            '_editor_class["K"].cards={_tmp_sc,_tmp_sc}\n%1')
        r,d=f.report(alias)
        local k=d.by_key["card:K"].unit.context.layout
        eq(k[1],k[2],"genuine discovery reused descriptor")
        eq(row(r,"K",1).status,"ambiguous","first alias claimant rejected")
        eq(row(r,"K",2).status,"ambiguous","second alias claimant rejected")
        eq(#r.pending,2,"both alias owners pending")
        eq(#r.unowned,2,"both ambiguous source slots retained")
        eq(row(r,"L",1).status,"located","independent owner unaffected by alias")
        eq(Target.CheckFileDiscovery(r,f.capture,f.live),true,"alias diagnosis rechecked")
        f=fixture({"Same","Other"});r=f.report(alias)
        eq(row(r,"K",2).status,"ambiguous","one claimant still rejects reused source")
        eq(#r.unowned,2,"source aliases not treated as new identities")
        -- Separate class parses can refer to one physical declaration as well.
        f=fixture({"Same"})
        local shared=source(layout({"Same"})):gsub(
            '_editor_class%["L"%]%.cards={}',
            '_editor_class["L"].cards={_tmp_sc}')
        r,d=f.report(shared)
        eq(row(r,"K",1).status,"ambiguous","cross-class source reuse rejected")
        eq(row(r,"L",1).status,"located","separate side declaration still mapped")
        eq(row(r,"L",1).candidate_slot,2,"side follows proven prefix shift")
        eq(#r.unowned,2,"both cross-class reused positions remain unowned")
        f=fixture();d=f.discover(f.bytes)
        d.by_key["card:K"].unit.context.layout[1].callback_points.init=nil
        refuse(function() return Target.LocateFileDiscovery(d,f.capture,f.live) end,
            "ownership","missing source occurrence")
        -- No compile/debug/write/cache/body execution during pure proof/recheck.
        f=fixture();d=f.discover(source(layout({"Prefix","A","B"})))
        local chunk=assert(loadfile(assert(opts.module_path,"module_path required")))
        local traps=0
        local function forbidden() traps=traps+1;error("forbidden operation") end
        setfenv(chunk,setmetatable({load=forbidden,loadstring=forbidden,rawset=forbidden,
            debug=setmetatable({},{__index=forbidden}),jit={flush=forbidden}},{__index=_G}))
        local pure=chunk()
        before_effect,before_ctor=effects,constructors
        Callbacks.Read=forbidden;Card.Match=forbidden;Source.Build=forbidden
        IR.Analyze=forbidden;Syntax.Parse=forbidden;Compose.Create=forbidden
        local ran,value=pcall(function()
            r=must(pure.LocateFileDiscovery(d,f.capture,f.live))
            return pure.CheckFileDiscovery(r,f.capture,f.live)
        end)
        restore_apis()
        eq(ran,true,"imported modules do not re-read, re-match, rebuild or construct")
        eq(value,true,"read-only proof")
        eq(traps,0,"no forbidden APIs");eq(effects,before_effect,"no replay")
        eq(constructors,before_ctor,"no constructors")
        local hostile=setmetatable({},{__index=forbidden,__tostring=forbidden})
        refuse(function() return pure.LocateFileDiscovery(d,hostile,f.live) end,"unsupported","capture metatable")
        eq(traps,0,"no hostile handlers")
    end)
    restore_apis()
    -- Restore nil saves as well as existing globals.
    for _,n in ipairs({"boss","_editor_class","_tmp_sc","_BOSS_ESCAPE","FILE_TARGET_EFFECT"}) do rawset(_G,n,saved[n]) end
    if not ok then error(problem) end
    for _,label in ipairs(failures) do print("FAIL FileCardTargetSpec: "..label) end
    print(string.format("FileCardTargetSpec: %d passed, %d failed",passed,failed))
    return {passed=passed,failed=failed}
end
return M
