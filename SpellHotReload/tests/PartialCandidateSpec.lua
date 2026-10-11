--------------------------------------------------------------------------------
--- Partial publication bookkeeping and byte-only watcher regression coverage.
--- Synthetic committed revisions only: this spec does not prove production Apply.
--------------------------------------------------------------------------------
local M = {}
local passed, failed, failures
local function check(value, label)
    if value then passed = passed + 1
    else failed = failed + 1; failures[#failures + 1] = label end
end
local function eq(actual, expected, label)
    check(actual == expected, label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end
local FILE, OTHER = "A_Boss.lua", "B_Boss.lua"
local BASE, EDIT = "loaded bytes", "edited bytes"
local function stable(store, file, bytes, update)
    local c = store:BeginCandidate(file, update, "spec")
    assert(store:RecordFirstRead(file, c.generation, bytes, update + 1))
    local result, status = store:VerifyStable(file, c.generation, bytes, update + 2, 1)
    eq(status, "stable", "fixture stable candidate")
    return assert(result)
end

local function store_contract()
    local Store = require("SpellHotReload.Runtime.SnapshotStore")
    -- Deliberate hash collision: exact bytes, never just hash, control the gate.
    local store = Store.New({ hash = function() return "collision" end })
    store:SetAccepted(FILE, BASE, "baseline")
    eq(store:HasPartialPublication(FILE), false, "no initial partial flag")
    eq(store:GetPartialPublication(FILE), nil, "no initial revision metadata")
    local c = store:BeginCandidate(FILE, 1, "spec")
    local record, err = store:RecordPartialPublication(FILE, c.generation, EDIT, 1)
    eq(record, nil, "unread candidate cannot record publication")
    eq(err, "stable candidate bytes required", "unread candidate rejection")
    store:RecordFirstRead(FILE, c.generation, EDIT, 2)
    eq(store:RecordPartialPublication(FILE, c.generation, EDIT, 1), nil, "first read is not stable")
    assert(store:VerifyStable(FILE, c.generation, EDIT, 3, 1))
    eq(store:RecordPartialPublication(FILE, c.generation, BASE, 1), nil, "same hash different bytes rejected")
    eq(store:HasPartialPublication(FILE), false, "failed record leaves flag unset")

    local invalid = { false, "1", 0, -1, 1.5, math.huge, -math.huge, 0/0 }
    for _, revision in ipairs(invalid) do
        record, err = store:RecordPartialPublication(FILE, c.generation, EDIT, revision)
        eq(record, nil, "invalid revision rejected: " .. tostring(revision))
        eq(err, "positive integer revision required", "invalid revision reason")
    end
    eq(store:RecordPartialPublication(FILE, c.generation, EDIT, nil), nil, "missing revision rejected")
    eq(store:HasPartialPublication(FILE), false, "all invalid revisions leave flag unset")
    record = assert(store:RecordPartialPublication(FILE, c.generation, EDIT, 1))
    eq(record.generation, c.generation, "record exact generation")
    eq(record.revision, 1, "record committed revision")
    eq(store:HasPartialPublication(FILE), true, "partial flag set")
    eq(store:GetCandidate(FILE).generation, c.generation, "record retains candidate generation")
    eq(store:GetCandidate(FILE).first_content, EDIT, "record retains complete candidate bytes")
    eq(store:GetCandidate(FILE).stable, true, "record retains stable candidate")
    eq(store:GetAccepted(FILE).content, BASE, "record never advances accepted bytes")
    record.revision, record.generation = 999, -1
    eq(store:GetPartialPublication(FILE).revision, 1, "returned metadata is a copy")
    local copy = store:GetPartialPublication(FILE)
    copy.revision = 999
    eq(store:GetPartialPublication(FILE).revision, 1, "query metadata is a copy")
    local before = store._partial[FILE]
    for _, revision in ipairs({ 1, 0, -1 }) do
        eq(store:RecordPartialPublication(FILE, c.generation, EDIT, revision), nil, "no duplicate/backward revision")
        eq(store._partial[FILE], before, "rejected revision does not replace metadata")
    end
    local acknowledged, reason = store:SetAccepted(FILE, EDIT, "published")
    eq(acknowledged, nil, "partial cannot promote whole file to accepted")
    eq(reason, "partial publication cannot acknowledge the whole file", "whole file ACK refusal")
    eq(store:GetAccepted(FILE).content, BASE, "failed ACK leaves baseline unchanged")
    eq(store:GetCandidate(FILE).generation, c.generation, "failed ACK leaves candidate")
    eq(store._partial[FILE], before, "failed ACK leaves partial metadata")
    eq(store:HasPartialPublication(OTHER), false, "other file unaffected")
    eq(store:SetAccepted(OTHER, BASE, "baseline").content, BASE, "other file still allows baseline")

    store:DismissCandidate(FILE)
    eq(store:GetCandidate(FILE), nil, "Dismiss hides partial candidate")
    eq(store:IsDismissed(FILE, EDIT), true, "Dismiss remembers exact bytes")
    eq(store:HasPartialPublication(FILE), true, "Dismiss never clears partial flag")
    eq(store:GetPartialPublication(FILE).revision, 1, "Dismiss never advances revision")
    eq(store:RecordPartialPublication(FILE, c.generation, EDIT, 2), nil, "dismissed generation cannot record")
    eq(store:GetAccepted(FILE).content, BASE, "Dismiss never advances accepted")
    local reverted = stable(store, FILE, BASE, 10)
    eq(store:IsDismissed(FILE, EDIT), false, "different stable bytes clear old Dismiss")
    eq(store:GetCandidate(FILE).first_content, BASE, "original bytes remain a candidate after partial")
    eq(store:GetPartialPublication(FILE).revision, 1, "source revert alone never advances revision")
    record, err = store:RecordPartialPublication(FILE, c.generation, EDIT, 2)
    eq(record, nil, "old generation rejected")
    eq(err, "superseded", "old generation reason")
    eq(store._partial[FILE], before, "stale record cannot mutate publication metadata")
    assert(store:RecordPartialPublication(FILE, reverted.generation, BASE, 2))
    eq(store:GetPartialPublication(FILE).revision, 2, "reverted publication revision advances")
    eq(store:GetCandidate(FILE).generation, reverted.generation, "reverted publication retains candidate")
    store:CancelCandidate(FILE)
    eq(store:HasPartialPublication(FILE), true, "Cancel does not reset partial state")
    local next_candidate = stable(store, FILE, EDIT, 20)
    store:RecordFirstRead(FILE, next_candidate.generation, EDIT, 30)
    eq(store:RecordPartialPublication(FILE, next_candidate.generation, EDIT, 3), nil,
        "repeated first read loses stability and cannot record publication")
    assert(store:VerifyStable(FILE, next_candidate.generation, EDIT, 31, 1))
    assert(store:RecordPartialPublication(FILE, next_candidate.generation, EDIT, 3))
    store:Clear()
    eq(store:HasPartialPublication(FILE), false, "session Clear resets partial flag")
    eq(store:GetPartialPublication(FILE), nil, "Clear releases partial metadata")
    eq(store:GetAccepted(FILE), nil, "Clear drops accepted")
    eq(store:GetCandidate(FILE), nil, "Clear drops candidate")
    eq(store:IsDismissed(FILE, BASE), false, "Clear drops rejected bytes")
    local fresh = store:BeginCandidate(FILE, 40, "new session")
    check(fresh.generation > next_candidate.generation, "Clear preserves generation monotonicity")
    eq(store:RecordPartialPublication(FILE, reverted.generation, BASE, 4), nil, "pre-Clear ticket rejected")
    store:SetAccepted(FILE, BASE, "new baseline")
    store:RecordFirstRead(FILE, fresh.generation, BASE, 41)
    local result, status = store:VerifyStable(FILE, fresh.generation, BASE, 42, 1)
    eq(result, nil, "new session baseline bytes are unchanged again")
    eq(status, "unchanged", "normal equality optimization restored")
end

local function watcher_paths()
    local Store = require("SpellHotReload.Runtime.SnapshotStore")
    local saved = {
        lstg = rawget(_G, "lstg"),
        fs = package.loaded["lstg.FileSystemWatcher"],
        action = package.loaded["lstg.FileSystemWatcher.FileAction"],
        watcher = package.loaded["SpellHotReload.Runtime.Watcher"],
    }
    local action = { added = 1, modified = 2, removed = 3, renamed_old_name = 4, renamed_new_name = 5 }
    package.loaded["lstg.FileSystemWatcher"] = { create = function() error("native watcher not allowed") end }
    package.loaded["lstg.FileSystemWatcher.FileAction"] = action
    package.loaded["SpellHotReload.Runtime.Watcher"] = nil
    _G.lstg = { Log = function() end }
    local ok, err = pcall(function()
        local Watcher = require("SpellHotReload.Runtime.Watcher")
        for _, path in ipairs({ "event", "drift", "rescan" }) do
            local disk = { [FILE] = EDIT, [OTHER] = BASE }
            local store, ready, queued = Store.New(), {}, {}
            store:SetAccepted(FILE, BASE, "baseline")
            store:SetAccepted(OTHER, BASE, "baseline")
            local c = stable(store, FILE, EDIT, 0)
            assert(store:RecordPartialPublication(FILE, c.generation, EDIT, 1))
            _G.lstg.FileManager = { EnumFiles = function()
                return { { FILE, false }, { OTHER, false }, { "unsafe.lua", false } }
            end }
            local w = Watcher.New({
                root = "mod/Test", store = store, quiet_frames = 1, read_gap = 1,
                drift_interval = 100000,
                on_candidate = function(file) ready[#ready + 1] = file end,
            })
            w.ReadFile = function(_, name) return disk[name] end
            w._fs = {
                read = function(_, info)
                    local event = table.remove(queued, 1)
                    if not event then return false end
                    info.file_name, info.action = event, action.modified
                    return true
                end,
                close = function() end,
            }
            local function tick(count) for _ = 1, count do w:update() end end
            local function scan()
                if path == "event" then queued[#queued + 1] = FILE
                elseif path == "drift" then w:_drift_scan()
                else w:rescan() end
                tick(5)
            end
            -- All three paths must surface original bytes, even with a prior candidate.
            disk[FILE] = BASE
            scan()
            local reverted = store:GetCandidate(FILE)
            check(reverted and reverted.stable, path .. ": revert surfaced")
            if not reverted then error(path .. ": no reverted candidate") end
            eq(reverted.first_content, BASE, path .. ": complete original bytes retained")
            check(reverted.generation > c.generation, path .. ": revert starts new generation")
            eq(#ready, 1, path .. ": exactly one ready callback")
            eq(ready[1], FILE, path .. ": only target file surfaced")
            eq(store:GetCandidate(OTHER), nil, path .. ": untouched file suppressed")
            eq(store:GetPartialPublication(FILE).revision, 1, path .. ": watcher never records publication")
            eq(store:GetAccepted(FILE).content, BASE, path .. ": watcher never advances accepted")

            store:DismissCandidate(FILE)
            for _ = 1, 4 do scan() end
            eq(store:GetCandidate(FILE), nil, path .. ": dismissed original bytes stay hidden")
            eq(#ready, 1, path .. ": Dismiss survives all scans")
            eq(store:IsDismissed(FILE, BASE), true, path .. ": dismissed original bytes remembered")
            eq(store:HasPartialPublication(FILE), true, path .. ": Dismiss retains partial state")
            -- baseline recapture cannot make already-published definitions disappear.
            w:baseline()
            eq(store:HasPartialPublication(FILE), true, path .. ": baseline cannot reset partial state")
            eq(store:GetAccepted(FILE).content, BASE, path .. ": original accepted bytes retained")
            eq(store:IsDismissed(FILE, BASE), true, path .. ": failed baseline ACK preserves Dismiss")
            disk[FILE] = "third bytes"
            scan()
            local third = store:GetCandidate(FILE)
            check(third and third.stable, path .. ": new bytes surface after Dismiss")
            eq(#ready, 2, path .. ": new bytes notify once")
            eq(store:IsDismissed(FILE, BASE), false, path .. ": new stable edit clears Dismiss")
            assert(store:RecordPartialPublication(FILE, third.generation, disk[FILE], 2))
            store:CancelCandidate(FILE)
            disk[FILE] = BASE
            scan()
            check(store:GetCandidate(FILE) and store:GetCandidate(FILE).stable,
                path .. ": original bytes surface even with no previous candidate")
            eq(#ready, 3, path .. ": no-candidate revert notifies once")
            eq(store:GetPartialPublication(FILE).revision, 2, path .. ": revert detection never invents revision")
            if path == "drift" then
                local generation = store:GetCandidate(FILE).generation
                for _ = 1, 4 do scan() end
                eq(store:GetCandidate(FILE).generation, generation, "drift: showing unchanged candidate not churned")
                eq(#ready, 3, "drift: no duplicate ready callback")
                store:CancelCandidate(FILE)
                w._drift_interval = 5
                tick(10)
                check(store:GetCandidate(FILE) and store:GetCandidate(FILE).stable, "periodic drift detects partial baseline")
                eq(#ready, 4, "periodic drift notifies once")
            end
            local candidate_before_release = store:GetCandidate(FILE)
            w:Release()
            w.ReadFile = function() error("released watcher must not read") end
            scan()
            eq(store:GetCandidate(FILE).generation, candidate_before_release.generation,
                path .. ": released watcher leaves Store untouched")
            eq(store:GetPartialPublication(FILE).revision, 2, path .. ": watcher Release does not own Store lifetime")
            store:Clear()
            eq(store:HasPartialPublication(FILE), false, path .. ": Store owner clears partial metadata")
        end
    end)
    package.loaded["lstg.FileSystemWatcher"] = saved.fs
    package.loaded["lstg.FileSystemWatcher.FileAction"] = saved.action
    package.loaded["SpellHotReload.Runtime.Watcher"] = saved.watcher
    _G.lstg = saved.lstg
    if not ok then error(err, 0) end
end

function M.run()
    passed, failed, failures = 0, 0, {}
    for _, test in ipairs({ store_contract, watcher_paths }) do
        local ok, err = pcall(test)
        if not ok then failed = failed + 1; failures[#failures + 1] = "unexpected error: " .. tostring(err) end
    end
    print(string.format("PartialCandidateSpec: %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do print("  FAIL: " .. label) end
    return { passed = passed, failed = failed, failures = failures }
end
return M
