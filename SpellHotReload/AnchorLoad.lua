--------------------------------------------------------------------------------
--- SpellHotReload.AnchorLoad
---
--- The R2 load-path capture output: run one generated file exactly once and get
--- both the legacy `name -> value` map and the file's anchor out of that single
--- execution.
---
--- Anchor.lua already models "one file, one anchor" and LoadCapture.lua already
--- generalizes the legacy map capture, but each of them runs the file for
--- itself. The production load path cannot pay two executions: the file body
--- registers stages, builds tables and starts music, and running it twice is
--- exactly the mistake the hook's trailer exists to avoid. This module owns the
--- joint output the hook needs:
---
---   Trailer   the dual trailer. It keeps the legacy `return { [name] = name }`
---             map as the chunk's *first* result - byte-derived from
---             LoadCapture.Trailer - and appends Anchor's anchor
---             closure as the *second*, so `results[1]` stays exactly what the
---             current hook stores and `results[2]` is the new model;
---   Capture   analyse with the shared TopLevelIR/Binding snapshot, apply the
---             Anchor policy, run once, and report the map, the anchor, the real
---             slots, the policy and whether the file may be hot-reloaded;
---   Get/Set   read and write through the anchor cell, so an external setter, a
---             function reassignment or a whole-table replacement is always
---             seen by every closure sharing the cell;
---   Values    a fresh map read through the anchor right now, for consumers that
---             want the map shape without owning a second source of truth.
---
--- `entry.map` is the load-time snapshot the legacy path already stored; it is
--- never live and must not be treated as the model state. `Values`/`Get`/`Set`
--- are the live accessors, and `entry.anchor` is what a later Apply must never
--- replace.
---
--- The policy keeps a file loading when it is not reloadable. A top-level
--- return, a duplicate top-level local, an unparsed statement, too many slots or
--- a runtime without `debug.upvaluejoin` still runs the file exactly once; the
--- map is still harvested - the legacy consumers must not regress, including on
--- vanilla Lua 5.1 - and only the reload capability is withheld with a clear
--- reason. Nothing here touches an engine global, joins a closure, writes a
--- cell or publishes anything.
--------------------------------------------------------------------------------

local Anchor = require("SpellHotReload.Anchor")
local Compose = require("SpellHotReload.Compose")
local Capture = require("SpellHotReload.LoadCapture")

local M = {}

M.Kind = "SpellHotReload.AnchorLoad"
M.Version = 1

local compile = loadstring or load
local unpack = table.unpack or unpack

local BOM = "\239\187\191"

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

---Pack a call so trailing nils survive.
local function pack(...)
    return { n = select("#", ...), ... }
end

--------------------------------------------------------------------------------
--- return values
--------------------------------------------------------------------------------

---Arity of the values the file's own chunk returned on this load. A captured
---file returns through the trailer instead, so its arity is 0.
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
--- trailer
--------------------------------------------------------------------------------

---Build the dual capture trailer for the given names.
---
---The map half is derived from `LoadCapture.Trailer`, so a hook
---that only reads `results[1]` keeps the exact bytes it stores today; the anchor
---half is derived from `Anchor.Trailer`, so the closure is the same shape the
---anchor service expects. Names are validated by `Anchor.Trailer` (a dense array
---of non-empty strings), never guessed here.
---@param names string[]
---@return string? trailer
---@return string? reason
function M.Trailer(names)
    local anchor_src, reason = Anchor.Trailer(names)
    if anchor_src == nil then
        return nil, reason
    end
    local map_src = Capture.Trailer(names)
    local map_expr = map_src:match("^return%s+(.*)$")
    local anchor_expr = anchor_src:match("^return%s+(.*)$")
    if map_expr == nil or anchor_expr == nil then
        return nil, "could not build the dual capture trailer"
    end
    return "return " .. map_expr .. ", " .. anchor_expr
end

--------------------------------------------------------------------------------
--- capture
--------------------------------------------------------------------------------

---Load `content` exactly once, as-is.
---@return table? packed  -- { n =, ... }
---@return string? error
---@return string? stage  -- "compile" | "run"
local function load_once(source, options)
    local chunk, cerr = compile(source, "@" .. tostring(options.name or "AnchorLoad"))
    if chunk == nil then
        return nil, "compile failed: " .. tostring(cerr), "compile"
    end
    local args = options.args or {}
    local ok, packed = pcall(function()
        return pack(chunk(unpack(args, 1, args.n or #args)))
    end)
    if not ok then
        return nil, "run failed: " .. tostring(packed), "run"
    end
    return packed
end

---Analyze and load `content` once, harvesting the legacy value map and the file
---anchor from the same execution.
---
---The map survives every refusal the policy or the runtime can produce; only
---the anchor and the reload verdict degrade, each with its own reason:
---
---   top-level return        maps to a plain single load, own values preserved
---   names that cannot form   the same plain single load, never a second run
---   a trailer that does not  plain single load (compile) or map kept without
---   compile                  an anchor, depending on how far it got
---   no anchor / no slots     map kept, reload denied, reason recorded
---   policy refusal           map and anchor kept, reload denied
---   missing `upvaluejoin`    map and anchor kept, reload denied
---
---@param content string
---@param options table?  -- { name=, analysis=, bindings=, ir_options=, limit=,
---                       --   capability=, args={n=,...} }
---@return table? entry  -- { policy, names, loaded_source, map, anchor, slots,
---                       --   order, captured, reloadable, reason, ret }
---@return string? error
---@return string? stage  -- "analyze" | "compile" | "run" | "capture"
function M.Capture(content, options)
    options = options or {}
    if type(content) ~= "string" then
        return nil, "content must be a string", "analyze"
    end
    local policy, perr = Anchor.Policy(content, options)
    if policy == nil then
        return nil, tostring(perr), "analyze"
    end

    local source = content
    if source:sub(1, 3) == BOM then source = source:sub(4) end

    local result = {
        policy = policy, names = policy.names, loaded_source = content,
        map = nil, anchor = nil, slots = nil, order = nil,
        captured = false, reloadable = false, reason = nil, ret = pack(),
    }

    -- A top-level return cannot be followed by a trailer, and a name list the
    -- builders refuse cannot become one either. Both load exactly once, as-is.
    if policy.has_return then
        local packed, err, stage = load_once(source, options)
        if packed == nil then return nil, err, stage end
        result.ret = packed
        result.reason = policy.reason
        return result
    end

    local trailer, terr = M.Trailer(policy.names)
    if trailer == nil then
        local packed, err, stage = load_once(source, options)
        if packed == nil then return nil, err, stage end
        result.ret = packed
        result.reason = "trailer: " .. tostring(terr)
        return result
    end

    local chunk, cerr = compile(source .. "\n" .. trailer,
        "@" .. tostring(options.name or "AnchorLoad"))
    if chunk == nil then
        -- The splitter can miss a return; the trailer then cannot be appended.
        -- The file must still load exactly once, as the engine would load it.
        local packed, err, stage = load_once(source, options)
        if packed == nil then return nil, err, stage end
        result.ret = packed
        result.reason = "trailer compile failed: " .. tostring(cerr)
        return result
    end

    local args = options.args or {}
    local ok, packed = pcall(function()
        return pack(chunk(unpack(args, 1, args.n or #args)))
    end)
    if not ok then
        return nil, "run failed: " .. tostring(packed), "run"
    end

    local map, anchor = packed[1], packed[2]
    if not plain(map) then
        result.reason = "capture trailer did not return a value map"
        return result
    end
    result.map = map
    result.captured = true

    if type(anchor) ~= "function" then
        result.reason = "capture trailer did not return an anchor function"
        return result
    end
    local slots, order, serr = Anchor.Slots(anchor, policy.names)
    if slots == nil then
        result.reason = "capture: " .. tostring(serr)
        return result
    end
    result.anchor = anchor
    result.slots = slots
    result.order = order

    if not policy.reloadable then
        result.reason = policy.reason
        return result
    end
    local capability = options.capability or Compose.Capability(debug)
    local supported, creason = Anchor.Supported(capability)
    if not supported then
        result.reason = "capability: " .. tostring(creason)
        return result
    end
    result.reloadable = true
    return result
end

--------------------------------------------------------------------------------
--- live access
--------------------------------------------------------------------------------

---Read one name through the anchor cell. A nil value is a success
---(`reason == nil`), so a name holding nil is still distinguishable from a name
---that does not exist.
---@param entry table
---@param name string
---@return any value
---@return string? reason
function M.Get(entry, name)
    if not plain(entry) then
        return nil, "entry must be a capture result"
    end
    if entry.anchor == nil then
        return nil, "entry has no captured anchor"
    end
    return Anchor.Get(entry, name)
end

---Write one name through the anchor cell, so every closure sharing the cell -
---including the file's own - sees the new value.
---@param entry table
---@param name string
---@param value any
---@return boolean
---@return string? reason
function M.Set(entry, name, value)
    if not plain(entry) then
        return false, "entry must be a capture result"
    end
    if entry.anchor == nil then
        return false, "entry has no captured anchor"
    end
    return Anchor.Set(entry, name, value)
end

---A fresh map read through the anchor now. It is a snapshot for consumers that
---want the map shape; the anchor stays the source of truth. Names holding nil
---are necessarily absent from a Lua table map - `slots`/`Get` are what tell nil
---apart from missing.
---@param entry table
---@return table? values
---@return string? reason
function M.Values(entry)
    if not plain(entry) then
        return nil, "entry must be a capture result"
    end
    if entry.anchor == nil then
        return nil, "entry has no captured anchor"
    end
    return Anchor.Read(entry)
end

return M
