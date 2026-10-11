--------------------------------------------------------------------------------
--- SpellHotReload.Source.Binding
---
--- Lexical declaration set and definition-point visibility for one shared
--- TopLevelIR analysis snapshot.
---
--- The module states only what the shared token stream can prove about
--- *top-level* Lua scope:
---
---   declarations   the names a file binds as top-level locals, in source
---                  order, with their TopLevelIR kind/slot and byte range;
---   visibility     the top-level locals in scope *before* each statement
---                  (Lua top-level scoping is strictly backwards; a
---                  `local function` name is additionally visible inside its
---                  own body);
---   certain        in-scope names occurring at block depth 0 inside the
---                  statement, outside every nested function/if/do/repeat
---                  block, so no nested parameter, loop variable or nested
---                  local can rebind them;
---   uncertain      in-scope names occurring inside a nested block, where such
---                  a rebinding is possible.
---
--- It deliberately does NOT claim a complete Lua binding proof. TopLevelIR's
--- `_link` token-name deps are a heuristic over these same tokens and are never
--- upgraded into safety: `bindings.complete` is always false, and a statement
--- TopLevelIR could not parse marks the snapshot `opaque`.
---
--- Nothing here executes the analyzed source.
--------------------------------------------------------------------------------

local M = {}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function is_word(token)
    return token ~= nil and token.kind == "word"
end

---Token indices in `first..last` that *introduce* a binding instead of reading
---one: names of a `local` statement, parameters of a `function` literal, and
---the control variables of a `for` loop. A scope lookup must skip them.
---@param tokens table[]
---@param first integer
---@param last integer
---@return table<integer, boolean>
local function declaration_sites(tokens, first, last)
    local sites = {}
    local i = first
    while i <= last do
        local token = tokens[i]
        if is_word(token) and token.value == "local" then
            local j = i + 1
            if is_word(tokens[j]) and tokens[j].value == "function" then
                if is_word(tokens[j + 1]) then sites[j + 1] = true end
            else
                local expecting = true
                while j <= last do
                    local next_token = tokens[j]
                    if next_token.value == "=" then break end
                    if next_token.value == "," then
                        expecting = true
                    elseif expecting and is_word(next_token) then
                        sites[j] = true
                        expecting = false
                    end
                    j = j + 1
                end
            end
        elseif is_word(token) and token.value == "function" then
            local j = i + 1
            while j <= last and not (tokens[j] ~= nil and tokens[j].value == "(") do
                j = j + 1
            end
            if j <= last then
                local nest = 0
                j = j + 1
                while j <= last do
                    local next_token = tokens[j]
                    if next_token.value == "(" then
                        nest = nest + 1
                    elseif next_token.value == ")" then
                        if nest == 0 then break end
                        nest = nest - 1
                    elseif nest == 0 and is_word(next_token) then
                        sites[j] = true
                    end
                    j = j + 1
                end
            end
        elseif is_word(token) and token.value == "for" then
            local j = i + 1
            while j <= last do
                local next_token = tokens[j]
                if next_token.value == "=" then break end
                if is_word(next_token) and next_token.value == "in" then break end
                if is_word(next_token) then sites[j] = true end
                j = j + 1
            end
        end
        i = i + 1
    end
    return sites
end

---Declaration sites introduced by a whole top-level `local` statement, in
---source order. Returns nil when the statement is not a top-level `local`.
---@param tokens table[]
---@param first integer
---@param last integer
---@return table[]?  -- { { token = integer, name = string, slot = integer?, self_visible = boolean? } }
local function top_level_declarations(tokens, first, last)
    local head = tokens[first]
    if not is_word(head) or head.value ~= "local" or head.depth ~= 0 then
        return nil
    end
    if is_word(tokens[first + 1]) and tokens[first + 1].value == "function" then
        local name_token = tokens[first + 2]
        if not is_word(name_token) then return {} end
        return { { token = first + 2, name = name_token.value, self_visible = true } }
    end
    local names, expecting, slot = {}, true, 0
    local i = first + 1
    while i <= last do
        local token = tokens[i]
        if token.value == "=" then break end
        if token.value == "," then
            expecting = true
        elseif expecting and is_word(token) then
            slot = slot + 1
            names[#names + 1] = { token = i, name = token.value, slot = slot }
            expecting = false
        end
        i = i + 1
    end
    return names
end

---Split the identifier occurrences of one statement into occurrences that must
---read the visible top-level local (`certain`, block depth 0) and occurrences a
---nested binding may intercept (`uncertain`, nested block).
---A statement containing `repeat` demotes every hit to `uncertain`, because the
---`until` expression is evaluated in the body's scope and may see a body local.
---@return table[] certain
---@return table[] uncertain
local function scan_references(tokens, first, last, scope, self_declares, sites)
    local certain, uncertain = {}, {}
    local brace, repeat_scope = 0, false
    for i = first, last do
        if is_word(tokens[i]) and tokens[i].value == "repeat" then
            repeat_scope = true
            break
        end
    end
    for i = first, last do
        local token = tokens[i]
        local value = token.value
        if value == "{" then
            brace = brace + 1
        elseif value == "}" then
            brace = brace - 1
        elseif is_word(token) and not sites[i] then
            local prev = tokens[i - 1]
            local next_token = tokens[i + 1]
            local field = prev ~= nil and (prev.value == "." or prev.value == ":"
                or (is_word(prev) and prev.value == "goto"))
            local key = brace > 0 and next_token ~= nil and next_token.value == "="
                and not (tokens[i + 2] ~= nil and tokens[i + 2].value == "=")
            if not field and not key then
                local bound = scope[value] ~= nil
                    or (self_declares ~= nil and self_declares[value] ~= nil)
                if bound then
                    local hit = { name = value, token = i, depth = token.depth }
                    if token.depth == 0 and not repeat_scope then
                        certain[#certain + 1] = hit
                    else
                        uncertain[#uncertain + 1] = hit
                    end
                end
            end
        end
    end
    return certain, uncertain
end

---Build the declaration/visibility model for one TopLevelIR analysis snapshot.
---@param analysis table  the third return of TopLevelIR.Analyze
---@return table? bindings
---@return string? reason
function M.Analyze(analysis)
    if not plain(analysis) then
        return nil, "analysis must be a plain table"
    end
    local tokens, statements, nodes = analysis.tokens, analysis.statements, analysis.nodes
    if not plain(tokens) or not plain(statements) or not plain(nodes) then
        return nil, "analysis must provide tokens, statements and nodes"
    end

    -- Group TopLevelIR's local nodes by the statement that declares them, so the
    -- declaration set cannot drift from the classification the rest of the
    -- model already consumes.
    local local_nodes, opaque = {}, false
    for _, node in ipairs(nodes) do
        if node.carrier == "local" and node.name ~= nil then
            local start = node.tok and node.tok.first
            if start == nil then
                return nil, "local node is missing its token range"
            end
            local bucket = local_nodes[start]
            if bucket == nil then
                bucket = {}
                local_nodes[start] = bucket
            end
            bucket[#bucket + 1] = node
        elseif node.carrier == "effect" and node.kind == "unknown" then
            opaque = true
        end
    end

    local bindings = {
        complete = false, scope = "top-level", opaque = opaque,
        statements = {}, declarations = {}, names = {}, by_name = {}, duplicates = {},
    }
    local scope, ownership = {}, {}

    for index = 1, #statements do
        local statement = statements[index]
        local first, last = statement.tok.first, statement.tok.last
        local record = {
            index = index, visible = {}, declares = {}, certain = {}, uncertain = {},
            nested = false, self_visible = false, unparsed = false,
        }
        for name, declaration in next, scope do record.visible[name] = declaration end
        for i = first, last do
            if tokens[i].depth > 0 then
                record.nested = true
                break
            end
        end

        local scanned = top_level_declarations(tokens, first, last)
        local bucket = local_nodes[first]
        if scanned ~= nil then
            if bucket ~= nil and #scanned == #bucket then
                for k = 1, #scanned do
                    local declaration = {
                        name = bucket[k].name, kind = bucket[k].kind, slot = bucket[k].slot,
                        statement = index, token = scanned[k].token,
                        source_range = statement.source_range,
                        self_visible = scanned[k].self_visible == true,
                    }
                    bindings.declarations[#bindings.declarations + 1] = declaration
                    record.declares[declaration.name] = declaration
                    if declaration.self_visible then record.self_visible = true end
                    local owned = ownership[declaration.name]
                    if owned == nil then
                        owned = {}
                        ownership[declaration.name] = owned
                    end
                    owned[#owned + 1] = declaration
                    scope[declaration.name] = declaration
                end
            else
                -- TopLevelIR and the lexical scan disagree; do not guess.
                record.unparsed = true
                opaque = true
            end
        elseif bucket ~= nil then
            record.unparsed = true
            opaque = true
        end

        local sites = declaration_sites(tokens, first, last)
        local self_declares = record.self_visible and record.declares or nil
        record.certain, record.uncertain =
            scan_references(tokens, first, last, record.visible, self_declares, sites)
        bindings.statements[index] = record
    end

    local named = {}
    for _, declaration in ipairs(bindings.declarations) do
        local name = declaration.name
        if not named[name] then
            named[name] = true
            bindings.names[#bindings.names + 1] = name
        end
    end
    for _, name in ipairs(bindings.names) do
        local owned = ownership[name]
        if #owned == 1 then
            bindings.by_name[name] = owned[1]
        else
            bindings.duplicates[#bindings.duplicates + 1] =
                { name = name, count = #owned, declarations = owned }
        end
    end
    bindings.opaque = opaque
    return bindings
end

return M
