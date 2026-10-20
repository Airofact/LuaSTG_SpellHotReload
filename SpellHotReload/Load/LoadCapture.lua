--------------------------------------------------------------------------------
--- SpellHotReload.Load.LoadCapture
---
--- Generalized load-time capture service for the generic reload model.
---
--- The first-load capture path (LoadHook -> AnchorLoad) appends a
--- `return { [name] = name, ... }` trailer to `*_Boss.lua` so the file's
--- top-level `local function`s can be harvested. This module lifts that trick
--- into a pure, testable service:
---
---   * capture names come from TopLevelIR, so every top-level `local` is
---     harvested, not only `local function`;
---   * the file's own return values are preserved (a module ending in
---     `return M` is executed untouched);
---   * no engine global is touched - the caller supplies the content and
---     decides what to do with the captured map and the returned values.
---
--- Two execution shapes are chosen from the analyzed top-level statements:
---
---   side-effect file (no top-level `return`) -> append the trailer, capture
---                                               locals, own result is empty
---   module file (top-level `return`)         -> run as-is, return values
---                                               preserved, capture skipped
---
--- A top-level `return` must be the last statement of its block, so a trailer
--- can never be appended after one; that is why capture and return semantics
--- are mutually exclusive here. Nested `return`s (`function`, `if`, `do`)
--- do not block capture.
--------------------------------------------------------------------------------

local IR = require("SpellHotReload.Source.TopLevelIR")

local M = {}

local compile = loadstring or load
local unpack = table.unpack or unpack

local BOM = "\239\187\191"

---Pack a call into a table that records arity, so trailing nils survive.
---@param ... any
---@return table
local function pack(...)
    return { n = select("#", ...), ... }
end

function M.Pack(...)
    return pack(...)
end

---@param result table
---@return integer
function M.ReturnArity(result)
    local ret = result ~= nil and result.ret or nil
    return ret ~= nil and ret.n or 0
end

---Unpack the chunk's return values at full arity (trailing nils kept).
---@param result table
---@return any
function M.ReturnValues(result)
    local ret = result ~= nil and result.ret or nil
    if ret == nil then return end
    return unpack(ret, 1, ret.n)
end

--------------------------------------------------------------------------------
--- pure queries
--------------------------------------------------------------------------------

---Analyze source into carrier nodes; strips a leading UTF-8 BOM.
---@param content string
---@param options table?  -- forwarded to TopLevelIR (e.g. host_calls)
---@return table[]? nodes
---@return string? error
function M.Nodes(content, options)
    if type(content) ~= "string" then
        return nil, "content must be a string"
    end
    if content:sub(1, 3) == BOM then content = content:sub(4) end
    return IR.Analyze(content, options)
end

---Top-level `local` names in source order, deduplicated. Pure.
---@param content string
---@return string[]
function M.LocalNames(content)
    local names = {}
    local nodes = M.Nodes(content)
    if nodes == nil then return names end
    local seen = {}
    for _, node in ipairs(nodes) do
        local name = node.name
        if node.carrier == "local" and name ~= nil and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return names
end

---Whether the chunk has a top-level `return` (which forbids a trailer). Pure.
---@param content string
---@return boolean
function M.HasTopLevelReturn(content)
    local nodes = M.Nodes(content)
    if nodes == nil then return false end
    for _, node in ipairs(nodes) do
        if node.kind == "return" then return true end
    end
    return false
end

---Build the `return { [name] = name, ... }` trailer for the given names.
---@param names string[]
---@return string
function M.Trailer(names)
    if #names == 0 then return "return {}" end
    local parts = { "return {" }
    for i, name in ipairs(names) do
        parts[#parts + 1] = "[" .. string.format("%q", name) .. "]=" .. name
            .. (i < #names and "," or "")
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

--------------------------------------------------------------------------------
--- execution
--------------------------------------------------------------------------------

---Analyze and run `content` once, capturing top-level locals when possible.
---
---@param content string
---@param name string?   -- chunk name used in error messages
---@param options table? -- { capture = boolean (default true), args = {n=, ...} }
---@return table? result  -- { name, names, captured, map, ret, stage }
---@return string? error
---@return string? stage  -- "analyze" | "compile" | "run" | "capture"
function M.Run(content, name, options)
    options = options or {}

    local nodes, aerr = M.Nodes(content)
    if nodes == nil then
        return nil, tostring(aerr), "analyze"
    end

    local source = content
    if source:sub(1, 3) == BOM then source = source:sub(4) end

    local names = M.LocalNames(source)

    local has_return = false
    for _, node in ipairs(nodes) do
        if node.kind == "return" then
            has_return = true
            break
        end
    end

    local captured = options.capture ~= false and not has_return
    local chunk_src = source
    if captured then
        chunk_src = source .. "\n" .. M.Trailer(names)
    end

    local chunk, cerr = compile(chunk_src, "@" .. tostring(name or "LoadCapture"))
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

    local result = {
        name = name,
        names = names,
        captured = captured,
        map = nil,
        ret = { n = 0 },
    }

    if captured then
        if type(packed[1]) ~= "table" then
            return nil, "capture trailer did not return a table", "capture"
        end
        result.map = packed[1]
    else
        result.ret = packed
    end

    return result
end

return M
