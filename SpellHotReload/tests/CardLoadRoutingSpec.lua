-- Genuine Local/Class/Card first-load contributions and Card-owned current routing.
-- Synthetic FIRST loads only; dispatch spies never claim transaction/engine coverage.
local M = {}
function M.run()
    local Card = require("SpellHotReload.Adapters.Card.Card")
    local Binding = require("SpellHotReload.Adapters.Card.PracticeBinding")
    local Scanner = require("SpellHotReload.Adapters.Card.GeneratedBossScanner")
    local Local = require("SpellHotReload.Adapters.Local.Local")
    local ClassAdapter=require("SpellHotReload.Adapters.Class.Class")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local Files = require("SpellHotReload.Pipeline.FileVersions")
    local Planning = require("SpellHotReload.tests.PlanningFixture")
    local Source = require("SpellHotReload.Source.FileAnalysis")
    local Load = require("SpellHotReload.Adapters.Class.ClassLoad")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local environment
    local passed, failed, failures = 0, 0, {}
    local function check(v, label)
        if v then passed = passed + 1 else failed = failed + 1; failures[#failures + 1] = label end
    end
    local function eq(a, b, label) check(rawequal(a, b), label) end
    local function has(v, part, label)
        check(type(v) == "string" and v:find(part, 1, true) ~= nil, label)
    end
    local keys = {"boss", "_editor_class", "_tmp_sc", "_adapter_seed_runs"}
    local globals = {}
    for _, key in ipairs(keys) do globals[key] = rawget(_G, key) end
    local original_current, original_replay = Binding.CaptureCurrent, Binding.IsReplay
    local original_scan = Scanner.Scan
    local saved_set, saved_join, saved_jit = debug.setupvalue, debug.upvaluejoin, rawget(_G, "jit")
    local defaults = {}
    local metamethods = 0
    local hostile = setmetatable({}, {
        __index=function() metamethods=metamethods+1;error("unsafe index") end,
        __tostring=function() metamethods=metamethods+1;error("unsafe tostring") end,
    })
    local function must(v,e) assert(v,type(e)=="table" and rawget(e,"message") or e);return v end
    local ok, problem = pcall(function()
        -- Count only this fixture's explicit first execution, never whole-game init.
        for _, cb in ipairs({"before","init","frame","render","beforedel","del","after"}) do
            defaults[cb] = function() end
        end
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        rawset(_G, "_adapter_seed_runs", 0)
        rawset(_G, "_editor_class", {K={}})
        boss.card={_default_card=defaults, New=function(name)
            local card={name=name,is_combat=true}
            for cb, fn in next, defaults do card[cb]=fn end
            return card
        end}
        local source = table.concat({
            "local state=3", "local function helper(n) return state+n end",
            "_adapter_seed_runs=_adapter_seed_runs+1",
            "_editor_class['K']=Class(_object)","_editor_class['K'].cards={}",
            "_tmp_sc=boss.card.New('Live',1,2,3,100)",
            "function _tmp_sc:init(n) return helper(n) end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)",
        }, "\n")
        local loaded = assert(Load.Capture(source, {name="Adapter_Boss.lua"}))
        loaded.file = "Adapter_Boss.lua"
        eq(_adapter_seed_runs, 1, "real synthetic initialization once")
        local card = _editor_class.K.cards[1]
        local old_init, old_helper = card.init, loaded.map.helper
        debug.setupvalue = function() error("metadata must not write") end
        debug.upvaluejoin = saved_join and function() error("metadata must not join") end or nil
        rawset(_G, "jit", {flush=function() error("metadata must not flush") end})
        local f = must(Planning.Capture(loaded, "real:session", _editor_class, defaults))
        environment:FinishLoad()
        local captured = f.capture
        local local_group = must(Files.GetAdapterRecords(captured, Local))
        local card_group = must(Files.GetAdapterRecords(captured, Card))
        eq(#captured.snapshot.owners, 3, "complete Local/Class/Card capture")
        eq(local_group.state.by_name.helper.fn, old_helper, "original Local function identity")
        eq(card_group.state.units["card:1:K:1"].card, card, "original Card identity")
        eq(card_group.state.providers.helper, local_group.state.by_name.helper.unit_ref, "Card stores canonical Local reference")
        eq(captured.snapshot.revision, 0, "real first revision")
        eq(card.init, old_init, "metadata does not publish")
        eq(loaded.map.helper, old_helper, "metadata preserves original map")
        eq(_adapter_seed_runs, 1, "metadata never reruns initialization")
        debug.setupvalue, debug.upvaluejoin = saved_set, saved_join
        rawset(_G, "jit", saved_jit)

        local value, reason
        local current = {class_key="K",card=card,slot=1,names={"Live"}}
        local error_object = {}
        Binding.CaptureCurrent = function() return current, error_object end
        value, reason = Card.CaptureCurrent()
        eq(value, current, "current query delegates without caching/copying")
        eq(reason, error_object, "current query second result preserved")
        Binding.CaptureCurrent = function() return nil, "no practice" end
        value, reason = Card.CaptureCurrent()
        eq(value, nil, "current query refusal")
        eq(reason, "no practice", "current query diagnostic")
        for _, replay in ipairs({false,true}) do
            Binding.IsReplay = function() return replay end
            eq(Card.IsReplay(), replay, "replay query " .. tostring(replay))
        end
        local scan_marker = {}
        Scanner.Scan = function(content, file)
            eq(content, "bytes", "format gate exact bytes")
            eq(file, "Adapter_Boss.lua", "format gate file")
            return scan_marker
        end
        eq(Card.CheckCandidateSource("bytes", "Adapter_Boss.lua"), scan_marker, "format verdict unchanged")
        Scanner.Scan = original_scan
        for _, input in ipairs({
            {"-- Generated by LuaSTG Editor Sharp\n",true},
            {"\239\187\191-- Generated by LuaSTG Editor Sharp\n",true},
            {"print('unsupported')",false},
            {"-- Generated by LuaSTG Editor Sharp\n\0",false},
        }) do
            eq(Card.CheckCandidateSource(input[1], "F_Boss.lua").ok, input[2], "real format gate")
        end
        local discovery = must(Planning.Discover(f, must(Source.Build(source)), 1))
        check(discovery.snapshot.by_key["local:helper"] ~= nil, "complete discovery keeps Local")
        eq(Card.DefinesCurrent(discovery, {class_key="K"}), true, "complete discovered current class")
        eq(Card.DefinesCurrent(discovery, {class_key="Other"}), false, "other class not routed")
        local comments = "-- _editor_class['Ghost'].cards={}\nlocal note=\"_editor_class['Ghost'].cards={}\"\n"
        local unrelated = must(f.driver:Discover("Other_Boss.lua", must(Source.Build(comments)),
            {session_id=f.session,generation=2}))
        eq(Card.DefinesCurrent(unrelated, {class_key="Ghost"}), false, "comments/strings do not route")
        local old_only=must(Planning.Discover(f,must(Source.Build(
            "local state=3\nlocal function helper(n) return state+n end")),2))
        eq(Card.DefinesCurrent(old_only,current,captured),true,"captured old-only current still routes")
        eq(Card.DefinesCurrent(old_only,current,nil),false,"old-only route needs actual capture")
        eq(Card.DefinesCurrent(old_only,{class_key="K",slot=2,card=card},captured),false,"old-only wrong slot refused")
        eq(Card.DefinesCurrent(old_only,{class_key="K",slot=1,card={}},captured),false,"old-only wrong Card refused")
        eq(Card.DefinesCurrent(old_only,{class_key="Other",slot=1,card=card},captured),false,"old-only wrong class refused")
        eq(_adapter_seed_runs, 1, "discovery/query never execute candidate")
        local descriptor=must(FileMatch.ForOwner(discovery.snapshot,Card,discovery.source)).by_class.K.layout[1]
        local marker=assert(discovery.snapshot.by_key[descriptor.unit.key])
        eq(Card.DefinesCurrent(discovery, {class_key="K"}), true, "repeated query")
        eq(discovery.snapshot.by_key[descriptor.unit.key], marker, "single-card discovery retained")
    end)
    Binding.CaptureCurrent, Binding.IsReplay = original_current, original_replay
    Scanner.Scan = original_scan
    debug.setupvalue, debug.upvaluejoin = saved_set, saved_join
    rawset(_G, "jit", saved_jit)
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: " .. tostring(problem) end

    -- Real Plugin adoption and direct contributors; fault spies replace only the
    -- selected seam and always restore it. Dispatch is intercepted before publish.
    local module_keys = {"SpellHotReload.Runtime.Plugin","SpellHotReload.Runtime.Watcher"}
    local modules = {}
    for _, key in ipairs(module_keys) do modules[key]=package.loaded[key] end
    package.loaded[module_keys[1]], package.loaded[module_keys[2]] = nil, {}
    local methods = {"CaptureCurrent","IsReplay","CheckCandidateSource","DefinesCurrent"}
    local originals, counts = {}, {}
    for _, method in ipairs(methods) do originals[method], counts[method] = Card[method], 0 end
    local contributors = {{Local,"Capture"},{ClassAdapter,"Capture"},{Card,"Capture"},{Files,"Capture"}}
    local captures = {Local.Capture,ClassAdapter.Capture,Card.Capture,Files.Capture}
    local function with_capture(overrides,body)
        for i,slot in ipairs(contributors) do slot[1][slot[2]]=overrides[i] or captures[i] end
        local ran,why=pcall(body)
        for i,slot in ipairs(contributors) do slot[1][slot[2]]=captures[i] end
        if not ran then error(why,0) end
    end
    local plugins = {}
    local wired, werr = pcall(function()
        local Plugin = require("SpellHotReload.Runtime.Plugin")
        local function new_plugin()
            local p=Plugin.New();plugins[#plugins+1]=p;return p
        end
        local callbacks={"before","init","frame","render","beforedel","del","after"}
        for _,cb in ipairs(callbacks) do defaults[cb]=function() end end
        local bytes=table.concat({"local state=3","local function helper(n) return state+n end",
            "_editor_class['K']=Class(_object)","_editor_class['K'].cards={}","_tmp_sc=boss.card.New('Live',1,2,3,100)",
            "function _tmp_sc:init(n) return helper(n) end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
        local function first_load(file)
            if environment then environment:Restore() end
        environment=ClassFixture.Install()
        local classes={K={}};local saved_defaults={}
            for _,cb in ipairs(callbacks) do saved_defaults[cb]=defaults[cb] end
            rawset(_G,"_editor_class",classes)
            boss.card={_default_card=saved_defaults,New=function(name)
                local card={name=name,is_combat=true}
                for _,cb in ipairs(callbacks) do card[cb]=saved_defaults[cb] end
                return card
            end}
            return must(Load.Capture(bytes,{name=file})),classes,saved_defaults
        end
        local file = "Dispatch_Boss.lua"
        local p=new_plugin()
        local first,classes,first_defaults=first_load(file)
        local order,local_piece,class_piece,card_piece={},nil,nil,nil
        local shared_snapshot
        with_capture({
            function(e,s,snapshot)
                shared_snapshot=snapshot
                order[#order+1]="local"
                eq(e,first,"Local receives genuine adopted entry");eq(e.file,file,"common file assigned")
                eq(s,p._session_id,"Local receives owned session")
                local_piece=must(captures[1](e,s,snapshot));return local_piece
            end,
            function(e,s,lp,snapshot)
                order[#order+1]="class"
                eq(e,first,"Class receives genuine entry");eq(s,p._session_id,"Class session")
                eq(lp,local_piece,"Class receives original Local contribution")
                eq(snapshot,shared_snapshot,"Class consumes same completed discovery")
                class_piece=must(captures[2](e,s,lp,snapshot));return class_piece
            end,
            function(e,s,lp,cp,c,d,snapshot)
                order[#order+1]="card"
                eq(e,first,"Card receives same entry");eq(s,p._session_id,"Card receives same session")
                eq(lp,local_piece,"Card receives original Local contribution")
                eq(c,classes,"Plugin reads current registry");eq(d,first_defaults,"Plugin reads raw saved defaults")
                eq(cp,class_piece,"Card receives original Class contribution")
                eq(snapshot,shared_snapshot,"Card consumes same completed discovery")
                card_piece=must(captures[3](e,s,lp,cp,c,d,snapshot));return card_piece
            end,
            function(e,s,pieces)
                order[#order+1]="file"
                eq(e,first,"File receives same entry");eq(s,p._session_id,"File receives same session")
                eq(#pieces,3,"File receives complete contribution set")
                eq(pieces[1],local_piece,"Local contribution identity");eq(pieces[2],class_piece,"Class contribution identity");eq(pieces[3],card_piece,"Card contribution identity")
                return captures[4](e,s,pieces)
            end,
        },function()
            must(p:AdoptLoad(file,first))
            environment:FinishLoad()
            p:_CaptureVersions(file,first);must(p:AdoptLoad(file,first))
        end)
        eq(table.concat(order,","),"local,class,card,file","synchronous complete adoption exactly once")
        local capture=must(p:GetVersions(file))
        eq(Files.Validate(capture),true,"Plugin stores genuine common capture")
        eq(#capture.snapshot.owners,3,"Plugin keeps all three real owners")
        eq(capture.snapshot.entry,first,"common capture retains first load")

        -- A later independent adoption reads its own registry/defaults, never a cache.
        local other=new_plugin();local e2,c2,d2=first_load("Independent_Boss.lua")
        with_capture({[3]=function(e,s,lp,cp,c,d,snapshot)
            eq(c,c2,"no Plugin registry cache");eq(d,d2,"no Plugin defaults cache")
            return captures[3](e,s,lp,cp,c,d,snapshot)
        end},function() must(other:AdoptLoad("Independent_Boss.lua",e2)) end)
        check(other:GetVersions("Independent_Boss.lua")~=capture,"independent capture/session")
        for _,kind in ipairs({"absent","non-table","inherited-card","inherited-default"}) do
            local refused=new_plugin();local entry=first_load(file)
            if kind=="absent" then rawset(_G,"boss",nil)
            elseif kind=="non-table" then rawset(_G,"boss",false)
            elseif kind=="inherited-card" then rawset(_G,"boss",hostile)
            else rawset(_G,"boss",{card=hostile}) end
            local reason={message="standard defaults unavailable"};local calls=0
            with_capture({[3]=function(e,s,lp,cp,c,d,snapshot)
                calls=calls+1;eq(d,nil,kind.." does not invent defaults");return nil,reason
            end,[4]=function() error("partial Card refusal must not reach Files") end},function()
                must(refused:AdoptLoad(file,entry))
                local value,why=refused:GetVersions(file)
                eq(value,nil,kind.." no partial capture");eq(why,reason,kind.." reason identity")
                refused:_CaptureVersions(file,entry)
                eq(calls,1,kind.." refusal sticky")
            end)
        end
        -- Every contributor can refuse or throw. A completed earlier contribution
        -- cannot become an adopted partial ledger or be reconstructed on retry.
        for stage=1,4 do
            for _,fault in ipairs({"string","object","empty","throw-string","throw-object"}) do
                local refused=new_plugin();local entry=first_load(file)
                local called={0,0,0,0};local reason
                if fault=="string" then reason="plain refusal"
                elseif fault=="object" then reason=setmetatable({message="raw refusal"},getmetatable(hostile))
                else reason=hostile end
                local overrides={};local stored_reason
                for i=1,4 do
                    local index=i
                    overrides[i]=function(...)
                        called[index]=called[index]+1
                        if index~=stage then return captures[index](...) end
                        if fault=="throw-string" then error("metadata fixture") end
                        if fault=="throw-object" then error(hostile) end
                        return nil,reason
                    end
                end
                with_capture(overrides,function()
                    eq(refused:AdoptLoad(file,entry),true,"metadata fault is not load failure")
                    local value,why=refused:GetVersions(file);stored_reason=why
                    eq(value,nil,"no partial owner adoption")
                    if fault=="throw-string" or fault=="throw-object" then
                        eq(why,"first-load contribution capture threw; restart game","safe thrown category")
                    else eq(why,reason,"structured/string/opaque refusal retained without coercion") end
                end)
                -- Restore real contributors before retry: sticky failure cannot seed late.
                local retries={0,0,0,0};local retry_spies={}
                for i=1,4 do
                    local index=i
                    retry_spies[i]=function() retries[index]=retries[index]+1;error("sticky capture retry") end
                end
                with_capture(retry_spies,function()
                    refused:_CaptureVersions(file,entry);must(refused:AdoptLoad(file,entry))
                    local value,why=refused:GetVersions(file)
                    eq(value,nil,"sticky failure not retried");eq(why,stored_reason,"original sticky verdict retained")
                end)
                for i=1,4 do eq(retries[i],0,"no contributor retried after failure") end
                for i=1,4 do eq(called[i],i<=stage and 1 or 0,"capture stage boundary") end
            end
        end
        eq(metamethods,0,"Plugin raw extraction and fault handling invoke no hostile metamethods")

        local current = {class_key="K",card=classes.K.cards[1],slot=1,name="Live",names={"Live"}}
        local discovery = {snapshot={by_key={}}} -- deliberately empty; adapter decides routing
        local candidate = {stable=true,generation=1,first_content=bytes}
        p._activated,p._supported,p._sandbox_ok = true,true,true
        p._store = {GetCandidateFileNames=function() return {file} end,GetCandidate=function() return candidate end,
            Clear=function() end}
        p._watcher = {ReadFile=function() return candidate.first_content end,Release=function() end}
        local discoveries=0
        p._DiscoverVersioned = function(self,f,c,cap,facts)
            discoveries=discoveries+1
            eq(f,file,"discovery file");eq(c,candidate,"discovery candidate")
            eq(cap,capture,"discovery actual capture")
            eq(Source.Validate(facts),true,"discovery receives complete FileAnalysis")
            eq(facts.content,candidate.first_content,"discovery receives exact candidate bytes")
            return discovery
        end
        p._CheckLoad = function() return true end
        p._commit.Check = function() return true end
        p._ApplyVersioned = function(self, token, f, c, cap, d, b)
            eq(f, file, "versioned dispatch file");eq(cap, capture, "versioned dispatch capture")
            eq(d, discovery, "complete discovery dispatch");eq(b.card, current.card, "current live identity dispatch")
            return "versioned adapter dispatch"
        end
        Card.CaptureCurrent = function() counts.CaptureCurrent=counts.CaptureCurrent+1;return current end
        Card.IsReplay = function() counts.IsReplay=counts.IsReplay+1;return false end
        Card.CheckCandidateSource = function(content, f)
            counts.CheckCandidateSource=counts.CheckCandidateSource+1
            eq(content, candidate.first_content, "controller delegates source bytes")
            eq(f, file, "controller delegates source file");return {ok=true}
        end
        Card.DefinesCurrent = function(d, b, cap)
            counts.DefinesCurrent=counts.DefinesCurrent+1
            eq(d, discovery, "controller delegates complete route input")
            eq(cap,capture,"controller delegates genuine capture for old-only routing")
            eq(b.class_key, "K", "controller delegates current class");return true
        end
        Binding.CaptureCurrent = function() error("controller must use Card current query") end
        Binding.IsReplay = function() error("controller must use Card replay query") end
        Scanner.Scan = function() error("controller must use Card format rule") end
        eq(p:_apply({}), "versioned adapter dispatch", "Plugin versioned dispatch consumes adapter route")
        for _, method in ipairs({"CaptureCurrent","IsReplay","CheckCandidateSource","DefinesCurrent"}) do
            check(counts[method]>0, "actual Plugin consumes " .. method)
        end
        Card.DefinesCurrent = function() return false end
        eq(p:_apply({}), "no stable candidate defines the current class", "adapter route refusal stops Apply")
        Card.CheckCandidateSource = function() return {ok=false,error="adapter source refused"} end
        local before=discoveries
        eq(p:_apply({}), "no stable candidate defines the current class", "adapter source refusal stops discovery")
        eq(discoveries,before,"rejected format cannot enter discovery")
        Card.IsReplay = function() return true end
        eq(p:_apply({}), "replay mode not supported", "adapter replay refusal retained")
    end)
    for i,slot in ipairs(contributors) do slot[1][slot[2]]=captures[i] end
    for _, method in ipairs(methods) do Card[method] = originals[method] end
    Binding.CaptureCurrent, Binding.IsReplay = original_current, original_replay
    Scanner.Scan = original_scan
    for _, p in ipairs(plugins) do p:Release() end
    for _, key in ipairs(module_keys) do package.loaded[key]=modules[key] end
    if environment then environment:Restore() end
    for _, key in ipairs(keys) do rawset(_G, key, globals[key]) end
    if not wired then failed=failed+1;failures[#failures+1]="controller unexpected: " .. tostring(werr) end
    print(string.format("CardLoadRoutingSpec: %d passed / %d failed", passed, failed))
    for _, failure in ipairs(failures) do print("  FAIL: " .. failure) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
