--------------------------------------------------------------------------------
--- SpellHotReload.GeneratedBossLoader
---
--- Legacy harvest + value-injection compatibility only. Production initial
--- load uses LoadHook -> AnchorLoad; analysis/composition use Lexer directly.
--- Compatibility facade for historical tests only. Fragment implementation now
--- lives in Legacy.Functions; no adapter imports this hook-owning module.
---
--- 1. Intercept `lstg.DoFile` so that when a `*_Boss.lua` file loads (during normal
---    mod load), its top-level `local function`s are captured into an
---    UpvalueRegistry. Capture is done by appending a trailer
---    `return { [name] = name, ... }` and running the file exactly as the engine
---    would — no sandbox, no env table, no re-execution of wiring.
---
---    (A return-hook + `debug.getlocal` capture was rejected: at a function's own
---    `return` event its locals are already cleared in Lua 5.1, so the hook cannot
---    enumerate them.)
---
--- 2. Recompile a single changed `local function` fragment from the new file and
---    inject the captured sibling upvalues into it via `debug.setupvalue`, so its
---    free variables resolve to the currently-loaded siblings without re-running
---    the whole file.
--- CardCallbacks additionally extracts and rebuilds the current card's callbacks.
--------------------------------------------------------------------------------

local Lexer = require("SpellHotReload.Source.Lexer")
local Functions = require("SpellHotReload.Legacy.Functions")
local Capture = require("SpellHotReload.Load.LoadCapture")

local Loader = {}

--------------------------------------------------------------------------------
--- helpers
--------------------------------------------------------------------------------

-- LuaJIT's `load` accepts a string; Lua 5.1 needs `loadstring`.
local function compile(src, name)
	if loadstring then
		return loadstring(src, name)
	end
	return load(src, name)
end

-- basename must match this pattern and be a direct child of the watch root
local BOSS_FILE_PATTERN = "^[A-Za-z0-9_%%%-]+_Boss%.lua$"

---Return the basename when `name` is a Boss file, else nil.
---@param name string
---@return string?
local function boss_basename(name)
	if type(name) ~= "string" then return nil end
	local base = name:match("([^/\\]+)$") or name
	if base:match(BOSS_FILE_PATTERN) then
		return base
	end
	return nil
end

---Read the source text of a Boss file (search-path aware, then mod directory).
---@param filename string
---@param base string
---@return string?
local function read_text(filename, base)
	local ok, content = pcall(lstg.LoadTextFile, filename)
	if ok and type(content) == "string" then
		return content
	end
	local mod = setting and setting.mod
	if type(mod) == "string" and mod ~= "" and mod ~= "launcher" then
		local path = "mod/" .. mod .. "/" .. base
		local ok2, content2 = pcall(lstg.LoadTextFile, path)
		if ok2 and type(content2) == "string" then
			return content2
		end
		local f = io.open(path, "rb")
		if f ~= nil then
			local c = f:read("*a")
			f:close()
			return c
		end
	end
	return nil
end

--------------------------------------------------------------------------------
--- interception
--------------------------------------------------------------------------------

---Build `return { [name] = name, ... }` for the given names.
---@param names string[]
---@return string
local function build_trailer(names)
	return Capture.Trailer(names)
end

function Loader.BuildTrailer(names)
	return build_trailer(names)
end

local _installed = false

---Replace `lstg.DoFile` with a wrapper that captures Boss-file locals. The first
---installation wins, so the hook stays bound to the registries it was handed.
---
---`capture` is an optional extension the anchor wiring supplies. When present,
---`capture.trailer(names)` may return the richer dual trailer (legacy value map
---plus anchor closure) and `capture.on_capture(base, content, names, results)`
---runs once the file has executed, so the anchor half of `results` can be
---registered without this compatibility module owning an anchor service.
---@param registry table  -- UpvalueRegistry instance
---@param capture table?  -- { trailer = function(names), on_capture = function(base, content, names, results) }
function Loader.InstallDoFileHook(registry, capture)
	if _installed then return end
	_installed = true

	local trailer_of = capture and capture.trailer or nil
	local on_capture = capture and capture.on_capture or nil

	local orig_DoFile = lstg.DoFile
	lstg.DoFile = function(filename, ...)
		local base = boss_basename(filename)
		if base ~= nil then
			local content = read_text(filename, base)
			if content ~= nil then
				local names = Loader.ListFunctionNames(content)
				-- The plain map trailer stays the default, so a capture extension
				-- that cannot build its richer trailer changes nothing.
				local trailer = build_trailer(names)
				if trailer_of ~= nil then
					local dual = trailer_of(names)
					if dual ~= nil then
						trailer = dual
					end
				end
				local chunk = compile(content .. "\n" .. trailer, "@" .. tostring(filename))
				if chunk ~= nil then
					local results = { chunk() }
					if type(results[1]) == "table" then
						registry:SetAll(base, results[1])
						registry:SetSource(base, content)
					end
					if on_capture ~= nil then
						on_capture(base, content, names, results)
					end
					return nil -- Boss files carry no meaningful return value
				end
			end
		end
		return orig_DoFile(filename, ...)
	end
end

-- Historical entry points delegate dynamically to shared utilities/legacy code.
-- Keep signatures for existing regression fixtures; production uses LoadHook.
function Loader.Tokenize(content)
    return Lexer.Tokenize(content)
end

function Loader.ListFunctionNames(content)
    return Functions.ListFunctionNames(content)
end

function Loader.ExtractFunction(content, name)
    return Functions.ExtractFunction(content, name)
end

function Loader.BuildFunction(fragment, name, registry_entry)
    return Functions.BuildFunction(fragment, name, registry_entry)
end

return Loader
