-- Real first-load integration: LoadHook -> owner contributions -> one capture.
-- Only explicit miniature loads execute; Prepare/Seal below never publishes.
local M={}
function M.run()
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Hook=require("SpellHotReload.Load.LoadHook")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Dependencies=require("SpellHotReload.Pipeline.Dependencies")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Scanner=require("SpellHotReload.Adapters.Card.GeneratedBossScanner")
    local Binding=require("SpellHotReload.Adapters.Card.PracticeBinding")
    local passed,failed,failures=0,0,{}
    local function check(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
    local function has(v,text,label) check(type(v)=="string" and v:find(text,1,true)~=nil,label) end
    local function must(v,e) assert(v,type(e)=="table" and rawget(e,"message") or e);return v end
    local function refusal(fn,code,label)
        local v,e=fn();eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then eq(e.code,code,label.." code");check(type(e.message)=="string",label.." message") end
    end
    local function pack(...) return {n=select("#",...),...} end
    local keys={"boss","_editor_class","_tmp_sc","_versions_runs","_versions_api","lstg","jit"}
    local saved={};for _,key in ipairs(keys) do saved[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local slots={{Local,"Capture"},{Card,"Capture"},{Files,"Capture"},
        {Scanner,"Scan"},{Binding,"CaptureCurrent"},{Binding,"IsReplay"}}
    local methods={};for i,slot in ipairs(slots) do methods[i]=slot[1][slot[2]] end
    local module_keys={"SpellHotReload.Runtime.Plugin","SpellHotReload.Runtime.Watcher"}
    local modules={};for _,key in ipairs(module_keys) do modules[key]=package.loaded[key] end
    local engines,plugins={},{}
    local names={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(names) do defaults[name]=function() return "default" end end
    local SOURCE = table.concat({
        "local count=4", "local flag=false", "local empty",
        "local function helper(n) return count+n end",
        "local function other(n) return n+100 end",
        "local function set(v) count=v end",
        "local function read() return count,flag,empty end",
        "local alias=helper",
        "_versions_runs=_versions_runs+1",
        "_versions_api={set=set,read=read}",
        "_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('Discard',1,2,3,100)",
        "function _tmp_sc:init(n) return other(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end",
        "_tmp_sc.frame=function(self,n) return alias(n) end",
        "_editor_class['K'].cards={boss.move.New(0,0,1),_tmp_sc}",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init(n) return other(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_editor_class['L'].cards={}",
        "_tmp_sc=boss.card.New('C',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n)+100 end",
        "table.insert(_editor_class['L'].cards,_tmp_sc)",
    }, "\n")
    local function restore()
        for i,slot in ipairs(slots) do slot[1][slot[2]]=methods[i] end
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        rawset(_G,"jit",saved.jit)
    end
    local function reset()
        _versions_runs=0;_editor_class={K={},L={}}
        boss={card={_default_card=defaults,New=function(name)
            local card={name=name,is_combat=true};for _,cb in ipairs(names) do card[cb]=defaults[cb] end
            return card
        end},move={New=function() return {is_move=true,is_combat=false} end}}
    end
    local function fixture(content)
        restore();reset()
        local entry=must(Load.Capture(content or SOURCE,{name="Seed_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Seed_Boss.lua"
        return entry,_editor_class
    end
    local function engine_for(content,plugin)
        reset()
        local engine={original_calls=0,logs={}}
        engine.DoFile=function() engine.original_calls=engine.original_calls+1;return "original",nil,3,nil end
        engine.LoadTextFile=function() return content or SOURCE end
        engine.Log=function(_,value) engine.logs[#engine.logs+1]=value end
        engines[#engines+1]=engine
        must(Hook.Install(engine,function(file,entry) return plugin:AdoptLoad(file,entry) end,{select=Hook.BossFile}))
        return engine
    end
    local function group(snapshot,owner)
        for _,g in ipairs(snapshot.owners) do if g.owner==owner then return g end end
        error("real owner group missing")
    end
    local function view(discovery,owner)
        for _,g in ipairs(discovery.reconciliation.groups) do if g.owner==owner then return g.view end end
        error("real reconciliation missing")
    end
    local function fragment(prepared,owner)
        for _,record in ipairs(prepared.entries) do if record.owner==owner then return record.fragment end end
        error("real prepared owner missing")
    end
    local function seal(prepared)
        local fragments={};for _,record in ipairs(prepared.entries) do fragments[#fragments+1]=record.fragment end
        return must(Guard.Seal(prepared.operation,fragments))
    end
    local function no_actions(prepared,label)
        for _,record in ipairs(prepared.entries) do
            local f=record.fragment;eq(#f.joins+#f.cell_writes+#f.raw_writes,0,label.." no installation actions")
        end
        eq(#prepared.dependencies.blocked_roots,0,label.." no blocked root")
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug))) -- Real LuaJIT, never presence-only caps.
        package.loaded[module_keys[1]],package.loaded[module_keys[2]]=nil,{}
        local Plugin=require("SpellHotReload.Runtime.Plugin")
        local function new_plugin() local p=Plugin.New();plugins[#plugins+1]=p;return p end
        local entry,classes=fixture()
        local joins,writes,flushes=0,0,0
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        rawset(_G,"jit",{flush=function() flushes=flushes+1;error("premature flush") end})
        local f=must(Planning.Capture(entry,"session",classes,defaults));local result=f.capture
        local snapshot=result.snapshot;local ls=must(Files.Owner(result,Local)).state
        local cg,initial=Files.Owner(result,Card);must(cg,initial);local cs=cg.state
        eq(Files.Kind,"SpellHotReload.FileCapture","public capture kind")
        eq(Files.Version,1,"public capture protocol");eq(Files.Validate(result),true,"genuine complete capture")
        eq(result.kind,Files.Kind,"actual capture kind");eq(result.version,Files.Version,"actual capture version")
        eq(initial.evidence.classes,classes,"registry identity retained")
        eq(snapshot.entry,entry,"same entry");eq(snapshot.anchor,entry.anchor,"same unique anchor")
        eq(snapshot.file,"Seed_Boss.lua","file retained");eq(snapshot.session_id,"session","session retained")
        eq(snapshot.loaded_source,SOURCE,"full load bytes retained");eq(snapshot.revision,0,"initial common revision")
        eq(#snapshot.owners,2,"both first-load owners adopted")
        eq(#cs.order,3,"all final combat owners")
        eq(table.concat(cs.order,","),"card:1:K:2,card:1:K:3,card:1:L:1","final list not textual registration")
        eq(#initial.evidence.ownership,2,"both complete classes retained")
        local ownership={};for _,owner in ipairs(initial.evidence.ownership) do ownership[owner.class_key]=owner end
        for _,key in ipairs({"K","L"}) do
            local owner=ownership[key];eq(owner.class,classes[key],"class identity "..key)
            eq(owner.list,classes[key].cards,"list identity "..key);eq(#owner.slots,#classes[key].cards,"complete slots "..key)
            for slot,card in ipairs(owner.slots) do eq(card,classes[key].cards[slot],"raw slot "..key..slot) end
        end
        for _,key in ipairs(cs.order) do
            local unit=cs.units[key];eq(unit.card,classes[unit.class_key].cards[unit.slot],"first object "..key)
            eq(unit.definition_version,1,"first card version "..key)
            for _,name in ipairs(names) do
                eq(unit.callbacks[name].fn,rawget(unit.card,name),"first callback "..key..name)
                eq(unit.callbacks[name].definition_version,1,"first callback version "..key..name)
            end
        end
        for _,name in ipairs(ls.names) do
            local unit=ls.by_name[name]
            if unit.binding_kind=="function" then eq(unit.fn,entry.map[name],"original trailer function "..name) end
        end
        local content,generation=SOURCE,0
        local first=cs.units["card:1:K:2"]
        local function refresh()
            return {capture=result,snapshot=result.snapshot,entry=entry,session_id=f.session,classes=classes,
                content=content,generation=generation,binding={class_key="K",card=first.card,slot=2,name="A",
                    names={"","A","B"},mode="practice",include_previous=false}}
        end
        local function discover(bytes)
            content,generation=bytes,generation+1
            return must(Planning.Discover(f,must(Source.Build(bytes)),generation))
        end
        local same=discover(SOURCE)
        eq(#view(same,Local).version_view.changed,0,"unchanged Local definitions")
        local prepared=must(Planning.Prepare(f,same,{mode="file",refresh=refresh}))
        local same_versions=fragment(prepared,Card).card_runtime.version_view
        for _,key in ipairs(cs.order) do eq(same_versions.by_key[key].changed,false,"unchanged callbacks "..key) end
        no_actions(prepared,"unchanged full file");eq(#prepared.dependencies.safe_roots,7,"all four Local and three combat roots safe")
        local sealed=seal(prepared);eq(sealed.proposed_snapshot,snapshot,"unchanged retains actual snapshot")
        eq(next(must(Dependencies.PublicationImpact(sealed.proposed_snapshot,sealed.owner_deltas)).affected),nil,"unchanged impact empty")
        local empty=must(Planning.Prepare(f,discover(SOURCE),{mode="file",root_ids={},refresh=refresh}))
        no_actions(empty,"empty selection");eq(#empty.dependencies.safe_roots,0,"explicit empty roots")
        eq(seal(empty).proposed_snapshot,snapshot,"empty selection retains initial snapshot")
        local edited=SOURCE:gsub("count%+n","count+n+10"):gsub("other%(n%) end","other(n)+7 end")
        -- Original selection was Current-card scoped, not whole-file approval.
        -- The discarded earlier registration remains outside the owned callbacks.
        local changed=discover(edited)
        local partial=must(Planning.Prepare(f,changed,{mode="current",refresh=refresh}))
        eq(#partial.dependencies.blocked_roots,0,"selected Current remains usable")
        eq(#partial.dependencies.safe_roots,1,"only requested Current root safe")
        eq(partial.dependencies.safe_roots[1].root_id,first.key,"exact Current private root")
        local lf,cf=fragment(partial,Local),fragment(partial,Card)
        eq(#lf.cell_writes,1,"only necessary function prepared");eq(lf.cell_writes[1].name,"helper","selected helper only")
        eq(#cf.raw_writes,0,"helper-only retains all callback identities");eq(#cf.card_plan.publications,0,"no callback publication")
        eq(first.callbacks.frame.dependencies[1],"alias","independent alias binding")
        sealed=seal(partial)
        local proposed_local,proposed_card=group(sealed.proposed_snapshot,Local).state,group(sealed.proposed_snapshot,Card).state
        eq(proposed_local.by_name.helper.definition_version,2,"selected helper version proposed")
        eq(proposed_local.by_name.other.fn,ls.by_name.other.fn,"unselected function retained")
        eq(proposed_local.by_name.other.definition_version,1,"unselected function version retained")
        eq(proposed_card.units[first.key].callbacks.init.fn,first.callbacks.init.fn,"consumer callback retained")
        local pending=cs.units["card:1:K:3"]
        eq(proposed_card.units[pending.key],pending,"unselected changed card retained")
        eq(pending.callbacks.init.definition_version,1,"pending actual version unchanged")
        local impact=must(Dependencies.PublicationImpact(sealed.proposed_snapshot,sealed.owner_deltas))
        local described=must(Card.Describe(cf,{operation=partial.operation,snapshot=snapshot,impact=impact,dependencies=partial.dependencies}))
        local rows={};for _,row in ipairs(described.cards) do rows[row.key]=row end
        eq(rows[first.key].selected,true,"Current explicitly selected");eq(rows[first.key].affected,true,"helper affects actual consumer")
        eq(rows[pending.key].pending,true,"unselected card remains pending")
        eq(result.snapshot,snapshot,"Seal never installs proposed common snapshot")
        eq(snapshot.revision,0,"selection does not advance actual revision")
        local old_default=cs.defaults.after;defaults.after=function() return "changed-default" end
        eq(cs.defaults.after,old_default,"defaults frozen");defaults.after=old_default
        classes.K.cards={}
        eq(ownership.K.list[2],first.card,"saved list not live reread");eq(ownership.K.slots[2],first.card,"saved slots not live reread")
        classes.K.cards=ownership.K.list
        for _,value in ipairs({{},{false}}) do
            _versions_api.set(value[1]);eq(Anchor.Get(entry,"count"),value[1],"nil/false ordinary state preserved")
            local again=must(Planning.Prepare(f,discover(SOURCE),{mode="file",refresh=refresh}))
            no_actions(again,"state-only change");eq(seal(again).proposed_snapshot,snapshot,"state is not definition history")
        end
        eq(joins,0,"no join");eq(writes,0,"no setupvalue");eq(flushes,0,"no flush")
        eq(_versions_runs,1,"metadata and preparation do not replay miniature load")
        restore()
        local function capture(e,c,session) return Planning.Capture(e,session==nil and "session" or session,c,defaults) end
        local function bad(label,mutate,code)
            local e,c=fixture();mutate(e,c)
            refusal(function() return capture(e,c) end,code,label)
        end
        refusal(function() return capture(nil,classes) end,"ownership","missing entry")
        refusal(function() return capture(entry,classes,"") end,"ownership","missing session")
        bad("no reload verdict",function(e) e.reloadable=false end,"ownership")
        bad("missing file",function(e) e.file=nil end,"ownership")
        bad("empty file",function(e) e.file="" end,"ownership")
        bad("non-string file",function(e) e.file=7 end,"ownership")
        bad("missing map",function(e) e.map=nil end,"ownership")
        bad("missing trailer function",function(e) e.map.helper=nil end,"stale")
        bad("changed trailer function",function(e) e.map.helper=function() end end,"stale")
        bad("live setter not reseeded",function(e) must(Anchor.Set(e,"helper",function() return 99 end)) end,"stale")
        bad("missing class",function(_,c) c.K=nil end,"ownership")
        bad("missing list",function(_,c) c.K.cards=nil end,"ownership")
        bad("extra slot",function(_,c) c.K.cards[4]={} end,"ownership")
        bad("list hole",function(_,c) c.K.cards[2]=nil end,"ownership")
        bad("non-array list key",function(_,c) c.K.cards.extra=true end,"ownership")
        bad("duplicate owner",function(_,c) c.L.cards[1]=c.K.cards[2] end,"ownership")
        bad("not combat",function(_,c) c.K.cards[2].is_combat=false end,"ownership")
        bad("missing callback",function(_,c) c.K.cards[2].render=nil end,"stale")
        bad("changed default",function(_,c) c.K.cards[2].after=function() end end,"stale")
        local metamethod_calls=0
        local meta={__index=function() metamethod_calls=metamethod_calls+1;error("hostile index") end,
            __tostring=function() metamethod_calls=metamethod_calls+1;error("hostile tostring") end}
        bad("map metatable",function(e) e.map=setmetatable({},meta) end,"ownership")
        bad("class metatable",function(_,c) setmetatable(c.K,meta) end,"ownership")
        bad("list metatable",function(_,c) setmetatable(c.K.cards,meta) end,"ownership")
        bad("card metatable",function(_,c) setmetatable(c.K.cards[2],meta) end,"ownership")
        local e,c=fixture()
        refusal(function() return capture(e,setmetatable(c,meta)) end,"ownership","registry metatable")
        setmetatable(c,nil)
        refusal(function() return Planning.Capture(e,"session",c,setmetatable({},meta)) end,"ownership","defaults metatable")
        eq(metamethod_calls,0,"metamethods never invoked")
        local p=new_plugin();local engine=engine_for(SOURCE,p)
        local calls={0,0,0}
        for i=1,3 do
            local index=i;slots[i][1][slots[i][2]]=function(...) calls[index]=calls[index]+1;return methods[index](...) end
        end
        local returned=pack(engine.DoFile("mod/DiMS/Seed_Boss.lua"))
        eq(returned.n,0,"private trailer remains hidden");eq(engine.original_calls,0,"supported load not rerun")
        eq(_versions_runs,1,"hook body once")
        for i=1,3 do eq(calls[i],1,"synchronous complete contribution "..i) end
        local loaded=must(p:GetVersions("Seed_Boss.lua"));local loaded_local=must(Files.Owner(loaded,Local)).state
        check(loaded~=result and loaded.snapshot~=snapshot,"independent loads have separate common captures")
        check(loaded_local.by_name.helper.fn~=ls.by_name.helper.fn,"independent load owns a different helper function")
        eq(result.snapshot,snapshot,"production load never replaces earlier capture")
        eq(loaded.snapshot.entry,p:GetLoad("Seed_Boss.lua"),"production original load entry")
        eq(loaded.snapshot.file,"Seed_Boss.lua","basename ownership");eq(loaded.snapshot.revision,0,"production first revision")
        local old_identity=loaded_local.by_name.helper.fn
        must(p:AdoptLoad("Seed_Boss.lua",p:GetLoad("Seed_Boss.lua")))
        p:_CaptureVersions("Seed_Boss.lua",p:GetLoad("Seed_Boss.lua"))
        eq(p:GetVersions("Seed_Boss.lua"),loaded,"same entry keeps exact capture")
        for i=1,3 do eq(calls[i],1,"same entry no recapture "..i) end
        local accepted=p:AdoptLoad("",p:GetLoad("Seed_Boss.lua"));eq(accepted,false,"Plugin rejects empty file name")
        local p2=new_plugin();check(p._session_id~=p2._session_id,"unique Plugin sessions")
        p:StopWatching();p:SetView({});eq(p:GetVersions("Seed_Boss.lua"),loaded,"stop/view not session end")
        _versions_api.set(9);eq(p:GetVersions("Seed_Boss.lua"),loaded,"setter not new version history")
        eq(loaded_local.by_name.helper.fn,old_identity,"original function identity remains")
        engine.DoFile("mod/DiMS/Seed_Boss.lua")
        eq(_versions_runs,2,"explicit second load executes")
        local unavailable,why=p:GetVersions("Seed_Boss.lua")
        eq(unavailable,nil,"repeated load retires capture");has(why,"executed again","repeat diagnostic")
        eq(loaded_local.by_name.helper.fn,old_identity,"held original capture unchanged")
        p:_CaptureVersions("Seed_Boss.lua",p:GetLoad("Seed_Boss.lua"))
        eq(p:GetVersions("Seed_Boss.lua"),nil,"retirement cannot be revived")
        for i=1,3 do eq(calls[i],1,"second load never contributes "..i) end
        must(p:Release());restore()
        for _,action in ipairs({"missing","release"}) do
            local plugin=new_plugin();local hooked=engine_for(SOURCE,plugin);hooked.DoFile("Seed_Boss.lua")
            local first_capture=must(plugin:GetVersions("Seed_Boss.lua"))
            if action=="missing" then must(plugin:Missing("Seed_Boss.lua","gone")) else must(plugin:Release("done")) end
            local state,reason=plugin:GetVersions("Seed_Boss.lua")
            eq(state,nil,action.." retires capture");check(type(reason)=="string",action.." diagnostic")
            if action=="missing" then
                local retries=0;Local.Capture=function() retries=retries+1;error("late capture") end
                must(plugin:AdoptLoad("Seed_Boss.lua",plugin:GetLoad("Seed_Boss.lua")))
                plugin:_CaptureVersions("Seed_Boss.lua",plugin:GetLoad("Seed_Boss.lua"));restore()
                eq(retries,0,"Missing cannot retry capture");eq(plugin:GetVersions("Seed_Boss.lua"),nil,"Missing sticky")
            else eq(next(plugin._versions),nil,"Release clears strong captures");eq(plugin._session_id,nil,"Release clears session") end
            eq(first_capture.snapshot.revision,0,action.." held snapshot unchanged");must(plugin:Release())
        end
        for _,fault in ipairs({"throw","error-object","refuse","empty-refuse"}) do
            local plugin=new_plugin();local hooked=engine_for(SOURCE,plugin)
            local marker=setmetatable({},meta);local attempts=0
            Local.Capture=function()
                attempts=attempts+1
                if fault=="throw" then error("metadata-fault") end
                if fault=="error-object" then error(marker) end
                if fault=="refuse" then return nil,marker end
                return nil,nil
            end
            eq(pack(hooked.DoFile("Seed_Boss.lua")).n,0,fault.." normal load preserved")
            eq(_versions_runs,1,fault.." no replay");eq(hooked.original_calls,0,fault.." no engine fallback")
            local state,reason=plugin:GetVersions("Seed_Boss.lua");eq(state,nil,fault.." unavailable")
            if fault=="refuse" then eq(reason,marker,"explicit opaque refusal retained")
            elseif fault=="empty-refuse" then eq(reason,nil,"explicit absent reason retained")
            else eq(reason,"first-load contribution capture threw; restart game",fault.." safe fixed diagnostic") end
            eq(#hooked.logs,0,fault.." metadata refusal not logged through Hook tostring")
            -- Keep the spy installed so a mistaken late retry is observable.
            must(plugin:AdoptLoad("Seed_Boss.lua",plugin:GetLoad("Seed_Boss.lua")))
            plugin:_CaptureVersions("Seed_Boss.lua",plugin:GetLoad("Seed_Boss.lua"))
            eq(attempts,1,fault.." verdict sticky");local retained,retained_reason=plugin:GetVersions("Seed_Boss.lua")
            eq(retained,nil,fault.." no partial adopted capture");eq(retained_reason,reason,fault.." original reason retained")
            restore();must(plugin:Release())
        end
        eq(metamethod_calls,0,"fault metadata never invokes metamethods")
        -- Real missing capability refuses reload after one normal load; no shim.
        local disabled=new_plugin();local denied=engine_for(SOURCE,disabled)
        debug.upvaluejoin=nil
        local capability_returns=pack(denied.DoFile("Seed_Boss.lua"));restore()
        eq(capability_returns.n,0,"capability refusal hides trailer");eq(_versions_runs,1,"capability-refused file executes once")
        eq(denied.original_calls,0,"capability refusal no fallback replay")
        eq(disabled:GetLoad("Seed_Boss.lua").reloadable,false,"actual missing join denies reload")
        has(disabled:GetLoad("Seed_Boss.lua").reason,"capability","actual capability diagnostic")
        eq(disabled:GetVersions("Seed_Boss.lua"),nil,"capability-refused load not upgraded");must(disabled:Release())
        -- Preflight refusal must preserve actual capture and never prepare/commit.
        local plugin=new_plugin();engine_for(SOURCE,plugin).DoFile("Seed_Boss.lua")
        local captured=must(plugin:GetVersions("Seed_Boss.lua"));local state=must(Files.Owner(captured,Card)).state
        plugin._activated,plugin._supported,plugin._sandbox_ok=true,true,true
        local store=plugin:GetStore();local ticket=store:BeginCandidate("Seed_Boss.lua",0,"spec")
        must(store:RecordFirstRead("Seed_Boss.lua",ticket.generation,SOURCE,1))
        must(store:VerifyStable("Seed_Boss.lua",ticket.generation,SOURCE,2,1))
        plugin._watcher={ReadFile=function() return "stale disk" end,Release=function() end}
        Scanner.Scan=function() return {ok=true} end
        Binding.CaptureCurrent=function() return {class_key="K",card=state.units["card:1:K:2"].card,
            slot=2,name="A",names={"","A","B"},mode="practice",include_previous=false} end
        Binding.IsReplay=function() return false end
        local prepares,commits=0,0
        plugin._driver.PrepareDiscovery=function() prepares=prepares+1;error("unexpected preparation") end
        plugin._driver.CommitDiscovery=function() commits=commits+1;error("unexpected publication") end
        has(plugin:_apply(),"versioned UI scope","direct API lacks phase token")
        eq(plugin:GetVersions("Seed_Boss.lua"),captured,"phase refusal retains capture")
        has(plugin:ApplyFromUI(),"candidate generation or bytes changed","real UI stale disk refusal")
        eq(plugin:GetVersions("Seed_Boss.lua"),captured,"preflight refusal retains actual capture")
        eq(captured.snapshot.revision,0,"preflight refusal never advances revision")
        eq(prepares,0,"preflight never prepares");eq(commits,0,"preflight never publishes")
        restore();must(plugin:Release())
        local top=new_plugin();local hooked=engine_for("return 1,nil,3,nil",top)
        local values=pack(hooked.DoFile("Seed_Boss.lua"))
        eq(values.n,4,"top return arity");eq(values[1],1,"top first value");eq(values[2],nil,"top nil hole")
        eq(values[3],3,"top third value");eq(values[4],nil,"top trailing nil")
        eq(hooked.original_calls,0,"top return no second engine execution")
        eq(top:GetVersions("Seed_Boss.lua"),nil,"refused file not captured")
        eq(top:GetLoad("Seed_Boss.lua").reloadable,false,"original reload verdict retained");must(top:Release())
    end)
    restore()
    for _,engine in ipairs(engines) do local released=Hook.Release(engine);eq(released,true,"Hook released") end
    for _,plugin in ipairs(plugins) do local released=plugin:Release("LoadVersionsSpec complete");eq(released,true,"Plugin released") end
    for _,key in ipairs(module_keys) do package.loaded[key]=modules[key] end
    for _,key in ipairs(keys) do rawset(_G,key,saved[key]) end
    if not ok then check(false,"unexpected: "..(type(problem)=="string" and problem or "opaque error")) end
    for _,label in ipairs(failures) do print("FAIL LoadVersionsSpec: "..label) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
