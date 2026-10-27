--------------------------------------------------------------------------------
--- SpellHotReload.Source.TopLevelIR
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
--- native snapshot and its byte spans. Whole input compilation belongs to Parse.
--------------------------------------------------------------------------------

local Syntax = require("SpellHotReload.Source.SyntaxTree")

local M = {}

---Callee paths registered by host adapters. A call statement whose callee
---matches a key here is classified as `host`; every other call falls back to
---`effect`. Adapters register their entry points during the driver setup.
---@type table<string, boolean>
M.HostCalls = {}

-- Source discovery enumerates native statements; it does not reconstruct a token partition.
local function split(content, previous_syntax)
    local tree, reason,code = Syntax.Parse(content,previous_syntax)
    if not tree then return nil,reason,code end
    return tree
end

-- Classification consumes existing native nodes and source spans.
local function classify(ast,Tree,line,options)
    local nodes={}
    local function push(n)
        n.line=line;n.syntax=ast;nodes[#nodes+1]=n;return n
    end
    local declaration=Tree.Match(ast,"declaration")
    local definition=Tree.Match(ast,"definition")
    local assignment=Tree.Match(ast,"assignment")
    local call=Tree.Match(ast,"call_statement")
    if declaration then
        for slot,binding in ipairs(declaration.names) do
            push({carrier="local",kind=declaration.self_visible and "function" or (#declaration.values>0 and "value" or "declare"),
                name=Tree.Identifier(binding),slot=not declaration.self_visible and slot or nil,
                name_syntax=binding,self_visible=declaration.self_visible==true})
        end
    elseif definition and definition.form=="function-statement" then
        local target=definition.target
        if Tree.Is(target,"name") then push({carrier="global",kind="function",name=Tree.Identifier(target)})
        else push({carrier="field",kind="function",path=Tree.Display(target),root=Tree.Root(target)}) end
    elseif assignment then
        for slot,target in ipairs(assignment.targets) do
            local path=Tree.Display(target)
            if Tree.Is(target,"name") then
                push({carrier="global",kind="assign",name=Tree.Identifier(target),slot=slot,
                    table_rebuild=assignment.values[1] and Tree.Is(assignment.values[1],"table") or nil})
            else
                local append=false
                local index=Tree.Match(target,"index")
                if index then Tree.Walk(index.key,function(n)
                    local unary=Tree.Match(n,"unary")
                    if unary and unary.operator=="#" then append=true end
                end) end
                if append then push({carrier="container",kind="append",path=path,slot=slot})
                else push({carrier="field",kind="assign",path=path,root=Tree.Root(target),slot=slot}) end
            end
        end
    elseif call then
        local callee=Tree.Path(call.callee) or ""
        local registered=M.HostCalls[callee] or (options.host_calls and options.host_calls[callee])
        push({carrier=(callee=="table.insert" or callee=="table.remove") and "container" or (registered and "host" or "effect"),
            kind=(callee=="table.insert" or callee=="table.remove") and callee or "call",callee=callee,
            reason=not registered and ("unadapted call: "..callee) or nil})
    else
        push({carrier="effect",kind=Tree.Is(ast,"return") and "return" or "block",
            reason="control flow does not carry a value slot"})
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
---@return table? analysis -- shared lexical/syntax snapshot, NOT binding proof
local function analyze(content, options, previous_syntax,owned)
    options = options or {}
    if type(content) ~= "string" then
        return nil, "content must be a string"
    end
    local source_offset = 0
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
        source_offset = 3
    end

    local Tree, spans,code = split(content, previous_syntax)
    if not Tree then return nil,spans,nil,code end
    owned.tree=Tree
    spans=Tree.Statements(Tree.root)
    local nodes, statements = {}, {}
    local declarations, declaration_names, declarations_by_name = {}, {}, {}
    for k = 1, #spans do
        local first, last = Tree.Range(spans[k])
        local first_byte,last_byte = first,last
        local text = content:sub(first_byte, last_byte)
        statements[#statements + 1] = {
            line = Tree.Line(spans[k]), text = text, syntax = spans[k],
            scope_before = #declarations,
            source_range = {
                first = first_byte + source_offset, last = last_byte + source_offset,
            },
        }
        for _, node in ipairs(classify(spans[k], Tree, Tree.Line(spans[k]), options)) do
            node.text = text;node.statement=k
            nodes[#nodes + 1] = node
            if node.carrier == "local" then
                node.statement, node.ordinal = k, #declarations + 1
                node.source_range = statements[k].source_range
                declarations[node.ordinal] = node
                local named = declarations_by_name[node.name]
                if not named then
                    named = {}; declarations_by_name[node.name] = named
                    declaration_names[#declaration_names + 1] = node.name
                end
                named[#named + 1] = node
                if node.self_visible then statements[k].self_declaration = node end
            end
        end
    end

    -- Native spans use BOM-stripped source; public ranges use the original file.
    return nodes, nil, {
        source = content, source_offset = source_offset,
        statements = statements, syntax = Tree,
        nodes = nodes, scope_complete = true,
        declarations = declarations, declaration_names = declaration_names,
        declarations_by_name = declarations_by_name,
    }
end

function M.Analyze(content,options,previous_syntax)
    local owned={}
    local ok,nodes,err,analysis,code=pcall(analyze,content,options,previous_syntax,owned)
    if not ok then if owned.tree then owned.tree.Discard() end;return nil,tostring(nodes),nil,"unsupported" end
    return nodes,err,analysis,code
end

-- Reuse the same complete analysis contract for this diagnostic helper.
function M.SplitStatements(content)
    local nodes,err,analysis=M.Analyze(content)
    if not nodes then return nil,err end
    local result={}
    for i,row in ipairs(analysis.statements) do result[i]={line=row.line,text=row.text} end
    return result
end
return M
