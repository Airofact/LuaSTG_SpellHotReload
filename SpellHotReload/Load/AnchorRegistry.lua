--------------------------------------------------------------------------------
--- SpellHotReload.Load.AnchorRegistry
---
--- The R2 file registry: `file -> anchor`, with the legacy `name -> value` map
--- demoted from state truth to a read-through view of that anchor.
---
--- UpvalueRegistry keeps a merged `name -> value` map per file and that map is
--- what every consumer reads. A sibling closure that reassigns a local - or a
--- setter the file itself exposes - makes the stored map stale, so the reload
--- path keeps republishing values instead of holding the cells. Anchor already
--- models "one file, one anchor" and reads and writes the real cells; this
--- module is the registry that speaks both languages:
---
---   Set     register the entry a file's first load produced (anchor + slots).
---           The first anchor wins: registering the same anchor again is an
---           idempotent no-op, and a different anchor for an already-held file
---           is refused, so a later Apply can never replace the cell a live
---           closure is still reading. A bare `name -> value` map is exactly
---           what this registry refuses to keep as state.
---   Get     a fresh `name -> value` snapshot read through the anchor right
---           now, in the legacy map shape. It is a snapshot, never a second
---           source of truth: `GetValue` reads one cell, `Write` writes one.
---   SetAll  the legacy publication call, redirected. Every name the anchor
---           holds is written through its slot, so the file's own closures and
---           every joined closure observe the new definition; a name the anchor
---           cannot hold goes to the pending overlay instead of being dropped,
---           so the legacy consumers that inject `name -> value` still see it.
---   Names   the names the anchor really holds - including locals whose current
---           value is nil or false, which a map can never express - plus any
---           pending names. `Slot`/`Slots` are what tell a nil cell apart from
---           a name the anchor never captured.
---
--- Read through the anchor, write through the anchor, and the registry stops
--- being a place where a value can go stale. The registry holds the anchor
--- strongly for as long as the session needs it and drops every reference only
--- on Release. A file that vanishes is marked missing and loses its reload
--- verdict while its anchor and cells stay readable.
---
--- Nothing here touches an engine global, a watcher, a driver or the UI; it is
--- the service the production load path publishes into and the Apply path asks
--- for the anchor it must never replace.
--------------------------------------------------------------------------------

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
        _sources = {},   -- file -> the exact bytes the file was loaded from
        _pending = {},   -- file -> name -> value the anchor cannot hold
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

---Sorted names: what the anchor holds, plus what only the overlay holds.
local function names_of(entry, overlay)
    local names, seen = {}, {}
    for name in pairs(entry.slots) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for name in pairs(overlay or {}) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

---A fresh snapshot of every slot, read through the anchor now. It is built from
---the actual slot table - not from a load-time order - so a registered entry
---needs nothing beyond `anchor` and `slots`.
local function read_slots(entry)
    local names = names_of(entry, nil)
    local values = {}
    for i = 1, #names do
        local value, reason = Anchor.Get(entry, names[i])
        if reason ~= nil then return nil, reason end
        values[names[i]] = value
    end
    return values
end

local function put_pending(self, file, name, value)
    local overlay = self._pending[file]
    if overlay == nil then
        overlay = {}
        self._pending[file] = overlay
    end
    overlay[name] = value
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
---file's source unless `SetSource` already recorded one.
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
    if self._sources[file] == nil and type(entry.loaded_source) == "string" then
        self._sources[file] = entry.loaded_source
    end
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
---cells included) plus the pending overlay.
---@return string[]? names
---@return string? reason
function Registry:Names(file)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    return names_of(entry, self._pending[file])
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

--------------------------------------------------------------------------------
--- the legacy map surface
--------------------------------------------------------------------------------

---A fresh `name -> value` snapshot read through the anchor right now.
---
---This is the drop-in shape for `UpvalueRegistry:Get`: same table, read at call
---time instead of at load time, so it cannot go stale. Nil cells are absent from
---the table - a map cannot express nil - which is what `Slot`/`GetValue` are for.
---@return table? values
---@return string? reason
function Registry:Get(file)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    local values, vreason = read_slots(entry)
    if values == nil then return nil, vreason end
    local overlay = self._pending[file]
    if overlay ~= nil then
        for name, value in pairs(overlay) do values[name] = value end
    end
    return values
end

---Read one name through the anchor cell. A nil value is a success
---(`reason == nil`), so a name holding nil is still distinguishable from a name
---that does not exist. A pending-only name answers from the overlay.
---@return any value
---@return string? reason
function Registry:GetValue(file, name)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    local value, vreason = Anchor.Get(entry, name)
    if vreason == nil then return value end
    local overlay = self._pending[file]
    if text(name) and overlay ~= nil and overlay[name] ~= nil then
        return overlay[name]
    end
    return nil, vreason
end

---Write one name. A name the anchor holds goes through its slot, so every
---closure sharing the cell - the file's own included - sees the new value; a
---name the anchor cannot hold lands in the pending overlay, never dropped.
---@return boolean
---@return string? reason
function Registry:Write(file, name, value)
    local entry, reason = entry_of(self, file)
    if entry == nil then return false, reason end
    if not text(name) then
        return false, "slot name must be a non-empty string"
    end
    if entry.slots[name] == nil then
        put_pending(self, file, name, value)
        return true
    end
    return Anchor.Set(entry, name, value)
end

---The legacy publication call: store a whole `name -> value` map for one file.
---
---Every name the anchor holds is written through its slot; every name it cannot
---hold goes to the pending overlay, which `Get`/`GetValue`/`Names` merge. The
---overlay exists only so a legacy consumer is not silently robbed of a name -
---the anchor remains the state for everything that has a cell.
---@param file string
---@param map table
---@return boolean
---@return string? reason
function Registry:SetAll(file, map)
    local entry, reason = entry_of(self, file)
    if entry == nil then return false, reason end
    if type(map) ~= "table" then
        return false, "map must be a table"
    end
    local written, pending = {}, {}
    for name in pairs(map) do
        if type(name) == "string" and entry.slots[name] ~= nil then
            written[#written + 1] = name
        else
            pending[#pending + 1] = name
        end
    end
    for i = 1, #written do
        local ok, wreason = Anchor.Set(entry, written[i], map[written[i]])
        if not ok then return false, wreason end
    end
    for i = 1, #pending do
        put_pending(self, file, pending[i], map[pending[i]])
    end
    return true
end

---The pending overlay for a file: names published without an anchor cell. It is
---a migration shim for legacy consumers, empty when there are none.
---@return table
function Registry:Pending(file)
    if not text(file) then return {} end
    return self._pending[file] or {}
end

---The load-time map the entry was captured with. It is a snapshot of the first
---load and never updated - `Get` is the live read.
---@return table? map
---@return string? reason
function Registry:Legacy(file)
    local entry, reason = entry_of(self, file)
    if entry == nil then return nil, reason end
    if entry.map == nil then
        return nil, "entry has no load-time map"
    end
    return entry.map
end

--------------------------------------------------------------------------------
--- source
--------------------------------------------------------------------------------

---Keep the actual loaded source, independently of the watcher baseline.
---@return boolean
function Registry:SetSource(file, content)
    if not text(file) then return false end
    self._sources[file] = content
    return true
end

---@return string?
function Registry:GetSource(file)
    if not text(file) then return nil end
    return self._sources[file]
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
    self._sources = {}
    self._pending = {}
    return true
end

return M
