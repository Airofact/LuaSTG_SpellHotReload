--------------------------------------------------------------------------------
--- SpellHotReload.Plugin
---
--- Singleton lifecycle and orchestration. Owns the SnapshotStore, Watcher, and
--- View; resolves the mod root; activates the watcher from `afterTHlib` (resolve
--- root, capability gate, baseline, start watching) with a first-Tick fallback; and
--- implements the Apply / Retry / Dismiss / Rescan / Start-Stop Watching
--- transactions.
---
--- Production: complete Driver discovery -> current-root location -> actual
--- published-unit diff/selection -> CardCommit transaction -> frozen restart.
--- First-load entries never fall back to legacy planning/maps after refusal.
--- Partial publication retains complete candidate bytes; no whole-file ACK.
--- No-entry legacy callers remain isolated for historical regression fixtures.
--------------------------------------------------------------------------------

local Watcher = require("SpellHotReload.Watcher")
local SnapshotStore = require("SpellHotReload.SnapshotStore")
local Scanner = require("SpellHotReload.GeneratedBossScanner")
local Compose = require("SpellHotReload.Compose")
local Binding = require("SpellHotReload.PracticeBinding")
local ChangeLog = require("SpellHotReload.ChangeLog")
local UpvalueRegistry = require("SpellHotReload.UpvalueRegistry")
local Anchor = require("SpellHotReload.Anchor")
local AnchorRegistry = require("SpellHotReload.AnchorRegistry")
local Driver = require("SpellHotReload.Driver")
local Card = require("SpellHotReload.Card")
local CardCommit = require("SpellHotReload.CardCommit")
local session_serial = 0

local Plugin = {}
Plugin.__index = Plugin

---@param self table
---@param level string
---@param text string
local function log(self, level, text)
    if self._log ~= nil then
        self._log:Add(level, text)
    end
    -- mirror to the engine console so failures are visible without opening the tab
    if lstg and lstg.Log then
        local lvl = (level == "error") and 4 or (level == "warn") and 3 or 2
        pcall(lstg.Log, lvl, "[SpellHotReload] " .. tostring(text))
    end
end

---@return table
function Plugin.New()
	local self = setmetatable({}, Plugin)
	self._store = SnapshotStore.New()
	self._log = ChangeLog.New()
	self._registry = UpvalueRegistry.New()
	self._anchors = AnchorRegistry.New()
	self._loads = {} -- full first-load entries, including non-capturable files
	session_serial = session_serial + 1
	self._session_id = "SpellHotReload:" .. session_serial
	self._commit, self._commit_error = CardCommit.New(self._session_id)
	self._versions = {} -- first-load success/refusal; never lazily reseeded
	self._candidate_inspections = {} -- detached display data, never cached plans
	self._released = false
	self._watcher = nil
	self._view = nil
	self._root = nil
	self._supported = nil
	self._unsupported_reason = nil
	self._sandbox_ok = nil
	self._sandbox_error = nil
	self._activation_requested = false
	self._activation_attempted = false
	self._activated = false
	self._last_result = nil
	self._driver = Driver.New()
	self._driver_error = nil
	local registered, register_error = self._driver:Register("card", Card)
	if not registered then
		self._driver_error = register_error
	end
	local discovered, discovery_error = self._driver:RegisterDiscovery(Card)
	if not discovered then self._driver_error = discovery_error end
	self._publication_error = nil -- sticky post-commit bookkeeping refusal
	self._restart_active = false
	-- Committed frozen versioned target (or an isolated legacy Driver run).
	self._pending_restart_run = nil
	return self
end

function Plugin:GetStore() return self._store end
function Plugin:GetRegistry() return self._registry end
function Plugin:GetAnchors() return self._anchors end
function Plugin:GetLoad(file) return self._loads[file] end
---Read-only first-load capture or its sticky unavailability reason. Query never
---reads live to manufacture history. New transactions install capture.snapshot;
---only isolated legacy publication retires this capture.
function Plugin:GetVersions(file)
	if self._released then return nil, "session ended" end
	local record = self._versions[file]
	if record == nil then return nil, "first-load versions unavailable" end
	return record.capture, record.reason
end

function Plugin:_RetireVersions(file, reason)
	local record = self._versions[file]
	if record then record.capture, record.reason = nil, reason end
end

---Only AdoptLoad's first successful adoption calls this synchronously. Catch
---metadata faults after initialization; never turn them into a replay/load error.
function Plugin:_CaptureVersions(file, entry)
	if self._released or self._loads[file] ~= entry or self._versions[file] ~= nil then return end
	entry.file = file
	local capture, reason = Card.CaptureVersions(entry, self._session_id)
	self._versions[file] = { capture = capture, reason = reason }
end

function Plugin:GetDriver() return self._driver end
function Plugin:GetLog() return self._log end
function Plugin:GetWatcher() return self._watcher end
function Plugin:GetView() return self._view end
function Plugin:SetView(view) if not self._released then self._view = view end end
function Plugin:GetLastResult() return self._last_result end
function Plugin:IsActivated() return self._activated end
---@return boolean
function Plugin:IsActivationPending() return not self._activation_attempted end
function Plugin:GetRoot() return self._root end

function Plugin:IsSupported() return self._supported end
function Plugin:GetUnsupportedReason() return self._unsupported_reason end
function Plugin:IsSandboxOk() return self._sandbox_ok end
function Plugin:GetSandboxError() return self._sandbox_error end
function Plugin:IsWatching() return self._watcher ~= nil and self._watcher:IsRunning() end
function Plugin:HasRestartPending() return self._pending_restart_run ~= nil end
function Plugin:IsReleased() return self._released end

---End this Plugin session. Bootstrap retires its DoFile hook separately; this
---method drops only Plugin-owned state, not live game consumers or their cells.
---StopWatching and Tool visibility are deliberately not session termination.
function Plugin:Release(reason)
	if self._released then return true end
	if self._commit then
		local ok, err = self._commit:Release()
		if not ok then return nil, err end -- do not tear down an active transaction
	end
	self._commit, self._commit_error = nil, nil
	self._released = true
	self._activation_requested = false
	self._activation_attempted = true
	self._activated = false
	self._supported = false
	self._unsupported_reason = reason or "session ended"
	self._pending_restart_run = nil
	self._publication_error, self._restart_active = nil, false
	self._candidate_inspections = {}
	if self._watcher then self._watcher:Release() end
	self._watcher, self._view = nil, nil
	self._loads, self._versions, self._session_id = {}, {}, nil
	self._anchors:Release()
	self._registry:Release()
	self._store:Clear()
	self._log:Clear()
	self._root, self._last_result = nil, nil
	return true
end

---Register the anchor a Boss file's first load produced.
---
---The DoFile hook runs the file exactly once and hands back both the legacy
---`name -> value` map and the anchor closure the dual trailer returned. The
---anchor is registered first-load-wins: AnchorRegistry:Set refuses a second
---anchor for a file it already holds, so a later Apply can never replace the
---cells a live closure is still reading. A file whose locals cannot be
---enumerated (no capability, a name the anchor did not capture) keeps its
---legacy map and simply stays non-reloadable.
---@param file string
---@param content string
---@param names string[]
---@param map table?
---@param anchor function?
---@return boolean
function Plugin:CaptureAnchor(file, content, names, map, anchor)
	if self._released then return false, "session ended" end
	if type(anchor) ~= "function" then
		return false
	end
	local slots, order = Anchor.Slots(anchor, names)
	if slots == nil then
		return false
	end
	local registered = self._anchors:Set(file, {
		anchor = anchor, slots = slots, order = order,
		loaded_source = content, map = map, names = names,
	})
	if registered then
		self._anchors:SetSource(file, content)
	end
	return registered
end

---Adopt the FULL AnchorLoad result; never reconstruct or discard its verdict.
---Normal DoFile still executes on each call. If a selected file is executed
---again, hold the first anchor/source/map and disable reload: new consumers may
---now reference a different family of cells. This is not a supported Apply.
function Plugin:AdoptLoad(file, entry)
	if self._released then return false, "session ended" end
	if type(file) ~= "string" or file == "" or type(entry) ~= "table"
		or getmetatable(entry) ~= nil or type(entry.loaded_source) ~= "string" then
		return false, "invalid load entry"
	end
	local existing = self._loads[file]
	if existing then
		if existing == entry then return true end
		existing.reloadable = false
		existing.reason = "file executed again; restart game: " .. file
		self:_RetireVersions(file, existing.reason)
		return false, existing.reason
	end
	if entry.reloadable == true and type(entry.anchor) ~= "function" then
		return false, "reloadable entry must carry an anchor"
	end
	if type(entry.anchor) == "function" then
		local ok, reason = self._anchors:Set(file, entry)
		if not ok then return false, reason end
	end
	self._loads[file] = entry
	self:_CaptureVersions(file, entry)
	if type(entry.map) == "table" then self._registry:SetAll(file, entry.map) end
	self._registry:SetSource(file, entry.loaded_source)
	if self._watcher and type(self._watcher.Track) == "function" then
		self._watcher:Track(file)
	end
	if self._watcher and type(self._watcher.IsMissing) == "function" and self._watcher:IsMissing(file) then
		self:Missing(file, "file vanished earlier in this session")
	end
	if entry.reloadable ~= true then
		log(self, "warn", file .. ": reload disabled: " .. tostring(entry.reason))
	end
	return true
end

---A confirmed vanished file disables reload for this session, never destroys
---live cells, loaded bytes or a committed restart plan. Preserve the original
---capture verdict/reason; reappearance alone cannot revive this anchor.
function Plugin:Missing(file, reason)
	if self._released then return false, "session ended" end
	local entry = self._loads[file] or self._anchors:Entry(file)
	if entry == nil then return false, "unknown loaded file: " .. tostring(file) end
	if entry.missing then return true end
	entry.missing = true
	entry.missing_reason = "loaded file missing; restart game: " .. tostring(file)
	if reason ~= nil then entry.missing_reason = entry.missing_reason .. ": " .. tostring(reason) end
	self:_RetireVersions(file, entry.missing_reason)
	if self._anchors:Has(file) then self._anchors:Missing(file) end
	self._store:CancelCandidate(file)
	self._last_result = entry.missing_reason
	log(self, "warn", entry.missing_reason)
	return true
end

---Production captures never fall back to a legacy Apply after refusal. The
---no-entry branch is retained only for isolated legacy callers/spec fixtures.
function Plugin:_CheckLoad(file)
	if self._released then return false, "session ended" end
	local entry = self._loads[file]
	local held = entry or self._anchors:Entry(file)
	if held and held.missing then
		return false, held.missing_reason or "loaded file missing; restart game"
	end
	if entry == nil then return true end
	if entry.reloadable ~= true then
		return false, entry.reason or "file is not reloadable"
	end
	if self._anchors:Entry(file) ~= entry or not self._anchors:Live(file) then
		return false, "anchor entry is unavailable or missing; restart game"
	end
	return true
end

---The bytes a file was loaded from: the anchor registry first, then the legacy
---map store, so either registry can answer for a file the other never saw.
---@param file string
---@return string?
function Plugin:_LoadedSource(file)
	local source = self._anchors:GetSource(file)
	if source ~= nil then return source end
	return self._registry:GetSource(file)
end

---The live `name -> value` view for a file: a read-through snapshot from the
---anchor when the anchor registry holds it, otherwise the legacy map. The
---snapshot is built at call time, so a setter or a reassignment inside the file
---is observed instead of the load-time map going stale.
---@param file string
---@return table?
function Plugin:_LoadedValues(file)
	if self._anchors:Has(file) then
		local values = self._anchors:Get(file)
		if values ~= nil then return values end
	end
	return self._registry:Get(file)
end

---Publish the rebuilt named functions. The anchor cells are the shared units, so
---the new closures are written through them whenever the anchor registry holds
---the file; the legacy map is kept in step as the fallback view.
---@param file string
---@param functions table
function Plugin:_Publish(file, functions)
	if self._released then return false, "session ended" end
	self:_RetireVersions(file, "legacy publication; restart game for versioned Apply")
	self._registry:SetAll(file, functions)
	if self._anchors:Has(file) then
		self._anchors:SetAll(file, functions)
	end
end

---Fallback activation request from the `afterMod` hook. Activation normally
---happens from `afterTHlib`; this only takes effect if that path did not run.
function Plugin:RequestActivation()
	if self._released then return false, "session ended" end
	self._activation_requested = true
end

---Resolve the mod root, check patch capability, capture the baseline, and start
---watching. Called from the plugin's `afterTHlib` hook, before the mod's own
---synchronous load. Idempotent: the first attempt wins, success or failure.
---@return boolean  true when the watcher is active
function Plugin:Activate()
	if self._released then return false, "session ended" end
	if self._activation_attempted then
		return self._activated
	end
	self._activation_attempted = true
	self:_activate()
	return self._activated
end

---Resolve the physical mod directory to watch (directory mode only).
---@return string?, string?
function Plugin:ResolveRoot()
	local mod = setting and setting.mod
	if type(mod) ~= "string" or mod == "" or mod == "launcher" then
		return nil, "setting.mod is not a watchable mod"
	end
	local dir_path = "mod/" .. mod
	local zip_path = "mod/" .. mod .. ".zip"
	local zip_file = io.open(zip_path, "rb")
	if zip_file ~= nil then
		zip_file:close()
		return nil, "archive mode (mod/" .. mod .. ".zip) is not supported"
	end
	local root_file = io.open(dir_path .. "/root.lua", "rb")
	if root_file == nil then
		return nil, "mod directory root.lua not found (directory mode required)"
	end
	root_file:close()
	return dir_path
end

---Drive the first-Tick activation fallback and the per-frame watcher polling.
---Called from the View's update() each frame.
function Plugin:Tick()
	if self._released then return end
	if not self._activation_attempted and self._activation_requested then
		self:Activate()
	end
	if self._activated and self._watcher ~= nil then
		self._watcher:update()
	end
end

function Plugin:_activate()
	if self._released then return end
	self._activation_requested = false
	local root, rerr = self:ResolveRoot()
	if root == nil then
		self._supported = false
		self._unsupported_reason = rerr
		log(self, "error", "activation failed: " .. tostring(rerr))
		return
	end
	self._root = root
	self._supported = true
	log(self, "info", "activated; watching " .. tostring(root))

	local ok, serr = Anchor.Supported(Compose.Capability(debug))
	self._sandbox_ok = ok
	self._sandbox_error = serr
	if ok then
		log(self, "ok", "anchor capability available")
	else
		log(self, "warn", "anchor capability unavailable: " .. tostring(serr))
	end

	local known_files = {}
	for file in pairs(self._loads) do known_files[#known_files + 1] = file end
	self._watcher = Watcher.New({
		root = root,
		store = self._store,
		known_files = known_files,
		on_missing = function(file_name, reason)
			self:Missing(file_name, reason)
		end,
		on_candidate = function(file_name)
			self._last_result = "candidate ready: " .. file_name
			log(self, "info", "candidate ready: " .. file_name)
			if self._view then self._view:refresh() end
		end,
		on_error = function(msg)
			self._last_result = msg
			log(self, "error", msg)
		end,
	})

	self._watcher:baseline()
	log(self, "info", "baseline captured " .. #self._store:GetAcceptedFileNames() .. " file(s)")

	local started = self._watcher:Start()
	if not started then
		self._last_result = self._watcher:GetLastError()
		log(self, "error", "watcher start failed: " .. tostring(self._watcher:GetLastError()))
	else
		log(self, "info", "watcher started")
	end

	self._activated = true
end

---Trusted post-logic Monitor layout entry only; not proof of engine phase.
---Whitelist actions, never accept arbitrary callbacks. Tick must not open scopes.
---The same scoped token protects production Apply and restart-only retry.
function Plugin:_RunUIAction(action)
	if self._released then return "session ended" end
	if action ~= "apply" and action ~= "retry" then return "unknown UI action" end
	if not self._commit then return "UI commit scope unavailable" end
	local ran, result = self._commit:Run(function(token)
		if action == "apply" then return self:Apply(token) end
		return self:RetryRestart(token)
	end)
	if not ran then
		local message = type(result) == "table" and rawget(result, "message") or nil
		result = "UI phase: " .. (type(message) == "string" and message or "scope refused")
		self._last_result = result
		log(self, "warn", result)
	end
	return result
end

function Plugin:ApplyFromUI() return self:_RunUIAction("apply") end
function Plugin:RetryRestartFromUI() return self:_RunUIAction("retry") end

---Apply the current candidate to the current card and restart the practice.
---@return string
function Plugin:Apply(token)
    self._candidate_inspections = {}
	if self._released then return "session ended" end
	local result = self:_apply(token)
	self._last_result = result
	log(self, (result == "applied" or result:sub(1, 7) == "applied") and "ok" or "warn", result)
	return result
end

local function message(err)
    if type(err) == "string" then return err end
    if type(err) == "table" and getmetatable(err) == nil and type(rawget(err, "message")) == "string" then
        return rawget(err, "message")
    end
    return "operation refused"
end

local function copy_display(value)
    if type(value) ~= "table" then return value end
    local result = {};for key,item in next,value do result[key] = copy_display(item) end
    return result
end

-- Actual physical read + fresh binding, not a cached table passed as "live".
-- Called before planning and AGAIN inside CardCommit after any cache callback.
function Plugin:_FreshVersioned(file, candidate, capture)
    if self._released then return nil, {code="stale", message="session ended"} end
    if self._publication_error then return nil, {code="stale", message=self._publication_error} end
    local ok, err = self:_CheckLoad(file)
    if not ok then return nil, {code="stale", message=message(err)} end
    if self:GetVersions(file) ~= capture then return nil, {code="stale", message="first-load capture changed"} end
    if Card.IsReplay() then return nil, {code="stale", message="replay mode not supported"} end
    local content, rerr = self._watcher:ReadFile(file)
    if content == nil then return nil, {code="stale", message="read: " .. message(rerr)} end
    local current = self._store:GetCandidate(file)
    if not current or not current.stable or current.generation ~= candidate.generation
        or current.first_content ~= candidate.first_content or content ~= candidate.first_content then
        return nil, {code="stale", message="candidate generation or bytes changed since snapshot"}
    end
    local binding, berr = Card.CaptureCurrent()
    if not binding then return nil, {code="stale", message="re-capture: " .. message(berr)} end
    return {capture=capture, snapshot=capture.snapshot, entry=self._loads[file],
        session_id=self._session_id, classes=rawget(_G,"_editor_class"), content=content,
        binding=binding, released=self._released, poisoned=self._commit:Poisoned()}
end

-- Generic reentry/lifecycle control stays here; Card owns the frozen target,
-- full class/list/slot/callback checks and the actual practice handoff.
function Plugin:_RestartVersioned(run)
    if self._restart_active then return nil, "restart is already active" end
    if not self._commit then return nil, "frozen restart target or session changed; restart game" end
    local live = {released=self._released, poisoned=self._commit:Poisoned(),
        publication_error=self._publication_error, session_id=self._session_id,
        entry=self._loads[run.file], classes=rawget(_G,"_editor_class")}
    self._restart_active = true
    local context = {common={file=run.file, session_id=live.session_id,
        registry_entry=live.entry, published_units=run.snapshot}, adapter={restart=live}}
    local called, ok, err = pcall(Card.Restart,run,nil,context)
    self._restart_active = false
    if not called then error(ok,0) end
    if not ok then return nil, message(err) end
    return true
end

-- One pure preparation path for Apply and explicit inspection. No commit scope
-- is opened here; only Apply may consume a separately-owned UI token.
function Plugin:_PrepareVersioned(file, candidate, capture, discovery, initial)
    local proof = {capture=capture, snapshot=capture.snapshot, entry=self._loads[file],
        session_id=self._session_id, classes=rawget(_G,"_editor_class"), content=candidate.first_content,
        released=self._released, poisoned=self._commit:Poisoned()}
    return Card.PrepareVersioned(capture,discovery,initial,proof,function()
        return self:_FreshVersioned(file,candidate,capture)
    end)
end

function Plugin:_ApplyVersioned(token, file, candidate, capture, discovery, initial)
    if not self._commit then return "versioned UI scope unavailable" end
    local scoped, scope_error = self._commit:Check(token)
    if not scoped then return "versioned UI scope: " .. message(scope_error) end
    if not capture then
        local _, why = self:GetVersions(file)
        return "first-load versions unavailable: " .. message(why) .. "; restart game"
    end
    local prepared, err = self:_PrepareVersioned(file,candidate,capture,discovery,initial)
    if not prepared then return err end
    local target, live, location, selection = prepared.target, prepared.live, prepared.location, prepared.selection
    -- Scalars/references allocated BEFORE commit. Constructor/name metadata is
    -- NOT published: EXT_POS uses the genuine live name/slot, not candidate ones.
    local run = Card.FreezeRestart(target,capture)
    local handle, context, controller = prepared.handle, prepared.context, self._commit
    -- One-call writer, not an exposed controller/token or a general action API.
    -- Bind all arguments before entering the adapter; the kernel owns every
    -- recoverable operation and calls refresh only before final Guard/Consume.
    context.adapter.transaction = function(h, plan, ctx)
        if h~=handle or plan~=selection or ctx~=context then
            return nil, {phase="commit",code="ownership",message="foreign Card transaction input",file=file}
        end
        return controller:Commit(token,selection,capture,live,handle.refresh)
    end
    local committed, cerr, receipt = Card.Commit(handle,selection,context)
    if not committed then return "commit: " .. message(cerr) end
    run.snapshot = receipt.snapshot
    self._pending_restart_run = run
    if receipt.changed then
        local recorded, record, record_error = pcall(self._store.RecordPartialPublication,
            self._store,file,candidate.generation,candidate.first_content,receipt.snapshot.revision)
        if not recorded or not record then
            -- Do not ACK/cancel or roll back already-committed definitions.
            -- Refuse further Apply/retry, preserve the actual capture and require
            -- restart. Under the trusted synchronous path the record cannot go stale.
            self._publication_error = "partial publication bookkeeping failed; restart game"
            return "definitions committed; " .. self._publication_error .. ": " .. message(recorded and record_error or record)
        end
    end
    local restarted, restart_error = self:_RestartVersioned(run)
    if not restarted then return "definitions committed; restart failed: " .. message(restart_error) end
    self._pending_restart_run = nil
    return string.format("applied %s slot %d (%s): %s; candidate retained (partial file)",
        target.class_key,target.slot,location.match,receipt.changed and "definitions committed" or "no definition changes")
end

---Explicit, potentially expensive ANALYSIS. Never opens/consumes a commit token.
---Returns detached scalar data, not closures/anchors/plans or commit permission.
function Plugin:InspectCandidate(file)
    if type(file) ~= "string" or file == "" then return nil, "candidate file required" end
    self._candidate_inspections[file] = nil
    local ok, value, err = pcall(function()
        if self._released then return nil, "session ended" end
        if not self._activated or not self._supported then return nil, "plugin not active/supported" end
        if not self._sandbox_ok then return nil, "patch capability unavailable" end
        if self._driver_error then return nil, "driver: " .. message(self._driver_error) end
        local candidate = self._store:GetCandidate(file)
        if not candidate or not candidate.stable then return nil, "stable candidate required" end
        local capture, why = self:GetVersions(file)
        if not capture then return nil, "first-load versions unavailable: " .. message(why) end
        local initial, berr = Card.CaptureCurrent()
        if not initial then return nil, "capture: " .. message(berr) end
        initial = Card.FreezeBinding(initial)
        local live, lerr = self:_FreshVersioned(file,candidate,capture)
        if not live then return nil, "inspection: " .. message(lerr) end
        local discovery, derr = self._driver:Discover(file,candidate.first_content,{
            session_id=self._session_id, candidate_generation=candidate.generation,
            loaded_source=live.entry.loaded_source, registry_entry=live.entry,
            base_revision=capture.snapshot.revision, published_units=capture.snapshot})
        if not discovery then return nil, "discover: " .. message(derr) end
        local prepared, perr = self:_PrepareVersioned(file,candidate,capture,discovery,initial)
        if not prepared then return nil, perr end
        local model, fresh = Card.InspectPrepared(prepared,capture,function()
            return self:_FreshVersioned(file,candidate,capture)
        end)
        if not model then return nil, fresh end
        live = fresh
        self._candidate_inspections[file] = {model=model, content=candidate.first_content,
            generation=candidate.generation, capture=capture, snapshot=capture.snapshot,
            entry=live.entry, session_id=self._session_id, binding=initial,
            classes=prepared.target.classes, class=prepared.target.class, list=prepared.target.list}
        return copy_display(model)
    end)
    if not ok then return nil, "inspection failed: " .. message(value) end
    return value, err
end

---Cheap validity of a PAST inspection. No I/O/Match/compile/live-cell probing.
---Same versions can still be externally changed: display is NOT Apply authority.
function Plugin:GetCandidateInspection(file, current)
    local record = self._candidate_inspections[file]
    if not record then return nil end
    local candidate, capture = self._store:GetCandidate(file), self:GetVersions(file)
    local valid = not self._released and self._activated and self._supported
        and self._sandbox_ok and self._commit and not self._commit:Poisoned() and not self._publication_error
        and not Card.IsReplay() and self._loads[file] == record.entry
        and record.entry.reloadable == true and not record.entry.missing
        and self._session_id == record.session_id and capture == record.capture
        and capture.snapshot == record.snapshot and candidate and candidate.stable
        and candidate.generation == record.generation and candidate.first_content == record.content
        and Card.InspectionBindingMatches(record,current,rawget(_G,"_editor_class"))
    if not valid then self._candidate_inspections[file] = nil;return nil end
    return copy_display(record.model)
end

function Plugin:_apply(token)
    if self._released then return "session ended" end
    if not self._activated then return "not activated" end
    if not self._supported then return "unsupported: " .. tostring(self._unsupported_reason) end
    if not self._sandbox_ok then return "patch capability unavailable: " .. tostring(self._sandbox_error) end
    if self._driver_error ~= nil then return "driver: " .. tostring(self._driver_error) end
    if self._publication_error then return self._publication_error end
    if self._pending_restart_run and self._pending_restart_run.kind == "versioned-card-restart" then
        return "definitions already committed; retry restart first"
    end
    local current, err = Card.CaptureCurrent()
    if current == nil then return "capture: " .. message(err) end
    if Card.IsReplay() then return "replay mode not supported" end
    -- Freeze the initial UI choice before Match/IO can return a changed binding.
    current = Card.FreezeBinding(current)

    local target_file, target_candidate, target_capture, target_discovery
    for _, file in ipairs(self._store:GetCandidateFileNames()) do
        local candidate = self._store:GetCandidate(file)
        if candidate and candidate.stable and candidate.first_content then
            local gate = Card.CheckCandidateSource(candidate.first_content,file)
            if not gate.ok then log(self,"warn","apply: rejected " .. file .. ": " .. message(gate.error))
            else
                local entry, capture, discovery = self._loads[file]
                local matches
                if entry then
                    -- Sticky load/Missing refusals remain visible even before
                    -- entering a UI scope; this read-only gate grants no authority.
                    local load_ok, load_error = self:_CheckLoad(file)
                    if not load_ok then return "loaded file cannot reload: " .. message(load_error) end
                    if not self._commit then return "versioned UI scope unavailable" end
                    local scoped, scope_error = self._commit:Check(token)
                    if not scoped then return "versioned UI scope: " .. message(scope_error) end
                    capture = self:GetVersions(file)
                    local base = capture and capture.snapshot
                    local derr
                    discovery, derr = self._driver:Discover(file,candidate.first_content,{
                        session_id=self._session_id, candidate_generation=candidate.generation,
                        loaded_source=entry.loaded_source, registry_entry=entry,
                        base_revision=base and base.revision, published_units=base})
                    if not discovery then return "discover: " .. message(derr) end
                    matches = Card.DefinesCurrent(discovery,current)
                else
                    -- No first-load entry: isolated legacy fixtures only. A
                    -- production refusal above NEVER reaches this compatibility branch.
                    matches = Scanner.ClassKeys(candidate.first_content)[current.class_key]
                end
                if matches then
                    if target_file then return "multiple candidate files define the current class" end
                    if not self:_LoadedSource(file) then return "loaded source unavailable; restart game" end
                    target_file,target_candidate,target_capture,target_discovery = file,candidate,capture,discovery
                end
            end
        end
    end
    if not target_file then return "no stable candidate defines the current class" end
    local ok, why = self:_CheckLoad(target_file)
    if not ok then return "loaded file cannot reload: " .. message(why) end
    if self._loads[target_file] then
        return self:_ApplyVersioned(token,target_file,target_candidate,target_capture,target_discovery,current)
    end
    if token ~= nil then
        return "first-load entry unavailable; restart game" -- production UI never upgrades a legacy map
    end
    local content, rerr = self._watcher:ReadFile(target_file)
    if not content then return "read: " .. message(rerr) end
    local cand = self._store:GetCandidate(target_file)
    if not cand or not cand.stable or content ~= cand.first_content then return "candidate bytes changed since snapshot" end
    local cur2, cerr = Binding.CaptureCurrent()
    if not cur2 then return "re-capture: " .. message(cerr) end
    if cur2.class_key ~= current.class_key or cur2.card ~= current.card or cur2.slot ~= current.slot then
        return "current binding changed (stale abort)"
    end
    return self:_ApplyLegacy(target_file,content,current)
end

---No first-load entries only. Never a failure fallback for versioned production.
function Plugin:_ApplyLegacy(target_file,content,current)
	-- Locate + Inject only. Generated wiring is never executed, no callback body
	-- runs, and the live card is untouched until Driver:Commit.
	local request, qerr = Card.Request({
		class_key = current.class_key,
		card = current.card,
		slot = current.slot,
		name = current.name,
		names = current.names,
		include_previous = current.include_previous,
		binding = current,
	})
	if request == nil then return "card: " .. tostring(qerr) end
	local run, perr = Card.Plan(request, {
		file = target_file,
			original = self:_LoadedSource(target_file),
			content = content,
			registry = self:_LoadedValues(target_file),
	})
	if run == nil then return "card: " .. tostring(perr) end

	-- Commit is the single live mutation; the restartable card adapter restarts
	-- the practice right afterwards unless that restart fails.
	-- Legacy Commit can publish and enter Restart before returning. Retire the
	-- revision-0 baseline before that boundary, including a failed/partial run.
	self:_RetireVersions(target_file, "legacy Apply attempted; restart game for versioned Apply")
	local report = self._driver:Commit(run)
	if report.committed ~= 1 then
		local reason = report.failed[1] ~= nil and report.failed[1].reason or "no entry committed"
		return "commit: " .. tostring(reason)
	end
	-- Post-commit: republish the freshly compiled named functions so the next
	-- reload resolves sibling locals from the new closures instead of the old
	-- ones. The anchor cells are the shared units, so the new closures are
	-- written through them as well.
	self:_Publish(target_file, run.plan.functions)
	self._store:SetAccepted(target_file, content, "published")
	self._store:CancelCandidate(target_file)
	log(self, "ok", string.format("apply: replaced callbacks for %s slot %d (%s)",
		current.class_key, current.slot, tostring(run.handle.match)))

	-- A failed restart keeps the committed definitions and the run, so Retry
	-- Restart only retries the stage switch. The candidate may have renamed the
	-- card; Card.Commit already recorded the new name for the handoff.
	local restart = report.restarts[1]
	if restart ~= nil and restart.ok ~= true then
		self._pending_restart_run = run
		return "definitions committed; restart failed: " .. tostring(restart.reason)
	end
	self._pending_restart_run = nil
	return string.format("applied %s slot %d (%s): replaced card callbacks",
		current.class_key, current.slot, tostring(run.handle.match))
end

---Retry only the stage restart (definitions are already committed).
---@return string
function Plugin:RetryRestart(token)
	if self._released then return "session ended" end
	local run = self._pending_restart_run
	if run == nil then
		log(self, "warn", "retry: nothing to retry")
		return "nothing to retry"
	end
	if run.kind == "versioned-card-restart" then
		if not self._commit then return "versioned UI scope unavailable" end
		local scoped, err = self._commit:Check(token)
		if not scoped then return "versioned UI scope: " .. message(err) end
		local ok, why = self:_RestartVersioned(run)
		local result = ok and "restarted" or ("restart failed: " .. message(why))
		if ok then self._pending_restart_run = nil end
		self._last_result = result
		log(self,ok and "ok" or "error",result)
		return result
	end
	local report = self._driver:Restart(run)
	if report.ok > 0 and #report.failed == 0 then
		self._pending_restart_run = nil
		log(self, "ok", "restarted " .. tostring(run.request.class_key))
		return "restarted"
	end
	local reason = report.failed[1] ~= nil and report.failed[1].reason or "restart retry did not run"
	local msg = "restart failed: " .. tostring(reason)
	self._last_result = msg
	log(self, "error", msg)
	return msg
end

---@param file_name string
function Plugin:Dismiss(file_name)
	if self._released then return false, "session ended" end
	-- Remember the rejected bytes so the drift scan does not resurrect the
	-- candidate on the next interval.
	self._candidate_inspections[file_name] = nil
	self._store:DismissCandidate(file_name)
	self._last_result = "dismissed " .. file_name
	log(self, "info", "dismissed " .. file_name)
end

function Plugin:Rescan()
    self._candidate_inspections = {}
	if self._released then return end
	if self._watcher == nil then return end
	self._watcher:rescan()
	log(self, "info", "rescan requested")
end

function Plugin:StartWatching()
	if self._released then return end
	if self._watcher == nil then return end
	self._watcher:Start()
	log(self, "info", "watching started")
end

function Plugin:StopWatching()
	if self._watcher == nil then return end
	self._watcher:Stop()
	log(self, "info", "watching stopped")
end

return Plugin
