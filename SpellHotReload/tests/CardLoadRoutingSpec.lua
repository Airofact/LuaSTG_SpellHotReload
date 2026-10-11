-- Card-owned first-load metadata and current-class routing. Synthetic inputs only.
-- Existing LoadVersions/VersionedApply suites retain real capture/commit coverage.
local M = {}
function M.run()
    local Card = require("SpellHotReload.Adapters.Card.Card")
    local Binding = require("SpellHotReload.Adapters.Card.PracticeBinding")
    local Scanner = require("SpellHotReload.Adapters.Card.GeneratedBossScanner")
    local Driver = require("SpellHotReload.Pipeline.Driver")
    local Load = require("SpellHotReload.Load.AnchorLoad")
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
    local original_capture = Card.SeedVersions
    local original_current, original_replay = Binding.CaptureCurrent, Binding.IsReplay
    local original_scan = Scanner.Scan
    local saved_set, saved_join, saved_jit = debug.setupvalue, debug.upvaluejoin, rawget(_G, "jit")
    local entry = {file="Adapter_Boss.lua", loaded_source="original", map={}}
    local snapshot = {marker="original snapshot"}
    local classes, defaults = {}, {}
    local metadata_calls, metamethods = 0, 0
    local hostile = setmetatable({}, {
        __index=function() metamethods=metamethods+1;error("unsafe index") end,
        __tostring=function() metamethods=metamethods+1;error("unsafe tostring") end,
    })
    local ok, problem = pcall(function()
        rawset(_G, "_editor_class", classes)
        rawset(_G, "boss", {card={_default_card=defaults}})
        Card.SeedVersions = function(e, session, c, d)
            metadata_calls = metadata_calls + 1
            eq(e, entry, "original load entry consumed")
            eq(session, "adapter:session", "session explicit")
            eq(c, classes, "class registry read at call")
            eq(d, defaults, "defaults read at call")
            return snapshot
        end
        local value, reason = Card.CaptureVersions(entry, "adapter:session")
        eq(value, snapshot, "original metadata identity returned")
        eq(reason, nil, "success reason")
        eq(metadata_calls, 1, "single metadata handoff")
        local second_classes, second_defaults = {}, {}
        rawset(_G, "_editor_class", second_classes)
        rawset(_G, "boss", {card={_default_card=second_defaults}})
        Card.SeedVersions = function(e, session, c, d)
            eq(c, second_classes, "no adapter registry cache")
            eq(d, second_defaults, "no adapter defaults cache")
            return snapshot
        end
        eq(Card.CaptureVersions(entry, "another"), snapshot, "independent caller/session")
        for _, kind in ipairs({"absent", "non-table", "inherited-card", "inherited-default"}) do
            if kind == "absent" then rawset(_G, "boss", nil)
            elseif kind == "non-table" then rawset(_G, "boss", false)
            elseif kind == "inherited-card" then rawset(_G, "boss", hostile)
            else rawset(_G, "boss", {card=hostile}) end
            Card.SeedVersions = function(e, s, c, d)
                eq(d, nil, kind .. " does not invent defaults")
                return nil, {message="standard defaults unavailable"}
            end
            value, reason = Card.CaptureVersions(entry, "session")
            eq(value, nil, kind .. " refused")
            eq(reason, "standard defaults unavailable", kind .. " reason retained")
        end
        for _, fault in ipairs({"string", "object", "empty", "throw-string", "throw-object"}) do
            Card.SeedVersions = function()
                if fault == "throw-string" then error("metadata fixture") end
                if fault == "throw-object" then error(hostile) end
                if fault == "string" then return nil, "plain refusal" end
                if fault == "object" then return nil, setmetatable({message="raw refusal"}, getmetatable(hostile)) end
                return nil, hostile
            end
            value, reason = Card.CaptureVersions(entry, "session")
            eq(value, nil, fault .. " metadata unavailable")
            local expected = ({string="plain refusal", object="raw refusal", empty="first-load metadata unavailable",
                ["throw-string"]="first-load metadata failed:", ["throw-object"]="first-load metadata failed: non-string error"})[fault]
            has(reason, expected, fault .. " safe reason")
        end
        Card.SeedVersions = original_capture
        local version_key = "SpellHotReload.Source.FunctionVersions"
        local held_module, held_preload = package.loaded[version_key], package.preload[version_key]
        package.loaded[version_key] = nil
        package.preload[version_key] = function() error("lazy metadata import fixture") end
        value, reason = Card.CaptureVersions(entry, "session")
        package.loaded[version_key], package.preload[version_key] = held_module, held_preload
        eq(value, nil, "lazy import fault is metadata refusal")
        has(reason, "first-load metadata failed:", "lazy import fault category")
        has(reason, "lazy metadata import fixture", "lazy import fault diagnostic")
        eq(metamethods, 0, "metadata never invokes hostile metamethods")
        Card.SeedVersions = original_capture
        -- Real miniature initialization once, then real adapter metadata capture.
        -- Lua5.1 really lacks join and is refused, not granted shared support.
        for _, cb in ipairs({"before","init","frame","render","beforedel","del","after"}) do
            defaults[cb] = function() end
        end
        rawset(_G, "_adapter_seed_runs", 0)
        rawset(_G, "_editor_class", {K={}})
        rawset(_G, "boss", {card={_default_card=defaults, New=function(name)
            local card={name=name,is_combat=true}
            for cb, fn in next, defaults do card[cb]=fn end
            return card
        end}})
        local source = table.concat({
            "local state=3", "local function helper(n) return state+n end",
            "_adapter_seed_runs=_adapter_seed_runs+1",
            "_editor_class['K'].cards={}",
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
        local captured, why = Card.CaptureVersions(loaded, "real:session")
        if saved_join then
            check(captured ~= nil, "real shared first load captured")
            if captured then
                eq(captured.snapshot.functions.units.helper.fn, old_helper, "original trailer function identity")
                eq(captured.snapshot.units["card:1:K:1"].card, card, "original card identity")
                eq(captured.snapshot.revision, 0, "real first revision")
            end
        else
            eq(captured, nil, "real Lua5.1 missing join refused")
            has(why, "first load", "real Lua5.1 refusal reason")
        end
        eq(card.init, old_init, "metadata does not publish")
        eq(loaded.map.helper, old_helper, "metadata preserves original map")
        eq(_adapter_seed_runs, 1, "metadata never reruns initialization")
        debug.setupvalue, debug.upvaluejoin = saved_set, saved_join
        rawset(_G, "jit", saved_jit)

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
        local driver = Driver.New()
        assert(driver:RegisterDiscovery(Card))
        local discovery = assert(driver:Discover("Adapter_Boss.lua", source))
        eq(Card.DefinesCurrent(discovery, {class_key="K"}), true, "complete discovered current class")
        eq(Card.DefinesCurrent(discovery, {class_key="Other"}), false, "other class not routed")
        local comments = "-- _editor_class['Ghost'].cards={}\nlocal note=\"_editor_class['Ghost'].cards={}\"\n"
        local unrelated = assert(driver:Discover("Other_Boss.lua", comments))
        eq(Card.DefinesCurrent(unrelated, {class_key="Ghost"}), false, "comments/strings do not route")
        eq(_adapter_seed_runs, 1, "discovery/query never execute candidate")
        local marker = discovery.snapshot.by_key["card:K"]
        eq(Card.DefinesCurrent(discovery, {class_key="K"}), true, "repeated query")
        eq(discovery.snapshot.by_key["card:K"], marker, "discovery retained")
    end)
    Card.SeedVersions = original_capture
    Binding.CaptureCurrent, Binding.IsReplay = original_current, original_replay
    Scanner.Scan = original_scan
    debug.setupvalue, debug.upvaluejoin = saved_set, saved_join
    rawset(_G, "jit", saved_jit)
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: " .. tostring(problem) end

    -- Real Plugin call sites, fake capture/commit for dispatch only.
    local module_keys = {"SpellHotReload.Runtime.Plugin","SpellHotReload.Runtime.Watcher"}
    local modules = {}
    for _, key in ipairs(module_keys) do modules[key]=package.loaded[key] end
    package.loaded[module_keys[1]], package.loaded[module_keys[2]] = nil, {}
    local methods = {"CaptureVersions","CaptureCurrent","IsReplay","CheckCandidateSource","DefinesCurrent"}
    local originals, counts = {}, {}
    for _, method in ipairs(methods) do originals[method], counts[method] = Card[method], 0 end
    local plugins = {}
    local wired, werr = pcall(function()
        local Plugin = require("SpellHotReload.Runtime.Plugin")
        local file = "Dispatch_Boss.lua"
        local capture = {snapshot={revision=0}}
        local first = {loaded_source="original",map={},reloadable=false}
        local p = Plugin.New();plugins[#plugins+1] = p
        Card.CaptureVersions = function(e, s)
            counts.CaptureVersions = counts.CaptureVersions+1
            eq(e, first, "Plugin adapter receives adopted entry")
            eq(e.file, file, "Plugin keeps common file identity")
            eq(s, p._session_id, "Plugin adapter receives owned session")
            return capture
        end
        eq(p:AdoptLoad(file, first), true, "Plugin adoption preserved")
        eq(p:GetVersions(file), capture, "Plugin stores adapter capture")
        p:_CaptureVersions(file, first)
        p:AdoptLoad(file, first)
        eq(counts.CaptureVersions, 1, "Plugin owns once-only rule")
        local refusal = Plugin.New();plugins[#plugins+1] = refusal
        Card.CaptureVersions = function() return nil, "adapter metadata refusal" end
        eq(refusal:AdoptLoad(file, {loaded_source="original",map={},reloadable=false}), true, "metadata refusal not load failure")
        local value, why = refusal:GetVersions(file)
        eq(value, nil, "Plugin sticky adapter refusal")
        eq(why, "adapter metadata refusal", "Plugin refusal stored")
        Card.CaptureVersions = function() error("sticky capture cannot retry") end
        refusal:_CaptureVersions(file, refusal:GetLoad(file))
        eq(refusal:GetVersions(file), nil, "sticky refusal not retried")

        local current = {class_key="K",card={},slot=1,name="Live",names={"Live"}}
        local discovery = {snapshot={by_key={}}} -- deliberately empty; adapter decides routing
        local candidate = {stable=true,generation=1,first_content="candidate"}
        p._activated,p._supported,p._sandbox_ok = true,true,true
        p._store = {GetCandidateFileNames=function() return {file} end,GetCandidate=function() return candidate end,
            Clear=function() end}
        p._watcher = {ReadFile=function() return candidate.first_content end,Release=function() end}
        p._driver = {Discover=function() return discovery end}
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
        Card.DefinesCurrent = function(d, b)
            counts.DefinesCurrent=counts.DefinesCurrent+1
            eq(d, discovery, "controller delegates complete route input")
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
        eq(p:_apply({}), "no stable candidate defines the current class", "adapter source refusal stops discovery")
        Card.IsReplay = function() return true end
        eq(p:_apply({}), "replay mode not supported", "adapter replay refusal retained")
    end)
    for _, method in ipairs(methods) do Card[method] = originals[method] end
    Binding.CaptureCurrent, Binding.IsReplay = original_current, original_replay
    Scanner.Scan = original_scan
    for _, p in ipairs(plugins) do p:Release() end
    for _, key in ipairs(module_keys) do package.loaded[key]=modules[key] end
    for _, key in ipairs(keys) do rawset(_G, key, globals[key]) end
    if not wired then failed=failed+1;failures[#failures+1]="controller unexpected: " .. tostring(werr) end
    print(string.format("CardLoadRoutingSpec: %d passed / %d failed", passed, failed))
    for _, failure in ipairs(failures) do print("  FAIL: " .. failure) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
