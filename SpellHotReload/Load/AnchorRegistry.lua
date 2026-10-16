-- First-load anchor ownership and read-only cell queries.
-- Missing files retain their cells until session release.
local Anchor = require("SpellHotReload.Load.Anchor")

local M = {}

M.Kind = "SpellHotReload.AnchorRegistry"
M.Version = 1

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function text(value)
    return type(value) == "string" and value ~= ""
end

local Registry = {}
Registry.__index = Registry

---Open an empty registry. Files enter it through `Set` once a load produced
---their anchor.
---@return table
function M.New()
    return setmetatable({
        _entries = {},   -- file -> the entry that carries the anchor
        _order = {},     -- registration order, so Files can sort a stable set
    }, Registry)
end

---The registered entry for a file, or a reason when there is none.
local function entry_of(self, file)
    if not text(file) then
        return nil, "file must be a non-empty string"
    end
    local entry = self._entries[file]
    if entry == nil then
        return nil, "unknown file: " .. file
    end
    return entry
end

local function names_of(entry)
    local names = {}
    for name in pairs(entry.slots) do names[#names+1] = name end
    table.sort(names)
    return names
end

--------------------------------------------------------------------------------
--- registration
--------------------------------------------------------------------------------

---Register the anchor a file's first load produced.
---
---An entry must carry the anchor and the slots that name its cells. Registering
---the same anchor twice is an idempotent no-op; a different anchor for a file
---already held is refused, because replacing it would leave every live closure
---reading the old cell. The entry's `loaded_source`, when present, becomes the
---file's immutable first-load source.
---@param file string
---@param entry table  -- { anchor=, slots=, loaded_source=, map=, ... }
---@return boolean
---@return string? reason
function Registry:Set(file, entry)
    if not text(file) then
        return false, "file must be a non-empty string"
    end
    if not plain(entry) or type(entry.anchor) ~= "function" or not plain(entry.slots) then
        return false, "entry must carry an anchor and its slots"
    end
    local existing = self._entries[file]
    if existing ~= nil then
        if existing.anchor == entry.anchor then return true end
        return false, "file already registered with another anchor: " .. file
    end
    self._entries[file] = entry
    self._order[#self._order + 1] = file
    return true
end

--------------------------------------------------------------------------------
--- queries
--------------------------------------------------------------------------------

---@return boolean
function Registry:Has(file)
    if not text(file) then return false end
    return self._entries[file] ~= nil
end

---The entry holding the file's anchor, or nil with a reason.
---@return table? entry
---@return string? reason
function Registry:Entry(file)
    return entry_of(self, file)
end

---The anchor closure itself. It is what a later Apply must never replace.
---@return function? anchor
---@return string? reason
function Registry:Anchor(file)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    return entry.anchor
end

---The file's live slot table (`name -> upvalue index`).
---@return table? slots
---@return string? reason
function Registry:Slots(file)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    return entry.slots
end

---The upvalue index of one name, or nil with a reason. A nil index means the
---anchor never captured the name - not that the cell currently holds nil.
---@return integer? index
---@return string? reason
function Registry:Slot(file, name)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    return Anchor.Slot(entry, name)
end

---@return string[]  -- sorted file keys
function Registry:Files()
    local files, seen = {}, {}
    for _, file in ipairs(self._order) do
        if self._entries[file] ~= nil and not seen[file] then
            seen[file] = true
            files[#files + 1] = file
        end
    end
    table.sort(files)
    return files
end

---@return integer
function Registry:Size()
    local count = 0
    for _ in next, self._entries do count = count + 1 end
    return count
end

---Every name the file answers for, sorted: the anchor's slots (nil and false
---cells included).
---@return string[]? names
---@return string? reason
function Registry:Names(file)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    return names_of(entry)
end

---Whether the file may be hot-reloaded right now: captured as reloadable and
---not invalidated by a vanished file.
---@return boolean
function Registry:Live(file)
    if not text(file) then return false end
    local entry = self._entries[file]
    if entry == nil then return false end
    return Anchor.Live(entry)
end

---A vanished file only invalidates reload. The anchor and its live cells stay
---held while any consumer may still reference them.
---@return boolean
---@return string? reason
function Registry:Missing(file)
    local entry, reason = entry_of(self, file)
    if entry == nil then return false, reason end
    entry.missing = true
    return true
end

---Read the current value of one captured cell. Nil with no reason is success.
function Registry:GetValue(file, name)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    return Anchor.Get(entry, name)
end

---The bytes captured by the registered entry, never a watcher baseline.
function Registry:GetSource(file)
    local entry = entry_of(self, file)
    return entry and entry.loaded_source or nil
end

--------------------------------------------------------------------------------
--- lifecycle
--------------------------------------------------------------------------------

---Drop every strong reference (session end or a supported mod switch).
---Idempotent.
---@return boolean
function Registry:Release()
    self._entries = {}
    self._order = {}
    return true
end

return M
