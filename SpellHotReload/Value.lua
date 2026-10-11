--------------------------------------------------------------------------------
--- SpellHotReload.Value
---
--- The value adapter: the generic adapter for late-bound value slots.
---
--- Carriers: `global`, `field`, `local`.
---
--- Injection rebuilds the node's value from the new source without touching the
--- live object:
---   * an assignment slot (`NAME = expr`, `T.k = expr`, `local x = expr`) is
---     rebuilt by evaluating just its right-hand side;
---   * a function-sugar slot (`function PATH(args) ... end`) is rewritten into
---     a function expression and evaluated (the `:` form gets `self` inserted,
---     matching Lua's own desugaring);
---   * a `local function NAME` slot is extracted and rebuilt through
---     Legacy.Functions.BuildFunction, which also injects the captured
---     sibling upvalues.
--- Every evaluation runs in a write-isolating sandbox (reads fall through to
--- _G, writes stay in the sandbox) so injecting can never mutate the live game.
---
--- Commit is the single live mutation:
---   * `global` / `field` compile `function(__value) PATH = __value end` once
---     and assign through it in the real environment;
---   * `local` writes the captured table (`env.map`), which is where later
---     injections read the file's top-level locals from.
---
--- Restart is unnecessary for late-bound values: their next read sees the new
--- value. `Value.Restartable` is therefore false.
--------------------------------------------------------------------------------

local Lexer = require("SpellHotReload.Source.Lexer")

local Value = {}

Value.name = "Value"
Value.Restartable = false
Value.carriers = { global = true, field = true, ["local"] = true }

local compile = loadstring or load
local unpack = table.unpack or unpack
local apply_env = setfenv

local OPEN = { ["("] = true, ["{"] = true, ["["] = true }
local CLOSE = { [")"] = true, ["}"] = true, ["]"] = true }

--------------------------------------------------------------------------------
--- source slicing helpers
--------------------------------------------------------------------------------

local function find_assign(tokens, first, last)
    local nest = 0
    for i = first, last do
        local value = tokens[i].value
        if OPEN[value] then
            nest = nest + 1
        elseif CLOSE[value] then
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

local function comma_ranges(tokens, first, last)
    local ranges, nest, start = {}, 0, first
    for i = first, last do
        local value = tokens[i].value
        if OPEN[value] then
            nest = nest + 1
        elseif CLOSE[value] then
            nest = nest - 1
        elseif value == "," and nest == 0 then
            ranges[#ranges + 1] = { first = start, last = i - 1 }
            start = i + 1
        end
    end
    if start <= last then ranges[#ranges + 1] = { first = start, last = last } end
    return ranges
end

---Return the text of the `slot`-th comma range, or nil when it is absent
---(`local a, b = 1` gives `b` no right-hand side).
local function slice_slot(text, tokens, first, last, slot)
    if first > last then return nil end
    local ranges = comma_ranges(tokens, first, last)
    local range = ranges[slot or 1]
    if range == nil then return nil end
    return text:sub(tokens[range.first].pos, tokens[range.last].pos + #tokens[range.last].value - 1)
end

---Split `(...)` params and the tail that follows from a `function` fragment.
local function split_params(rest)
    local depth, i, n = 0, 1, #rest
    local inner_start = nil
    while i <= n do
        local c = rest:sub(i, i)
        if c == "(" then
            depth = depth + 1
            if depth == 1 then inner_start = i + 1 end
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then
                return rest:sub(inner_start, i - 1), rest:sub(i + 1)
            end
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local ch = rest:sub(j, j)
                if ch == "\\" then
                    j = j + 2
                elseif ch == c then
                    j = j + 1
                    break
                else
                    j = j + 1
                end
            end
            i = j
        end
        i = i + 1
    end
    return nil
end

--------------------------------------------------------------------------------
--- parsing
--------------------------------------------------------------------------------

---Describe the assignment site of one node in a form the hooks can rebuild.
---@param node table
---@return table? site  -- { form, target, rhs, local_target }
---@return string? reason
function Value.Parse(node)
    if type(node) ~= "table" or type(node.text) ~= "string" then
        return nil, "node has no source text"
    end
    local text = node.text
    local tokens = Lexer.Tokenize(text)
    if #tokens == 0 then return nil, "empty statement" end

    if node.kind == "function" and node.carrier == "local" then
        return { form = "local_function", name = node.name, target = node.name, local_target = true }
    end

    if node.kind == "function" then
        local paren = nil
        for i = 2, #tokens do
            if tokens[i].value == "(" then
                paren = i
                break
            end
        end
        if paren == nil then return nil, "function statement without a parameter list" end

        local head = text:sub(1, tokens[paren].pos - 1)
        local path = head:match("^%s*function%s+(.-)%s*$")
        if path == nil or path == "" then return nil, "unparsed function target" end

        local target, is_method = path, false
        if path:find(":", 1, true) ~= nil then
            local converted, count = path:gsub(":(%w+)$", ".%1")
            if count == 0 then return nil, "unparsed method target: " .. path end
            target, is_method = converted, true
        end

        local rest = text:sub(tokens[paren].pos)
        local rhs = "function" .. rest
        if is_method then
            local inner, tail = split_params(rest)
            if inner == nil then return nil, "unparsed method parameter list" end
            local params = inner:match("^%s*$") ~= nil and "self" or ("self, " .. inner)
            rhs = "function(" .. params .. ")" .. tail
        end
        return { form = "expr", target = target, rhs = rhs, local_target = false }
    end

    if node.carrier == "local" then
        local eq = find_assign(tokens, 3, #tokens)
        local rhs = eq ~= nil and slice_slot(text, tokens, eq + 1, #tokens, node.slot) or nil
        return { form = "expr", target = node.name, rhs = rhs, local_target = true }
    end

    if node.carrier == "global" or node.carrier == "field" then
        local eq = find_assign(tokens, 1, #tokens)
        if eq == nil then return nil, "no assignment operator" end
        local rhs = slice_slot(text, tokens, eq + 1, #tokens, node.slot)
        return {
            form = "expr",
            target = node.path or node.name,
            rhs = rhs,
            local_target = false,
        }
    end

    return nil, "carrier not handled by Value: " .. tostring(node.carrier)
end

--------------------------------------------------------------------------------
--- hooks
--------------------------------------------------------------------------------

function Value.Locate(node, env)
    if Value.carriers[node.carrier] ~= true then
        return nil, "Value does not handle carrier '" .. tostring(node.carrier) .. "'"
    end
    local site, reason = Value.Parse(node)
    if site == nil then return nil, reason end
    return { site = site }
end

---Sandbox whose writes never escape; reads fall through to the real globals.
local function isolated_env()
    return setmetatable({}, { __index = _G })
end

local function sibling_names(sibs)
    local names = {}
    for name in pairs(sibs) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function Value.Inject(handle, node, env)
    local site = handle.site
    env = env or {}
    local sibs = env.working or env.map or {}

    if site.form == "local_function" then
        if type(env.content) ~= "string" then
            return nil, "env.content is required to rebuild a local function"
        end
        -- Historical value-map construction, never the versioned Anchor path.
        local Functions = require("SpellHotReload.Legacy.Functions")
        local fragment = Functions.ExtractFunction(env.content, site.name)
        if fragment == nil then
            return nil, "local function '" .. tostring(site.name) .. "' not found in the new source"
        end
        local fn, ferr = Functions.BuildFunction(fragment, site.name, sibs)
        if fn == nil then return nil, ferr end
        return { value = fn, target = site.target, local_target = true, site = site }
    end

    local names = sibling_names(sibs)
    local decl = ""
    if #names > 0 then
        decl = "local " .. table.concat(names, ", ") .. " = ...\n"
    end
    local src = decl .. "return " .. (site.rhs or "nil")

    local chunk, cerr = compile(src, "@Value.Inject:" .. tostring(env.file))
    if chunk == nil then
        return nil, "compile failed: " .. tostring(cerr)
    end
    if apply_env ~= nil then
        apply_env(chunk, isolated_env())
    end

    local args = {}
    for i = 1, #names do args[i] = sibs[names[i]] end

    local ok, value = pcall(chunk, unpack(args, 1, #names))
    if not ok then
        return nil, "evaluation failed: " .. tostring(value)
    end
    -- The sandbox isolates inject-time writes; a value that escapes it must run
    -- against the real globals once committed, exactly as the source intended.
    if apply_env ~= nil and type(value) == "function" then
        apply_env(value, _G)
    end
    return { value = value, target = site.target, local_target = site.local_target, site = site }
end

function Value.Commit(handle, plan, env)
    env = env or {}

    if plan.local_target then
        local map = env.map
        if type(map) ~= "table" then
            return false, "no capture map for '" .. tostring(env.file) .. "'"
        end
        map[plan.target] = plan.value
        return true
    end

    local target = plan.target
    if type(target) ~= "string" or target == "" then
        return false, "no assignment target"
    end

    local src = "return function(__value)\n" .. target .. " = __value\nend"
    local chunk, cerr = compile(src, "@Value.Commit:" .. target)
    if chunk == nil then
        return false, "compile setter failed: " .. tostring(cerr)
    end
    local ok, setter = pcall(chunk)
    if not ok or type(setter) ~= "function" then
        return false, "setter build failed: " .. tostring(setter)
    end

    local applied, aerr = pcall(setter, plan.value)
    if not applied then
        return false, "commit failed: " .. tostring(aerr)
    end
    return true
end

function Value.Restart()
    return true
end

return Value
