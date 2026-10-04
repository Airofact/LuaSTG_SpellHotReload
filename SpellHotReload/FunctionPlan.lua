--- Pure R3 function preparation, NOT the production Apply transaction.
--- The caller selects names and supplies their actually-published function
--- identities. No implicit loaded-source revision or legacy map is trusted.
--- Only direct function literals are compiled; the full candidate is syntax
--- checked but never executed. No join, setupvalue, publication or restart.
--- Public plans are read-only by contract; R4 must recheck every read before
--- joining all closures, writing cells and publishing callbacks atomically.
local IR = require("SpellHotReload.TopLevelIR")
local Binding = require("SpellHotReload.Binding")
local Anchor = require("SpellHotReload.Anchor")
local Compose = require("SpellHotReload.Compose")
local M = { Kind = "SpellHotReload.FunctionPlan", Version = 1 }
local compile = loadstring or load

local function plain(v)
    return type(v) == "table" and getmetatable(v) == nil
end

local function dense(v)
    if not plain(v) then return nil end
    local count, maximum = 0, 0
    for k in next, v do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k)
            or k == math.huge then return nil end
        count, maximum = count + 1, math.max(maximum, k)
    end
    if count ~= maximum then return nil end
    return count
end

local function failure(code, message, file, name)
    return nil, { phase = "inject", code = code, message = tostring(message),
        file = file, unit_key = name and ("local:" .. name) or nil }
end

local function visible(record)
    local list = {}
    for name in next, record.visible do list[#list + 1] = name end
    table.sort(list)
    return list
end

local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- A literal must occupy the entire statement. Never run a statement wrapper
-- containing a trailing call/assignment, even when the full file is valid Lua.
local function literal(analysis, statement, record)
    local tokens = analysis.tokens
    local first, last = statement.tok.first, statement.tok.last
    while last >= first and tokens[last].value == ";" do last = last - 1 end
    local function val(i) return tokens[i] and tokens[i].value end
    local name, start, form, self_visible
    if val(first) == "local" and val(first + 1) == "function"
        and val(first + 3) == "(" then
        name, start, form, self_visible = val(first + 2), first, "statement", true
    elseif val(first) == "local" and val(first + 2) == "="
        and val(first + 3) == "function" and val(first + 4) == "(" then
        name, start, form = val(first + 1), first + 3, "expression"
    elseif val(first + 1) == "=" and val(first + 2) == "function"
        and val(first + 3) == "(" and record.visible[val(first)] then
        name, start, form = val(first), first + 2, "expression"
    elseif val(first) == "function" and val(first + 2) == "("
        and record.visible[val(first + 1)] then
        name, start, form = val(first + 1), first, "expression"
    end
    if name == nil or val(last) ~= "end" or tokens[last].depth ~= 1 then return nil end
    -- The first depth-1 end closes this outer literal. Any later code means
    -- this is not the single literal we are allowed to obtain by execution.
    local outer_end
    for i = start + 1, last do
        if val(i) == "end" and tokens[i].depth == 1 then outer_end = i break end
    end
    if outer_end ~= last then return nil end
    local source = analysis.source
    local stop = tokens[last].pos + #tokens[last].value - 1
    local body = source:sub(tokens[start].pos, stop)
    if val(first) == "function" then
        body = "function" .. source:sub(tokens[first + 2].pos, stop)
    end
    return { name = name, body = body, form = form, self_visible = self_visible == true,
        visible = visible(record), source_range = {
            first = statement.source_range.first, last = statement.source_range.last } }
end

local function analyze(content)
    if type(content) ~= "string" then return nil, "source must be a string", "unsupported" end
    local source = content
    if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
    local chunk, syntax = compile(source, "@FunctionPlan:syntax")
    if chunk == nil then return nil, syntax, "compile" end
    -- Discard chunk without calling it. Initialization/wiring is never replayed.
    local nodes, err, analysis = IR.Analyze(content)
    if nodes == nil then return nil, err, "unsupported" end
    local bindings, berr = Binding.Analyze(analysis)
    if bindings == nil then return nil, berr, "unsupported" end
    local policy, perr = Anchor.Policy(content, { analysis = analysis, bindings = bindings })
    if policy == nil or not policy.reloadable then
        return nil, perr or policy.reason, "unsupported"
    end
    local result = { analysis = analysis, bindings = bindings, definitions = {}, writes = {},
        blocked = {} }
    for index, statement in ipairs(analysis.statements) do
        local record = bindings.statements[index]
        local definition = literal(analysis, statement, record)
        if definition ~= nil then
            definition.statement = index
            local list = result.definitions[definition.name] or {}
            result.definitions[definition.name] = list
            list[#list + 1] = definition
        end
        -- Every direct write to a local is accounted for. Unrecognized RHS,
        -- multi-assignment and repeated definitions are NOT silently ignored.
        for _, node in ipairs(nodes) do
            if node.tok.first == statement.tok.first then
                -- The lightweight IR cannot prove which local a top-level
                -- control block writes. Conservatively refuse any selected
                -- name it mentions, rather than associate a conditional
                -- runtime replacement with the preceding literal's source.
                if node.carrier == "effect" and node.kind == "block" then
                    for i = node.tok.first, node.tok.last do
                        local token = analysis.tokens[i]
                        if token.kind == "word" and record.visible[token.value] then
                            result.blocked[token.value] = true
                        end
                    end
                end
                local target = (node.carrier == "local" and node.kind ~= "declare"
                    or node.carrier == "global" and record.visible[node.name]) and node.name
                if target then
                    local list = result.writes[target] or {}
                    result.writes[target] = list
                    list[#list + 1] = index
                end
            end
        end
    end
    return result
end

---Read-only source inspection used by the R3 version/diff service. Results
---contain direct literal candidates, direct-write counts and conservative
---blocked names, NOT a guarantee that every candidate can be published.
---Prepare remains the authority for selected-definition/anchor validation.
---The complete source is syntax checked; its chunk is never executed.
function M.Inspect(content)
    local result, reason, code = analyze(content)
    if result == nil then return failure(code, reason) end
    return result
end

---Prepare(content, entry, selected, published) -> plan | nil, structured error.
---selected is a dense name array, published[name] is the last published function
---identity (not a function discovered from an old snapshot). The caller owns
---selection, semantic diff/impact, unit versions and the R4 transaction.
---Supports local function f, local f=function, f=function and function f after
---a visible forward local declaration. No factories, aliases or unknown RHS.
function M.Prepare(content, entry, selected, published)
    local file = plain(entry) and entry.file or nil
    if not plain(entry) or not Anchor.Live(entry) or type(entry.anchor) ~= "function"
        or not plain(entry.slots) or type(entry.loaded_source) ~= "string" then
        return failure("unsupported", "a live loaded anchor entry is required", file)
    end
    local capable, reason = Anchor.Supported(Compose.Capability(debug))
    if not capable then return failure("capability", reason, file) end
    local count = dense(selected)
    if count == nil or not plain(published) then
        return failure("unsupported", "selected must be dense; published must be plain", file)
    end
    local requested = {}
    for _, name in ipairs(selected) do
        if type(name) ~= "string" or not name:match("^[A-Za-z_][A-Za-z0-9_]*$")
            or requested[name] then
            return failure("unsupported", "invalid or duplicate selected name", file)
        end
        if type(rawget(published, name)) ~= "function" then
            return failure("stale", "published function identity required", file, name)
        end
        requested[name] = true
    end
    local loaded, lerr, lcode = analyze(entry.loaded_source)
    if loaded == nil then return failure(lcode, lerr, file) end
    local candidate, cerr, ccode = analyze(content)
    if candidate == nil then return failure(ccode, cerr, file) end
    local old, new = loaded.bindings, candidate.bindings
    -- Fixed unique declarations, their kind and source order. This is stricter
    -- than name-set equality: reordered locals must not rebind old consumers.
    if not same(old.names, new.names) then
        return failure("unsupported", "top-level declaration order/set changed", file)
    end
    for _, name in ipairs(old.names) do
        local a, b = old.by_name[name], new.by_name[name]
        if a.kind ~= b.kind or a.self_visible ~= b.self_visible then
            return failure("unsupported", "declaration kind changed", file, name)
        end
        local _, slot_error = Anchor.Get(entry, name)
        if slot_error ~= nil then return failure("stale", slot_error, file, name) end
    end
    local definitions = {}
    for _, name in ipairs(selected) do
        if loaded.blocked[name] or candidate.blocked[name] then
            return failure("unsupported", "top-level control block mentions selected local", file, name)
        end
        local a, b = loaded.definitions[name], candidate.definitions[name]
        if a == nil or b == nil or #a ~= 1 or #b ~= 1
            or #(loaded.writes[name] or {}) ~= 1 or #(candidate.writes[name] or {}) ~= 1 then
            return failure("unsupported", "one direct function definition/write required", file, name)
        end
        a, b = a[1], b[1]
        if a.form ~= b.form or a.self_visible ~= b.self_visible or not same(a.visible, b.visible) then
            return failure("unsupported", "definition-point binding changed", file, name)
        end
        local current, read_error = Anchor.Get(entry, name)
        if read_error ~= nil or current ~= rawget(published, name) then
            return failure("stale", read_error or "published function was externally replaced", file, name)
        end
        definitions[#definitions + 1] = b
    end
    table.sort(definitions, function(a, b) return a.statement < b.statement end)
    local plan = { kind = M.Kind, version = M.Version, entry = entry, anchor = entry.anchor,
        loaded_source = entry.loaded_source, content = content, functions = {},
        joins = {}, writes = {}, read_set = {}, publications = {}, restarts = {} }
    for _, definition in ipairs(definitions) do
        local name = definition.name
        local created, create_error = Compose.Create(definition.body, name, definition.visible,
            { form = definition.form, name = "FunctionPlan:" .. tostring(file) .. ":" .. name })
        if created == nil then return failure("compile", create_error, file, name) end
        local join_plan, join_error = Compose.Plan(created, entry)
        if join_plan == nil then return failure("unsupported", join_error, file, name) end
        local slot, slot_error = Anchor.Slot(entry, name)
        if slot == nil then return failure("stale", slot_error, file, name) end
        local write = { name = name, anchor = entry.anchor, index = slot,
            before = rawget(published, name), value = created.fn }
        plan.functions[#plan.functions + 1] = { name = name, definition = definition,
            created = created, join_plan = join_plan }
        plan.writes[#plan.writes + 1] = write
        plan.read_set[#plan.read_set + 1] = { name = name, anchor = entry.anchor,
            index = slot, value = write.before }
        for _, join in ipairs(join_plan.joins) do plan.joins[#plan.joins + 1] = join end
    end
    return plan
end

return M
