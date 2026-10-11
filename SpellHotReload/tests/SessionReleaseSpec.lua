-- Production session-end lifecycle. Engine handles are stand-ins; only
-- synthetic Lua source is executed. Weak tables verify plugin-owned reachability.
local Hook = require("SpellHotReload.LoadHook")
local Capture = require("SpellHotReload.AnchorLoad")
local Store = require("SpellHotReload.SnapshotStore")
local Registry = require("SpellHotReload.UpvalueRegistry")
local M = {}
local this_file = debug.getinfo(1, "S").source:sub(2)
local bootstrap = this_file:match("^(.*[/\\])") .. "../../__init__.lua"

function M.run()
    local passed, failed, failures = 0, 0, {}
    local function check(value, label)
        if value then passed = passed + 1 else
            failed = failed + 1
            failures[#failures + 1] = label
        end
    end
    local function eq(a, b, label) check(a == b, label) end
    local function pack(...) return {n=select("#", ...), ...} end
    local function weak(value) return setmetatable({value}, {__mode="v"}) end
    local function gc() for _ = 1, 3 do collectgarbage("collect") end end
    local saved_globals, saved_modules = {}, {}
    local globals = {"lstg", "setting", "GameExit", "_release_during_load"}
    local modules = {"lstg.FileSystemWatcher", "lstg.FileSystemWatcher.FileAction",
        "SpellHotReload.Watcher", "SpellHotReload.Plugin", "lib.Ldebug", "SpellHotReload.UI.View"}
    for _, key in ipairs(globals) do saved_globals[key] = rawget(_G, key) end
    for _, key in ipairs(modules) do saved_modules[key] = package.loaded[key] end
    local ok, failure = pcall(function()
        local creates, closes, close_throws = 0, 0, false
        package.loaded["lstg.FileSystemWatcher"] = {create=function()
            creates = creates + 1
            return {read=function() return false end,close=function()
                closes = closes + 1
                if close_throws then error("native close failed") end
            end}
        end}
        package.loaded["lstg.FileSystemWatcher.FileAction"] = {}
        package.loaded["SpellHotReload.Watcher"] = nil
        package.loaded["SpellHotReload.Plugin"] = nil
        local Watcher = require("SpellHotReload.Watcher")
        local Plugin = require("SpellHotReload.Plugin")
        lstg = {Log=function() end,FileManager={EnumFiles=function() return {} end}}
        setting = nil
        local function engine()
            local e = {calls=0}
            e.DoFile = function(filename, ...)
                e.calls = e.calls + 1
                e.args = pack(filename, ...)
                return "original", nil, 3, nil
            end
            e.LoadTextFile = function() return "local value = {}" end
            return e
        end
        local function install(e, callback, options)
            check(Hook.Install(e, callback or function() end,
                options or {select=Hook.BossFile}), "install hook")
        end
        local function stable(store, name, content)
            local c = store:BeginCandidate(name, 1, "test")
            store:RecordFirstRead(name, c.generation, content, 2)
            store:VerifyStable(name, c.generation, content, 4, 2)
            return c.generation
        end

        -- Keep caller-held records intact; Clear does not recycle generation IDs.
        local store = Store.New()
        store:SetAccepted("A_Boss.lua", "baseline")
        local generation = stable(store, "A_Boss.lua", "candidate")
        local record = store:GetCandidate("A_Boss.lua")
        stable(store, "B_Boss.lua", "dismissed")
        store:DismissCandidate("B_Boss.lua")
        check(store:Clear(), "clear snapshots")
        eq(#store:GetAcceptedFileNames(), 0, "clear accepted")
        eq(#store:GetCandidateFileNames(), 0, "clear candidates")
        check(not store:IsDismissed("B_Boss.lua", "dismissed"), "clear rejected bytes")
        eq(record.first_content, "candidate", "caller-held snapshot not mutated")
        check(store:Clear(), "clear idempotent")
        local newer = store:BeginCandidate("A_Boss.lua", 5)
        check(newer.generation > generation, "generation remains monotonic")
        eq(store:RecordFirstRead("A_Boss.lua", generation, "stale", 6), nil, "old ticket refused")

        local registry, map = Registry.New(), {helper=function() return 9 end}
        registry:SetAll("A_Boss.lua", map)
        registry:SetSource("A_Boss.lua", "loaded bytes")
        local held = registry:Get("A_Boss.lua")
        check(registry:Release(), "release legacy registry")
        check(registry:Release(), "legacy release idempotent")
        eq(registry:Get("A_Boss.lua"), nil, "legacy map released")
        eq(registry:GetSource("A_Boss.lua"), nil, "legacy source released")
        eq(held.helper(), 9, "caller-held map not mutated")

        -- A retained watcher handle must drop callbacks/store and stay retired.
        local watcher_store, owner = Store.New(), {}
        local owner_weak, store_weak = weak(owner), weak(watcher_store)
        local function owning_callback(value) return function() return value end end
        local w = Watcher.New({root="virtual",store=watcher_store,
            on_candidate=owning_callback(owner),on_error=owning_callback(owner)})
        check(w:Start(), "watcher started")
        w._pending.A, w._known.A = {first_content="retained bytes"}, true
        owner, watcher_store = nil, nil
        local before_close = closes
        check(w:Release(), "watcher released")
        eq(closes, before_close + 1, "native handle closed once")
        check(w:Release(), "watcher release idempotent")
        eq(closes, before_close + 1, "no double close")
        check(not w:IsRunning(), "watcher stopped")
        eq(w._store, nil, "watcher store detached")
        eq(w._on_candidate, nil, "candidate callback detached")
        eq(w._on_error, nil, "error callback detached")
        eq(next(w._pending), nil, "pending read bytes cleared")
        eq(next(w._known), nil, "known files cleared")
        gc()
        eq(owner_weak[1], nil, "watcher does not retain callback owner")
        eq(store_weak[1], nil, "watcher does not retain snapshot store")
        local before_create, update = creates, w._update
        local started, reason = w:Start()
        eq(started, false, "released watcher cannot restart")
        eq(reason, "watcher released", "restart diagnostic")
        w:update(); w:rescan(); w:baseline(); w:_drift_scan()
        eq(creates, before_create, "retired methods never create handle")
        eq(w._update, update, "retired poll does no work")
        local bytes, read_error = w:ReadFile("A_Boss.lua")
        eq(bytes, nil, "retired read refused")
        eq(read_error, "watcher released", "retired read diagnostic")
        close_throws = true
        local bad = Watcher.New({root="virtual",store=Store.New()})
        check(bad:Start(), "close-error watcher starts")
        check(bad:Release(), "native close failure still retires watcher")
        check(not bad:IsRunning(), "failed native close drops handle")
        close_throws = false

        -- Release all plugin-owned references while an outside consumer is live.
        local p = Plugin.New()
        local entry = assert(Capture.Capture([[local state = {}
local function consumer() return state end]]))
        check(p:AdoptLoad("A_Boss.lua", entry), "adopt complete load")
        local anchors, legacy, snapshots = p:GetAnchors(), p:GetRegistry(), p:GetStore()
        local tool = require("SpellHotReload.UI.View")
        tool:initialize(p)
        p:SetView(tool)
        tool:setEnable(true)
        tool:setEnable(false)
        eq(p:GetLoad("A_Boss.lua"), entry, "closing Tool retains load")
        eq(anchors:Entry("A_Boss.lua"), entry, "closing Tool retains anchor")
        check(not p:IsReleased(), "closing Tool not session end")
        local consumer = entry.map.consumer
        local entry_weak, anchor_weak, policy_weak = weak(entry), weak(entry.anchor), weak(entry.policy)
        local run = {env={registry={state={}}},plan={value=function() end}}
        local run_weak = weak(run)
        p._pending_restart_run = run
        stable(snapshots, "A_Boss.lua", "candidate bytes")
        local pw = Watcher.New({root="virtual",store=snapshots,on_candidate=owning_callback(p)})
        p._watcher, p._activated, p._activation_attempted, p._supported = pw, true, true, true
        check(pw:Start(), "plugin watcher starts")
        p:StopWatching()
        eq(p:GetLoad("A_Boss.lua"), entry, "Stop Watching retains first load")
        eq(anchors:Entry("A_Boss.lua"), entry, "Stop Watching retains anchor")
        check(p:HasRestartPending(), "Stop Watching retains restart plan")
        check(not p:IsReleased(), "Stop Watching not session end")
        p:StartWatching()
        check(p:IsWatching(), "stopped watcher may restart")
        entry, run = nil, nil
        check(p:Release("test exit"), "plugin release")
        check(p:Release("second exit"), "plugin release idempotent")
        check(p:IsReleased(), "plugin tombstone")
        eq(p:GetUnsupportedReason(), "test exit", "first release reason wins")
        check(not p:IsActivated(), "release deactivates")
        check(not p:IsActivationPending(), "release cancels fallback")
        check(not p:IsWatching(), "release stops watcher")
        check(not p:HasRestartPending(), "release clears pending restart")
        eq(p:GetWatcher(), nil, "plugin drops watcher")
        eq(p:GetView(), nil, "plugin drops view")
        eq(p:GetLoad("A_Boss.lua"), nil, "plugin drops full load entry")
        eq(anchors:Entry("A_Boss.lua"), nil, "anchor registry cleared in place")
        eq(legacy:Get("A_Boss.lua"), nil, "legacy registry cleared in place")
        eq(legacy:GetSource("A_Boss.lua"), nil, "source bytes cleared")
        eq(#snapshots:GetCandidateFileNames(), 0, "plugin clears candidate bytes")
        eq(#snapshots:GetAcceptedFileNames(), 0, "plugin clears baseline bytes")
        eq(p:GetLog():Count(), 0, "log references cleared")
        check(type(consumer()) == "table", "outside consumer survives release")
        gc()
        eq(entry_weak[1], nil, "load entry collectible")
        eq(anchor_weak[1], nil, "anchor collectible while consumer survives")
        eq(policy_weak[1], nil, "analysis collectible")
        eq(run_weak[1], nil, "pending restart collectible")
        check(not p:Activate(), "ended plugin cannot activate")
        check(not p:RequestActivation(), "ended plugin cannot request activation")
        p:Tick(); p:_activate(); p:Rescan(); p:StartWatching(); p:StopWatching()
        eq(p:Apply(), "session ended", "ended Apply refused")
        eq(p:_apply(), "session ended", "ended internal Apply refused")
        eq(p:RetryRestart(), "session ended", "ended restart refused")
        check(not p:Dismiss("A_Boss.lua"), "ended dismiss refused")
        check(not p:CaptureAnchor("A", "bytes", {}, {}, function() end), "ended capture refused")
        check(not p:AdoptLoad("A", {loaded_source="bytes"}), "ended adoption refused")
        check(not p:_CheckLoad("A"), "ended absent-entry fallback refused")
        check(not p:_Publish("A", {helper=consumer}), "ended publication refused")
        p:SetView({})
        eq(p:GetView(), nil, "ended plugin cannot acquire view")
        eq(legacy:Get("A"), nil, "guards cannot resurrect legacy values")

        -- Retire a direct hook and preserve original argument/result arity.
        local e, notifications = engine(), 0
        local original = e.DoFile
        install(e, function() notifications = notifications + 1 end)
        local retired_wrapper = e.DoFile
        e.DoFile("A_Boss.lua")
        eq(notifications, 1, "active hook notifies")
        check(Hook.Release(e), "release direct hook")
        eq(e.DoFile, original, "original DoFile restored")
        check(Hook.Release(e), "hook release idempotent")
        local returns = pack(retired_wrapper("A_Boss.lua", false, nil, 7, nil))
        eq(returns.n, 4, "retired wrapper preserves result arity")
        eq(returns[1], "original", "retired wrapper forwards")
        eq(returns[2], nil, "result nil hole preserved")
        eq(returns[3], 3, "later result preserved")
        eq(e.args.n, 5, "argument trailing nil preserved")
        eq(e.args[2], false, "false argument preserved")
        eq(e.args[4], 7, "later argument preserved")
        eq(notifications, 1, "retired wrapper never notifies")
        check(not Hook.Release(nil), "invalid release target refused")
        local boom = {}
        local throwing = {DoFile=function() error(boom, 0) end}
        install(throwing)
        local old_throwing = throwing.DoFile
        Hook.Release(throwing)
        local error_ok, error_value = pcall(old_throwing, "A_Boss.lua")
        eq(error_ok, false, "original errors still thrown")
        eq(error_value, boom, "original error object preserved")

        -- Later wrappers must remain installed, but cannot keep capture owners.
        local chained, owner2 = engine(), {large={}}
        local owner2_weak = weak(owner2)
        install(chained, owning_callback(owner2), {select=owning_callback(owner2),
            read=owning_callback(owner2), capability=owner2, ir_options=owner2})
        local captured = chained.DoFile
        local outer = function(...) return captured(...) end
        chained.DoFile = outer
        owner2 = nil
        gc()
        check(owner2_weak[1] ~= nil, "active configuration holds owner")
        check(Hook.Release(chained), "retire inner hook")
        eq(chained.DoFile, outer, "outer plugin hook not overwritten")
        gc()
        eq(owner2_weak[1], nil, "retired callback and configuration collectible")
        eq(pack(chained.DoFile("A_Boss.lua")).n, 4, "outer chain forwards original")
        local fresh = 0
        install(chained, function() fresh = fresh + 1 end)
        chained.DoFile("A_Boss.lua")
        eq(fresh, 1, "explicit fresh Install begins new session")
        check(Hook.Release(chained), "fresh session releases")
        eq(chained.DoFile, outer, "fresh release restores outer predecessor")

        -- Weak-key-only indices root cycles on Lua 5.1; a lost engine must die.
        local lost, lost_weak = engine(), nil
        lost_weak = weak(lost)
        install(lost)
        lost = nil
        gc()
        eq(lost_weak[1], nil, "index does not root unreachable engine/wrapper cycle")

        -- If a selected body ends the session itself, never adopt or replay it.
        local reentrant = engine()
        local reentrant_calls = 0
        reentrant.LoadTextFile = function()
            return "local x = {}\n_release_during_load()"
        end
        _release_during_load = function() Hook.Release(reentrant) end
        install(reentrant, function() reentrant_calls = reentrant_calls + 1 end)
        reentrant.DoFile("A_Boss.lua")
        eq(reentrant.calls, 0, "release inside successful body never replays original")
        eq(reentrant_calls, 0, "release inside body suppresses adoption")
        reentrant.LoadTextFile = function()
            return "local x = {}\n_release_during_load()\nerror('body failed')"
        end
        install(reentrant, function() reentrant_calls = reentrant_calls + 1 end)
        local ran, why = pcall(reentrant.DoFile, "A_Boss.lua")
        eq(ran, false, "release inside failing body preserves failure")
        check(tostring(why):find("body failed", 1, true), "failing body error unchanged")
        eq(reentrant.calls, 0, "failing body not replayed after release")
        eq(reentrant_calls, 0, "failing body cannot resurrect capture")
        local during_callback = engine()
        install(during_callback, function()
            Hook.Release(during_callback)
            return false, "ignored after retirement"
        end)
        check(pcall(during_callback.DoFile, "A_Boss.lua"), "callback may retire its own hook")
        for _, phase in ipairs({"select", "read"}) do
            local early = engine()
            local options = {select=Hook.BossFile}
            options[phase] = function()
                Hook.Release(early)
                return phase == "select" and "A_Boss.lua" or "local x = {}"
            end
            install(early, function() error("retired hook adopted") end, options)
            eq(pack(early.DoFile("A_Boss.lua")).n, 4, "retirement during " .. phase .. " forwards")
            eq(early.calls, 1, "retirement during " .. phase .. " invokes original once")
        end

        -- Execute the exact proposal/bootstrap with actual Plugin and Watcher.
        local events, instance, view_adds = {}, nil, 0
        local boot = engine()
        local boot_original = boot.DoFile
        boot.plugin = {RegisterEvent=function(group, _, _, fn) events[group] = fn end}
        boot.FileManager = {EnumFiles=function() return {} end}
        boot.Log = function() end
        lstg = boot
        package.loaded["lib.Ldebug"] = {addView=function() view_adds = view_adds + 1 end}
        package.loaded["SpellHotReload.UI.View"] = {initialize=function(_, value) instance = value end}
        Plugin.ResolveRoot = function() return "virtual/mod" end
        local exit_calls, exit_args, fail_exit = 0, nil, false
        GameExit = function(...)
            exit_calls, exit_args = exit_calls + 1, pack(...)
            check(instance:IsReleased(), "cleanup precedes previous GameExit")
            if fail_exit then error(boom, 0) end
            return "exit", nil, false, nil
        end
        assert(loadfile(bootstrap))()
        events.afterTHlib()
        local exit_wrapper = GameExit
        local boot_watcher = instance:GetWatcher()
        events.afterTHlib(); events.afterMod()
        eq(GameExit, exit_wrapper, "bootstrap exit hook installed once")
        eq(view_adds, 1, "bootstrap view installed once")
        boot.DoFile("A_Boss.lua")
        check(instance:GetLoad("A_Boss.lua") ~= nil, "bootstrap hook captures before exit")
        local before_exit_close = closes
        local exit_returns = pack(GameExit(1, nil, false, nil))
        eq(exit_returns.n, 4, "GameExit result arity preserved")
        eq(exit_returns[1], "exit", "GameExit first return preserved")
        eq(exit_returns[3], false, "GameExit false return preserved")
        eq(exit_args.n, 4, "GameExit argument arity preserved")
        eq(exit_args[3], false, "GameExit false argument preserved")
        eq(exit_calls, 1, "previous GameExit called")
        eq(boot.DoFile, boot_original, "bootstrap retires capture")
        eq(instance:GetLoad("A_Boss.lua"), nil, "bootstrap releases load entries")
        eq(closes, before_exit_close + 1, "bootstrap closes watcher once")
        GameExit()
        eq(exit_calls, 2, "second exit still chains previous callback")
        eq(closes, before_exit_close + 1, "second exit cleanup idempotent")
        events.afterTHlib(); events.afterMod(); instance:Tick()
        eq(boot.DoFile, boot_original, "events cannot resurrect ended hook")
        eq(instance:GetWatcher(), nil, "events cannot resurrect ended watcher")
        check(not boot_watcher:Start(), "outside bootstrap watcher handle stays retired")
        fail_exit = true
        local exit_ok, exit_error = pcall(GameExit)
        eq(exit_ok, false, "previous exit failure not swallowed")
        eq(exit_error, boom, "previous exit error object unchanged")

        -- No previous callback is valid too (fallback environments).
        local no_exit_engine = engine()
        no_exit_engine.plugin = boot.plugin
        no_exit_engine.FileManager = boot.FileManager
        lstg, GameExit = no_exit_engine, nil
        assert(loadfile(bootstrap))()
        events.afterTHlib()
        eq(pack(GameExit()).n, 0, "missing previous exit returns zero values")
        check(instance:IsReleased(), "missing previous exit still releases")
    end)
    for _, key in ipairs(globals) do rawset(_G, key, saved_globals[key]) end
    for _, key in ipairs(modules) do package.loaded[key] = saved_modules[key] end
    if not ok then check(false, "uncaught: " .. tostring(failure)) end
    for _, label in ipairs(failures) do print("[SessionReleaseSpec] FAIL " .. label) end
    return {passed=passed,failed=failed,failures=failures}
end

return M
