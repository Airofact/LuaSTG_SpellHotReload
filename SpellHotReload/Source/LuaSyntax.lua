-- Pure Lua 5.1 syntax tree over complete Lexer tokens. No compilation/execution.
-- Each node retains first/last token indices and ordered children. No binding,
-- ownership, deletion or runtime-type claims are derived by this parser.
local M={}
local keywords={}
for name in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%S+") do keywords[name]=true end
local binary={["or"]=1,["and"]=2,["<"]=3,[">"]=3,["<="]=3,[">="]=3,["~="]=3,["=="]=3,[".."]=4,["+"]=5,["-"]=5,["*"]=6,["/"]=6,["%"]=6,["^"]=8}
local unary={["not"]=true,["-"]=true,["#"]=true}
local terminator={["end"]=true,["else"]=true,["elseif"]=true,["until"]=true,["<eof>"]=true}

function M.Parse(source,tokens)
    local eof={value="<eof>",kind="eof"}
    local i,level,loops,vararg=1,0,0,true
    local expr,block,statement,body,constructor,prefix
    local function term(at) return tokens[at] or eof end
    local function value() return term(i).value end
    local function bad(reason)
        error("Lua syntax: "..reason.." at byte "..(tokens[i] and tokens[i].pos or #source+1),0)
    end
    local function take(wanted)
        if value()~=wanted then bad("expected '"..wanted.."', got '"..value().."'") end
        local at=i;i=i+1;return at
    end
    local function accept(wanted)
        if value()==wanted then i=i+1;return true end
        return false
    end
    local function enter()
        level=level+1;if level>160 then bad("analysis nesting limit exceeded") end
    end
    local function node(kind,first,properties,children)
        local n=properties or {};n.kind=kind;n.first=first;n.last=i-1;n.children=children or {};return n
    end
    local function name(kind)
        local at,t=i,term(i)
        if t.kind~="word" or keywords[t.value] then bad("identifier required") end
        i=i+1;return node(kind or "name",at,{name=t.value})
    end
    local function expressions()
        local list={expr(1)}
        while accept(",") do list[#list+1]=expr(1) end
        return list
    end
    local function arguments()
        if value()=="(" then
            local prev=tokens[i-1]
            local gap=source:sub(prev.pos+#prev.value,tokens[i].pos-1)
            if gap:find("[\r\n]") then bad("ambiguous newline before call arguments") end
            take("(");local list=value()~=")" and expressions() or {};take(")");return list
        elseif value()=="{" then return {constructor()}
        elseif term(i).kind=="string" then
            local at,t=i,term(i);i=i+1
            return {node("literal",at,{literal_kind="string",raw=t.value,value=t.literal})}
        end
        bad("call arguments required")
    end
    prefix=function()
        local first=i
        local n
        if accept("(") then local inner=expr(1);take(")");n=node("paren",first,{expression=inner},{inner})
        else n=name() end
        while true do
            if accept(".") then
                local field=name("binding")
                n=node("member",first,{base=n,name=field.name,separator="."},{n})
            elseif accept("[") then
                local key=expr(1);take("]")
                n=node("index",first,{base=n,key=key},{n,key})
            elseif accept(":") then
                local field=name("binding")
                local callee=node("member",first,{base=n,name=field.name,separator=":"},{n})
                local args=arguments();local children={callee}
                for _,a in ipairs(args) do children[#children+1]=a end
                n=node("call",first,{callee=callee,args=args,method=true},children)
            elseif value()=="(" or value()=="{" or term(i).kind=="string" then
                local args=arguments();local children={n}
                for _,a in ipairs(args) do children[#children+1]=a end
                n=node("call",first,{callee=n,args=args,method=false},children)
            else break end
        end
        return n
    end
    constructor=function()
        local first=take("{");local fields={}
        if value()~="}" then
            while true do
                local at=i;local key,label
                if accept("[") then key=expr(1);take("]");take("=")
                elseif term(i).kind=="word" and not keywords[value()] and term(i+1).value=="=" then
                    label=name("binding").name;take("=")
                end
                local val=expr(1);local children=key and {key,val} or {val}
                fields[#fields+1]=node("field",at,{key=key,name=label,array=not key and not label,value=val},children)
                if not accept(",") and not accept(";") then break end
                if value()=="}" then break end
            end
        end
        take("}");return node("table",first,{fields=fields},fields)
    end
    body=function(first)
        local open=take("(");local params={}
        local old_loops,old_vararg=loops,vararg
        loops,vararg=0,false
        if value()~=")" then
            if accept("...") then vararg=true
            else
                params[#params+1]=name("binding")
                while accept(",") do
                    if accept("...") then vararg=true;break end
                    params[#params+1]=name("binding")
                end
            end
        end
        take(")");local inside=block();take("end")
        local children={};for _,p in ipairs(params) do children[#children+1]=p end
        children[#children+1]=inside
        local fn=node("function",first,{params=params,open=open,body=inside,vararg=vararg},children)
        loops,vararg=old_loops,old_vararg;return fn
    end
    expr=function(minimum)
        enter();local first,v=i,value();local n
        if unary[v] then
            i=i+1;local operand=expr(7)
            n=node("unary",first,{operator=v,operand=operand},{operand})
        elseif v=="nil" or v=="true" or v=="false" or term(i).kind=="number" or term(i).kind=="string" then
            local t=term(i);i=i+1
            local kind=(v=="nil" and "nil") or ((v=="true" or v=="false") and "boolean") or t.kind
            n=node("literal",first,{literal_kind=kind,raw=v,value=t.literal})
        elseif accept("...") then
            if not vararg then bad("vararg outside a vararg function") end
            n=node("vararg",first)
        elseif accept("function") then n=body(first)
        elseif v=="{" then n=constructor()
        else n=prefix() end
        while binary[value()] and binary[value()]>=minimum do
            local op=value();local rank=binary[op];i=i+1
            local right=expr((op==".." or op=="^") and rank or rank+1)
            n=node("binary",first,{operator=op,left=n,right=right},{n,right})
        end
        level=level-1;return n
    end
    local function variable(n) return n.kind=="name" or n.kind=="member" or n.kind=="index" end
    statement=function()
        local first=i;local n,laststat
        if accept("if") then
            local clauses,children={},{}
            local condition=expr(1);take("then");local inside=block()
            clauses[#clauses+1]={condition=condition,body=inside};children[#children+1]=condition;children[#children+1]=inside
            while accept("elseif") do
                condition=expr(1);take("then");inside=block()
                clauses[#clauses+1]={condition=condition,body=inside};children[#children+1]=condition;children[#children+1]=inside
            end
            local otherwise
            if accept("else") then otherwise=block();children[#children+1]=otherwise end
            take("end");n=node("if",first,{clauses=clauses,otherwise=otherwise},children)
        elseif accept("while") then
            local condition=expr(1);take("do");loops=loops+1
            local inside=block();loops=loops-1;take("end")
            n=node("while",first,{condition=condition,body=inside},{condition,inside})
        elseif accept("do") then
            local inside=block();take("end");n=node("do",first,{body=inside},{inside})
        elseif accept("repeat") then
            loops=loops+1;local inside=block();loops=loops-1;take("until");local condition=expr(1)
            n=node("repeat",first,{body=inside,condition=condition},{inside,condition})
        elseif accept("for") then
            local names={name("binding")};local values,kind
            if accept("=") then
                kind="for_numeric";values={expr(1)};take(",");values[#values+1]=expr(1)
                if accept(",") then values[#values+1]=expr(1) end
            else
                kind="for_generic";while accept(",") do names[#names+1]=name("binding") end
                take("in");values=expressions()
            end
            take("do");loops=loops+1;local inside=block();loops=loops-1;take("end")
            local children={};for _,x in ipairs(names) do children[#children+1]=x end
            for _,x in ipairs(values) do children[#children+1]=x end;children[#children+1]=inside
            n=node(kind,first,{names=names,values=values,body=inside},children)
        elseif accept("function") then
            local target=name();local method=false
            while accept(".") do
                local field=name("binding")
                target=node("member",target.first,{base=target,name=field.name,separator="."},{target})
            end
            if accept(":") then
                local field=name("binding");method=true
                target=node("member",target.first,{base=target,name=field.name,separator=":"},{target})
            end
            local fn=body(first)
            n=node("function_statement",first,{target=target,fn=fn,method=method},{target,fn})
        elseif accept("local") then
            if accept("function") then
                local binding=name("binding");local fn=body(first+1)
                n=node("local_function",first,{names={binding},fn=fn},{binding,fn})
            else
                local names={name("binding")};while accept(",") do names[#names+1]=name("binding") end
                local values=accept("=") and expressions() or {};local children={}
                for _,x in ipairs(names) do children[#children+1]=x end
                for _,x in ipairs(values) do children[#children+1]=x end
                n=node("local",first,{names=names,values=values},children)
            end
        elseif accept("return") then
            local values={}
            if not terminator[value()] and value()~=";" then values=expressions() end
            n=node("return",first,{values=values},values);laststat=true
        elseif accept("break") then
            if loops==0 then bad("break outside a loop") end
            n=node("break",first);laststat=true
        else
            local firstexpr=prefix()
            if value()=="=" or value()=="," then
                if not variable(firstexpr) then bad("assignment target required") end
                local targets={firstexpr}
                while accept(",") do
                    local target=prefix();if not variable(target) then bad("assignment target required") end
                    targets[#targets+1]=target
                end
                take("=");local values=expressions();local children={}
                for _,x in ipairs(targets) do children[#children+1]=x end
                for _,x in ipairs(values) do children[#children+1]=x end
                n=node("assign",first,{targets=targets,values=values},children)
            elseif firstexpr.kind=="call" then n=node("call_statement",first,{expression=firstexpr},{firstexpr})
            else bad("assignment or call required") end
        end
        n.content_last=n.last
        accept(";");n.last=i-1
        return n,laststat
    end
    block=function()
        enter();local first=i;local statements={}
        while not terminator[value()] do
            local n,laststat=statement();statements[#statements+1]=n
            if laststat then break end
        end
        level=level-1;return node("block",first,{body=statements},statements)
    end
    local ok,result=pcall(function()
        local root=block();take("<eof>");root.kind="chunk";return root
    end)
    if not ok then return nil,tostring(result) end
    return result
end
return M
