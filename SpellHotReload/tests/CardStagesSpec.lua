-- Versioned Card stage inputs, real miniature capture and production preparation.
-- Candidate bytes/initializers/bodies never execute; no game source or UI run.
-- Lua5.1 uses a presence-only join fixture for read-only plans, not shared proof.
local M = {}
local serial = 0
function M.run()
    local Card = require("SpellHotReload.Adapters.Card.Card")
    local Driver = require("SpellHotReload.Pipeline.Driver")
    local Load = require("SpellHotReload.Load.AnchorLoad")
    local Versions = require("SpellHotReload.Adapters.Card.Card")
    local Cards = require("SpellHotReload.Adapters.Card.CardVersions")
    local Target = require("SpellHotReload.Adapters.Card.CardTarget")
    local Callbacks = require("SpellHotReload.Adapters.Card.CardCallbacks")
    local Binding = require("SpellHotReload.Adapters.Card.PracticeBinding")
    local Restart=require("SpellHotReload.Runtime.CurrentRestart")
    local Anchor = require("SpellHotReload.Load.Anchor")
    local passed, failed, failures = 0, 0, {}
    local function check(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v,e end
    local function copy(v) local r={};for k,x in next,v do r[k]=x end;return r end
    local function refuse(call,phase,label,value)
        local ok,v,e=pcall(call)
        eq(ok,true,label.." no throw");eq(v,value,label.." refused")
        eq(type(e),"table",label.." structured error")
        if type(e)=="table" then
            eq(e.phase,phase,label.." phase")
            check(type(e.code)=="string",label.." code")
            check(type(e.message)=="string",label.." message")
        end
        return e
    end
    local keys={"boss","_editor_class","_tmp_sc","_stages_runs","jit"}
    local globals={};for _,key in ipairs(keys) do globals[key]=rawget(_G,key) end
    local join,set=debug.upvaluejoin,debug.setupvalue
    local locate,inject=Card.Locate,Card.Inject
    local publish,restart=Callbacks.Publish,Restart.Handoff
    local resolve,compare=Target.Resolve,Cards.CompareLocated
    local modules={}
    local module_keys={"SpellHotReload.Runtime.Plugin","SpellHotReload.Runtime.Watcher"}
    for _,key in ipairs(module_keys) do modules[key]=package.loaded[key] end
    local mutations,traps=0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("hostile read") end,
        __newindex=function() traps=traps+1;error("hostile write") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end})
    local defaults={}
    for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
        defaults[name]=function() end
    end
    local function source(helper,bump)
        return table.concat({
            "local state=4",
            "local function helper(n) return state+n+"..helper.." end",
            "_stages_runs=_stages_runs+1",
            "_editor_class['K'].cards={}",
            "_tmp_sc=boss.card.New('A',1,2,3,4)",
            "function _tmp_sc:init(n) return helper(n)+"..bump.." end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)",
            "_tmp_sc=boss.card.New('B',1,2,3,4)",
            "function _tmp_sc:init(n) return helper(n)+20 end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)",
            "_editor_class['L'].cards={}",
            "_tmp_sc=boss.card.New('Side',1,2,3,4)",
            "function _tmp_sc:init() return 44 end",
            "table.insert(_editor_class['L'].cards,_tmp_sc)",
        },"\n")
    end
    local function fixture()
        serial=serial+1
        _stages_runs=0;_editor_class={K={},L={}}
        boss={card={_default_card=defaults,New=function(label)
            local card={name=label,is_combat=true}
            for name,fn in next,defaults do card[name]=fn end
            return card
        end}}
        debug.upvaluejoin=join or function() error("presence-only fixture") end
        local entry=must(Load.Capture(source(0,10),{name="Stages_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Stages_Boss.lua"
        local capture=must(Versions.SeedVersions(entry,"stages:"..serial,_editor_class,defaults))
        local base=capture.snapshot
        local bytes=source(7,15)
        local driver=Driver.New();assert(driver:RegisterDiscovery(Card))
        local discovery=must(driver:DiscoverPublished(entry.file,bytes,assert(require("SpellHotReload.Adapters.Card.CardVersions").Publication(base)),{
            session_id=base.session_id,registry_entry=entry,loaded_source=base.loaded_source,
            base_revision=base.revision,published_units=base,candidate_generation=3}))
        local initial={class_key="K",card=_editor_class.K.cards[1],slot=1,
            name="A",names={"A","B"},mode="practice",include_previous=false}
        local live={capture=capture,snapshot=base,entry=entry,classes=_editor_class,
            session_id=base.session_id,content=bytes,binding=initial}
        local refreshes=0
        local function refresh() refreshes=refreshes+1;return live end
        local unit,context=must(Card.RuntimeContext(capture,discovery,initial,live,refresh))
        return {entry=entry,capture=capture,base=base,bytes=bytes,driver=driver,
            discovery=discovery,initial=initial,live=live,refresh=refresh,unit=unit,context=context,
            refreshes=function() return refreshes end}
    end
    local function ban()
        local function mutation() mutations=mutations+1;error("premature mutation") end
        debug.upvaluejoin,debug.setupvalue=mutation,mutation
        rawset(_G,"jit",{flush=mutation})
        Callbacks.Publish,Restart.Handoff=mutation,mutation
    end
    local ok,problem=pcall(function()
        local f=fixture()
        local entry=f.discovery.snapshot.by_key["card:K"]
        eq(f.unit,entry.unit,"actual complete discovered unit")
        eq(f.context.common,entry.context.common,"same common identity")
        eq(f.context.adapter.file,entry.context.adapter.file,"same file context")
        eq(f.context.adapter.unit,entry.unit.context,"same unit context")
        eq(entry.context.adapter.runtime,nil,"discovery never mutated")
        eq(#f.discovery.snapshot.entries,2,"unselected class retained")
        eq(f.context.adapter.runtime.capture,f.capture,"explicit capture")
        eq(f.context.adapter.runtime.discovery,f.discovery,"explicit discovery")
        eq(f.context.adapter.runtime.snapshot,f.base,"actual published snapshot")
        eq(f.context.adapter.runtime.initial,f.initial,"explicit frozen current root")
        eq(f.context.adapter.runtime.proof,f.live,"explicit caller proof")
        eq(f.context.adapter.runtime.refresh,f.refresh,"explicit refresh")
        local unit,context=must(Card.RuntimeContext(f.capture,f.discovery,f.initial,f.live,f.refresh))
        eq(unit,f.unit,"no rediscovery")
        check(context~=f.context and context.adapter.runtime~=f.context.adapter.runtime,
            "per-call runtime contexts are independent")
        for _,which in ipairs({"capture","discovery","initial","proof","refresh"}) do
            local args={f.capture,f.discovery,f.initial,f.live,f.refresh}
            local positions={capture=1,discovery=2,initial=3,proof=4,refresh=5}
            args[positions[which]]=hostile
            refuse(function() return Card.RuntimeContext(unpack(args)) end,"locate",
                "runtime bridge "..which)
        end
        local absent={snapshot={common=f.context.common,by_key={}}}
        refuse(function() return Card.RuntimeContext(f.capture,absent,f.initial,f.live,f.refresh) end,
            "locate","runtime bridge absent owner")
        local foreign=copy(entry);foreign.adapter={}
        local wrong={snapshot={common=f.context.common,by_key={["card:K"]=foreign}}}
        refuse(function() return Card.RuntimeContext(f.capture,wrong,f.initial,f.live,f.refresh) end,
            "locate","runtime bridge foreign adapter")
        local original_init=f.initial.card.init
        local helper=Anchor.Get(f.entry,"helper")
        ban()
        local handle=must(Card.Locate(f.unit,f.context))
        eq(handle.unit,f.unit,"locate consumes full unit")
        eq(handle.context,f.context,"locate preserves explicit context")
        eq(handle.location.entry,entry,"location retains registered entry")
        eq(handle.location.discovery,f.discovery.snapshot,"location full snapshot")
        eq(handle.target.key,"card:1:K:1","published root not source class key")
        eq(f.refreshes(),1,"one fresh read per locate")
        local selection=must(Card.Inject(handle,f.unit,f.context))
        eq(selection.kind,"SpellHotReload.CardVersions.Selection","real selection output")
        eq(selection.discovery,f.discovery.snapshot,"selection retains full discovery")
        eq(table.concat(selection.selected,","),"card:1:K:1","only current root selected")
        eq(table.concat(selection.functions.selected,","),"helper","necessary shared definition")
        check(#selection.publications>0 and #selection.joins>0 and #selection.writes>0,
            "real deferred raw/join/cell operations")
        eq(f.refreshes(),1,"inject does not invent another refresh")
        eq(f.capture.snapshot,f.base,"no premature version install")
        eq(f.initial.card.init,original_init,"no premature raw publication")
        eq(Anchor.Get(f.entry,"helper"),helper,"no premature function cell write")
        eq(Anchor.Get(f.entry,"state"),4,"ordinary state retained")
        eq(_stages_runs,1,"candidate initialization never replayed")
        eq(Card.Restart,nil,"adapter restart hook removed")
        for _,method in ipairs({"Commit"}) do
            local phase=method:lower()
            for _,mode in ipairs({"context","handle","selection"}) do
                local h=mode=="handle" and handle or {request={card=f.initial.card}}
                local p=mode=="selection" and selection or {restart={class_key="K",card=f.initial.card}}
                local ctx=mode=="context" and f.context or {}
                refuse(function() return Card[method](h,p,ctx) end,phase,
                    "no legacy "..phase.." via "..mode,false)
            end
        end
        refuse(function() return Card.Inject(handle,f.unit,context) end,"inject","foreign call context")
        refuse(function() return Card.Inject(handle,copy(f.unit),f.context) end,"inject","copied unit")
        refuse(function() return Card.Inject(handle,f.unit,{}) end,"inject","lost context")
        for _,field in ipairs({"unit","context","runtime","capture","snapshot","discovery","entry",
            "initial","proof","refresh","target","live","location"}) do
            local bad=copy(handle);bad[field]=hostile
            refuse(function() return Card.Inject(bad,f.unit,f.context) end,"inject","handle "..field)
        end
        for _,bad in ipairs({false,1,"bad",hostile}) do
            local ctx={common=f.context.common,adapter={runtime=bad}}
            refuse(function() return Card.Locate(f.unit,ctx) end,"locate","malformed runtime")
            refuse(function() return Card.Inject(handle,f.unit,ctx) end,"inject","malformed inject context")
        end
        local runtime=f.context.adapter.runtime
        for _,field in ipairs({"capture","snapshot","discovery","initial","proof","refresh"}) do
            local before=runtime[field];runtime[field]=hostile
            refuse(function() return Card.Locate(f.unit,f.context) end,"locate","runtime "..field)
            refuse(function() return Card.Inject(handle,f.unit,f.context) end,"inject","changed runtime "..field)
            runtime[field]=before
        end
        for _,bad in ipairs({false,{},hostile}) do
            local before=f.initial.class_key;f.initial.class_key=bad
            refuse(function() return Card.Locate(f.unit,f.context) end,"locate","non-string class key")
            refuse(function() return Card.Inject(handle,f.unit,f.context) end,"inject","non-string inject class key")
            f.initial.class_key=before
        end
        f.initial.class_key=nil
        refuse(function() return Card.Locate(f.unit,f.context) end,"locate","nil class key")
        f.initial.class_key="K"
        for _,field in ipairs({"file","unit"}) do
            local before=f.context.adapter[field];f.context.adapter[field]={}
            refuse(function() return Card.Locate(f.unit,f.context) end,"locate","context "..field)
            f.context.adapter[field]=before
        end
        local before=f.capture.snapshot;f.capture.snapshot={}
        refuse(function() return Card.Inject(handle,f.unit,f.context) end,"inject","publication snapshot changed")
        f.capture.snapshot=before
        local original_entry=f.discovery.snapshot.by_key["card:K"]
        f.discovery.snapshot.by_key["card:K"]=copy(original_entry)
        local e=refuse(function() return Card.Inject(handle,f.unit,f.context) end,"inject","entry identity replaced")
        eq(e.file,"Stages_Boss.lua","refusal file diagnostic")
        eq(e.unit_key,"card:K","refusal source coordinate")
        f.discovery.snapshot.by_key["card:K"]=original_entry
        runtime.refresh=function() runtime.initial.class_key=nil;return f.live end
        refuse(function() return Card.Locate(f.unit,f.context) end,"locate","refresh invalidates context")
        runtime.initial.class_key="K"
        runtime.refresh=function() return hostile end
        refuse(function() return Card.Locate(f.unit,f.context) end,"locate","malformed fresh view")
        runtime.refresh=function() return nil,hostile end
        e=refuse(function() return Card.Locate(f.unit,f.context) end,"locate","fresh refusal")
        eq(e.stage,"versioned preflight","preflight diagnostic category preserved")
        eq(e.message,"operation refused","preflight hostile error safe")
        runtime.refresh=f.refresh
        f.live.content=f.bytes.."\n"
        e=refuse(function() return Card.Inject(handle,f.unit,f.context) end,"inject","fresh byte disagreement")
        eq(e.code,"stale","service error code preserved")
        eq(e.stage,"compare","service stage preserved")
        f.live.content=f.bytes
        local calls={locate=0,inject=0}
        Card.Locate=function(u,c)
            calls.locate=calls.locate+1
            eq(u,f.unit,"production stage gets real unit")
            eq(c.common,f.discovery.snapshot.common,"production stage gets common")
            eq(c.adapter.runtime.capture,f.capture,"production stage explicit capture")
            return locate(u,c)
        end
        Card.Inject=function(h,u,c)
            calls.inject=calls.inject+1
            eq(h.unit,u,"production inject unit")
            eq(h.context,c,"production inject same context")
            return inject(h,u,c)
        end
        local prepared=must(Card.PrepareVersioned(f.capture,f.discovery,f.initial,f.live,f.refresh))
        eq(calls.locate,1,"PrepareVersioned really calls Locate")
        eq(calls.inject,1,"PrepareVersioned really calls Inject")
        eq(prepared.target.key,"card:1:K:1","prepared shape compatible")
        eq(prepared.location.discovery,f.discovery.snapshot,"prepared discovery compatible")
        -- Actual Plugin preparation call site, real downstream services. No commit or UI.
        package.loaded[module_keys[1]],package.loaded[module_keys[2]]=nil,{}
        local Plugin=require("SpellHotReload.Runtime.Plugin")
        local p=setmetatable({_loads={[f.entry.file]=f.entry},_session_id=f.base.session_id,
            _commit={Poisoned=function() return false end}},Plugin)
        p._FreshVersioned=function(self,file,candidate,capture)
            eq(file,f.entry.file,"Plugin retains physical file")
            eq(candidate.first_content,f.bytes,"Plugin retains exact bytes")
            eq(capture,f.capture,"Plugin retains adopted capture")
            return f.live
        end
        prepared=must(p:_PrepareVersioned(f.entry.file,{first_content=f.bytes},f.capture,f.discovery,f.initial))
        eq(calls.locate,2,"Plugin production preparation calls Locate")
        eq(calls.inject,2,"Plugin production preparation calls Inject")
        eq(prepared.selection.discovery,f.discovery.snapshot,"Plugin complete discovery retained")
        Card.Locate=function() return nil,hostile end
        local v,why=Card.PrepareVersioned(f.capture,f.discovery,f.initial,f.live,f.refresh)
        eq(v,nil,"unexpected Locate refusal preserved")
        eq(why,"locate: operation refused","unexpected Locate error safely formatted")
        Card.Locate=locate;Card.Inject=function() return nil,hostile end
        v,why=Card.PrepareVersioned(f.capture,f.discovery,f.initial,f.live,f.refresh)
        eq(v,nil,"unexpected Inject refusal preserved")
        eq(why,"inject: operation refused","unexpected Inject error safely formatted")
        Card.Inject=inject
        Target.Resolve=function() return nil,{code="ownership",message="explicit resolve refusal"} end
        e=refuse(function() return Card.Locate(f.unit,f.context) end,"locate","resolve structured failure")
        eq(e.code,"ownership","resolve code preserved");eq(e.stage,"locate","resolve stage preserved")
        Target.Resolve=resolve
        Cards.CompareLocated=function() return nil,hostile end
        e=refuse(function() return Card.Inject(handle,f.unit,f.context) end,"inject","hostile service error")
        eq(e.message,"operation refused","service error never stringifies object")
        Cards.CompareLocated=compare
        eq(mutations,0,"all versioned preparation and legacy guard paths read-only")
        eq(traps,0,"malformed context/errors never run metamethods")
        eq(entry.context.adapter.runtime,nil,"no runtime stored in shared discovery")
        eq(f.capture.snapshot,f.base,"versioned preparation remains uncommitted")
        eq(_stages_runs,1,"all preparation avoids candidate top level")
    end)
    Card.Locate,Card.Inject=locate,inject
    Target.Resolve,Cards.CompareLocated=resolve,compare
    Callbacks.Publish,Restart.Handoff=publish,restart
    debug.upvaluejoin,debug.setupvalue=join,set
    for _,key in ipairs(module_keys) do package.loaded[key]=modules[key] end
    for _,key in ipairs(keys) do rawset(_G,key,globals[key]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..tostring(problem) end
    print(string.format("CardStagesSpec: %d passed / %d failed",passed,failed))
    for _,label in ipairs(failures) do print("  FAIL: "..label) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
