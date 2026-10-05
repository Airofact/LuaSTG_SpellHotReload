--------------------------------------------------------------------------------
--- SpellHotReload.Watcher
---
--- Polls `lstg.FileSystemWatcher` for changes to generated Boss files under the
--- active mod directory, applies an allowlist + quiet-window debounce, and turns
--- repeated identical reads into an immutable candidate via SnapshotStore.
---
--- Watcher events only ever trigger reads and candidate bookkeeping; they NEVER
--- execute generated files. That is gated behind the user-facing Apply action.
--------------------------------------------------------------------------------

local Watcher = {}

local FileSystemWatcher = require("lstg.FileSystemWatcher")
local FileAction = require("lstg.FileSystemWatcher.FileAction")

--- basename must match this pattern and be a direct child of the watch root
local BOSS_FILE_PATTERN = "^[A-Za-z0-9_%%%-]+_Boss%.lua$"

local DEFAULT_QUIET_FRAMES = 15
local DEFAULT_READ_GAP = 2
local DEFAULT_MAX_EVENTS_PER_FRAME = 64
-- consecutive failed reads before we conclude a file is truly gone (vs. an
-- editor delete+rewrite that reappears within the next quiet window)
local DEFAULT_MAX_READ_FAILURES = 4
-- frames between periodic drift scans; fallback for lost watcher events
local DEFAULT_DRIFT_INTERVAL = 120

---Mirror a diagnostic line to the engine console (lstg.Log level 2 = info).
local function diag(msg)
    if lstg and lstg.Log then
        pcall(lstg.Log, 2, "[SpellHotReload.Watcher] " .. tostring(msg))
    end
end

---@param name string
---@return boolean
local function is_safe_basename(name)
    if type(name) ~= "string" then return false end
    if name:find("[/\\:]") then return false end
    if name:find("%.%.", 1, true) then return false end
    if not name:match(BOSS_FILE_PATTERN) then return false end
    return true
end

---Reduce a reported file name to its basename. The watcher may report a bare
---basename, a path relative to the watch root, or an absolute path; in every case
---only the trailing component identifies the direct child we track.
---@param name string
---@return string?
local function basename_of(name)
    if type(name) ~= "string" then return nil end
    local base = name:match("([^/\\]+)$")
    if base == nil or base == "" then return nil end
    return base
end

---@class SpellHotReload.Watcher
---@field _root string
---@field _store table
---@field _fs table?
---@field _update integer
---@field _pending table<string, table>
---@field _known table<string, boolean>
---@field _on_candidate fun(file_name: string)?
---@field _on_error fun(message: string)?
---@field _on_missing fun(file_name: string, message: string)?
---@field _quiet_frames integer
---@field _read_gap integer
---@field _max_events integer
---@field _last_error string?

---@param options table
---@return SpellHotReload.Watcher
function Watcher.New(options)
    options = options or {}
    local self = setmetatable({}, { __index = Watcher })
    self._root = options.root
    self._store = options.store
    self._on_candidate = options.on_candidate
    self._on_error = options.on_error
    self._on_missing = options.on_missing
    self._quiet_frames = options.quiet_frames or DEFAULT_QUIET_FRAMES
    self._read_gap = options.read_gap or DEFAULT_READ_GAP
    self._max_events = options.max_events or DEFAULT_MAX_EVENTS_PER_FRAME
    self._max_read_failures = options.max_read_failures or DEFAULT_MAX_READ_FAILURES
    self._drift_interval = options.drift_interval or DEFAULT_DRIFT_INTERVAL
    self._fs = nil
    self._update = 0
    self._pending = {}
    self._known = {}
    self._missing = {} -- confirmed once per session; reappearance is not a reset
    self._last_error = nil
    for _, name in ipairs(options.known_files or {}) do self:Track(name) end
    return self
end

---Remember a normally loaded file too, even if baseline/event enumeration
---missed it. Only the existing direct-child Boss allowlist can be tracked.
function Watcher:Track(file_name)
    if self._released or not is_safe_basename(file_name) then return false end
    self._known[file_name] = true
    return true
end

---Whether this watcher confirmed absence earlier in the current session.
function Watcher:IsMissing(file_name)
    return self._missing[file_name] == true
end

---@return string
function Watcher:GetRoot()
    return self._root
end

---@return boolean
function Watcher:IsRunning()
    return self._fs ~= nil
end

---@return string?
function Watcher:GetLastError()
    return self._last_error
end

---@return boolean, string?
function Watcher:Start()
    if self._released then return false, "watcher released" end
    if self._fs ~= nil then
        return true
    end
    local ok, fs = pcall(FileSystemWatcher.create, self._root)
    if not ok then
        self._last_error = "watcher create failed: " .. tostring(fs)
        diag("Start: create(" .. tostring(self._root) .. ") FAILED: " .. tostring(fs))
        if self._on_error then self._on_error(self._last_error) end
        return false, self._last_error
    end
    self._fs = fs
    self._last_error = nil
    diag("Start: create(" .. tostring(self._root) .. ") -> " .. tostring(fs) .. " (type " .. type(fs) .. ")")
    return true
end

function Watcher:Stop()
    if self._fs ~= nil then
        pcall(function() self._fs:close() end)
        self._fs = nil
    end
end

---Session end, unlike Stop Watching. Retained watcher handles cannot restart or
---poll after this, and no longer hold Plugin callbacks or SnapshotStore bytes.
function Watcher:Release()
    if self._released then return true end
    self._released = true
    self:Stop()
    self._pending, self._known, self._missing = {}, {}, {}
    self._on_candidate, self._on_error, self._on_missing, self._store = nil, nil, nil, nil
    return true
end

---@param file_name string
---@return string
function Watcher:GetPath(file_name)
    return self._root .. "/" .. file_name
end

---Read full physical bytes; an open failure also returns errno. ENOENT (2),
---not an arbitrary read error or an empty EnumFiles result, proves absence.
---@param file_name string
---@return string?, string?, integer?
function Watcher:ReadFile(file_name)
    if self._released then return nil, "watcher released" end
    local path = self:GetPath(file_name)
    local f, err, code = io.open(path, "rb")
    if f == nil then
        return nil, err, code
    end
    local content, read_error = f:read("*a")
    f:close()
    return content, read_error
end

---@param file_name string
local function begin_pending(self, file_name, source)
    diag("begin_pending " .. tostring(file_name) .. " source=" .. tostring(source))
    local gen_candidate = self._store:BeginCandidate(file_name, self._update, source)
    self._pending[file_name] = {
        generation = gen_candidate.generation,
        quiet_left = self._quiet_frames,
        first_content = nil,
        first_read_update = nil,
        fail_count = 0,
        missing_count = 0,
    }
    self._known[file_name] = true
end

---Exhaustion cancels the candidate, but only consecutive ENOENT opens invalidate
---reload. Permission/I/O/unknown failures are diagnostic, never Missing.
local function failed_read(self, file_name, pending, err, code)
    pending.fail_count = pending.fail_count + 1
    pending.missing_count = code == 2 and (pending.missing_count or 0) + 1 or 0
    if pending.fail_count <= self._max_read_failures then
        pending.quiet_left = self._quiet_frames
        return
    end
    self._pending[file_name] = nil
    self._store:CancelCandidate(file_name)
    local message = "read failed after retries: " .. file_name .. ": " .. tostring(err)
    diag(message)
    if pending.missing_count > self._max_read_failures then
        if not self._missing[file_name] then
            self._missing[file_name] = true
            if self._on_missing then self._on_missing(file_name, message) end
        end
    else
        self._last_error = message
        if self._on_error then self._on_error(message) end
    end
end

---@param file_name string
---@param source string
local function handle_change(self, file_name, source)
    if not is_safe_basename(file_name) then
        return
    end
    begin_pending(self, file_name, source)
end

---@param file_name string
local function handle_remove(self, file_name)
    -- The editor deletes-and-rewrites on export, so a `removed` event is usually
    -- followed by the file reappearing with new content — but the engine watcher
    -- can drop the follow-up added/modified events (buffer overflow). Treat a
    -- removal as a potential change: poll disk and let the read/verify state
    -- machine decide whether the file is truly gone or just rewritten.
    handle_change(self, file_name, "removed")
end

---Poll events (bounded per frame) and advance the read/verify state machine.
function Watcher:update()
    if self._released then return end
    self._update = self._update + 1

    if self._fs ~= nil then
        local info = {}
        local count = 0
        while count < self._max_events and self._fs:read(info) do
            count = count + 1
            local name = basename_of(info.file_name)
            local action = info.action
            diag(string.format("event action=%s file=%s", tostring(action), tostring(name)))
            if action == FileAction.removed or action == FileAction.renamed_old_name then
                handle_remove(self, name)
            elseif action == FileAction.added or action == FileAction.modified or action == FileAction.renamed_new_name then
                handle_change(self, name, tostring(action))
            end
        end
        -- heartbeat: prove the poll loop runs even when read() returns nothing
        if count == 0 and self._update % 600 == 0 then
            diag("alive frame=" .. self._update .. " fs=" .. type(self._fs) .. " no events")
        end
    end

    -- drive pending candidates
    for file_name, pending in pairs(self._pending) do
        if self._released then return end
        if pending.quiet_left > 0 then
            pending.quiet_left = pending.quiet_left - 1
        elseif pending.first_content == nil then
            local content, err, code = self:ReadFile(file_name)
            if content ~= nil then
                if self._store:IsDismissed(file_name, content) then
                    -- bytes the user already rejected: drop without surfacing a candidate
                    self._pending[file_name] = nil
                    self._store:CancelCandidate(file_name)
                else
                    local record = self._store:RecordFirstRead(file_name, pending.generation, content, self._update)
                    if record ~= nil then
                        pending.first_content = content
                        pending.first_read_update = self._update
                        pending.fail_count = 0
                        pending.missing_count = 0
                    else
                        -- superseded (newer change arrived) — drop
                        self._pending[file_name] = nil
                    end
                end
            else
                failed_read(self, file_name, pending, err, code)
            end
        else
            -- second read after the gap
            if self._update - pending.first_read_update >= self._read_gap then
                local content, err, code = self:ReadFile(file_name)
                if content == nil then
                    failed_read(self, file_name, pending, err, code)
                else
                    pending.fail_count = 0
                    pending.missing_count = 0
                    local verified, status = self._store:VerifyStable(
                        file_name, pending.generation, content, self._update, self._read_gap)
                    diag("VerifyStable " .. file_name .. " -> " .. tostring(status))
                    if status == "stable" then
                        self._pending[file_name] = nil
                        if self._on_candidate then self._on_candidate(file_name) end
                    elseif status == "unchanged" or status == "dismissed" then
                        -- unchanged: identical to the accepted baseline
                        -- dismissed: identical to bytes the user already rejected
                        self._pending[file_name] = nil
                    elseif status == "superseded" then
                        self._pending[file_name] = nil
                    elseif status == "changed" then
                        -- mismatch: store restarted a new generation, go quiet again
                        local candidate = self._store:GetCandidate(file_name)
                        if candidate ~= nil then
                            pending.generation = candidate.generation
                        end
                        pending.first_content = nil
                        pending.first_read_update = nil
                        pending.quiet_left = self._quiet_frames
                    elseif status == "too-soon" then
                        -- wait longer
                    end
                    _ = verified
                end
            end
        end
    end

    -- periodic drift scan: fallback for lost watcher events (the engine watcher
    -- can overflow and drop added/modified events when the editor bulk-rewrites)
    if not self._released and self._update % self._drift_interval == 0 then
        self:_drift_scan()
    end
end

---Union disk names with previously observed/loaded names: lost removal events
---must not hide disappeared files. Enumeration itself never proves Missing.
local function tracked_files(self)
    for _, name in ipairs(self:list_boss_files()) do self:Track(name) end
    local names = {}
    for name in pairs(self._known) do names[#names + 1] = name end
    table.sort(names)
    return names
end

---Conservative drift scan. Only starts a candidate when nothing is already in
---flight; a showing candidate is restarted only if its bytes changed again. Used
---as a periodic fallback for lost watcher events. After partial publication,
---accepted-byte equality cannot suppress a candidate (including source reverts).
function Watcher:_drift_scan()
    if self._released then return end
    for _, name in ipairs(tracked_files(self)) do
        if self._pending[name] ~= nil then
            -- event path already working on it
        else
            local content = self:ReadFile(name)
            if content == nil then
                -- Schedule the SAME quiet/retry path as an event, never an
                -- immediate invalidation from a one-off failure or lost enum.
                if not self._missing[name] then begin_pending(self, name, "drift-unreadable") end
            else
                local cand = self._store:GetCandidate(name)
                if cand ~= nil and cand.first_content ~= nil then
                    -- already showing a candidate: only restart if bytes changed again
                    if content ~= cand.first_content then
                        begin_pending(self, name, "drift")
                    end
                else
                    local accepted = self._store:GetAccepted(name)
                    -- skip bytes the user already dismissed; otherwise every drift
                    -- scan resurrects the same candidate after a Dismiss
                    if (self._store:HasPartialPublication(name)
                        or accepted == nil or accepted.content ~= content)
                        and not self._store:IsDismissed(name, content) then
                        begin_pending(self, name, "drift")
                    end
                end
            end
        end
    end
end

---Force re-read every Boss file on disk and promote any drift to a fresh
---candidate (used by the user-facing Rescan button).
function Watcher:rescan()
    if self._released then return end
    for _, name in ipairs(tracked_files(self)) do
        local accepted = self._store:GetAccepted(name)
        local content = self:ReadFile(name)
        if content ~= nil and (self._store:HasPartialPublication(name)
            or accepted == nil or accepted.content ~= content)
            and not self._store:IsDismissed(name, content) then
            begin_pending(self, name, "rescan")
        elseif content == nil and self._pending[name] == nil and not self._missing[name] then
            begin_pending(self, name, "rescan-unreadable")
        end
    end
end

---Establish a baseline for files currently on disk, marking them accepted without
---prompting. Called once when activation initializes the watcher (the plugin's
---`afterTHlib` hook, before the mod's own synchronous load).
function Watcher:baseline()
    if self._released then return end
    local names = self:list_boss_files()
    for _, name in ipairs(names) do
        if is_safe_basename(name) then
            local content = self:ReadFile(name)
            if content ~= nil then
                self._store:SetAccepted(name, content, "baseline")
                self._known[name] = true
            end
        end
    end
end

---List allowlisted Boss files directly under the watch root via FileManager.
---@return string[]
function Watcher:list_boss_files()
    local result = {}
    local ok, entries = pcall(lstg.FileManager.EnumFiles, self._root .. "/")
    if not ok then
        return result
    end
    for _, entry in ipairs(entries) do
        local name = entry[1]
        local is_dir = entry[2]
        if is_dir == false or is_dir == nil then
            -- entry name may include the search-path prefix; keep the basename
            local base = name:match("([^/\\]+)$")
            if base == nil then base = name end
            if is_safe_basename(base) then
                result[#result + 1] = base
            end
        end
    end
    return result
end

return Watcher
