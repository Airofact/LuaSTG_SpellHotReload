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
--- shared engine-independent Lexer, so it can be exercised under plain Lua
--- and LuaJIT without an engine.
--------------------------------------------------------------------------------

local Lexer = require("SpellHotReload.Source.Lexer")
local Syntax = require("SpellHotReload.Source.LuaSyntax")
local Tree = require("SpellHotReload.Source.SyntaxTree")

local M = {}

---Callee paths registered by host adapters. A call statement whose callee
---matches a key here is classified as `host`; every other call falls back to
---`effect`. Adapters register their entry points during the driver setup.
---@type table<string, boolean>
M.HostCalls = {}

-- Parse full Lua 5.1 statements; whitespace never chooses a boundary.
local function split(content)
    local tokens, lexical_error = Lexer.Tokenize(content)
    if lexical_error then return nil, lexical_error end
    local lines, line, cursor = {}, 1, 1
    for i, token in ipairs(tokens) do
        while cursor < token.pos do
            local c = content:sub(cursor,cursor)
            if c == "\r" or c == "\n" then
                line = line + 1
                local nextc = content:sub(cursor+1,cursor+1)
                if nextc ~= c and (nextc == "\r" or nextc == "\n") then cursor=cursor+1 end
            end
            cursor=cursor+1
        end
        lines[i]=line
    end
    local syntax, reason = Syntax.Parse(content,tokens)
    if not syntax then return nil, reason end
    return tokens, lines, syntax.body, syntax
end

-- Classification consumes the parser's nodes; token text is used only for display.
local function classify(ast,tokens,line,options)
    local nodes={}
    local function push(n)
        n.line=line;n.tok={first=ast.first,last=ast.last};n.syntax=ast;nodes[#nodes+1]=n;return n
    end
    if ast.kind=="local" or ast.kind=="local_function" then
        for slot,binding in ipairs(ast.names) do
            push({carrier="local",kind=ast.kind=="local_function" and "function" or (#ast.values>0 and "value" or "declare"),
                name=binding.name,slot=ast.kind=="local" and slot or nil})
        end
    elseif ast.kind=="function_statement" then
        local target=ast.target
        if target.kind=="name" then push({carrier="global",kind="function",name=target.name})
        else push({carrier="field",kind="function",path=Tree.Display(target,tokens),root=Tree.Root(target)}) end
    elseif ast.kind=="assign" then
        for slot,target in ipairs(ast.targets) do
            local path=Tree.Display(target,tokens)
            if target.kind=="name" then
                push({carrier="global",kind="assign",name=target.name,slot=slot,
                    table_rebuild=ast.values[1] and ast.values[1].kind=="table" or nil})
            else
                local append=false
                if target.kind=="index" then Tree.Walk(target.key,function(n)
                    if n.kind=="unary" and n.operator=="#" then append=true end
                end) end
                if append then push({carrier="container",kind="append",path=path,slot=slot})
                else push({carrier="field",kind="assign",path=path,root=Tree.Root(target),slot=slot}) end
            end
        end
    elseif ast.kind=="call_statement" then
        local callee=Tree.Path(ast.expression.callee) or ""
        local registered=M.HostCalls[callee] or (options.host_calls and options.host_calls[callee])
        push({carrier=(callee=="table.insert" or callee=="table.remove") and "container" or (registered and "host" or "effect"),
            kind=(callee=="table.insert" or callee=="table.remove") and callee or "call",callee=callee,
            reason=not registered and ("unadapted call: "..callee) or nil})
    else
        push({carrier="effect",kind=ast.kind=="return" and "return" or "block",
            reason="control flow does not carry a value slot"})
    end
    return nodes
end

-- Dependency hints come from identifier-expression nodes. They are not scope proofs.
function M._link(tokens,nodes)
    local visible={}
    local i=1
    while i<=#nodes do
        local j=i
        while j<=#nodes and nodes[j].syntax==nodes[i].syntax do j=j+1 end
        for k=i,j-1 do
            local n=nodes[k]
            if n.carrier=="local" then
                local names,seen={},{}
                for _,ref in ipairs(Tree.Names(n.syntax)) do
                    if visible[ref.name] and not seen[ref.name] then seen[ref.name]=true;names[#names+1]=ref.name end
                    if n.kind=="function" and ref.name==n.name then n.recursive=true end
                end
                table.sort(names);n.deps=names
            end
        end
        for k=i,j-1 do if nodes[k].carrier=="local" then visible[nodes[k].name]=true end end
        i=j
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
function M.Analyze(content, options)
    options = options or {}
    if type(content) ~= "string" then
        return nil, "content must be a string"
    end
    local source_offset = 0
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
        source_offset = 3
    end

    local tokens, lines, spans, syntax = split(content)
    if not tokens then return nil, lines end
    local nodes, statements = {}, {}
    for k = 1, #spans do
        local first, last = spans[k].first, spans[k].last
        local first_byte = tokens[first].pos
        local last_byte = tokens[last].pos + #tokens[last].value - 1
        local text = content:sub(first_byte, last_byte)
        statements[#statements + 1] = {
            tok = { first = first, last = last }, line = lines[first], text = text, syntax = spans[k],
            source_range = {
                first = first_byte + source_offset, last = last_byte + source_offset,
            },
        }
        for _, node in ipairs(classify(spans[k], tokens, lines[first], options)) do
            node.text = text
            nodes[#nodes + 1] = node
        end
    end

    M._link(tokens, nodes)
    -- Token positions refer to BOM-stripped source; public byte ranges refer to
    -- the original content. Syntax boundaries do not make name deps a binding proof.
    return nodes, nil, {
        source = content, source_offset = source_offset,
        tokens = tokens, token_lines = lines, statements = statements, syntax = syntax,
        nodes = nodes, binding_complete = false,
    }
end

---Split into top-level statements and return their source text. Exposed
---separately so the statement boundaries can be tested without classification.
---@param content string
---@return table[]?  -- { { line = integer, text = string } }
---@return string? error
function M.SplitStatements(content)
    if type(content) ~= "string" then return nil, "content must be a string" end
    if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
    local tokens, lines, spans, syntax = split(content)
    if not tokens then return nil, lines end
    local result = {}
    for k = 1, #spans do
        local first, last = spans[k].first, spans[k].last
        result[#result + 1] = {
            line = lines[first],
            text = content:sub(tokens[first].pos, tokens[last].pos + #tokens[last].value - 1),
        }
    end
    return result
end

return M
