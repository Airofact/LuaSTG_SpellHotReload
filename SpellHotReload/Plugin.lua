--------------------------------------------------------------------------------
--- SpellHotReload.Plugin
---
--- Singleton lifecycle and orchestration. Owns the SnapshotStore, Watcher, and
--- View; resolves the mod root; activates the watcher from `afterTHlib` (resolve
--- root, probe, baseline, start watching) with a first-Tick fallback; and
--- implements the Apply / Retry / Dismiss / Rescan / Start-Stop Watching
--- transactions.
---
--- Apply routes the candidate file and validates the live binding itself (a
--- driver run plans exactly one file and cannot tell which candidate owns the
--- current card), then hands a `Card.Plan` run to the generic `Driver`, which
--- owns the Locate -> Inject -> Commit -> Restart phase discipline. A failed
--- stage restart keeps the committed run so `Driver:Restart` can retry it
--- without recompiling.
--------------------------------------------------------------------------------

local Watcher = require("SpellHotReload.Watcher")
local SnapshotStore = require("SpellHotReload.SnapshotStore")
local Scanner = require("SpellHotReload.GeneratedBossScanner")
local Loader = require("SpellHotReload.GeneratedBossLoader")
local Binding = require("SpellHotReload.PracticeBinding")
local ChangeLog = require("SpellHotReload.ChangeLog")
local UpvalueRegistry = require("SpellHotReload.UpvalueRegistry")
local Anchor = require("SpellHotReload.Anchor")
local AnchorRegistry = require("SpellHotReload.AnchorRegistry")
local Driver = require("SpellHotReload.Driver")
local Card = require("SpellHotReload.Card")

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
	-- The committed run whose stage restart failed; Driver:Restart retries it.
	self._pending_restart_run = nil
	return self
end

function Plugin:GetStore() return self._store end
function Plugin:GetRegistry() return self._registry end
function Plugin:GetAnchors() return self._anchors end
function Plugin:GetDriver() return self._driver end
function Plugin:GetLog() return self._log end
function Plugin:GetWatcher() return self._watcher end
function Plugin:GetView() return self._view end
function Plugin:SetView(view) self._view = view end
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
	self._registry:SetAll(file, functions)
	if self._anchors:Has(file) then
		self._anchors:SetAll(file, functions)
	end
end

---Fallback activation request from the `afterMod` hook. Activation normally
---happens from `afterTHlib`; this only takes effect if that path did not run.
function Plugin:RequestActivation()
	self._activation_requested = true
end

---Resolve the mod root, probe patch capability, capture the baseline, and start
---watching. Called from the plugin's `afterTHlib` hook, before the mod's own
---synchronous load. Idempotent: the first attempt wins, success or failure.
---@return boolean  true when the watcher is active
function Plugin:Activate()
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
	if not self._activation_attempted and self._activation_requested then
		self:Activate()
	end
	if self._activated and self._watcher ~= nil then
		self._watcher:update()
	end
end

function Plugin:_activate()
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

	local ok, serr = Loader.Probe()
	self._sandbox_ok = ok
	self._sandbox_error = serr
	if ok then
		log(self, "ok", "patch probe ok")
	else
		log(self, "error", "patch probe failed: " .. tostring(serr))
	end

	self._watcher = Watcher.New({
		root = root,
		store = self._store,
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

---Apply the current candidate to the current card and restart the practice.
---@return string
function Plugin:Apply()
	local result = self:_apply()
	self._last_result = result
	log(self, (result == "applied" or result:sub(1, 7) == "applied") and "ok" or "warn", result)
	return result
end

function Plugin:_apply()
	if not self._activated then return "not activated" end
	if not self._supported then return "unsupported: " .. tostring(self._unsupported_reason) end
	if not self._sandbox_ok then return "patch capability unavailable: " .. tostring(self._sandbox_error) end
	if self._driver_error ~= nil then return "driver: " .. tostring(self._driver_error) end

	local current, err = Binding.CaptureCurrent()
	if current == nil then return "capture: " .. tostring(err) end
	if Binding.IsReplay() then return "replay mode not supported" end

	-- Route the candidates to the single file that owns the current class. This
	-- stays at the plugin layer: a driver run plans one file and has no notion of
	-- "which candidate defines this card".
	local target_file
	for _, file_name in ipairs(self._store:GetCandidateFileNames()) do
		local cand = self._store:GetCandidate(file_name)
		if cand and cand.stable and cand.first_content then
			local gate = Scanner.Scan(cand.first_content, file_name)
			if not gate.ok then
				log(self, "warn", "apply: rejected " .. file_name .. ": " .. tostring(gate.error))
			elseif Scanner.ClassKeys(cand.first_content)[current.class_key] then
				if target_file then return "multiple candidate files define the current class" end
				if not self:_LoadedSource(file_name) then
					return "loaded source unavailable; restart game"
				end
				target_file = file_name
			end
		end
	end
	if not target_file then return "no stable candidate defines the current class" end

	-- Re-read the bytes shown in the UI and re-capture the live binding before
	-- planning. The driver compares statement text, not the live binding, so a
	-- card that moved under us must be caught here.
	local content, rerr = self._watcher:ReadFile(target_file)
	if not content then return "read: " .. tostring(rerr) end
	local cand = self._store:GetCandidate(target_file)
	if not cand or not cand.stable or content ~= cand.first_content then
		return "candidate bytes changed since snapshot"
	end
	local cur2, cerr = Binding.CaptureCurrent()
	if not cur2 then return "re-capture: " .. tostring(cerr) end
	if cur2.class_key ~= current.class_key or cur2.card ~= current.card or cur2.slot ~= current.slot then
		return "current binding changed (stale abort)"
	end

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
function Plugin:RetryRestart()
	local run = self._pending_restart_run
	if run == nil then
		log(self, "warn", "retry: nothing to retry")
		return "nothing to retry"
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
	-- Remember the rejected bytes so the drift scan does not resurrect the
	-- candidate on the next interval.
	self._store:DismissCandidate(file_name)
	self._last_result = "dismissed " .. file_name
	log(self, "info", "dismissed " .. file_name)
end

function Plugin:Rescan()
	if self._watcher == nil then return end
	self._watcher:rescan()
	log(self, "info", "rescan requested")
end

function Plugin:StartWatching()
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
