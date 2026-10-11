--------------------------------------------------------------------------------
--- SpellHotReload.Load.UpvalueRegistry
---
--- A `file -> (name -> value)` store of a generated Boss file's top-level locals,
--- captured at load time by intercepting `lstg.DoFile` (see GeneratedBossLoader).
--- The registry is the "file-level upvalue collection": when a changed fragment is
--- recompiled for hot-reload, its free variables (sibling `local function`s) are
--- injected from here via `debug.setupvalue`.
--------------------------------------------------------------------------------

local Registry = {}
Registry.__index = Registry

---@return table
function Registry.New()
	return setmetatable({ _files = {}, _sources = {} }, Registry)
end

-- Keep the actual loaded source for card identity checks, independently of the
-- watcher baseline (which may be read after an editor export).
function Registry:SetSource(file, content)
	self._sources[file] = content
end

function Registry:GetSource(file)
	return self._sources[file]
end

---Store a whole `name -> value` map for one file.
---@param file string
---@param map table<string, any>
function Registry:SetAll(file, map)
	assert(type(file) == "string", "file must be a string")
	if type(map) ~= "table" then return end
	local entry = self._files[file]
	if entry == nil then
		entry = {}
		self._files[file] = entry
	end
	for name, value in pairs(map) do
		entry[name] = value
	end
end

---@param file string
---@return table<string, any>?
function Registry:Get(file)
	return self._files[file]
end

---@param file string
---@param name string
---@return any
function Registry:GetValue(file, name)
	local entry = self._files[file]
	if entry == nil then return nil end
	return entry[name]
end

---@param file string
---@return string[]
function Registry:Names(file)
	local entry = self._files[file]
	local result = {}
	if entry ~= nil then
		for name in pairs(entry) do
			result[#result + 1] = name
		end
	end
	return result
end

---Drop session-owned maps and loaded-source bytes, without mutating maps held
---by other consumers. Reusable, like AnchorRegistry:Release; idempotent.
function Registry:Release()
	self._files = {}
	self._sources = {}
	return true
end

return Registry
