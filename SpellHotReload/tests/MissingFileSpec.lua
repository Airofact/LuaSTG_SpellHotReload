-- Confirm Missing without confusing editor delete+rewrite or unreadable files
-- with session end. All executed source is synthetic; no game source executes.
local Store = require("SpellHotReload.SnapshotStore")
local Hook = require("SpellHotReload.LoadHook")
local M = {}

function M.run()
    local passed, failed, failures = 0, 0, {}
    local function check(value, label)
        if value then passed = passed + 1 else
            failed = failed + 1
            failures[#failures + 1] = label
        end
    end
    local function eq(a, b, label) check(a == b, label) end
    local function has(value, part, label)
        check(type(value) == "string" and value:find(part, 1, true), label)
    end
    local saved_globals, saved_modules = {}, {}
    local globals = {"lstg", "setting", "_missing_exports", "_missing_runs"}
    local modules = {"lstg.FileSystemWatcher", "lstg.FileSystemWatcher.FileAction",
        "SpellHotReload.Watcher", "SpellHotReload.Plugin"}
    for _, key in ipairs(globals) do saved_globals[key] = rawget(_G, key) end
    for _, key in ipairs(modules) do saved_modules[key] = package.loaded[key] end
    local restore = {}
    local ok, failure = pcall(function()
        local queue, enum_names, enum_error, closes = {}, {}, false, 0
        local action = {added="added",modified="modified",removed="removed",
            renamed_old_name="old",renamed_new_name="new"}
        package.loaded["lstg.FileSystemWatcher.FileAction"] = action
        package.loaded["lstg.FileSystemWatcher"] = {create=function()
            return {read=function(_, info)
                local event = table.remove(queue, 1)
                if event == nil then return false end
                info.file_name, info.action = event.name, event.action
                return true
            end,close=function() closes = closes + 1 end}
        end}
        package.loaded["SpellHotReload.Watcher"] = nil
        package.loaded["SpellHotReload.Plugin"] = nil
        local Watcher = require("SpellHotReload.Watcher")
        local Plugin = require("SpellHotReload.Plugin")
        lstg = {Log=function() end,FileManager={EnumFiles=function()
            if enum_error then error("enumeration unavailable") end
            local entries = {}
            for _, name in ipairs(enum_names) do entries[#entries + 1] = {name,false} end
            return entries
        end}}
        setting = nil
        local function event(name, value) queue[#queue + 1] = {name=name,action=value} end
        local function tick(w, count) for _ = 1, count do w:update() end end
        local function stable(store, name, content)
            local c = store:BeginCandidate(name, 1, "test")
            store:RecordFirstRead(name, c.generation, content, 2)
            store:VerifyStable(name, c.generation, content, 4, 2)
        end
        local function fixture(options)
            options = options or {}
            queue, enum_names, enum_error = {}, {}, false
            local disk, codes, missing, errors, ready, reads = {}, {}, {}, {}, {}, {}
            local store = Store.New()
            local w = Watcher.New({root="virtual",store=store,quiet_frames=1,read_gap=1,
                max_read_failures=2,drift_interval=options.drift_interval or 100000,
                known_files=options.known_files,
                on_missing=function(name, reason) missing[#missing + 1] = {name,reason} end,
                on_error=function(reason) errors[#errors + 1] = reason end,
                on_candidate=function(name) ready[#ready + 1] = name end})
            w.ReadFile = function(_, name)
                reads[name] = (reads[name] or 0) + 1
                if disk[name] ~= nil then return disk[name] end
                local code = codes[name]
                if code == false then return nil, "unknown read failure" end
                return nil, "open failure", code or 2
            end
            return w,store,disk,codes,missing,errors,ready,reads
        end

        -- Actual io.open errno and error classification are verified separately
        -- from virtual reads. The fixture path is required to be absent.
        local physical = Watcher.New({root="tasks/generic-reload-model/missing-file",store=Store.New()})
        local physical_bytes, physical_error, physical_code = physical:ReadFile("Absent_Boss.lua")
        eq(physical_bytes, nil, "physical absent fixture has no bytes")
        check(type(physical_error) == "string", "physical absent error retained")
        eq(physical_code, 2, "physical open supplies ENOENT on both runtimes")
        local original_open = io.open
        restore[#restore + 1] = function() io.open = original_open end
        io.open = function() return nil, "permission denied", 13 end
        local permission_bytes, permission_error, permission_code = physical:ReadFile("A_Boss.lua")
        eq(permission_bytes, nil, "physical reader preserves permission failure")
        eq(permission_error, "permission denied", "permission error retained")
        eq(permission_code, 13, "permission errno not recoded as absence")
        local reader_closed = false
        io.open = function() return {read=function() return nil,"I/O failure",2 end,
            close=function() reader_closed = true end} end
        local io_bytes, io_error, io_code = physical:ReadFile("A_Boss.lua")
        eq(io_bytes, nil, "physical reader preserves read failure")
        eq(io_error, "I/O failure", "read error retained")
        eq(io_code, nil, "opened-handle read error cannot become missing-open errno")
        check(reader_closed, "read-error handle still closed")
        io.open = original_open

        local w,store,disk,codes,missing,errors,ready,reads = fixture()
        check(w:Start(), "event watcher starts")
        store:SetAccepted("A_Boss.lua", "loaded")
        event("A_Boss.lua", action.removed)
        tick(w, 5)
        eq(#missing, 0, "removed event plus two failures not enough")
        check(store:GetCandidate("A_Boss.lua") ~= nil, "candidate held while retries continue")
        tick(w, 1)
        eq(#missing, 1, "third consecutive ENOENT confirms Missing")
        eq(missing[1][1], "A_Boss.lua", "Missing basename")
        has(missing[1][2], "after retries", "Missing diagnostic includes retry exhaustion")
        eq(store:GetCandidate("A_Boss.lua"), nil, "vanished candidate cancelled")
        eq(store:GetAccepted("A_Boss.lua").content, "loaded", "accepted baseline retained")
        eq(reads["A_Boss.lua"], 3, "quiet windows respected")
        eq(#errors, 0, "confirmed absence is not arbitrary I/O diagnostic")
        event("A_Boss.lua", action.removed)
        tick(w, 6)
        eq(#missing, 1, "repeat disappearance notifies once per session")
        w:Release()

        -- Editor delete+rewrite recovers before exhaustion, even with no added
        -- event; a renamed pair in the same poll also does not mark Missing.
        w,store,disk,codes,missing,errors,ready,reads = fixture()
        check(w:Start(), "rewrite watcher starts")
        store:SetAccepted("A_Boss.lua", "loaded")
        event("A_Boss.lua", action.removed)
        tick(w, 2)
        disk["A_Boss.lua"] = "new bytes"
        tick(w, 3)
        eq(#missing, 0, "transient absence recovers")
        eq(#ready, 1, "recovered rewrite surfaces stable candidate")
        check(store:GetCandidate("A_Boss.lua").stable, "rewrite candidate stable")
        eq(store:GetAccepted("A_Boss.lua").content, "loaded", "rewrite not implicitly accepted")
        event("A_Boss.lua", action.renamed_old_name)
        event("A_Boss.lua", action.renamed_new_name)
        disk["A_Boss.lua"] = "newer bytes"
        tick(w, 3)
        eq(#missing, 0, "rename old/new not Missing")
        eq(#ready, 2, "rename rewrite stable")
        w:Release()

        -- Disappearance AFTER a first successful read uses the same policy.
        w,store,disk,codes,missing,errors,ready,reads = fixture()
        check(w:Start(), "second-read watcher starts")
        disk["A_Boss.lua"] = "first bytes"
        event("A_Boss.lua", action.modified)
        tick(w, 2)
        eq(store:GetCandidate("A_Boss.lua").first_content, "first bytes", "first read recorded")
        disk["A_Boss.lua"] = nil
        tick(w, 4)
        eq(#missing, 0, "second-read failures still debounce")
        tick(w, 1)
        eq(#missing, 1, "second-read ENOENT exhaustion notifies")
        eq(#ready, 0, "absent second read never promotes")
        w:Release()

        -- Permission/I/O/unknown/mixed errors must NEVER masquerade as deletion.
        for _, code in ipairs({13,5,false}) do
            w,store,disk,codes,missing,errors,ready,reads = fixture()
            check(w:Start(), "error watcher starts")
            codes["A_Boss.lua"] = code
            event("A_Boss.lua", action.modified)
            tick(w, 6)
            eq(#missing, 0, "non-ENOENT never Missing: " .. tostring(code))
            eq(#errors, 1, "non-ENOENT diagnostic: " .. tostring(code))
            eq(store:GetCandidate("A_Boss.lua"), nil, "unreadable candidate cancelled")
            has(w:GetLastError(), "after retries", "unreadable status available")
            w:Release()
        end
        w,store,disk,codes,missing,errors,ready,reads = fixture()
        check(w:Start(), "mixed watcher starts")
        codes["A_Boss.lua"] = 13
        event("A_Boss.lua", action.modified)
        tick(w, 2)
        codes["A_Boss.lua"] = 2
        tick(w, 4)
        eq(#missing, 0, "mixed errors lack three consecutive absent opens")
        eq(#errors, 1, "mixed retry exhaustion diagnostic")
        event("A_Boss.lua", action.modified)
        tick(w, 6)
        eq(#missing, 1, "fresh consecutive absence can later confirm")
        w:Release()

        -- Lost removal events and files missing from EnumFiles use known names.
        w,store,disk,codes,missing,errors,ready,reads = fixture({drift_interval=2,known_files={"A_Boss.lua"}})
        store:SetAccepted("A_Boss.lua", "loaded")
        tick(w, 7)
        eq(#missing, 0, "drift absence waits quiet/retry windows")
        tick(w, 1)
        eq(#missing, 1, "drift detects deletion without event or enumerated file")
        local before_reads = reads["A_Boss.lua"]
        tick(w, 20)
        eq(#missing, 1, "drift does not spam Missing")
        eq(w._pending["A_Boss.lua"], nil, "confirmed absence not endlessly requeued")
        check(reads["A_Boss.lua"] > before_reads, "drift can observe reappearance")
        disk["A_Boss.lua"] = "reappeared"
        tick(w, 5)
        eq(#ready, 1, "reappearance may surface bytes without resetting Missing")
        check(w._missing["A_Boss.lua"], "reappearance leaves session Missing sticky")
        w:Release()
        eq(w._on_missing, nil, "release detaches Missing callback")
        eq(next(w._missing), nil, "release drops Missing index")
        check(not w:Track("A_Boss.lua"), "released watcher cannot reacquire names")

        w,store,disk,codes,missing,errors,ready,reads = fixture({known_files={"A_Boss.lua"}})
        disk["A_Boss.lua"] = "loaded"
        store:SetAccepted("A_Boss.lua", "loaded")
        enum_error = true
        w:_drift_scan(); tick(w, 8)
        eq(#missing, 0, "enum failure alone not deletion")
        eq(store:GetCandidate("A_Boss.lua"), nil, "enum failure with readable baseline creates no candidate")
        enum_error = false
        disk["A_Boss.lua"] = nil
        w:rescan()
        tick(w, 6)
        eq(#missing, 1, "Rescan checks known names missing from enum")
        check(not w:Track("other.txt"), "Track keeps allowlist")
        check(not w:Track("nested/A_Boss.lua"), "Track rejects nested paths")
        check(not w:Track("../A_Boss.lua"), "Track rejects traversal")
        check(not w:Track(3), "Track rejects non-string")
        w:Release()

        -- Production-shaped capture -> Plugin activation -> watcher callback.
        -- Capture before activation seeds known_files; capture after activation
        -- uses Track, so even an unenumerated load has a deletion audit path.
        queue, enum_names, enum_error = {}, {}, false
        local old_read = Watcher.ReadFile
        restore[#restore + 1] = function() Watcher.ReadFile = old_read end
        local plugin_disk = {}
        Watcher.ReadFile = function(_, name)
            if plugin_disk[name] ~= nil then return plugin_disk[name] end
            return nil, "open failure", 2
        end
        local source = [[local state, empty, flag = {}, nil, false
local function read() return state end
local function set(value) state = value end
_missing_exports = { read=read, set=set }
_missing_runs = _missing_runs + 1]]
        _missing_runs = 0
        local original_calls = 0
        local engine = {DoFile=function() original_calls = original_calls + 1 end,
            LoadTextFile=function() return source end}
        local p = Plugin.New()
        check(Hook.Install(engine, function(file, entry) return p:AdoptLoad(file, entry) end,
            {select=Hook.BossFile}), "install full production load capture")
        restore[#restore + 1] = function() Hook.Release(engine) end
        engine.DoFile("A_Boss.lua")
        local entry = p:GetLoad("A_Boss.lua")
        local original_anchor, original_map, verdict, original_reason = entry.anchor, entry.map, entry.reloadable, entry.reason
        local consumer, setter = _missing_exports.read, _missing_exports.set
        local live_state = {}
        setter(live_state)
        p.ResolveRoot = function() return "virtual/mod" end
        check(p:Activate(), "plugin activates real watcher")
        w = p:GetWatcher()
        eq(w._known["A_Boss.lua"], true, "preactivation load seeded into known names")
        w._quiet_frames, w._read_gap, w._max_read_failures, w._drift_interval = 1,1,2,2
        engine.DoFile("B_Boss.lua")
        eq(w._known["B_Boss.lua"], true, "postactivation load tracked")
        plugin_disk["B_Boss.lua"] = source
        p:GetStore():SetAccepted("B_Boss.lua", source, "baseline")
        p:GetStore():SetAccepted("A_Boss.lua", source, "baseline")
        local committed = {env={loaded=entry},plan={}}
        p._pending_restart_run = committed
        tick(w, 8)
        eq(entry.missing, true, "watcher callback marks same full load entry Missing")
        eq(entry, p:GetAnchors():Entry("A_Boss.lua"), "Missing preserves entry identity")
        eq(entry.anchor, original_anchor, "Missing preserves unique anchor")
        eq(entry.map, original_map, "Missing preserves capture map")
        eq(entry.reloadable, verdict, "Missing does not overwrite capture capability verdict")
        eq(entry.reason, original_reason, "Missing preserves original capture refusal")
        eq(p:GetAnchors():Live("A_Boss.lua"), false, "Missing disables effective Live")
        local allowed, deny = p:_CheckLoad("A_Boss.lua")
        eq(allowed, false, "Missing refuses reload even when legacy map exists")
        has(deny, "loaded file missing", "explicit Missing gate reason")
        eq(p:_LoadedSource("A_Boss.lua"), source, "loaded source retained")
        eq(p:GetRegistry():GetSource("A_Boss.lua"), source, "legacy source retained")
        eq(p:GetStore():GetAccepted("A_Boss.lua").content, source, "baseline retained")
        eq(p:GetStore():GetCandidate("A_Boss.lua"), nil, "Missing cancels only candidate")
        eq(p._pending_restart_run, committed, "committed restart plan retained")
        eq(consumer(), live_state, "live outside consumer intact")
        eq(p:_LoadedValues("A_Boss.lua").state, live_state, "Missing anchor read-through intact")
        local replacement = {}
        setter(replacement)
        eq(p:_LoadedValues("A_Boss.lua").state, replacement, "setter still shares live cells")
        local log_count, missing_reason = p:GetLog():Count(), entry.missing_reason
        check(p:Missing("A_Boss.lua", "repeat notification"), "Plugin Missing idempotent")
        eq(p:GetLog():Count(), log_count, "no repeat Missing log")
        eq(entry.missing_reason, missing_reason, "first Missing reason stable")
        check(not p:Missing("Unknown_Boss.lua"), "unknown file Missing refused")
        eq(p:GetLoad("Unknown_Boss.lua"), nil, "unknown file creates no load entry")

        local refused = {loaded_source="return 1",reloadable=false,reason="top-level return"}
        check(p:AdoptLoad("NoAnchor_Boss.lua", refused), "noncapturable load recorded")
        check(p:Missing("NoAnchor_Boss.lua"), "noncapturable file can become Missing")
        eq(refused.reason, "top-level return", "noncapturable refusal preserved")
        eq(refused.missing, true, "noncapturable Missing flag held")
        check(not p:_CheckLoad("NoAnchor_Boss.lua"), "noncapturable Missing gate denies")
        check(p:CaptureAnchor("Legacy_Boss.lua", source, entry.names, entry.map, entry.anchor), "legacy capture fixture")
        check(p:Missing("Legacy_Boss.lua"), "legacy held anchor marks Missing")
        check(not p:_CheckLoad("Legacy_Boss.lua"), "missing legacy fixture cannot take no-entry bypass")
        -- A deletion confirmed before a first normal load must not disappear
        -- from the Plugin gate simply because no entry existed at notification.
        event("Late_Boss.lua", action.removed)
        tick(w, 6)
        check(w:IsMissing("Late_Boss.lua"), "absence confirmed before first capture")
        eq(p:GetLoad("Late_Boss.lua"), nil, "preload notification creates no fictitious entry")
        engine.DoFile("Late_Boss.lua")
        eq(p:GetLoad("Late_Boss.lua").missing, true, "late first capture inherits confirmed absence")
        has(p:GetLoad("Late_Boss.lua").missing_reason, "vanished earlier", "late load diagnostic")
        check(not p:_CheckLoad("Late_Boss.lua"), "late capture cannot revive disappeared file")
        plugin_disk["Late_Boss.lua"] = source
        p:GetStore():SetAccepted("Late_Boss.lua", source, "baseline")

        -- Reappearance can produce a candidate, but NEVER replaces/revives the
        -- original entry/anchor and never executes file initialization.
        plugin_disk["A_Boss.lua"] = source .. "\n-- reappeared edit"
        tick(w, 5)
        check(p:GetStore():GetCandidate("A_Boss.lua").stable, "reappeared bytes may stabilize")
        eq(p:GetLoad("A_Boss.lua"), entry, "reappearance keeps first entry")
        eq(entry.anchor, original_anchor, "reappearance keeps original anchor")
        eq(entry.missing, true, "reappearance not an implicit new session")
        check(not p:_CheckLoad("A_Boss.lua"), "reappearance still denies reload")
        eq(_missing_runs, 3, "watcher never executes appeared source")
        eq(original_calls, 0, "load capture and watcher never replay engine DoFile")

        -- Exercise the real Apply route with poison read/plan sentinels: the
        -- Missing gate must precede stale-byte reads, planning and publication.
        local Binding = require("SpellHotReload.PracticeBinding")
        local Scanner = require("SpellHotReload.GeneratedBossScanner")
        local Card = require("SpellHotReload.Card")
        local old_current, old_replay = Binding.CaptureCurrent, Binding.IsReplay
        local old_scan, old_keys, old_plan = Scanner.Scan, Scanner.ClassKeys, Card.Plan
        restore[#restore + 1] = function()
            Binding.CaptureCurrent, Binding.IsReplay = old_current, old_replay
            Scanner.Scan, Scanner.ClassKeys, Card.Plan = old_scan, old_keys, old_plan
        end
        Binding.CaptureCurrent = function() return {class_key="Test:Normal",card={},slot=1} end
        Binding.IsReplay = function() return false end
        Scanner.Scan = function() return {ok=true} end
        Scanner.ClassKeys = function() return {["Test:Normal"]=true} end
        Card.Plan = function() error("Missing file planned") end
        w.ReadFile = function() error("Missing file reread in Apply") end
        p._sandbox_ok = true -- the Missing gate is orthogonal to runtime capability
        has(p:Apply(), "loaded file cannot reload: loaded file missing", "production Apply Missing gate")
        check(p:GetStore():GetCandidate("A_Boss.lua") ~= nil, "denied Apply retains reappeared candidate")
        w.ReadFile = nil

        local held = setmetatable({entry,entry.anchor}, {__mode="v"})
        entry, original_anchor, committed = nil,nil,nil
        for _ = 1, 3 do collectgarbage("collect") end
        check(held[1] ~= nil, "Missing deliberately holds load metadata")
        check(held[2] ~= nil, "Missing deliberately holds anchor")
        Hook.Release(engine)
        check(p:Release("test end"), "session end releases Missing files")
        for _ = 1, 3 do collectgarbage("collect") end
        eq(held[1], nil, "Missing metadata collectible only after release")
        eq(held[2], nil, "Missing anchor collectible after session end")
        eq(consumer(), replacement, "outside consumer survives session release too")
        eq(p:GetLoad("A_Boss.lua"), nil, "ended session drops Missing entry")
        check(not p:Missing("A_Boss.lua"), "ended session cannot reacquire Missing state")
        -- An external Missing callback may end the watcher while pending work
        -- remains; do not touch a cleared store on the next iteration/drift.
        w,store,disk,codes,missing,errors,ready,reads = fixture({drift_interval=2})
        check(w:Start(), "release-in-callback watcher starts")
        local callback_releases = 0
        w._on_missing = function()
            callback_releases = callback_releases + 1
            w:Release()
        end
        event("A_Boss.lua", action.removed)
        event("B_Boss.lua", action.removed)
        check(pcall(function() tick(w, 6) end), "Missing callback may release mid-poll")
        eq(callback_releases, 1, "mid-poll retirement prevents further callbacks")
        eq(w._on_missing, nil, "mid-poll release drops callback")
    end)
    for i = #restore, 1, -1 do restore[i]() end
    for _, key in ipairs(globals) do rawset(_G, key, saved_globals[key]) end
    for _, key in ipairs(modules) do package.loaded[key] = saved_modules[key] end
    if not ok then check(false, "uncaught: " .. tostring(failure)) end
    for _, label in ipairs(failures) do print("[MissingFileSpec] FAIL " .. label) end
    return {passed=passed,failed=failed,failures=failures}
end

return M
