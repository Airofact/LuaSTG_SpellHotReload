--------------------------------------------------------------------------------
--- SpellHotReload.Source.Compose
---
--- The anchor-cell composition primitive: connect a freshly compiled closure to
--- the cells an Anchor already holds, and build that closure from a fragment so
--- its free top-level names really are upvalues.
---
--- This is the R3/R4 join half of "一文件一 Anchor". Anchor.lua captures the
--- file's real cells and never joins anything; this module is what the Inject
--- and Commit stages call to:
---
---   Upvalues  enumerate a closure's real upvalue slots by index - never by
---             declaration order, always including slots whose value is
---             nil/false;
---   Create    assemble a fragment into a new closure: only the names the
---             definition point proves visible are predeclared, so a name that
---             is not a top-level local of the file stays a global instead of
---             being silently rebound; the produced function body is never
---             called;
---   Plan      build the per-slot wiring plan against an anchor - every free
---             name of the new closure is matched to an existing anchor slot by
---             name, and a name with no slot is a refusal, not a guess;
---   Join      execute `debug.upvaluejoin(new, index, anchor, donor)`, the only
---             honest way to make a new closure share the old cell; and
---   Attach    Plan + Join, which is exactly Inject's wiring step.
---
--- Two things this module deliberately does not do:
---
---   * it never writes a cell and never publishes a function. `setupvalue` on
---     the anchor slot is Commit's job (Anchor.Set), because writing the cell
---     before every new closure is wired would break recursion;
---   * it never replaces the anchor. Joining only ever adds an alias to an
---     existing cell.
---
--- Capability: enumeration needs `debug.getupvalue`; joining needs
--- `debug.upvaluejoin`. A runtime without join is honestly refused with a
--- `capability: ...` reason - `Create` still works there, but `Join`/`Attach`
--- say so instead of pretending the fresh cells are the file's cells.
--- `debug.upvalueid`, when present, is used to verify a join; it is never the
--- holder of anything.
--------------------------------------------------------------------------------

local Anchor = require("SpellHotReload.Load.Anchor")
local Syntax = require("SpellHotReload.Source.SyntaxTree")
local CodeCache = require("SpellHotReload.Source.CodeCache")

local M = {}

M.Kind = "SpellHotReload.Compose"
M.Version = 1

local compile = loadstring or load

-- Identity of the actual compiler captured by Create, not the current global.
-- Syntax evidence from a different compiler cannot authorize closure reuse.
function M.CompilerIdentity() return compile end

local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
    ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
    ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
    ["while"] = true,
}

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

-- ASCII identifiers only: the generated sources we support are ASCII names, and
-- a locale-dependent %a would accept bytes we cannot promise to the lexer.
local function identifier(value)
    if type(value) ~= "string" then return false end
    if value:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then return false end
    return KEYWORDS[value] ~= true
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

--------------------------------------------------------------------------------
--- capability gate
--------------------------------------------------------------------------------

---Read the facilities the running `runtime` reports. Presence only; the table
---is what `Supported` judges, so no closure is ever built or joined here.
---@param runtime table?  -- defaults to the global `debug`
---@return table capability  -- { getupvalue, setupvalue, upvaluejoin, upvalueid }
function M.Capability(runtime)
    if type(runtime) ~= "table" then runtime = {} end
    return {
        getupvalue = type(runtime.getupvalue) == "function",
        setupvalue = type(runtime.setupvalue) == "function",
        upvaluejoin = type(runtime.upvaluejoin) == "function",
        upvalueid = type(runtime.upvalueid) == "function",
    }
end

---Whether `capability` declares what composing a closure needs: enumeration
---(`getupvalue`) and joining (`upvaluejoin`). Presence contract only;
---`upvalueid` stays optional and is used solely to double-check a join.
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
    if capability.upvaluejoin ~= true then
        return false, "debug.upvaluejoin is unavailable"
    end
    return true
end

--------------------------------------------------------------------------------
--- enumeration
--------------------------------------------------------------------------------

---Enumerate a closure's real upvalue slots, in index order.
---@param fn function
---@return table? list  -- dense { { index =, name =, value = }, ... }
---@return string? reason
function M.Upvalues(fn)
    if type(fn) ~= "function" then
        return nil, "fn must be a function"
    end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
        return nil, "debug.getupvalue is unavailable"
    end
    local list, seen = {}, {}
    local index = 1
    while true do
        local name, value = debug.getupvalue(fn, index)
        if name == nil then break end
        if name == "" then
            return nil, "upvalue name is unavailable (debug info stripped)"
        end
        if seen[name] then
            -- Two slots can share a name (`do local x end do local x end`); such
            -- a closure cannot be addressed by name, and a silent pick would be
            -- a guess. Refuse instead.
            return nil, "duplicate upvalue name: " .. name
        end
        seen[name] = true
        list[index] = { index = index, name = name, value = value }
        index = index + 1
    end
    return list
end

---The names of a closure's real upvalue slots, in index order.
---@param fn function
---@return string[]? names
---@return string? reason
function M.Names(fn)
    local list, reason = M.Upvalues(fn)
    if list == nil then return nil, reason end
    local names = {}
    for i = 1, #list do names[i] = list[i].name end
    return names
end

--------------------------------------------------------------------------------
--- source assembly (read-only)
--------------------------------------------------------------------------------

---Build a `local a, b` prefix for the given names. An empty list yields an
---empty string, so callers never emit a dangling `local`.
---@param names string[]
---@return string? declaration
---@return string? reason
function M.Declare(names)
    local count = dense(names)
    if count == nil then
        return nil, "names must be a dense array of identifiers"
    end
    if count == 0 then return "" end
    local seen, parts = {}, {}
    for i = 1, count do
        local name = names[i]
        if not identifier(name) then
            return nil, "not an identifier: " .. tostring(name)
        end
        if seen[name] then
            return nil, "duplicate declaration: " .. name
        end
        seen[name] = true
        parts[i] = name
    end
    return "local " .. table.concat(parts, ", ")
end

---Conservative nested-function identifier mentions from the shared syntax tree.
---Field labels and declarations are distinct nodes. Scope shadowing is not proved.
local function nested_mentions(Tree,ast,declared)
    local mentions={}
    Tree.Walk(ast,function(n,parent,functions)
        if Tree.Is(n,"name") and functions>=2 then
            local name=Tree.Identifier(n)
            if declared[name] then mentions[name]=true end
        end
    end)
    return mentions
end

---Assemble a fragment into a new closure whose free top-level names are real
---upvalue slots.
---
---`visible` is the set the definition-point analysis proved visible (Binding /
---FileMatch / UnitIndex own that decision). Nothing outside it is ever
---predeclared, so a name that is not a top-level local of the file keeps
---resolving as a global exactly like it does in the real file.
---
---Forms:
---
---   statement   the fragment is a statement list that defines `target`
---               (`local function target(...) ... end`); the wrapper returns it.
---   expression  the fragment is an expression (`function(...) ... end`); the
---               wrapper returns it directly.
---
---The wrapper chunk is compiled and run to obtain the closure; the closure's own
---body is never called. The returned closure shares nothing yet: its cells are
---fresh, and using it before `Attach` would read the fresh cells, so the caller
---must join it (`Plan`/`Join`) before publishing anything. The anchor is not
---read, modified or inspected here.
---@param body string
---@param target string?  -- required for the statement form; naming aid otherwise
---@param visible string[]  -- definition-point visible top-level locals
---@param options table?  -- { form=, name=, capability= }
---@return table? result  -- { fn, source, declared, prefix, used, target, form, nested }
---@return string? reason
function M.Create(body, target, visible, options)
    if type(body) ~= "string" then
        return nil, "body must be a string"
    end
    if options == nil then options = {} end
    if type(options) ~= "table" then
        return nil, "options must be a table"
    end
    local form = options.form
    if form == nil then form = "statement" end
    if form ~= "statement" and form ~= "expression" then
        return nil, "form must be 'statement' or 'expression'"
    end
    local capability = options.capability or M.Capability(debug)
    if capability.getupvalue ~= true then
        return nil, "capability: debug.getupvalue is unavailable"
    end

    local count = dense(visible)
    if count == nil then
        return nil, "visible must be a dense array of identifiers"
    end
    local declared = {}
    for i = 1, count do
        if not identifier(visible[i]) then
            return nil, "visible must be a dense array of identifiers"
        end
        declared[i] = visible[i]
    end

    -- The statement form declares the target itself, so predeclaring it would
    -- only add a shadowed, unused local. A recursive reference still shows up as
    -- a real upvalue named after the target, and that is what gets joined.
    local prefix = {}
    if form == "statement" then
        if not identifier(target) then
            return nil, "target must be an identifier"
        end
        local n = 0
        for i = 1, #declared do
            if declared[i] ~= target then
                n = n + 1
                prefix[n] = declared[i]
            end
        end
    else
        if target ~= nil and not identifier(target) then
            return nil, "target must be an identifier"
        end
        for i = 1, #declared do prefix[i] = declared[i] end
    end

    local decl, derr = M.Declare(prefix)
    if decl == nil then return nil, derr end

    local source
    if form == "statement" then
        source = (decl == "" and "" or (decl .. "\n")) .. body
            .. "\nreturn " .. target
    else
        source = (decl == "" and "" or (decl .. "\n")) .. "return " .. body
    end

    local chunk, cerr = compile(source, "@" .. tostring(options.name or "Compose"))
    if chunk == nil then
        return nil, "compile failed: " .. tostring(cerr)
    end
    local ok, fn = pcall(chunk)
    if not ok then
        return nil, "run failed: " .. tostring(fn)
    end
    if type(fn) ~= "function" then
        return nil, "fragment did not produce a function"
    end

    local list, uerr = M.Upvalues(fn)
    if list == nil then return nil, uerr end
    local used = {}
    for i = 1, #list do used[i] = list[i].name end

    -- Every upvalue must come from the prefix or be the target's own cell;
    -- anything else means the wrapper and the fragment disagree.
    local allowed = {}
    for i = 1, #prefix do allowed[prefix[i]] = true end
    if form == "statement" then allowed[target] = true end
    for i = 1, #used do
        if not allowed[used[i]] then
            return nil, "unexpected upvalue: " .. used[i]
        end
    end

    -- A nested closure alone capturing a prefix cell cannot be wired after the
    -- fact: no handle to that inner closure exists. Refuse rather than leave it
    -- reading a fresh cell. Over-approximating here can only over-refuse.
    local prefix_set = {}
    for i = 1, #prefix do prefix_set[prefix[i]] = true end
    local syntax,Tree=options.syntax,options.tree
    if not syntax then
        local fragment=form=="expression" and ("return "..body) or body
        local reason;Tree,reason=Syntax.Parse(fragment)
        if not Tree then return nil,reason end
        syntax=Tree.root
    end
    if not Syntax.IsSnapshot(Tree) or not Tree.IsNode(syntax) then return nil,"source-owned syntax reference required" end
    -- Source bodies are mapped on demand. Refuse unsupported selected syntax
    -- through Create's failure contract without executing the function body.
    local walked,nested=pcall(nested_mentions,Tree,syntax,prefix_set)
    if not walked then return nil,tostring(nested) end
    for name in pairs(nested) do
        local found = false
        for i = 1, #used do
            if used[i] == name then found = true break end
        end
        if not found then
            return nil, "nested scope captures '" .. name
                .. "' without a joinable upvalue"
        end
    end

    return {
        fn = fn, source = source, declared = declared, prefix = prefix,
        used = used, target = target, form = form, nested = next(nested) ~= nil,
    }
end

--------------------------------------------------------------------------------
--- planning (read-only)
--------------------------------------------------------------------------------

---Build the per-slot join plan: every real upvalue of `fn` is matched to an
---existing anchor slot by name. `options.mapping` may rename a fragment upvalue
---(`mapping[name] = anchor_name`).
---
---A free name with no anchor slot is a refusal: guessing a donor would wire the
---new closure to the wrong cell, and leaving it fresh would read a value the
---file does not have.
---
---@param fn function|table  -- a closure or a `Compose.Create` result
---@param entry table  -- a captured Anchor entry
---@param options table?  -- { mapping=, }
---@return table? plan  -- { fn, entry, anchor, joins, names, joined }
---@return string? reason
function M.Plan(fn, entry, options)
    if options == nil then options = {} end
    if type(options) ~= "table" then
        return nil, "options must be a table"
    end
    local result = type(fn) == "table" and fn or nil
    if result ~= nil then fn = result.fn end
    if type(fn) ~= "function" then
        return nil, "fn must be a function"
    end
    if not plain(entry) then
        return nil, "entry must be an anchor entry"
    end
    if not Anchor.Live(entry) then
        return nil, "anchor is not live: " .. tostring(entry.file or "entry")
    end
    local mapping = options.mapping
    if mapping ~= nil and not plain(mapping) then
        return nil, "mapping must be a table"
    end

    local list, uerr = M.Upvalues(fn)
    if list == nil then return nil, uerr end

    local joins, names = {}, {}
    for i = 1, #list do
        local up = list[i]
        local anchor_name = up.name
        if mapping ~= nil and mapping[up.name] ~= nil then
            anchor_name = mapping[up.name]
            if not identifier(anchor_name) then
                return nil, "mapping must name an anchor slot"
            end
        end
        local donor, sreason = Anchor.Slot(entry, anchor_name)
        if donor == nil then
            return nil, "no anchor slot for upvalue '" .. up.name .. "'"
        end
        -- The slot must still answer to that name; a drifted slot means the
        -- entry and the live anchor no longer agree.
        local live_name = debug.getupvalue(entry.anchor, donor)
        if live_name ~= anchor_name then
            return nil, "anchor slot drifted for '" .. anchor_name .. "'"
        end
        names[i] = up.name
        joins[i] = {
            fn = fn, index = up.index, name = up.name,
            anchor = entry.anchor, anchor_name = anchor_name, donor = donor,
        }
    end
    return {
        fn = fn, entry = entry, anchor = entry.anchor,
        joins = joins, names = names, result = result, joined = false,
    }
end

--------------------------------------------------------------------------------
--- joining
--------------------------------------------------------------------------------

---Execute a join plan: `debug.upvaluejoin(fn, index, anchor, donor)` per slot.
---
---Joining makes the new closure share the anchor's existing cell; it does not
---write any value and does not replace the anchor, so it is always safe to run
---before the Commit step decides whether to publish. Returns the number of
---slots joined. Before the first alias change, invalidate the entire compiled
---code cache, including callers which inlined the closure. JIT stays enabled;
---cache failure refuses before any join. An empty plan needs no invalidation.
---@param plan table  -- a `Compose.Plan` result
---@param capability table?  -- defaults to the running runtime
---@return integer? joined
---@return string? reason
function M.Join(plan, capability)
    if not plain(plan) or not plain(plan.joins) or type(plan.fn) ~= "function" then
        return nil, "plan must be a join plan"
    end
    if capability == nil then capability = M.Capability(debug) end
    local supported, sreason = M.Supported(capability)
    if not supported then
        return nil, "capability: " .. tostring(sreason)
    end
    local id = type(debug) == "table" and type(debug.upvalueid) == "function"
        and debug.upvalueid or nil
    local joined = 0
    for i = 1, #plan.joins do
        local join = plan.joins[i]
        if not plain(join) or type(join.fn) ~= "function"
            or type(join.anchor) ~= "function" then
            return nil, "join " .. i .. " is not a join record"
        end
        if not integer(join.index) or join.index < 1
            or not integer(join.donor) or join.donor < 1 then
            return nil, "join " .. i .. " has an invalid upvalue index"
        end
        if joined == 0 then
            local ready, cache_reason = CodeCache.Invalidate()
            if not ready then return nil, cache_reason end
        end
        local ok, err = pcall(debug.upvaluejoin, join.fn, join.index,
            join.anchor, join.donor)
        if not ok then
            return nil, "join failed for '" .. tostring(join.name) .. "': "
                .. tostring(err)
        end
        if id ~= nil then
            local a, b = id(join.fn, join.index), id(join.anchor, join.donor)
            if a == nil or b == nil or a ~= b then
                return nil, "join did not share the cell for '"
                    .. tostring(join.name) .. "'"
            end
        end
        joined = joined + 1
    end
    plan.joined = true
    return joined
end

---Plan and join in one call; returns the now-wired closure (and the plan).
---This is Inject's wiring step. It still publishes nothing: writing the
---function into its anchor slot (Anchor.Set) belongs to Commit, after every
---new closure of the batch has been wired.
---@param fn function|table
---@param entry table
---@param options table?  -- { mapping=, capability=, }
---@return function? attached
---@return table? plan
---@return string? reason
function M.Attach(fn, entry, options)
    if options == nil then options = {} end
    local plan, perr = M.Plan(fn, entry, options)
    if plan == nil then return nil, nil, perr end
    local joined, jerr = M.Join(plan, options.capability)
    if joined == nil then return nil, nil, jerr end
    return plan.fn, plan
end

return M
