-- Normal-load replacement tests. No generated game source is executed.
local Hook = require("SpellHotReload.Load.LoadHook")
local Capture = require("SpellHotReload.Load.AnchorLoad")
local Loader = require("SpellHotReload.GeneratedBossLoader")
local watcher_name = "SpellHotReload.Watcher"
local old_watcher = package.loaded[watcher_name]
if not old_watcher then package.loaded[watcher_name] = {} end
local Plugin = require("SpellHotReload.Plugin")
local Watcher = package.loaded[watcher_name]
package.loaded[watcher_name] = old_watcher
local Binding = require("SpellHotReload.PracticeBinding")
local Scanner = require("SpellHotReload.GeneratedBossScanner")
local Card = require("SpellHotReload.Card")
local M = {}

local SOURCE = [[
local counter, flag, empty, config = 0, false, nil, { a = 1 }
local function helper() return counter end
local function bump() counter = counter + 1 end
local function set(value) counter = value end
local function read() return counter, flag, empty, config end
local function rebind(value) config = value end
_hook_runs = _hook_runs + 1
_hook_exports = { helper=helper, bump=bump, set=set, read=read, rebind=rebind }
]]

function M.run()
    local passed, failed, failures = 0, 0, {}
    local function check(value, label)
        if value then passed = passed + 1 else
            failed = failed + 1
            failures[#failures + 1] = label
        end
    end
    local function eq(a, b, label) check(a == b, label) end
    local function has(s, part, label)
        check(type(s) == "string" and s:find(part, 1, true) ~= nil, label)
    end
    local function pack(...) return { n=select("#", ...), ... } end
    local saved_globals = {}
    local keys = { "lstg", "setting", "_hook_runs", "_hook_exports", "_hook_args" }
    for _, key in ipairs(keys) do saved_globals[key] = rawget(_G, key) end
    local old_probe, old_install, old_names = Loader.Probe, Loader.InstallDoFileHook, Loader.ListFunctionNames
    local old_capture, old_getupvalue = Capture.Capture, debug.getupvalue
    local old_new, old_root = Watcher.New, Plugin.ResolveRoot
    local old_binding, old_replay = Binding.CaptureCurrent, Binding.IsReplay
    local old_scan, old_classes, old_plan = Scanner.Scan, Scanner.ClassKeys, Card.Plan
    local old_debug, old_view = package.loaded["lib.Ldebug"], package.loaded["SpellHotReload.UI.View"]
    local supported = type(debug.upvaluejoin) == "function"

    local ok, failure = pcall(function()
        _hook_runs = 0
        setting = nil
        -- Tokenize/BuildTrailer remain shared utilities. The former production
        -- hook, function-only enumeration and behavioral probe must be unused.
        Loader.Probe = function() error("legacy probe called") end
        Loader.InstallDoFileHook = function() error("legacy hook called") end
        Loader.ListFunctionNames = function() error("function-only scan called") end

        local function engine_for(sources)
            local e = { original_calls=0, reads=0, logs={} }
            e.DoFile = function(filename, ...)
                e.original_calls = e.original_calls + 1
                e.last_original = { filename=filename, args=pack(...) }
                return "original", nil, 3, nil
            end
            e.LoadTextFile = function(filename)
                e.reads = e.reads + 1
                local source = sources[filename]
                if source == nil then error("unreadable") end
                return source
            end
            e.Log = function(_, message) e.logs[#e.logs + 1] = message end
            return e
        end
        local function install(e, plugin, options)
            options = options or { select=Hook.BossFile }
            check(Hook.Install(e, function(file, entry)
                return plugin:AdoptLoad(file, entry)
            end, options), "install capture hook")
        end

        eq(Hook.BossFile("mod/demo/First_Boss.lua"), "First_Boss.lua", "slash basename")
        eq(Hook.BossFile("mod\\demo\\First_Boss.lua"), "First_Boss.lua", "backslash basename")
        eq(Hook.BossFile("First_Mid.lua"), nil, "scope not widened to Mid")
        eq(Hook.BossFile(9), nil, "non-string not selected")
        check(not Hook.Install({}, function() end, {}), "invalid engine refused")
        check(not Hook.Install(engine_for({}), nil, {}), "missing selector/callback refused")
        check(not Hook.Install(engine_for({}), function() end, 3), "invalid options refused")

        local sources = { ["First_Boss.lua"]=SOURCE }
        local e, p = engine_for(sources), Plugin.New()
        install(e, p)
        eq(pack(e.DoFile("First_Boss.lua")).n, 0, "private trailer results hidden")
        eq(_hook_runs, 1, "normal body exactly once")
        eq(e.original_calls, 0, "capture never replays original")
        local entry = p:GetLoad("First_Boss.lua")
        check(entry ~= nil, "full entry adopted")
        eq(entry, p:GetAnchors():Entry("First_Boss.lua"), "same entry held in registry")
        eq(entry.loaded_source, SOURCE, "exact loaded bytes")
        eq(entry.reloadable, supported, "real runtime reload verdict carried")
        eq(p:GetAnchors():Live("First_Boss.lua"), supported, "Live reflects runtime verdict")
        eq(#entry.names, 9, "all declarations, not just five functions")
        for _, name in ipairs({"counter","flag","empty","config","helper","bump","set","read","rebind"}) do
            check(entry.slots[name] ~= nil, "real slot: " .. name)
        end
        eq(p:GetAnchors():GetValue("First_Boss.lua", "flag"), false, "false captured")
        local empty, reason = p:GetAnchors():GetValue("First_Boss.lua", "empty")
        eq(empty, nil, "nil captured")
        eq(reason, nil, "nil is not a missing slot")
        eq(p:GetRegistry():GetValue("First_Boss.lua", "counter"), 0, "compatibility snapshot")
        _hook_exports.set(5)
        eq(p:_LoadedValues("First_Boss.lua").counter, 5, "setter seen live")
        eq(entry.map.counter, 0, "load map remains stale")
        _hook_exports.rebind({a=2})
        eq(p:_LoadedValues("First_Boss.lua").config.a, 2, "whole table replacement live")
        eq(entry.map.config.a, 1, "initial table snapshot unchanged")
        eq(p:GetAnchors():GetValue("First_Boss.lua", "helper"), _hook_exports.helper, "same closure identity")
        eq(p:_CheckLoad("First_Boss.lua"), supported, "per-file gate agrees with verdict")
        check(p:AdoptLoad("First_Boss.lua", entry), "identical entry is idempotent")
        check(not p:AdoptLoad("", entry), "empty file rejected")
        check(not p:AdoptLoad("Invalid_Boss.lua", {loaded_source=SOURCE,reloadable=true}), "false live entry rejected")

        local wrapper = e.DoFile
        check(Hook.Install(e, function() error("retargeted") end, {select=function() return "wrong" end}), "reinstall idempotent")
        eq(e.DoFile, wrapper, "same wrapper after reinstall")
        local returned = pack(e.DoFile("Other.lua", 1, nil, 3, nil))
        eq(returned.n, 4, "unselected return arity preserved")
        eq(returned[1], "original", "unselected original returned")
        eq(e.last_original.args.n, 4, "unselected args retain trailing nil")
        eq(e.reads, 1, "unselected file never read")
        e.DoFile("Unreadable_Boss.lua")
        eq(e.original_calls, 2, "unreadable goes to engine")
        eq(p:GetLoad("Unreadable_Boss.lua"), nil, "no fake load for unreadable")

        sources["Return_Boss.lua"] = "_hook_runs = _hook_runs + 1\nreturn 1, nil, 3, nil"
        local ret = pack(e.DoFile("Return_Boss.lua"))
        eq(ret.n, 4, "top-level return arity")
        eq(ret[1], 1, "top-level first value")
        eq(ret[2], nil, "top-level nil hole")
        eq(ret[3], 3, "top-level third value")
        eq(ret[4], nil, "top-level trailing nil")
        local rejected = p:GetLoad("Return_Boss.lua")
        eq(rejected.reloadable, false, "return file stored as nonreloadable")
        eq(rejected.anchor, nil, "return file needs no fake anchor")
        eq(p:_LoadedSource("Return_Boss.lua"), sources["Return_Boss.lua"], "refused source still recorded")
        local allowed, refusal = p:_CheckLoad("Return_Boss.lua")
        eq(allowed, false, "no legacy fallback for return file")
        has(refusal, "top-level return", "return refusal diagnostic")

        sources["Args_Boss.lua"] = "_hook_args = { n=select('#', ...), ... }\nlocal value = 9"
        e.DoFile("Args_Boss.lua", 1, nil, 3, nil)
        eq(_hook_args.n, 4, "capture chunk receives full argument arity")
        eq(_hook_args[3], 3, "capture chunk receives third argument")
        sources["Bom_Boss.lua"] = "\239\187\191local value = false"
        e.DoFile("Bom_Boss.lua")
        eq(p:GetLoad("Bom_Boss.lua").loaded_source:sub(1,3), "\239\187\191", "BOM kept in recorded bytes")
        eq(p:_LoadedValues("Bom_Boss.lua").value, false, "BOM stripped for execution only")

        sources["Duplicate_Boss.lua"] = "local value = 1\nlocal value = 2"
        e.DoFile("Duplicate_Boss.lua")
        local dup = p:GetLoad("Duplicate_Boss.lua")
        eq(dup.reloadable, false, "duplicate declaration refused")
        has(dup.reason, "duplicate", "duplicate reason retained")
        local limited, lp = engine_for({["Limit_Boss.lua"]=SOURCE}), Plugin.New()
        install(limited, lp, {select=Hook.BossFile,limit=1})
        limited.DoFile("Limit_Boss.lua")
        has(lp:GetLoad("Limit_Boss.lua").reason, "slot limit", "limit verdict retained")
        eq(limited.original_calls, 0, "limit refusal never reruns body")
        local incapable, ip = engine_for({["NoJoin_Boss.lua"]=SOURCE}), Plugin.New()
        install(incapable, ip, {select=Hook.BossFile,capability={getupvalue=true,setupvalue=true,upvaluejoin=false}})
        incapable.DoFile("NoJoin_Boss.lua")
        eq(ip:GetLoad("NoJoin_Boss.lua").reloadable, false, "missing join denied on both runtimes")
        has(ip:GetLoad("NoJoin_Boss.lua").reason, "upvaluejoin", "capability diagnostic retained")
        eq(ip:GetAnchors():Live("NoJoin_Boss.lua"), false, "incapable entry not Live")
        eq(ip:_CheckLoad("NoJoin_Boss.lua"), false, "incapable file cannot legacy Apply")
        check(ip:GetRegistry():Get("NoJoin_Boss.lua") ~= nil, "legacy map exists but cannot bypass gate")

        sources["NoSlots_Boss.lua"] = SOURCE
        debug.getupvalue = nil
        e.DoFile("NoSlots_Boss.lua")
        debug.getupvalue = old_getupvalue
        eq(p:GetLoad("NoSlots_Boss.lua").reloadable, false, "slot capture failure recorded")
        eq(p:GetLoad("NoSlots_Boss.lua").anchor, nil, "slot failure does not invent anchor")
        eq(p:_CheckLoad("NoSlots_Boss.lua"), false, "slot failure cannot fall back to map")

        sources["Fault_Boss.lua"] = "_hook_runs = _hook_runs + 1\nerror('normal-load failure')"
        local before_runs, before_original = _hook_runs, e.original_calls
        local ran, err = pcall(e.DoFile, "Fault_Boss.lua")
        eq(ran, false, "runtime error propagated")
        has(err, "normal-load failure", "runtime diagnostic retained")
        eq(_hook_runs, before_runs + 1, "failed body ran only once")
        eq(e.original_calls, before_original, "runtime failure never replays")
        eq(p:GetLoad("Fault_Boss.lua").failed, true, "failed initialization diagnostic recorded")
        eq(p:_CheckLoad("Fault_Boss.lua"), false, "partial initialization cannot Apply")
        sources["RepeatFault_Boss.lua"] = SOURCE
        e.DoFile("RepeatFault_Boss.lua")
        local before_fault = p:GetLoad("RepeatFault_Boss.lua")
        sources["RepeatFault_Boss.lua"] = sources["Fault_Boss.lua"]
        local count = e.original_calls
        eq(pcall(e.DoFile, "RepeatFault_Boss.lua"), false, "repeated load can fail without replay")
        eq(e.original_calls, count, "failed repeated load never calls original")
        eq(p:GetLoad("RepeatFault_Boss.lua"), before_fault, "first entry survives failed repeated load")
        eq(p:_CheckLoad("RepeatFault_Boss.lua"), false, "failed repeated load invalidates old reload verdict")

        sources["Syntax_Boss.lua"] = "local = invalid"
        e.DoFile("Syntax_Boss.lua")
        eq(e.original_calls, before_original + 1, "compile failure goes to engine without body execution")
        for _, phase in ipairs({"analyze","compile"}) do
            Capture.Capture = function() return nil, "pre-execution rejection", phase end
            local count = e.original_calls
            e.DoFile("First_Boss.lua")
            eq(e.original_calls, count+1, phase .. " fallback precedes execution")
        end
        Capture.Capture = old_capture

        local callback_engine = engine_for({["Callback_Boss.lua"]=SOURCE})
        check(Hook.Install(callback_engine, function() error("adoption failure") end, {select=Hook.BossFile}), "install failing callback")
        before_runs = _hook_runs
        eq(pcall(callback_engine.DoFile, "Callback_Boss.lua"), false, "callback error surfaced")
        eq(_hook_runs, before_runs+1, "callback error cannot rerun body")
        eq(callback_engine.original_calls, 0, "callback error never falls through")

        -- Default reader retains the engine search path and mod-directory
        -- fallback. A custom selector can capture non-Boss files without
        -- changing the bootstrap's monitored scope.
        setting = {mod="fixture"}
        local fallback, fp = engine_for({["mod/fixture/Fallback_Boss.lua"]=SOURCE}), Plugin.New()
        install(fallback, fp)
        fallback.DoFile("Fallback_Boss.lua")
        check(fp:GetLoad("Fallback_Boss.lua") ~= nil, "mod-relative source fallback")
        eq(fallback.reads, 2, "search path read then mod-relative read")
        setting = nil
        local generic, gp = engine_for({}), Plugin.New()
        install(generic, gp, {select=function(name) return name end,read=function() return SOURCE end})
        generic.DoFile("Custom.lua")
        check(gp:GetLoad("Custom.lua") ~= nil, "generic selector independent of Boss format")

        sources["Nested_Boss.lua"] = "lstg.DoFile('Inner_Boss.lua')\nlocal outer = 5"
        sources["Inner_Boss.lua"] = "local inner = false"
        lstg = e
        e.DoFile("Nested_Boss.lua")
        check(p:GetLoad("Inner_Boss.lua") ~= nil, "nested synchronous load captured")
        check(p:GetLoad("Nested_Boss.lua") ~= nil, "outer load captured after inner")

        -- Repeated DoFile retains normal execution semantics but poisons reload
        -- for that file rather than replacing the first anchor or snapshot.
        local first_anchor, first_map = entry.anchor, entry.map
        before_runs = _hook_runs
        sources["First_Boss.lua"] = SOURCE .. "\n-- different bytes"
        e.DoFile("First_Boss.lua")
        eq(_hook_runs, before_runs+1, "explicit repeated DoFile still executes")
        eq(p:GetLoad("First_Boss.lua"), entry, "first load entry retained")
        eq(p:GetAnchors():Anchor("First_Boss.lua"), first_anchor, "first anchor retained")
        eq(entry.map, first_map, "first map retained")
        eq(p:_LoadedSource("First_Boss.lua"), SOURCE, "first source retained")
        eq(p:GetRegistry():GetValue("First_Boss.lua", "counter"), 0, "legacy map not overwritten by recapture")
        eq(p:_CheckLoad("First_Boss.lua"), false, "repeat invalidates reload")
        has(entry.reason, "executed again", "repeat diagnostic")
        check(#e.logs > 0, "refused recapture reported")

        -- The production Apply checks the captured refusal before disk rereads,
        -- planning or publishing, even with a populated legacy registry.
        ip._activated, ip._supported, ip._sandbox_ok = true, true, true
        Binding.CaptureCurrent = function() return {class_key="Gate:Normal",card={},slot=1} end
        Binding.IsReplay = function() return false end
        Scanner.Scan = function() return {ok=true} end
        Scanner.ClassKeys = function() return {["Gate:Normal"]=true} end
        ip._watcher = {ReadFile=function() error("refused file read during Apply") end}
        Card.Plan = function() error("refused file planned") end
        local c = ip:GetStore():BeginCandidate("NoJoin_Boss.lua", 1, "test")
        ip:GetStore():RecordFirstRead("NoJoin_Boss.lua", c.generation, SOURCE, 2)
        ip:GetStore():VerifyStable("NoJoin_Boss.lua", c.generation, SOURCE, 4, 2)
        has(ip:Apply(), "loaded file cannot reload", "production Apply denies known refusal")
        check(ip:GetStore():GetCandidate("NoJoin_Boss.lua") ~= nil, "denial does not swallow pending candidate")
        Binding.CaptureCurrent, Binding.IsReplay = old_binding, old_replay
        Scanner.Scan, Scanner.ClassKeys, Card.Plan = old_scan, old_classes, old_plan

        -- Load the real bootstrap with engine/UI stand-ins. No old hook/probe
        -- survives on this path, even during activation before the mod loads.
        local events, boot_plugin, watcher_creates, view_adds = {}, nil, 0, 0
        local boot = engine_for({["Bootstrap_Boss.lua"]=SOURCE})
        boot.plugin = {RegisterEvent=function(group, _, _, fn) events[group]=fn end}
        lstg = boot
        package.loaded["lib.Ldebug"] = {addView=function() view_adds=view_adds+1 end}
        package.loaded["SpellHotReload.UI.View"] = {initialize=function(_, instance) boot_plugin=instance end}
        Plugin.ResolveRoot = function() return "virtual/mod" end
        Watcher.New = function()
            watcher_creates=watcher_creates+1
            return {baseline=function() end,Start=function() return true end,IsRunning=function() return true end}
        end
        local root = arg[1] == "landed" and "THDiMS/game/plugin/SpellHotReload" or
            "tasks/generic-reload-model/load-hook/proposed"
        assert(loadfile(root .. "/__init__.lua"))()
        check(type(events.afterTHlib) == "function", "afterTHlib registered")
        check(type(events.afterMod) == "function", "afterMod fallback registered")
        events.afterTHlib()
        local boot_wrapper = boot.DoFile
        events.afterTHlib()
        events.afterMod()
        eq(boot.DoFile, boot_wrapper, "bootstrap idempotent")
        eq(watcher_creates, 1, "watcher activation once")
        eq(view_adds, 1, "debug view registered once")
        eq(boot_plugin:IsSandboxOk(), supported, "presence-only activation gate")
        boot.DoFile("Bootstrap_Boss.lua")
        local boot_entry = boot_plugin:GetLoad("Bootstrap_Boss.lua")
        eq(#boot_entry.names, 9, "bootstrap captures every local")
        eq(boot_entry.reloadable, supported, "bootstrap carries real capability verdict")
        eq(boot_entry, boot_plugin:GetAnchors():Entry("Bootstrap_Boss.lua"), "bootstrap adopts full entry unchanged")
        eq(boot.original_calls, 0, "bootstrap initialization not replayed")
        if not supported then
            has(boot_plugin:GetSandboxError(), "upvaluejoin", "Lua 5.1 activation refusal explicit")
        end
    end)

    for _, key in ipairs(keys) do rawset(_G, key, saved_globals[key]) end
    Loader.Probe, Loader.InstallDoFileHook, Loader.ListFunctionNames = old_probe, old_install, old_names
    Capture.Capture, debug.getupvalue = old_capture, old_getupvalue
    Watcher.New, Plugin.ResolveRoot = old_new, old_root
    Binding.CaptureCurrent, Binding.IsReplay = old_binding, old_replay
    Scanner.Scan, Scanner.ClassKeys, Card.Plan = old_scan, old_classes, old_plan
    package.loaded["lib.Ldebug"], package.loaded["SpellHotReload.UI.View"] = old_debug, old_view
    if not ok then check(false, "uncaught: " .. tostring(failure)) end
    for _, label in ipairs(failures) do print("[LoadHookSpec] FAIL " .. label) end
    return {passed=passed,failed=failed,failures=failures}
end

return M
