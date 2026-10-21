--------------------------------------------------------------------------------
--- SpellHotReload plugin bootstrap.
---
--- Registers one `afterTHlib` callback that instantiates the singleton, installs
--- the debug View, and initializes the Watcher (baseline + start). `afterTHlib`
--- runs after the launch script has resolved `setting.mod` and registered
--- `mod/<mod>/` on the search path, so the mod directory is already known;
--- watching then covers the mod's own synchronous load and the rest of the
--- session.
---
--- One `afterMod` callback remains as a safety net: activation is idempotent, so
--- it only initializes the watcher when `afterTHlib` did not.
--------------------------------------------------------------------------------

local lstg_debug = require("lib.Ldebug")
local Plugin = require("SpellHotReload.Runtime.Plugin")
local View = require("SpellHotReload.UI.View")
local LoadHook = require("SpellHotReload.Load.LoadHook")
local ObjectLoad = require("SpellHotReload.Adapters.Object.ObjectLoad")

local plugin = nil
local view = nil

local function ensure_loaded()
	if plugin ~= nil then
		return
	end
	plugin = Plugin.New()
	view = View
	view:initialize(plugin)
	plugin:SetView(view)
	lstg_debug.addView("lstg.debug.SpellHotReload", view)
	-- Keep the existing watch scope, but capture ALL top-level locals and the
	-- complete reload verdict from one normal execution, not the legacy hook.
	local ok, reason = LoadHook.Install(lstg, function(file, entry)
		return plugin:AdoptLoad(file, entry)
	end, { select = LoadHook.BossFile, capture = ObjectLoad.Capture })
	if not ok then error("SpellHotReload load hook: " .. tostring(reason)) end
	-- THlib's final GameExit is already defined here. FrameFunc and the engine
	-- can both call it: our cleanup is idempotent, but the previous callback must
	-- still run on every invocation with its arguments/results/errors unchanged.
	local original_GameExit = GameExit
	GameExit = function(...)
		LoadHook.Release(lstg)
		plugin:Release("game exit")
		if original_GameExit then return original_GameExit(...) end
	end
end

lstg.plugin.RegisterEvent("afterTHlib", "dims.debug.spellHotReload", 0, function()
	ensure_loaded()
	-- The mod search path is settled by now, so initialize the watcher here
	-- instead of deferring to the first Tick. This runs before the mod's own
	-- synchronous load, so the baseline is the bytes the mod is about to run.
	plugin:Activate()
end)

lstg.plugin.RegisterEvent("afterMod", "dims.debug.spellHotReload.activation", 0, function()
	ensure_loaded()
	plugin:RequestActivation()
end)
