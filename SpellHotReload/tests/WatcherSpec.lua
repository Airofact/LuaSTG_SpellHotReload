--------------------------------------------------------------------------------
--- SpellHotReload tests/WatcherSpec.lua
---
--- Guards the regression where a Dismissed candidate reappeared on the next
--- drift interval: the periodic scan compared disk bytes against the stale
--- accepted baseline, so every interval re-promoted the same rejected file.
---
--- The engine modules (`lstg.FileSystemWatcher`, `lstg.FileManager`), the
--- physical read, and the watcher handle are stubbed, so the spec runs under
--- plain Lua 5.1 and LuaJIT with the game directory as cwd.
--------------------------------------------------------------------------------

local M = {}

local passed, failed = 0, 0
local failures = {}

local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = label
    end
end

local function eq(actual, expected, label)
    check(actual == expected,
        label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

local FS_MODULE = "lstg.FileSystemWatcher"
local ACTION_MODULE = "lstg.FileSystemWatcher.FileAction"
local WATCHER_MODULE = "SpellHotReload.Watcher"

---Run `fn` with stubbed engine modules and globals, then restore everything.
---@param entries table[] entries as returned by lstg.FileManager.EnumFiles
---@param fn fun()
local function with_stubs(entries, fn)
    local saved_lstg = rawget(_G, "lstg")
    local saved_fs = package.loaded[FS_MODULE]
    local saved_action = package.loaded[ACTION_MODULE]
    local saved_watcher = package.loaded[WATCHER_MODULE]

    package.loaded[FS_MODULE] = { create = function() error("FileSystemWatcher must not be created in this spec") end }
    package.loaded[ACTION_MODULE] = {
        added = "added",
        modified = "modified",
        removed = "removed",
        renamed_old_name = "renamed_old_name",
        renamed_new_name = "renamed_new_name",
    }
    package.loaded[WATCHER_MODULE] = nil
    _G.lstg = {
        Log = function() end,
        FileManager = { EnumFiles = function() return entries end },
    }

    local ok, err = pcall(fn)

    package.loaded[FS_MODULE] = saved_fs
    package.loaded[ACTION_MODULE] = saved_action
    package.loaded[WATCHER_MODULE] = saved_watcher
    _G.lstg = saved_lstg

    if not ok then error(err, 0) end
end

--------------------------------------------------------------------------------

local function test_dismiss_stops_drift()
    local Store = require("SpellHotReload.SnapshotStore")
    local entries = { { "A_Boss.lua", false }, { "B_Boss.lua", false } }

    with_stubs(entries, function()
        local Watcher = require("SpellHotReload.Watcher")
        local store = Store.New()
        local disk = { ["A_Boss.lua"] = "draft-a", ["B_Boss.lua"] = "draft-b" }
        local ready = {}
        local w = Watcher.New({
            root = "mod/Test",
            store = store,
            quiet_frames = 1,
            read_gap = 1,
            drift_interval = 5,
            on_candidate = function(file_name) ready[#ready + 1] = file_name end,
        })
        w.ReadFile = function(_, name) return disk[name] end
        store:SetAccepted("A_Boss.lua", "base-a", "baseline")
        store:SetAccepted("B_Boss.lua", "base-b", "baseline")

        local function tick(count)
            for _ = 1, count do w:update() end
        end

        -- baseline flow: the first drift scan (update 5) promotes both changed files
        tick(10)
        eq(#ready, 2, "drift scan promotes changed files")
        check(store:GetCandidate("A_Boss.lua") ~= nil, "A candidate is stable")
        check(store:GetCandidate("B_Boss.lua") ~= nil, "B candidate is stable")

        -- the reported bug: dismissing must survive the periodic drift scan
        store:DismissCandidate("A_Boss.lua")
        store:DismissCandidate("B_Boss.lua")
        eq(#ready, 2, "dismiss does not itself raise a candidate")
        tick(40) -- eight drift intervals
        eq(#ready, 2, "dismissed candidates stay dismissed across drift scans")
        check(store:GetCandidate("A_Boss.lua") == nil, "dismissed A stays out of the candidate set")
        check(store:GetCandidate("B_Boss.lua") == nil, "dismissed B stays out of the candidate set")
        check(store:IsDismissed("A_Boss.lua", "draft-a"), "A rejection is remembered")

        -- Rescan is a user action, but it must not resurrect rejected bytes either
        w:rescan()
        tick(10)
        eq(#ready, 2, "rescan does not resurrect dismissed bytes")

        -- a genuinely new edit is still allowed to surface
        disk["A_Boss.lua"] = "draft-a2"
        tick(40)
        eq(#ready, 3, "a new edit after dismissal surfaces again")
        check(store:GetCandidate("A_Boss.lua") ~= nil, "new bytes produce a candidate")
        check(not store:IsDismissed("A_Boss.lua", "draft-a2"), "rejection cleared for new bytes")

        -- an explicit watcher event for still-dismissed bytes stays quiet
        local action = package.loaded[ACTION_MODULE]
        local queued = { { file_name = "B_Boss.lua", action = action.modified } }
        w._fs = {
            read = function(_, info)
                local event = table.remove(queued, 1)
                if event == nil then return false end
                info.file_name = event.file_name
                info.action = event.action
                return true
            end,
            close = function() end,
        }
        tick(6)
        eq(#ready, 3, "a watcher event for dismissed bytes does not surface")
        check(store:GetCandidate("B_Boss.lua") == nil, "event path also honors the rejection")
    end)
end

--------------------------------------------------------------------------------

function M.run()
    local ok, err = pcall(test_dismiss_stops_drift)
    if not ok then
        failed = failed + 1
        failures[#failures + 1] = "unexpected error: " .. tostring(err)
    end
    print(string.format("[SpellHotReload watcher] %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do
        print("  FAIL: " .. label)
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
