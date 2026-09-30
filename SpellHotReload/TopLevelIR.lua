--------------------------------------------------------------------------------
--- SpellHotReload.TopLevelIR
---
--- Pure top-level analyzer for generated Lua sources. Splits a file into
--- top-level statements and classifies each carrier slot into the generic
--- reload model's node taxonomy:
---
---   local      顶层 local / local function   -> 需要加载期捕获与回灌
---   global     顶层裸 NAME = ...             -> _G 槽，晚绑定
---   field      T.k = ... / T["k"] = ...      -> 表字段，晚绑定
---   host       已注册宿主调用（如 stage.group.DefStageFunc）
---   container  table.insert / T[#T+1] = ...  -> 结构容器，需要结构 diff
---   effect     require / Include / New 等     -> 无载体副作用，不可重放
---
--- The module never executes the analyzed source. Everything is derived from the
--- shared lexer in GeneratedBossLoader, so it can be exercised under plain Lua
--- and LuaJIT without an engine.
--------------------------------------------------------------------------------

local Loader = require("SpellHotReload.GeneratedBossLoader")

local M = {}

---Callee paths registered by host adapters. A call statement whose callee
---matches a key here is classified as `host`; every other call falls back to
---`effect`. Adapters register their entry points during the driver setup.
---@type table<string, boolean>
M.HostCalls = {}

local BLOCK_STATEMENT = {
    ["if"] = true, ["for"] = true, ["while"] = true, ["do"] = true,
    ["repeat"] = true, ["return"] = true,
}

local OPEN = { ["("] = true, ["{"] = true, ["["] = true }
local CLOSE = { [")"] = true, ["}"] = true, ["]"] = true }

local function is_open(value) return OPEN[value] == true end
local function is_close(value) return CLOSE[value] == true end

--------------------------------------------------------------------------------
--- statement splitting
--------------------------------------------------------------------------------

---Split `content` into top-level statements.
---
---A statement starts at a token that is (a) the first token on its line, (b) at
---block depth 0, and (c) outside every `(`/`{`/`[` nesting. Generated sources
---are laid out one statement per line, so this recovers the statement list
---without carrying a full Lua grammar. Multi-line function bodies and table
---constructors are protected by the block/bracket depth test.
---@param content string
---@return table[] tokens
---@return integer[] lines
---@return integer[] starts
local function split(content)
    local tokens = Loader.Tokenize(content)
    local lines, starts = {}, {}
    local nest = 0
    local line = 1
    local cursor = 1
    local prev_end = nil

    for i = 1, #tokens do
        local tok = tokens[i]

        -- advance the running line counter up to this token (tokens are ordered)
        while true do
            local nl = content:find("\n", cursor, true)
            if nl == nil or nl >= tok.pos then break end
            line = line + 1
            cursor = nl + 1
        end
        lines[i] = line

        local at_line_start = true
        if prev_end ~= nil then
            local nl = content:find("\n", prev_end + 1, true)
            at_line_start = nl ~= nil and nl < tok.pos
        end
        if at_line_start and tok.depth == 0 and nest == 0 then
            starts[#starts + 1] = i
        end

        if is_open(tok.value) then
            nest = nest + 1
        elseif is_close(tok.value) then
            nest = nest - 1
        end
        prev_end = tok.pos + #tok.value - 1
    end

    return tokens, lines, starts
end

--------------------------------------------------------------------------------
--- token helpers
--------------------------------------------------------------------------------

local function join_values(tokens, first, last)
    local parts = {}
    for i = first, last do parts[#parts + 1] = tokens[i].value end
    return table.concat(parts)
end

local function is_single_word(tokens, first, last)
    return first == last and tokens[first].kind == "word"
end

local function contains(tokens, first, last, value)
    for i = first, last do
        if tokens[i].value == value then return true end
    end
    return false
end

---Split `first..last` on commas that sit outside brackets.
local function split_commas(tokens, first, last)
    local ranges, nest, start = {}, 0, first
    for i = first, last do
        local value = tokens[i].value
        if is_open(value) then
            nest = nest + 1
        elseif is_close(value) then
            nest = nest - 1
        elseif value == "," and nest == 0 then
            ranges[#ranges + 1] = { first = start, last = i - 1 }
            start = i + 1
        end
    end
    if start <= last then ranges[#ranges + 1] = { first = start, last = last } end
    return ranges
end

---Find the assignment `=` of a statement, skipping comparison operators. The
---lexer emits `==`, `<=`, `>=` and `~=` as separate one-character symbols, so a
---standalone `=` is one whose neighbours are not part of such a pair.
local function find_assign_eq(tokens, first, last)
    local nest = 0
    for i = first, last do
        local value = tokens[i].value
        if is_open(value) then
            nest = nest + 1
        elseif is_close(value) then
            nest = nest - 1
        elseif value == "=" and nest == 0 then
            local prev = tokens[i - 1] and tokens[i - 1].value
            local nxt = tokens[i + 1] and tokens[i + 1].value
            local paired = prev == "=" or prev == "<" or prev == ">" or prev == "~"
                or nxt == "="
            if not paired then return i end
        end
    end
    return nil
end

---Walk a `word ( . word | : word )*` callee chain starting at `first`.
---@return string path, integer next_index
local function callee_path(tokens, first, last)
    local parts, i = {}, first
    while i <= last do
        local tok = tokens[i]
        if tok.kind == "word" then
            parts[#parts + 1] = tok.value
            i = i + 1
        elseif (tok.value == "." or tok.value == ":") and tokens[i + 1] ~= nil
            and tokens[i + 1].kind == "word" then
            parts[#parts + 1] = tok.value
            i = i + 1
        else
            break
        end
    end
    return table.concat(parts), i
end

local function first_open_paren(tokens, first, last)
    for i = first, last do
        if tokens[i].value == "(" then return i end
    end
    return nil
end

--------------------------------------------------------------------------------
--- classification
--------------------------------------------------------------------------------

---Classify one top-level statement into zero or more carrier nodes.
---@return table[]
local function classify(tokens, first, last, line, options)
    local head = tokens[first]
    local nodes = {}

    local function push(node)
        node.line = line
        node.tok = { first = first, last = last }
        nodes[#nodes + 1] = node
        return node
    end

    if head.value == "local" then
        local a = tokens[first + 1]
        if a ~= nil and a.value == "function" and tokens[first + 2] ~= nil
            and tokens[first + 2].kind == "word" then
            push({ carrier = "local", kind = "function", name = tokens[first + 2].value })
        else
            local eq = find_assign_eq(tokens, first + 1, last)
            local stop = eq ~= nil and (eq - 1) or last
            local slot = 0
            for _, range in ipairs(split_commas(tokens, first + 1, stop)) do
                slot = slot + 1
                if range.first == range.last and tokens[range.first].kind == "word" then
                    push({
                        carrier = "local",
                        kind = eq ~= nil and "value" or "declare",
                        name = tokens[range.first].value,
                        slot = slot,
                    })
                end
            end
        end
        if #nodes == 0 then
            push({ carrier = "effect", kind = "unknown", reason = "unparsed local statement" })
        end
        return nodes
    end

    if head.value == "function" then
        local paren = first_open_paren(tokens, first + 1, last)
        local target_last = paren ~= nil and (paren - 1) or last
        if target_last >= first + 1 then
            local path = join_values(tokens, first + 1, target_last)
            if is_single_word(tokens, first + 1, target_last) then
                push({ carrier = "global", kind = "function", name = path })
            else
                push({
                    carrier = "field", kind = "function", path = path,
                    root = tokens[first + 1].value,
                })
            end
        else
            push({ carrier = "effect", kind = "unknown", reason = "unparsed function statement" })
        end
        return nodes
    end

    if BLOCK_STATEMENT[head.value] then
        push({
            carrier = "effect",
            kind = head.value == "return" and "return" or "block",
            reason = "control flow does not carry a value slot",
        })
        return nodes
    end

    local eq = find_assign_eq(tokens, first, last)
    if eq ~= nil then
        local rhs_table = tokens[eq + 1] ~= nil and tokens[eq + 1].value == "{"
        local slot = 0
        for _, range in ipairs(split_commas(tokens, first, eq - 1)) do
            slot = slot + 1
            local path = join_values(tokens, range.first, range.last)
            if is_single_word(tokens, range.first, range.last) then
                local node = push({
                    carrier = "global", kind = "assign",
                    name = tokens[range.first].value,
                    slot = slot,
                })
                if rhs_table then node.table_rebuild = true end
            elseif contains(tokens, range.first, range.last, "#") then
                push({ carrier = "container", kind = "append", path = path, slot = slot })
            else
                push({
                    carrier = "field", kind = "assign", path = path,
                    root = tokens[range.first] and tokens[range.first].value,
                    slot = slot,
                })
            end
        end
        return nodes
    end

    local callee = callee_path(tokens, first, last)
    local registered = M.HostCalls[callee] == true
        or (options.host_calls ~= nil and options.host_calls[callee] == true)
    if callee == "table.insert" or callee == "table.remove" then
        push({ carrier = "container", kind = callee, callee = callee })
    elseif registered then
        push({ carrier = "host", kind = "call", callee = callee })
    elseif callee == "" then
        push({ carrier = "effect", kind = "unknown", reason = "unparsed statement" })
    else
        push({
            carrier = "effect", kind = "call", callee = callee,
            reason = "unadapted call: " .. callee,
        })
    end
    return nodes
end

--------------------------------------------------------------------------------
--- dependency linking
--------------------------------------------------------------------------------

---Second pass: resolve `local` dependencies against the locals visible *before*
---each statement. Lua top-level scoping is strictly backwards, so a forward
---reference is a global read, not an edge. A `local function` may reference
---itself, which is recorded as `recursive` instead of an edge.
---@param tokens table[]
---@param nodes table[]
function M._link(tokens, nodes)
    local visible = {}
    local i = 1
    while i <= #nodes do
        local first, last = nodes[i].tok.first, nodes[i].tok.last
        local j = i
        while j <= #nodes and nodes[j].tok.first == first and nodes[j].tok.last == last do
            j = j + 1
        end

        for k = i, j - 1 do
            local node = nodes[k]
            if node.carrier == "local" then
                local deps, seen = {}, {}
                for t = node.tok.first, node.tok.last do
                    local tok = tokens[t]
                    if tok.kind == "word" and visible[tok.value] and not seen[tok.value] then
                        seen[tok.value] = true
                        deps[#deps + 1] = tok.value
                    end
                end
                table.sort(deps)
                node.deps = deps
                if node.kind == "function" and node.name ~= nil then
                    for t = node.tok.first + 3, node.tok.last do
                        local tok = tokens[t]
                        if tok.kind == "word" and tok.value == node.name then
                            node.recursive = true
                            break
                        end
                    end
                end
            end
        end

        for k = i, j - 1 do
            local node = nodes[k]
            if node.carrier == "local" and node.name ~= nil then
                visible[node.name] = true
            end
        end
        i = j
    end
    return nodes
end

--------------------------------------------------------------------------------
--- public surface
--------------------------------------------------------------------------------

---Analyze generated source and return its carrier nodes in source order.
---@param content string
---@param options table?  -- { host_calls = { [callee_path] = true } }
---@return table[]? nodes
---@return string? error
function M.Analyze(content, options)
    options = options or {}
    if type(content) ~= "string" then
        return nil, "content must be a string"
    end
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end

    local tokens, lines, starts = split(content)
    local nodes = {}
    for k = 1, #starts do
        local first = starts[k]
        local last = (starts[k + 1] and starts[k + 1] - 1) or #tokens
        local text = content:sub(tokens[first].pos, tokens[last].pos + #tokens[last].value - 1)
        for _, node in ipairs(classify(tokens, first, last, lines[first], options)) do
            node.text = text
            nodes[#nodes + 1] = node
        end
    end

    M._link(tokens, nodes)
    return nodes
end

---Split into top-level statements and return their source text. Exposed
---separately so the statement boundaries can be tested without classification.
---@param content string
---@return table[]  -- { { line = integer, text = string } }
function M.SplitStatements(content)
    if type(content) ~= "string" then return {} end
    if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
    local tokens, lines, starts = split(content)
    local result = {}
    for k = 1, #starts do
        local first = starts[k]
        local last = (starts[k + 1] and starts[k + 1] - 1) or #tokens
        result[#result + 1] = {
            line = lines[first],
            text = content:sub(tokens[first].pos, tokens[last].pos + #tokens[last].value - 1),
        }
    end
    return result
end

return M
