--------------------------------------------------------------------------------
--- SpellHotReload.Runtime.Plugin
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
--- Missing first-load entries are refused; no alternate publication path exists.
--------------------------------------------------------------------------------

local Watcher = require("SpellHotReload.Runtime.Watcher")
local SnapshotStore = require("SpellHotReload.Runtime.SnapshotStore")
local Compose = require("SpellHotReload.Source.Compose")
local Binding = require("SpellHotReload.Adapters.Card.PracticeBinding")
local CurrentRestart = require("SpellHotReload.Runtime.CurrentRestart")
local ChangeLog = require("SpellHotReload.Runtime.ChangeLog")
local Anchor = require("SpellHotReload.Load.Anchor")
local AnchorRegistry = require("SpellHotReload.Load.AnchorRegistry")
local Driver = require("SpellHotReload.Pipeline.Driver")
local Card = require("SpellHotReload.Adapters.Card.Card")
local CardCommit = require("SpellHotReload.Apply.CardCommit")
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
	self._anchors = AnchorRegistry.New()
	self._loads = {} -- full first-load entries, including non-capturable files
	session_serial = session_serial + 1
	self._session_id = "SpellHotReload:" .. session_serial
	self._commit, self._commit_error = CardCommit.New(self._session_id)
	self._versions = {} -- first-load success/refusal; never lazily reseeded
	self._candidate_inspections = {} -- detached display data, never cached plans
	self._candidate_remainders = {} -- checked post-publication scalar display
	self._completion_checks = {} -- no-op read witnesses, never a commit writer
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
	local discovered, discovery_error = self._driver:RegisterDiscovery(Card)
	if not discovered then self._driver_error = discovery_error end
	self._publication_error = nil -- sticky post-commit bookkeeping refusal
	self._restart_active = false
	-- Committed frozen workflow target.
	self._pending_restart_run = nil
	return self
end

function Plugin:GetStore() return self._store end
function Plugin:GetAnchors() return self._anchors end
function Plugin:GetLoad(file) return self._loads[file] end
---Read-only first-load capture or its sticky unavailability reason. Query never
---reads live to manufacture history. New transactions install capture.snapshot;
---session invalidation retires this capture.
function Plugin:GetVersions(file)
	if self._released then return nil, "session ended" end
	local record = self._versions[file]
	if record == nil then return nil, "first-load versions unavailable" end
	return record.capture, record.reason
end

function Plugin:_RetireVersions(file, reason)
	self:_ClearCompletion(file)
	self._candidate_remainders[file] = nil
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

function Plugin:_DiscoverVersioned(file, candidate, capture)
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    if type(capture)~="table" or getmetatable(capture)~=nil
        or type(capture.snapshot)~="table" then
        return nil,{phase="reconcile",code="unsupported",message="first-load versions unavailable; restart game",file=file}
    end
    local publication,err=Cards.Publication(capture.snapshot)
    if not publication then return nil,err end
    return self._driver:DiscoverPublished(file,candidate.first_content,publication,{
        candidate_generation=candidate.generation,published_units=capture.snapshot})
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
	self._candidate_remainders, self._completion_checks = {}, {}
	if self._watcher then self._watcher:Release() end
	self._watcher, self._view = nil, nil
	self._loads, self._versions, self._session_id = {}, {}, nil
	self._anchors:Release()
	self._store:Clear()
	self._log:Clear()
	self._root, self._last_result = nil, nil
	return true
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
	local entry = self._loads[file]
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

---Require the complete authoritative first-load entry before preparation.
function Plugin:_CheckLoad(file)
	if self._released then return false, "session ended" end
	local entry = self._loads[file]
	local held = entry
	if held and held.missing then
		return false, held.missing_reason or "loaded file missing; restart game"
	end
	if entry == nil then return false, "first-load entry unavailable; restart game" end
	if entry.reloadable ~= true then
		return false, entry.reason or "file is not reloadable"
	end
	if self._anchors:Entry(file) ~= entry or not self._anchors:Live(file) then
		return false, "anchor entry is unavailable or missing; restart game"
	end
	return true
end

---Exact first-load bytes, including entries whose reload capability was refused.
function Plugin:_LoadedSource(file)
    local entry = self._loads[file]
    return entry and entry.loaded_source or nil
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
		is_completed = function(file_name, content)
			return self:_IsCompleted(file_name, content)
		end,
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
function Plugin:_RunUIAction(action, file)
	if self._released then return "session ended" end
	if action ~= "apply" and action ~= "apply-file" and action ~= "retry" then return "unknown UI action" end
	if not self._commit then return "UI commit scope unavailable" end
	local ran, result = self._commit:Run(function(token)
		if action == "apply" then return self:Apply(token) end
		if action == "apply-file" then return self:ApplyFile(file,token) end
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
function Plugin:ApplyFileFromUI(file) return self:_RunUIAction("apply-file",file) end
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

-- Completion records never stand in for accepted source or commit permission.
function Plugin:_ClearCompletion(file)
    self._completion_checks[file] = nil
    self._store:ClearCompletion(file)
end

-- Cheap scope only: no disk, discovery, compilation or current-card capture.
function Plugin:_CompletionScope(file)
    if self._released or self._publication_error or not self._commit or self._commit:Poisoned() then return nil end
    local ok = self:_CheckLoad(file)
    local capture = self:GetVersions(file)
    if not ok or type(capture)~="table" or getmetatable(capture)~=nil
        or type(capture.snapshot)~="table" or getmetatable(capture.snapshot)~=nil then return nil end
    return {session_id=self._session_id, capture=capture, snapshot=capture.snapshot,
        entry=self._loads[file], revision=capture.snapshot.revision}
end

-- Watcher supplies the bytes it just read. A saved completion is not trusted
-- when versions, ownership, function values or original shared cells changed.
function Plugin:_IsCompleted(file, content)
    local record = self._completion_checks[file]
    if not record then return false end
    local scope = self:_CompletionScope(file)
    if not self._store:IsCompleted(file,content,scope) then self:_ClearCompletion(file);return false end
    local checked = require("SpellHotReload.Apply.CommitCheck").Check(record.selection,scope.capture,
        {capture=scope.capture, snapshot=scope.snapshot, entry=scope.entry, session_id=scope.session_id,
            classes=rawget(_G,"_editor_class"), content=content, released=false, poisoned=false})
    if not checked then self:_ClearCompletion(file);return false end
    return true
end

-- Last checked remainder is display data, never Apply/removal permission.
function Plugin:GetCandidateRemainder(file)
    local record = self._candidate_remainders[file]
    if not record then return nil end
    local candidate, scope = self._store:GetCandidate(file), self:_CompletionScope(file)
    if not scope or not candidate or not candidate.stable
        or scope.capture~=record.capture or scope.snapshot~=record.snapshot
        or scope.session_id~=record.model.session_id or scope.entry~=record.entry
        or candidate.generation~=record.model.generation or candidate.first_content~=record.model.content then
        self._candidate_remainders[file]=nil;return nil
    end
    return copy_display(record.model)
end

local function remainder_text(model, selection)
    local rows = {}
    for _, row in ipairs(selection.blocked or {}) do rows[#rows+1]=row.key .. ": " .. row.reason end
    for _, row in ipairs(selection.pending_sources or {}) do
        rows[#rows+1]=row.source_key .. " source slot " .. row.candidate_slot .. ": " .. row.reason
    end
    for _, row in ipairs(selection.structural_pending or {}) do rows[#rows+1]=row.source_key .. ": " .. row.reason end
    for _, row in ipairs(model.pending) do
        local point = row.first and (" bytes " .. row.first .. ".." .. tostring(row.last)) or ""
        rows[#rows+1] = row.kind .. " " .. row.key .. point .. ": " .. row.reason
    end
    return "; candidate retained; pending: " .. table.concat(rows," | ")
end

-- Both Apply paths call only after a successful real Driver/CardCommit receipt.
-- No SetAccepted, Dismiss, second commit, or partial-ledger reset is allowed.
function Plugin:_AccountVersioned(file, candidate, capture, base, receipt)
    self:_ClearCompletion(file)
    self._candidate_remainders[file] = nil
    local snapshot = type(receipt)=="table" and receipt.snapshot
    if type(receipt)~="table" or getmetatable(receipt)~=nil
        or receipt.kind~="SpellHotReload.CardCommit.Receipt" or receipt.version~=1
        or type(snapshot)~="table" or getmetatable(snapshot)~=nil
        or receipt.file~=file or snapshot~=capture.snapshot
        or snapshot.session_id~=self._session_id or snapshot.entry~=self._loads[file]
        or snapshot.file~=file or snapshot.anchor~=base.anchor
        or (receipt.changed~=true and receipt.changed~=false)
        or (receipt.changed and (snapshot==base or snapshot.revision~=base.revision+1))
        or (not receipt.changed and snapshot~=base) then
        self._publication_error="publication receipt bookkeeping failed; restart game"
        return nil, self._publication_error
    end
    if receipt.changed then
        local recorded, record, record_error = pcall(self._store.RecordPartialPublication,
            self._store,file,candidate.generation,candidate.first_content,snapshot.revision)
        if not recorded or not record then
            self._publication_error="partial publication bookkeeping failed; restart game"
            return nil, self._publication_error .. ": " .. message(recorded and record_error or record)
        end
    end
    local refresh = function() return self:_FreshVersioned(file,candidate,capture,true) end
    local live, lerr = refresh()
    if not live then return nil, message(lerr) end
    local discovery, derr = self:_DiscoverVersioned(file,candidate,capture)
    if not discovery then return nil, "discover: " .. message(derr) end
    local model, witness, fresh = require("SpellHotReload.Apply.FileApply").InspectFileRemainder(capture,discovery,live,refresh)
    if not model then return nil, message(witness) end
    if capture.snapshot~=snapshot or model.file~=file or model.session_id~=self._session_id
        or model.revision~=snapshot.revision or model.generation~=candidate.generation
        or model.content~=candidate.first_content then return nil, "remainder scope changed" end
    if not model.complete then
        self._candidate_remainders[file]={model=model,capture=capture,snapshot=snapshot,entry=fresh.entry}
        return remainder_text(model,witness)
    end
    if #model.pending~=0 then return nil, "complete remainder still contains pending changes" end
    local scope = self:_CompletionScope(file)
    if not scope or scope.snapshot~=snapshot then return nil, "completion scope changed" end
    local done, err = self._store:RecordCompletion(file,candidate.generation,candidate.first_content,scope)
    if not done then return nil, "completion bookkeeping: " .. message(err) end
    self._completion_checks[file]={selection=witness}
    return "; candidate complete; removed (published definitions + unchanged remainder)"
end

function Plugin:_FinishVersioned(file, candidate, capture, base, receipt)
    local called, status, err = pcall(self._AccountVersioned,self,file,candidate,capture,base,receipt)
    if not called then status,err=nil,status end
    if not status then
        self:_ClearCompletion(file)
        if self._publication_error then return "; " .. message(err) .. "; candidate retained" end
        return "; candidate retained (completion unavailable): " .. message(err)
    end
    return status
end

-- Actual physical read + fresh binding, not a cached table passed as "live".
-- Called before planning and AGAIN inside CardCommit after any cache callback.
function Plugin:_FreshVersioned(file, candidate, capture, file_scope)
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
    local binding, berr
    if not file_scope then
        binding, berr = Card.CaptureCurrent()
        if not binding then return nil, {code="stale", message="re-capture: " .. message(berr)} end
    end
    return {capture=capture, snapshot=capture.snapshot, entry=self._loads[file],
        session_id=self._session_id, classes=rawget(_G,"_editor_class"), content=content,
        binding=binding, released=self._released, poisoned=self._commit:Poisoned()}
end

-- Workflow reentry/lifecycle stays here; CurrentRestart owns frozen targets,
-- receipt association, full ownership checks and the concrete practice request.
function Plugin:_RestartVersioned(run)
    if self._restart_active then return nil, "restart is already active" end
    if not self._commit then return nil, "frozen restart target or session changed; restart game" end
    local live = {released=self._released, poisoned=self._commit:Poisoned(),
        publication_error=self._publication_error, session_id=self._session_id,
        entry=self._loads[run.file], classes=rawget(_G,"_editor_class")}
    self._restart_active = true
    local called, ok, err = pcall(CurrentRestart.Request,run,live)
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
    local run = CurrentRestart.Freeze(target,capture)
    local handle, controller = prepared.handle, self._commit
    -- Driver binds/revokes the exact-input one-call writer. The unchanged
    -- Card kernel still owns every recoverable operation and final Guard/Consume.
    local committed, cerr, receipt = self._driver:CommitDiscovery(prepared.driver_prepared,
        function()
            return controller:Commit(token,selection,capture,live,handle.refresh)
        end)
    if not committed then return "commit: " .. message(cerr) end
    local bound, bind_error = CurrentRestart.BindReceipt(run,receipt,capture)
    if not bound then
        self._publication_error = "definitions committed; restart receipt refused: " .. message(bind_error)
        return self._publication_error
    end
    self._pending_restart_run = run
    local accounting = self:_FinishVersioned(file,candidate,capture,selection.base,receipt)
    if self._publication_error then return "definitions committed" .. accounting end
    local restarted, restart_error = self:_RestartVersioned(run)
    if not restarted then return "definitions committed; restart failed: " .. message(restart_error) .. accounting end
    self._pending_restart_run = nil
    return string.format("applied %s slot %d (%s): %s%s",
        target.class_key,target.slot,location.match,receipt.changed and "definitions committed" or "no definition changes",
        "; restart requested" .. accounting)
end

---Publish one explicitly named file's captured Card/function definitions.
---No practice selection, frozen restart, whole-file ACK or legacy fallback.
function Plugin:ApplyFile(file, token)
    self._candidate_inspections = {}
    if self._released then return "session ended" end
    local called, result = pcall(self._applyFile,self,file,token)
    if not called then result = "file apply failed: " .. message(result) end
    self._last_result = result
    log(self,result:sub(1,7)=="applied" and "ok" or "warn",result)
    return result
end

function Plugin:_applyFile(file, token)
    if type(file)~="string" or file=="" then return "candidate file required" end
    if not self._activated or not self._supported then return "plugin not active/supported" end
    if not self._sandbox_ok then return "patch capability unavailable" end
    if self._driver_error then return "driver: " .. message(self._driver_error) end
    if self._publication_error then return self._publication_error end
    if self._restart_active or self._pending_restart_run then return "retry restart first" end
    if Card.IsReplay() then return "replay mode not supported" end
    if not self._commit then return "versioned UI scope unavailable" end
    local scoped, scope_error = self._commit:Check(token)
    if not scoped then return "versioned UI scope: " .. message(scope_error) end
    local candidate = self._store:GetCandidate(file)
    if not candidate or not candidate.stable then return "stable candidate required" end
    local capture, why = self:GetVersions(file)
    if not capture then return "first-load versions unavailable: " .. message(why) .. "; restart game" end
    local gate = Card.CheckCandidateSource(candidate.first_content,file)
    if not gate.ok then return "source: " .. message(gate.error) end
    local live, lerr = self:_FreshVersioned(file,candidate,capture,true)
    if not live then return "file preflight: " .. message(lerr) end
    local discovery, derr = self:_DiscoverVersioned(file,candidate,capture)
    if not discovery then return "discover: " .. message(derr) end
    local refresh = function() return self:_FreshVersioned(file,candidate,capture,true) end
    local has_card=false
    for _,entry in ipairs(discovery.snapshot.entries) do
        if entry.adapter==Card then has_card=true;break end
    end
    if not has_card then
        -- Old-only publications still need full accounting. No fake candidate
        -- key, empty commit/receipt, helper write, restart or completion record.
        self:_ClearCompletion(file)
        self._candidate_remainders[file]=nil
        local model,witness,fresh=require("SpellHotReload.Apply.FileApply").InspectFileRemainder(
            capture,discovery,live,refresh)
        if not model then return "file remainder: "..message(witness).."; candidate retained" end
        if model.complete then return "file remainder has no Card aggregate; candidate retained" end
        self._candidate_remainders[file]={model=model,capture=capture,snapshot=capture.snapshot,entry=fresh.entry}
        return "pending file "..file..": no candidate Card aggregate; no definitions published; no restart"
            ..remainder_text(model,witness)
    end
    local prepared, perr = Card.PrepareFileVersioned(capture,discovery,live,refresh)
    if not prepared then return perr end
    local selection, controller = prepared.selection, self._commit
    local committed, cerr, receipt = self._driver:CommitDiscovery(prepared.driver_prepared,
        function()
            return controller:Commit(token,selection,capture,prepared.live,refresh)
        end)
    if not committed then return "commit: " .. message(cerr) end
    local accounting = self:_FinishVersioned(file,candidate,capture,selection.base,receipt)
    if self._publication_error then return "definitions committed" .. accounting end
    local status=receipt.changed and "definitions committed" or "no definition changes"
    local prefix=not receipt.changed and self._candidate_remainders[file] and "pending" or "applied"
    return string.format("%s file %s: %s; no restart%s",prefix,file,status,accounting)
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
        local discovery, derr = self:_DiscoverVersioned(file,candidate,capture)
        if not discovery then return nil, "discover: " .. message(derr) end
        local prepared, perr = self:_PrepareVersioned(file,candidate,capture,discovery,initial)
        if not prepared then return nil, perr end
        -- Reuse this current-root report for read-only file leftovers. This is
        -- not file Apply preflight, selection, or commit/removal permission.
        local inspected, remainder, diagnostic = pcall(
            require("SpellHotReload.Apply.FileApply").Remaining, prepared.selection.report)
        local model, fresh = Card.InspectPrepared(prepared,capture,function()
            return self:_FreshVersioned(file,candidate,capture)
        end)
        if not model then return nil, fresh end
        model.file_remainder = inspected and remainder and {pending=remainder.pending}
            or {error=message(inspected and diagnostic or remainder)}
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
                    discovery, derr = self:_DiscoverVersioned(file,candidate,capture)
                    if not discovery then return "discover: " .. message(derr) end
                    matches = Card.DefinesCurrent(discovery,current)
                else
                    local unmatched, discovery_error = self._driver:Discover(file,candidate.first_content,{
                        session_id=self._session_id,candidate_generation=candidate.generation})
                    if not unmatched then return "discover: " .. message(discovery_error) end
                    if Card.DefinesCurrent(unmatched,current) then
                        return "first-load entry unavailable; restart game"
                    end
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
    return self:_ApplyVersioned(token,target_file,target_candidate,target_capture,target_discovery,current)
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
    if not self._commit then return "versioned UI scope unavailable" end
    local scoped, err = self._commit:Check(token)
    if not scoped then return "versioned UI scope: " .. message(err) end
    local ok, why = self:_RestartVersioned(run)
    local result = ok and "restart requested" or ("restart failed: " .. message(why))
    if ok then self._pending_restart_run = nil end
    self._last_result = result
    log(self,ok and "ok" or "error",result)
    return result
end

---@param file_name string
function Plugin:Dismiss(file_name)
	if self._released then return false, "session ended" end
	-- Remember the rejected bytes so the drift scan does not resurrect the
	-- candidate on the next interval.
	self._candidate_inspections[file_name] = nil
	self._candidate_remainders[file_name] = nil
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
