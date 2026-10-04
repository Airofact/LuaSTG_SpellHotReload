-- First-load snapshot integration. Only miniature synthetic files execute.
local M = {}
function M.run()
    local Capture = require("SpellHotReload.LoadVersions")
    local Hook = require("SpellHotReload.LoadHook")
    local Load = require("SpellHotReload.AnchorLoad")
    local Anchor = require("SpellHotReload.Anchor")
    local Cards = require("SpellHotReload.CardVersions")
    local Source = require("SpellHotReload.FunctionPlan")
    local watcher_key = "SpellHotReload.Watcher"
    local old_watcher = package.loaded[watcher_key]
    local old_plugin = package.loaded["SpellHotReload.Plugin"]
    if not old_watcher then package.loaded[watcher_key] = {} end
    local Plugin = require("SpellHotReload.Plugin")
    package.loaded[watcher_key] = old_watcher
    local passed, failed, failures = 0, 0, {}
    local function check(v, label)
        if v then passed = passed + 1 else
            failed = failed + 1; failures[#failures + 1] = label
        end
    end
    local function eq(a, b, label) check(a == b, label) end
    local function has(v, text, label)
        check(type(v) == "string" and v:find(text, 1, true) ~= nil, label)
    end
    local function must(v, err)
        assert(v, type(err) == "table" and err.message or err); return v
    end
    local function refusal(fn, code, label)
        local value, err = fn()
        eq(value, nil, label .. " refused")
        eq(type(err), "table", label .. " structured")
        if type(err) == "table" then
            eq(err.code, code, label .. " code")
            check(type(err.message) == "string", label .. " message")
        end
    end
    local keys = { "boss", "_editor_class", "_tmp_sc", "_versions_runs", "_versions_api", "lstg" }
    local saved = {}
    for _, key in ipairs(keys) do saved[key] = rawget(_G, key) end
    local saved_join, saved_set, saved_jit = debug.upvaluejoin, debug.setupvalue, rawget(_G, "jit")
    local original_capture = Capture.Capture
    local engines = {}
    local names = { "before", "init", "frame", "render", "beforedel", "del", "after" }
    local defaults = {}
    for _, name in ipairs(names) do defaults[name] = function() return "default" end end
    local caps = { getupvalue = true, setupvalue = true, upvaluejoin = true }
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
    local function reset()
        _versions_runs = 0
        _editor_class = { K = {}, L = {} }
        boss = { card = { _default_card = defaults, New = function(name)
            local card = { name = name, is_combat = true }
            for _, cb in ipairs(names) do card[cb] = defaults[cb] end
            return card
        end }, move = { New = function() return { is_move = true, is_combat = false } end } }
    end
    local function fixture(source)
        reset()
        local entry = must(Load.Capture(source or SOURCE, { capability = caps, name = "Seed_Boss.lua" }))
        entry.file = "Seed_Boss.lua"
        return entry, _editor_class
    end
    local function engine_for(source, plugin)
        reset()
        local engine = { original_calls = 0, logs = {} }
        engine.DoFile = function()
            engine.original_calls = engine.original_calls + 1
            return "original", nil, 3, nil
        end
        engine.LoadTextFile = function() return source or SOURCE end
        engine.Log = function(_, value) engine.logs[#engine.logs + 1] = value end
        engines[#engines + 1] = engine
        must(Hook.Install(engine, function(file, entry) return plugin:AdoptLoad(file, entry) end,
            { select = Hook.BossFile, capability = caps }))
        return engine
    end
    local function pack(...) return { n = select("#", ...), ... } end
    local ok, problem = pcall(function()
        if not saved_join then debug.upvaluejoin = function() error("presence-only fixture") end end
        local entry, classes = fixture()
        local join_calls, write_calls, flush_calls = 0, 0, 0
        debug.upvaluejoin = function() join_calls=join_calls+1;error("premature join") end
        debug.setupvalue = function() write_calls=write_calls+1;error("premature write") end
        _G.jit = { flush = function() flush_calls=flush_calls+1;error("premature flush") end }
        local result = must(Capture.Capture(entry, "session", classes, defaults))
        local snapshot = result.snapshot
        eq(Capture.Kind, "SpellHotReload.LoadVersions", "kind")
        eq(Capture.Version, 1, "version")
        eq(result.kind, Capture.Kind, "capture kind")
        eq(result.version, Capture.Version, "capture version")
        eq(result.classes, classes, "registry identity retained")
        eq(snapshot.entry, entry, "same entry")
        eq(snapshot.anchor, entry.anchor, "same unique anchor")
        eq(snapshot.file, "Seed_Boss.lua", "file retained")
        eq(snapshot.session_id, "session", "session retained")
        eq(snapshot.loaded_source, SOURCE, "load bytes retained")
        eq(snapshot.revision, 0, "initial aggregate revision")
        eq(snapshot.functions.revision, 0, "initial function revision")
        eq(#snapshot.order, 3, "all final combat owners")
        eq(table.concat(snapshot.order, ","), "card:1:K:2,card:1:K:3,card:1:L:1", "final list not textual registration")
        eq(#result.ownership, 2, "both classes retained")
        local ownership = {}
        for _, owner in ipairs(result.ownership) do ownership[owner.class_key] = owner end
        for _, class_key in ipairs({ "K", "L" }) do
            local owner = ownership[class_key]
            eq(owner.class, classes[class_key], "class identity " .. class_key)
            eq(owner.list, classes[class_key].cards, "list identity " .. class_key)
            eq(#owner.slots, #classes[class_key].cards, "complete slots " .. class_key)
            for slot, card in ipairs(owner.slots) do
                eq(card, classes[class_key].cards[slot], "raw owner " .. class_key .. slot)
            end
        end
        for _, key in ipairs(snapshot.order) do
            local unit = snapshot.units[key]
            eq(unit.card, classes[unit.class_key].cards[unit.slot], "first object " .. key)
            eq(unit.definition_version, 1, "first card version " .. key)
            for _, name in ipairs(names) do
                eq(unit.callbacks[name].fn, rawget(unit.card, name), "first callback " .. key .. name)
                eq(unit.callbacks[name].definition_version, 1, "first callback version " .. key .. name)
            end
        end
        for _, name in ipairs(snapshot.functions.names) do
            eq(snapshot.functions.units[name].fn, entry.map[name], "trailer identity " .. name)
        end
        local report = must(Cards.Compare(snapshot, SOURCE))
        eq(#report.changed, 0, "unchanged callbacks")
        eq(#report.functions.changed, 0, "unchanged functions")
        eq(#report.affected, 0, "unchanged impact")
        eq(Cards.Next(must(Cards.Select(report, {}))), snapshot, "empty selection retains initial snapshot")
        local first = snapshot.units["card:1:K:2"]
        local edited = SOURCE:gsub("count%+n", "count+n+10"):gsub("other%(n%) end", "other(n)+7 end")
        local partial = must(Cards.Select(must(Cards.Compare(snapshot, edited)), { first.key }))
        eq(table.concat(partial.functions.selected, ","), "helper", "only necessary function")
        eq(table.concat(partial.pending, ","), "card:1:K:3", "unselected card stays pending")
        eq(first.callbacks.frame.dependencies[1], "alias", "independent alias")
        eq(#partial.publications, 0, "helper-only retains consumer identity")
        local old_default = snapshot.defaults.after
        defaults.after = function() return "changed-default" end
        eq(snapshot.defaults.after, old_default, "defaults frozen")
        defaults.after = old_default
        classes.K.cards = {}
        eq(ownership.K.list[2], first.card, "saved list not live reread")
        eq(ownership.K.slots[2], first.card, "saved slots not live reread")
        classes.K.cards = ownership.K.list
        _versions_api.set(nil)
        eq(Anchor.Get(entry, "count"), nil, "nil ordinary state preserved")
        must(Cards.Compare(snapshot, SOURCE))
        _versions_api.set(false)
        eq(Anchor.Get(entry, "count"), false, "false ordinary state preserved")
        must(Cards.Compare(snapshot, SOURCE))
        eq(join_calls, 0, "no join")
        eq(write_calls, 0, "no setupvalue")
        eq(flush_calls, 0, "no flush")
        eq(_versions_runs, 1, "no initialization replay")
        debug.upvaluejoin, debug.setupvalue, _G.jit = saved_join, saved_set, saved_jit
        if not saved_join then debug.upvaluejoin = function() error("presence-only fixture") end end

        local function bad(label, mutate, code)
            local e, c = fixture()
            mutate(e, c)
            refusal(function() return Capture.Capture(e, "session", c, defaults) end, code, label)
        end
        refusal(function() return Capture.Capture(nil, "session", classes, defaults) end, "unsupported", "missing entry")
        refusal(function() return Capture.Capture(entry, "", classes, defaults) end, "unsupported", "missing session")
        bad("no reload verdict", function(e) e.reloadable=false end, "unsupported")
        bad("missing file", function(e) e.file=nil end, "unsupported")
        bad("missing map", function(e) e.map=nil end, "unsupported")
        bad("missing trailer function", function(e) e.map.helper=nil end, "stale")
        bad("changed trailer function", function(e) e.map.helper=function() end end, "stale")
        bad("live setter not reseeded", function(e)
            must(Anchor.Set(e, "helper", function() return 99 end))
        end, "stale")
        bad("missing class", function(_, c) c.K=nil end, "ownership")
        bad("missing list", function(_, c) c.K.cards=nil end, "ownership")
        bad("extra slot", function(_, c) c.K.cards[4]={} end, "ownership")
        bad("list hole", function(_, c) c.K.cards[2]=nil end, "ownership")
        bad("non-array list key", function(_, c) c.K.cards.extra=true end, "ownership")
        bad("duplicate owner", function(_, c) c.L.cards[1]=c.K.cards[2] end, "ownership")
        bad("not combat", function(_, c) c.K.cards[2].is_combat=false end, "ownership")
        bad("missing callback", function(_, c) c.K.cards[2].render=nil end, "stale")
        bad("changed default", function(_, c) c.K.cards[2].after=function() end end, "stale")
        local metamethod_calls = 0
        local meta = { __index = function() metamethod_calls=metamethod_calls+1;error("metamethod") end }
        bad("class metatable", function(_, c) setmetatable(c.K, meta) end, "ownership")
        bad("list metatable", function(_, c) setmetatable(c.K.cards, meta) end, "ownership")
        bad("card metatable", function(_, c) setmetatable(c.K.cards[2], meta) end, "ownership")
        local e, c = fixture()
        refusal(function() return Capture.Capture(e, "session", setmetatable(c, meta), defaults) end,
            "unsupported", "registry metatable")
        refusal(function() return Capture.Capture(e, "session", c, setmetatable({}, meta)) end,
            "unsupported", "defaults metatable")
        eq(metamethod_calls, 0, "metamethods never invoked")
        setmetatable(c, nil) -- restore the negative registry fixture before capability test
        if not saved_join then
            debug.upvaluejoin = nil
            refusal(function() return Capture.Capture(e, "session", c, defaults) end, "capability", "real Lua5.1 missing join")
            debug.upvaluejoin = function() error("presence-only fixture") end
        end

        local p = Plugin.New()
        local engine = engine_for(SOURCE, p)
        local calls = 0
        Capture.Capture = function(...)
            calls=calls+1; return original_capture(...)
        end
        local returns = pack(engine.DoFile("Seed_Boss.lua"))
        eq(returns.n, 0, "private trailer remains hidden")
        eq(engine.original_calls, 0, "supported initialization not rerun")
        eq(_versions_runs, 1, "hook body once")
        eq(calls, 1, "synchronous seed once")
        local loaded = must(p:GetVersions("Seed_Boss.lua"))
        eq(loaded.snapshot.entry, p:GetLoad("Seed_Boss.lua"), "production load entry")
        eq(loaded.snapshot.file, "Seed_Boss.lua", "basename ownership")
        eq(loaded.snapshot.revision, 0, "production first revision")
        local old_identity = loaded.snapshot.functions.units.helper.fn
        must(p:AdoptLoad("Seed_Boss.lua", p:GetLoad("Seed_Boss.lua")))
        eq(p:GetVersions("Seed_Boss.lua"), loaded, "same-entry query idempotent")
        eq(calls, 1, "same entry never reseeded")
        p:_CaptureVersions("Seed_Boss.lua", p:GetLoad("Seed_Boss.lua"))
        eq(calls, 1, "internal capture cannot be retried")
        local p2 = Plugin.New()
        check(p._session_id ~= p2._session_id, "unique Plugin sessions")
        p:StopWatching()
        p:SetView({})
        eq(p:GetVersions("Seed_Boss.lua"), loaded, "stop/view not session end")
        _versions_api.set(9)
        eq(p:GetVersions("Seed_Boss.lua"), loaded, "setter not new version history")
        eq(loaded.snapshot.functions.units.helper.fn, old_identity, "original identity remains")
        engine.DoFile("Seed_Boss.lua")
        eq(_versions_runs, 2, "explicit second load still executes")
        eq(calls, 1, "second load never reseeds")
        local unavailable, why = p:GetVersions("Seed_Boss.lua")
        eq(unavailable, nil, "repeated load retires versions")
        has(why, "executed again", "repeated load reason")
        eq(loaded.snapshot.functions.units.helper.fn, old_identity, "held old capture not rewritten")
        p:_CaptureVersions("Seed_Boss.lua", p:GetLoad("Seed_Boss.lua"))
        eq(p:GetVersions("Seed_Boss.lua"), nil, "internal capture cannot revive retirement")
        eq(calls, 1, "retired capture not retried")
        p:Release()

        for _, action in ipairs({ "missing", "publish", "release" }) do
            local plugin = Plugin.New()
            local hooked = engine_for(SOURCE, plugin)
            hooked.DoFile("Seed_Boss.lua")
            local first_capture = must(plugin:GetVersions("Seed_Boss.lua"))
            if action == "missing" then must(plugin:Missing("Seed_Boss.lua", "gone"))
            elseif action == "publish" then plugin:_Publish("Seed_Boss.lua", {})
            else plugin:Release("done") end
            local state, reason = plugin:GetVersions("Seed_Boss.lua")
            eq(state, nil, action .. " retires capture")
            check(type(reason) == "string", action .. " reason")
            if action ~= "release" then
                must(plugin:AdoptLoad("Seed_Boss.lua", plugin:GetLoad("Seed_Boss.lua")))
                eq(plugin:GetVersions("Seed_Boss.lua"), nil, action .. " sticky no retry")
            else
                eq(next(plugin._versions), nil, "release clears strong captures")
                eq(plugin._session_id, nil, "release clears session id")
            end
            eq(first_capture.snapshot.revision, 0, action .. " does not forge version")
            plugin:Release()
        end

        for _, fault in ipairs({ "throw", "error-object", "refuse" }) do
            local plugin = Plugin.New()
            local hooked = engine_for(SOURCE, plugin)
            Capture.Capture = function()
                if fault == "throw" then error("metadata-fault") end
                if fault == "error-object" then error(setmetatable({}, {
                    __tostring=function() error("must not stringify thrown object") end })) end
                return nil, setmetatable({}, meta)
            end
            eq(pack(hooked.DoFile("Seed_Boss.lua")).n, 0, fault .. " normal load preserved")
            eq(_versions_runs, 1, fault .. " no replay")
            local state, reason = plugin:GetVersions("Seed_Boss.lua")
            eq(state, nil, fault .. " unavailable")
            check(type(reason) == "string", fault .. " diagnostic")
            Capture.Capture = original_capture
            must(plugin:AdoptLoad("Seed_Boss.lua", plugin:GetLoad("Seed_Boss.lua")))
            eq(plugin:GetVersions("Seed_Boss.lua"), nil, fault .. " no repair from live")
            plugin:Release()
        end
        eq(metamethod_calls, 0, "fault metadata never invokes __index")

        -- The legacy runner can enter Restart inside Commit: baseline must be
        -- retired BEFORE that call, not after Commit returns or only in _Publish.
        local Scanner = require("SpellHotReload.GeneratedBossScanner")
        local Binding = require("SpellHotReload.PracticeBinding")
        local Card = require("SpellHotReload.Card")
        local old_scan, old_keys, old_current, old_replay, old_plan =
            Scanner.Scan, Scanner.ClassKeys, Binding.CaptureCurrent, Binding.IsReplay, Card.Plan
        local apply_ok, apply_error = pcall(function()
            local plugin = Plugin.New()
            engine_for(SOURCE, plugin).DoFile("Seed_Boss.lua")
            local captured = must(plugin:GetVersions("Seed_Boss.lua"))
            plugin._activated, plugin._supported, plugin._sandbox_ok = true, true, true
            local store = plugin:GetStore()
            store:GetCandidateFileNames() -- query is side-effect free
            store.GetCandidateFileNames = function() return { "Seed_Boss.lua" } end
            store.GetCandidate = function() return { stable=true, first_content=SOURCE } end
            plugin._watcher = { ReadFile=function() return SOURCE end, Release=function() end }
            Scanner.Scan = function() return { ok=true } end
            Scanner.ClassKeys = function() return { K=true } end
            local current = { class_key="K", card=captured.snapshot.units["card:1:K:2"].card,
                slot=2, name="A", names={"","A","B"}, include_previous=false }
            Binding.CaptureCurrent = function() return current end
            Binding.IsReplay = function() return false end
            Card.Plan = function() return nil, "prepare fault" end
            has(plugin:_apply(), "prepare fault", "prepare refusal preserved")
            eq(plugin:GetVersions("Seed_Boss.lua"), captured, "prepare failure does not retire")
            Card.Plan = function() return {} end
            local commits = 0
            plugin._driver = { Commit=function()
                commits=commits+1
                eq(plugin:GetVersions("Seed_Boss.lua"), nil, "retired before legacy Commit/Restart")
                return { committed=0, failed={{reason="commit fault"}} }
            end }
            has(plugin:_apply(), "commit fault", "legacy commit refusal preserved")
            eq(commits, 1, "one legacy commit attempt")
            local state, reason = plugin:GetVersions("Seed_Boss.lua")
            eq(state, nil, "failed commit keeps baseline retired")
            has(reason, "legacy Apply attempted", "legacy attempt diagnostic")
            plugin:Release()
        end)
        Scanner.Scan, Scanner.ClassKeys, Binding.CaptureCurrent, Binding.IsReplay, Card.Plan =
            old_scan, old_keys, old_current, old_replay, old_plan
        check(apply_ok, "legacy Apply fixture: " .. tostring(apply_error))

        local plugin = Plugin.New()
        local hooked = engine_for("return 1,nil,3,nil", plugin)
        local returned = pack(hooked.DoFile("Seed_Boss.lua"))
        eq(returned.n, 4, "top return arity")
        eq(returned[1], 1, "top return value")
        eq(returned[2], nil, "top return nil hole")
        eq(returned[3], 3, "top return third")
        eq(returned[4], nil, "top return trailing nil")
        eq(plugin:GetVersions("Seed_Boss.lua"), nil, "refused file not seeded")
        check(plugin:GetLoad("Seed_Boss.lua").reloadable == false, "capture verdict not upgraded")
        plugin:Release()
        Capture.Capture = original_capture
    end)
    for _, engine in ipairs(engines) do Hook.Release(engine) end
    Capture.Capture = original_capture
    package.loaded["SpellHotReload.Plugin"] = old_plugin
    debug.upvaluejoin, debug.setupvalue, _G.jit = saved_join, saved_set, saved_jit
    for _, key in ipairs(keys) do rawset(_G, key, saved[key]) end
    if not ok then check(false, "unexpected error: " .. tostring(problem)) end
    if failed > 0 then for _, message in ipairs(failures) do print("FAIL " .. message) end end
    return { passed = passed, failed = failed }
end
return M
