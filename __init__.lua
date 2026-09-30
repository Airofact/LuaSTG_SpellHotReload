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
local Plugin = require("SpellHotReload.Plugin")
local View = require("SpellHotReload.View")
local Loader = require("SpellHotReload.GeneratedBossLoader")

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
	-- Intercept lstg.DoFile before the mod loads so Boss-file top-level locals
	-- are captured during normal load (the "file-level upvalue collection").
	Loader.InstallDoFileHook(plugin:GetRegistry())
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
