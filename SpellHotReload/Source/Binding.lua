--------------------------------------------------------------------------------
--- SpellHotReload.Source.Binding
---
--- Lexical declaration set and definition-point visibility for one shared
--- TopLevelIR analysis snapshot.
---
--- The module reads declarations and reference expressions from shared syntax for
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
--- `_link` identifier-expression deps are a heuristic over these same tokens and are never
--- upgraded into safety: `bindings.complete` is always false, and a statement
--- TopLevelIR could not parse marks the snapshot `opaque`.
---
--- Nothing here executes the analyzed source.
--------------------------------------------------------------------------------

local Tree = require("SpellHotReload.Source.SyntaxTree")
local M = {}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

-- Declaration and reference sites are parser nodes, not token-neighbour guesses.
local function top_level_declarations(ast)
    local declaration=Tree.Match(ast,"declaration")
    if not declaration then return nil end
    local names={}
    for slot,binding in ipairs(declaration.names) do
        names[#names+1]={token=Tree.Range(binding),name=Tree.Identifier(binding),
            slot=not declaration.self_visible and slot or nil,self_visible=declaration.self_visible}
    end
    return names
end
local function scan_references(tokens,ast,scope,self_declares)
    local certain,uncertain={},{}
    local repeat_scope=false
    Tree.Walk(ast,function(n) if Tree.Is(n,"repeat") then repeat_scope=true end end)
    for _,ref in ipairs(Tree.Names(ast)) do
        local value=Tree.Identifier(ref)
        if scope[value] or (self_declares and self_declares[value]) then
            local first=Tree.Range(ref)
            local token=tokens[first];local hit={name=value,token=first,depth=token.depth}
            if token.depth==0 and not repeat_scope then certain[#certain+1]=hit
            else uncertain[#uncertain+1]=hit end
        end
    end
    return certain,uncertain
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
        if not Tree.SameSnapshot(analysis.syntax,statement.syntax) then return nil,"statement syntax is required" end
        Tree.Walk(statement.syntax,function(n)
            if Tree.Is(n,"function") or Tree.Is(n,"block") then record.nested=true end
        end)

        local scanned = top_level_declarations(statement.syntax)
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
                -- TopLevelIR and the syntax declaration disagree; do not guess.
                record.unparsed = true
                opaque = true
            end
        elseif bucket ~= nil then
            record.unparsed = true
            opaque = true
        end

        local self_declares = record.self_visible and record.declares or nil
        record.certain, record.uncertain =
            scan_references(tokens, statement.syntax, record.visible, self_declares)
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
