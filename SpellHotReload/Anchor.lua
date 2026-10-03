--------------------------------------------------------------------------------
--- SpellHotReload.Anchor
---
--- One file, one anchor: the load-time handle that keeps a generated file's
--- top-level locals in their real cells, so a later hot reload can connect a
--- freshly compiled closure to those same cells instead of replacing them.
---
--- This is the pure service behind R2 ("首次加载 Anchor 与注册表生命周期"):
---
---   Supported the capability gate - `getupvalue`/`setupvalue`/`upvaluejoin`
---             must be present, so a runtime without join never claims it can
---             hot-reload a shared unit;
---   Policy    read-only verdict over the shared TopLevelIR analysis and the
---             Binding declaration model: a top-level return, a duplicate
---             top-level local, an unparsed statement or too many slots is
---             loaded normally but marked non-reloadable;
---   Trailer   the `return function() return <locals> end` suffix that turns the
---             file's own chunk into the anchor factory;
---   Capture   run the file exactly once (with the trailer when allowed) and
---             enumerate the anchor's real slot indices, nil/false included;
---   Get/Set   read and write through the anchor cell, so an external setter, a
---             function reassignment or a whole-table replacement is always seen
---             by every closure sharing the cell;
---   Store     the per-session registry stub - first load wins (an anchor is
---             never replaced), a vanished file only invalidates reload, and
---             Release drops every strong reference.
---
--- The module never touches an engine global, never joins or replaces a live
--- closure and never publishes a callback; connecting new closures to these
--- cells is the later Apply pipeline. Nothing here runs wiring twice: a file
--- that cannot be captured is executed once, as-is.
--------------------------------------------------------------------------------

local IR = require("SpellHotReload.TopLevelIR")
local Binding = require("SpellHotReload.Binding")

local M = {}

M.Kind = "SpellHotReload.Anchor"
M.Version = 1
M.DefaultSlotLimit = 60

local compile = loadstring or load
local unpack = table.unpack or unpack

local BOM = "\239\187\191"

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function text(value)
    return type(value) == "string" and value ~= ""
end

local function integer(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
        and value == math.floor(value)
end

-- Do not use # alone: holes and extra keys must not be silently discarded.
local function dense(value)
    if not plain(value) then return nil end
    local count, max = 0, 0
    for key in next, value do
        if not integer(key) or key < 1 then return nil end
        count = count + 1
        if key > max then max = key end
    end
    if count ~= max then return nil end
    return count
end

---Pack a call so trailing nils survive.
local function pack(...)
    return { n = select("#", ...), ... }
end

--------------------------------------------------------------------------------
--- capability gate
--------------------------------------------------------------------------------

---Whether `capability` declares the debug facilities an anchor needs. This is a
---presence contract only: the module never experiments on the runtime to prove
---it, it reads what the runtime itself reports.
---@param capability table
---@return boolean
---@return string? reason
function M.Supported(capability)
    if type(capability) ~= "table" then
        return false, "capability must be a table"
    end
    if capability.getupvalue ~= true then
        return false, "debug.getupvalue is unavailable"
    end
    if capability.setupvalue ~= true then
        return false, "debug.setupvalue is unavailable"
    end
    if capability.upvaluejoin ~= true then
        return false, "debug.upvaluejoin is unavailable"
    end
    return true
end

---Read the facilities the running `runtime` reports. Presence only; the table
---is what `Supported` judges, so no closure is ever built or joined here.
---@param runtime table?  -- defaults to the global `debug`
---@return table capability  -- { getupvalue, setupvalue, upvaluejoin, upvalueid }
local function capability_of(runtime)
    if type(runtime) ~= "table" then runtime = {} end
    return {
        getupvalue = type(runtime.getupvalue) == "function",
        setupvalue = type(runtime.setupvalue) == "function",
        upvaluejoin = type(runtime.upvaluejoin) == "function",
        upvalueid = type(runtime.upvalueid) == "function",
    }
end

--------------------------------------------------------------------------------
--- trailer
--------------------------------------------------------------------------------

---Build the anchor trailer that returns a closure over the named locals.
---Indices are enumerated at capture time; this builder never assumes an order.
---@param names string[]
---@return string? trailer
---@return string? reason
function M.Trailer(names)
    local count = dense(names)
    if count == nil then
        return nil, "names must be a dense array of strings"
    end
    if count == 0 then
        return "return function() end"
    end
    local parts = {}
    for i = 1, count do
        local name = names[i]
        if not text(name) then
            return nil, "names must be a dense array of strings"
        end
        parts[i] = name
    end
    return "return function() return " .. table.concat(parts, ", ") .. " end"
end

--------------------------------------------------------------------------------
--- policy (read-only)
--------------------------------------------------------------------------------

---Decide whether a file can be captured, without executing it.
---@param content string
---@param options table?  -- { analysis =, bindings =, ir_options =, limit = }
---@return table? policy  -- { reloadable, reason, names, has_return, duplicates,
---                       --   opaque, statements, limit }
---@return string? reason
function M.Policy(content, options)
    if type(content) ~= "string" then
        return nil, "content must be a string"
    end
    options = options or {}
    local analysis = options.analysis
    if analysis == nil then
        local nodes, err, snapshot = IR.Analyze(content, options.ir_options)
        if nodes == nil or snapshot == nil then
            return nil, tostring(err or "top-level analysis failed")
        end
        analysis = snapshot
    end
    if not plain(analysis) or not plain(analysis.nodes) or not plain(analysis.statements) then
        return nil, "analysis must provide nodes and statements"
    end
    local bindings = options.bindings
    if bindings == nil then
        local err
        bindings, err = Binding.Analyze(analysis)
        if bindings == nil then
            return nil, tostring(err)
        end
    end
    if not plain(bindings) or not plain(bindings.names) or not plain(bindings.duplicates) then
        return nil, "bindings must provide names and duplicates"
    end
    local has_return = false
    for _, node in ipairs(analysis.nodes) do
        if node.kind == "return" then
            has_return = true
            break
        end
    end
    local names = {}
    for i = 1, #bindings.names do names[i] = bindings.names[i] end
    local limit = options.limit or M.DefaultSlotLimit
    if not integer(limit) or limit < 0 then limit = M.DefaultSlotLimit end

    local policy = {
        reloadable = true, names = names, has_return = has_return,
        duplicates = bindings.duplicates, opaque = bindings.opaque == true,
        statements = #analysis.statements, limit = limit,
    }
    if has_return then
        policy.reloadable = false
        policy.reason = "top-level return disables capture"
    elseif #bindings.duplicates > 0 then
        policy.reloadable = false
        policy.reason = "duplicate top-level local: " .. tostring(bindings.duplicates[1].name)
    elseif policy.opaque then
        policy.reloadable = false
        policy.reason = "unparsed top-level statement"
    elseif #names > limit then
        policy.reloadable = false
        policy.reason = "slot limit exceeded: " .. #names .. " > " .. limit
    end
    return policy
end

--------------------------------------------------------------------------------
--- anchor slots, read and write through
--------------------------------------------------------------------------------

---Enumerate an anchor's real upvalue slots. `expected`, when given, must match
---the captured names exactly (same count, every name present).
---@param anchor function
---@param expected string[]?
---@return table? slots  -- name -> upvalue index
---@return table? order  -- index -> name (diagnostic only)
---@return string? reason
function M.Slots(anchor, expected)
    if type(anchor) ~= "function" then
        return nil, nil, "anchor must be a function"
    end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
        return nil, nil, "debug.getupvalue is unavailable"
    end
    local slots, order, count = {}, {}, 0
    while true do
        count = count + 1
        local name = debug.getupvalue(anchor, count)
        if name == nil then break end
        if name == "" then
            return nil, nil, "anchor upvalue name is unavailable (debug info stripped)"
        end
        if slots[name] ~= nil then
            return nil, nil, "duplicate anchor slot: " .. name
        end
        slots[name] = count
        order[count] = name
    end
    local captured = count - 1
    if expected ~= nil then
        local total = dense(expected)
        if total == nil then
            return nil, nil, "expected names must be a dense array of strings"
        end
        for i = 1, total do
            if slots[expected[i]] == nil then
                return nil, nil, "anchor did not capture local: " .. tostring(expected[i])
            end
        end
        if captured ~= total then
            return nil, nil, "anchor captured " .. captured .. " upvalues for " .. total .. " locals"
        end
    end
    return slots, order
end

---Anchor slot index for a name, or nil when the entry cannot answer.
---@return integer? index
---@return string? reason
function M.Slot(entry, name)
    if not plain(entry) or type(entry.anchor) ~= "function" or not plain(entry.slots) then
        return nil, "entry has no captured anchor"
    end
    if not text(name) then
        return nil, "slot name must be a non-empty string"
    end
    local index = entry.slots[name]
    if index == nil then
        return nil, "unknown slot: " .. name
    end
    return index
end

---Read the current value of a slot through the anchor cell. A nil value is a
---success (`reason == nil`), so an external setter or a sibling closure that
---reassigned the local is always observed.
---@return any value
---@return string? reason
function M.Get(entry, name)
    local index, reason = M.Slot(entry, name)
    if index == nil then return nil, reason end
    local uname, value = debug.getupvalue(entry.anchor, index)
    if uname ~= name then
        return nil, "anchor slot drifted for '" .. tostring(name) .. "'"
    end
    return value
end

---Write a slot through the anchor cell via `debug.setupvalue`.
---@return boolean
---@return string? reason
function M.Set(entry, name, value)
    local index, reason = M.Slot(entry, name)
    if index == nil then return false, reason end
    local uname = debug.setupvalue(entry.anchor, index, value)
    if uname ~= name then
        return false, "anchor slot drifted for '" .. tostring(name) .. "'"
    end
    return true
end

---Fresh snapshot of every slot, read through the anchor now. It is a snapshot,
---never a second source of truth.
---@return table? values
---@return string? reason
function M.Read(entry)
    if not plain(entry) or not plain(entry.slots) then
        return nil, "entry has no slots"
    end
    local values = {}
    for _, name in ipairs(entry.order or {}) do
        local value, reason = M.Get(entry, name)
        if reason ~= nil then return nil, reason end
        values[name] = value
    end
    return values
end

---Whether two closures share one cell, via `debug.upvalueid`. Identity aid
---only; the anchor remains the holder.
---@return boolean
---@return string? reason
function M.Shared(entry, name, fn, index)
    local slot, reason = M.Slot(entry, name)
    if slot == nil then return false, reason end
    if type(fn) ~= "function" then return false, "fn must be a function" end
    if not integer(index) or index < 1 then
        return false, "index must be a positive integer"
    end
    if type(debug) ~= "table" or type(debug.upvalueid) ~= "function" then
        return false, "debug.upvalueid is unavailable"
    end
    local a = debug.upvalueid(entry.anchor, slot)
    local b = debug.upvalueid(fn, index)
    if a == nil or b == nil then return false, "upvalue index out of range" end
    return a == b
end

---Whether the entry may be hot-reloaded right now: captured and not invalidated
---by a vanished file.
---@return boolean
function M.Live(entry)
    if not plain(entry) then return false end
    return entry.reloadable == true and entry.missing ~= true
end

--------------------------------------------------------------------------------
--- capture
--------------------------------------------------------------------------------

local function run_chunk(source, options, name)
    local chunk, cerr = compile(source, "@" .. tostring(name or "Anchor"))
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

---Analyze and load `content` once, capturing the file anchor when the policy
---and the runtime capability allow it.
---
---A file that cannot be captured is still run exactly once, as-is, so its
---normal initialisation is honoured and its own return values are preserved.
---After the trailer chunk has run, a capture problem never re-runs the file.
---
---@param content string
---@param options table?  -- { name=, analysis=, bindings=, ir_options=,
---                       --   capability=, limit=, args={n=,...} }
---@return table? result  -- { captured, reloadable, reason, anchor, slots, order,
---                       --   names, missing, loaded_source, ret, policy }
---@return string? error
---@return string? stage  -- "analyze" | "compile" | "run" | "capture"
function M.Capture(content, options)
    options = options or {}
    if type(content) ~= "string" then
        return nil, "content must be a string", "analyze"
    end
    local policy, perr = M.Policy(content, options)
    if policy == nil then
        return nil, tostring(perr), "analyze"
    end

    local source = content
    if source:sub(1, 3) == BOM then source = source:sub(4) end

    local result = {
        captured = false, reloadable = false, anchor = nil, slots = nil,
        order = nil, names = policy.names, missing = false,
        loaded_source = content, ret = pack(), policy = policy,
    }

    -- Non-reloadable files (and files on an incapable runtime) load normally.
    local blocked
    if not policy.reloadable then
        blocked = policy.reason
    else
        local capability = options.capability or capability_of(debug)
        local supported, reason = M.Supported(capability)
        if not supported then blocked = "capability: " .. tostring(reason) end
    end
    if blocked ~= nil then
        local ret, err, stage = run_chunk(source, options, options.name)
        if ret == nil then return nil, err, stage end
        result.reason = blocked
        result.ret = ret
        return result
    end

    local trailer, terr = M.Trailer(policy.names)
    local chunk
    if trailer ~= nil then
        local cerr
        chunk, cerr = compile(source .. "\n" .. trailer,
            "@" .. tostring(options.name or "Anchor"))
        if chunk == nil then
            -- The trailer cannot be appended (e.g. a return the splitter missed):
            -- fall back to a plain single load instead of failing the file.
            local ret, err, stage = run_chunk(source, options, options.name)
            if ret == nil then return nil, err, stage end
            result.reason = "trailer compile failed: " .. tostring(cerr)
            result.ret = ret
            return result
        end
    else
        result.reason = "trailer: " .. tostring(terr)
        local ret, err, stage = run_chunk(source, options, options.name)
        if ret == nil then return nil, err, stage end
        result.ret = ret
        return result
    end

    local args = options.args or {}
    local ok, packed = pcall(function()
        return pack(chunk(unpack(args, 1, args.n or #args)))
    end)
    if not ok then
        return nil, "run failed: " .. tostring(packed), "run"
    end
    local anchor = packed[1]
    if type(anchor) ~= "function" then
        result.reason = "capture trailer did not return an anchor function"
        return result
    end
    local slots, order, serr = M.Slots(anchor, policy.names)
    if slots == nil then
        result.reason = "capture: " .. tostring(serr)
        return result
    end
    result.captured = true
    result.reloadable = true
    result.anchor = anchor
    result.slots = slots
    result.order = order
    result.reason = nil
    return result
end

--------------------------------------------------------------------------------
--- session store
--------------------------------------------------------------------------------

local Store = {}
Store.__index = Store

---Per-session registry stub: one anchor per file, first load wins.
---@return table
function M.NewStore()
    return setmetatable({ _entries = {}, _order = {} }, Store)
end

---Register a captured entry. Re-registering the same anchor is idempotent; a
---different anchor for a file already held is refused, so the anchor is never
---replaced.
---@return boolean
---@return string? reason
function Store:Set(file, entry)
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

---@return table? entry
function Store:Get(file)
    if not text(file) then return nil end
    return self._entries[file]
end

---@return boolean
function Store:Has(file)
    if not text(file) then return false end
    return self._entries[file] ~= nil
end

---A vanished file only invalidates reload; the anchor and its live cells stay
---held while any consumer may still reference them.
---@return boolean
---@return string? reason
function Store:Missing(file)
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

---@return string[]  -- sorted file keys
function Store:Files()
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
function Store:Size()
    local count = 0
    for _ in next, self._entries do count = count + 1 end
    return count
end

---Drop every strong reference (session end or a supported mod switch).
---@return boolean
function Store:Release()
    self._entries = {}
    self._order = {}
    return true
end

return M
