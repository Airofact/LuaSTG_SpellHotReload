--------------------------------------------------------------------------------
--- SpellHotReload.Load.AnchorSession
---
--- The R2 session half of "one file, one anchor": it owns the first load of a
--- supported file, keeps the anchor that load produced, and defines when the
--- registry is held and when it is released.
---
--- SpellHotReload.Anchor already captures a file exactly once, reads and writes
--- its real cells and offers a first-load-wins registry stub. This module adds
--- the lifecycle the contract requires on top of that service:
---
---   Load       first load wins - a file is executed at most once per session.
---              Loading the same bytes again is an idempotent no-op; loading
---              different bytes for an already-loaded file is refused, because
---              that is an Apply, not a load. A file the anchor policy refuses
---              (top-level return, duplicate declaration, opaque statement,
---              slot limit, incapable runtime) is still executed exactly once
---              and remembered as non-reloadable - never re-run, never
---              silently dropped.
---   Missing    a vanished file only invalidates reload; the anchor and its
---              live cells stay held while any consumer may still reference
---              them, and readers still see the current cell contents.
---   SwitchMod  a supported mod switch releases the old registry/analysis
---              references and bumps the generation, keeping the session
---              usable without pretending the old anchors are still current.
---   Release    session end - drops every strong reference and closes the
---              session; later loads answer `session is closed`.
---
--- Following the R0 contract, closing the tool or stopping the watcher is NOT a
--- session end and must not clear anchors. That decision belongs to the caller,
--- which simply never calls Release. Nothing here touches an engine global, a
--- watcher or the UI: this is the piece the future production load path calls,
--- and the piece the Apply pipeline asks for the anchor it must never replace.
--------------------------------------------------------------------------------

local Anchor = require("SpellHotReload.Load.Anchor")

local M = {}

M.Kind = "SpellHotReload.AnchorSession"
M.Version = 1

local unpack = table.unpack or unpack

local function text(value)
    return type(value) == "string" and value ~= ""
end

local Session = {}
Session.__index = Session

---Drop the session's own bookkeeping and, when the session created the store,
---release it too. An injected store is left alone: the caller that shared it
---owns its lifetime.
local function drop(self)
    self._entries = {}
    self._order = {}
    if self._owns_store then
        self._store:Release()
    end
end

--------------------------------------------------------------------------------
--- return values
--------------------------------------------------------------------------------

---Arity of the values the file's own chunk returned on first load.
---@param entry table?
---@return integer
function M.ReturnArity(entry)
    local ret = entry ~= nil and entry.ret or nil
    return ret ~= nil and ret.n or 0
end

---The file's own return values at full arity (trailing nils kept).
---@param entry table?
---@return any
function M.ReturnValues(entry)
    local ret = entry ~= nil and entry.ret or nil
    if ret == nil then return end
    return unpack(ret, 1, ret.n)
end

--------------------------------------------------------------------------------
--- construction
--------------------------------------------------------------------------------

---Open a session. `options.id` names it (default `"session"`); `options.store`
---injects an anchor store (default: a fresh one the session owns and releases);
---`options.limit`/`options.capability`/`options.ir_options` are the defaults
---every Load inherits.
---@param options table?  -- { id=, store=, limit=, capability=, ir_options= }
---@return table? session
---@return string? reason
function M.New(options)
    if options == nil then options = {} end
    if type(options) ~= "table" then
        return nil, "options must be a table"
    end
    local id = options.id
    if id == nil then id = "session" end
    if not text(id) then
        return nil, "id must be a non-empty string"
    end
    local store, owns_store
    if options.store == nil then
        store, owns_store = Anchor.NewStore(), true
    else
        store, owns_store = options.store, false
        if type(store) ~= "table" or type(store.Set) ~= "function"
            or type(store.Release) ~= "function" then
            return nil, "store must be an anchor store"
        end
    end
    return setmetatable({
        id = id,
        _generation = 1,
        _entries = {},
        _order = {},
        _store = store,
        _owns_store = owns_store,
        _closed = false,
        _limit = options.limit,
        _capability = options.capability,
        _ir_options = options.ir_options,
    }, Session)
end

--------------------------------------------------------------------------------
--- first load
--------------------------------------------------------------------------------

---Load `file` once and keep its anchor for the session.
---
---The first call runs the file exactly once (through the anchor service) and
---records the entry. A later call with identical bytes returns the same entry
---without running anything; a later call with different bytes is refused, so a
---first load can never be replayed through this path.
---@param file string
---@param content string
---@param options table?  -- { analysis=, bindings=, ir_options=, limit=,
---                       --   capability=, args={n=,...} }
---@return table? entry
---@return string? reason
---@return string? stage  -- "lifecycle" | "analyze" | "compile" | "run" | "capture"
function Session:Load(file, content, options)
    if not text(file) then
        return nil, "file must be a non-empty string", "lifecycle"
    end
    if type(content) ~= "string" then
        return nil, "content must be a string", "lifecycle"
    end
    if self._closed then
        return nil, "session is closed", "lifecycle"
    end
    if options == nil then options = {} end
    if type(options) ~= "table" then
        return nil, "options must be a table", "lifecycle"
    end

    local existing = self._entries[file]
    if existing ~= nil then
        if existing.loaded_source == content then
            return existing
        end
        return nil, "file already loaded with different source: " .. file, "lifecycle"
    end

    local entry, err, stage = Anchor.Capture(content, {
        name = file,
        analysis = options.analysis,
        bindings = options.bindings,
        ir_options = options.ir_options or self._ir_options,
        limit = options.limit or self._limit,
        capability = options.capability or self._capability,
        args = options.args,
    })
    if entry == nil then
        return nil, tostring(err), stage or "capture"
    end

    entry.file = file
    entry.session_id = self.id
    entry.generation = self._generation
    self._entries[file] = entry
    self._order[#self._order + 1] = file

    if type(entry.anchor) == "function" then
        local ok, sreason = self._store:Set(file, entry)
        if not ok then
            -- The registry must never hold a second anchor for one file. If it
            -- ever does, the session bookkeeping is inconsistent and the load
            -- must not be reported as successful.
            self._entries[file] = nil
            return nil, "store refused anchor: " .. tostring(sreason), "lifecycle"
        end
    end
    return entry
end

--------------------------------------------------------------------------------
--- queries
--------------------------------------------------------------------------------

---@return table? entry
function Session:Get(file)
    if not text(file) then return nil end
    return self._entries[file]
end

---@return boolean
function Session:Has(file)
    if not text(file) then return false end
    return self._entries[file] ~= nil
end

---The anchor of a loaded file, or nil when it could not be captured.
---@return function?
function Session:Anchor(file)
    local entry = self:Get(file)
    return entry ~= nil and entry.anchor or nil
end

---The exact bytes the file was first loaded from.
---@return string?
function Session:Source(file)
    local entry = self:Get(file)
    return entry ~= nil and entry.loaded_source or nil
end

---Whether the file may be hot-reloaded right now: captured, not marked missing
---and the session still open.
---@return boolean
function Session:Live(file)
    if self._closed then return false end
    local entry = self:Get(file)
    if entry == nil then return false end
    return Anchor.Live(entry)
end

---@return string[]  -- sorted file keys
function Session:Files()
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
function Session:Size()
    local count = 0
    for _ in next, self._entries do count = count + 1 end
    return count
end

---The anchor store backing this session.
---@return table
function Session:Store()
    return self._store
end

---The generation the session is on; every entry records the one it loaded in.
---@return integer
function Session:Generation()
    return self._generation
end

---@return boolean
function Session:IsClosed()
    return self._closed
end

--------------------------------------------------------------------------------
--- lifecycle
--------------------------------------------------------------------------------

---A vanished file only invalidates reload. The entry, its anchor and its live
---cells stay held; readers still see whatever the cells hold now.
---@return boolean
---@return string? reason
function Session:Missing(file)
    if not text(file) then
        return false, "file must be a non-empty string"
    end
    local entry = self._entries[file]
    if entry == nil then
        return false, "unknown file: " .. file
    end
    entry.missing = true
    return true
end

---Release the registry and analysis references after a supported mod switch and
---start a new generation. The session stays open and usable; the anchors from
---the previous generation are gone, so nothing may keep assuming them.
---@return boolean
---@return string? reason
function Session:SwitchMod()
    if self._closed then
        return false, "session is closed"
    end
    drop(self)
    self._generation = self._generation + 1
    return true
end

---End the session: drop every strong reference and refuse further loads.
---Idempotent.
---@return boolean
function Session:Release()
    if not self._closed then
        drop(self)
        self._closed = true
    end
    return true
end

return M
