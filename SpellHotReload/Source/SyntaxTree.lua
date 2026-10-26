-- Public Lua syntax queries over one immutable parser snapshot.
-- Only this module and LuaSyntax inspect the current parser's node layout.
-- Captures are detached facts containing opaque, snapshot-owned node references.
local Parser=require("SpellHotReload.Source.LuaSyntax")
local M={}
-- Values never reference keys: snapshots and their cycles can be collected.
local snapshots=setmetatable({}, {__mode="k"})
local roles={chunk=true,block=true,name=true,binding=true,literal=true,vararg=true,
    member=true,index=true,call=true,paren=true,["function"]=true,unary=true,binary=true,
    ["table"]=true,field=true,["local"]=true,local_function=true,assign=true,
    function_statement=true,call_statement=true,["return"]=true,["break"]=true,
    ["do"]=true,["while"]=true,["repeat"]=true,for_numeric=true,for_generic=true,["if"]=true}
local patterns={declaration=true,assignment=true,definition=true,member=true,index=true,
    call=true,call_statement=true,literal=true,unary=true,["table"]=true,
    ["function"]=true,["return"]=true}
local function owner(node)
    local snapshot=type(node)=="table" and rawget(node,1)
    if not snapshot or not snapshots[snapshot] or not snapshot.owns(node) then
        error("syntax: foreign or invalid node reference",3)
    end
    return snapshot
end
function M.IsNode(node)
    local snapshot=type(node)=="table" and rawget(node,1)
    return snapshot~=nil and snapshots[snapshot]==true and snapshot.owns(node) or false
end
function M.SameSnapshot(a,b)
    return M.IsNode(a) and M.IsNode(b) and rawget(a,1)==rawget(b,1) or false
end
function M.MatchesInput(root,source,tokens)
    return M.IsNode(root) and owner(root).input(root,source,tokens) or false
end
function M.Parse(source,tokens)
    local root,reason=Parser.Parse(source,tokens)
    if not root then return nil,reason end
    local snapshot,by_node,by_raw={},{},{}
    local function ref(raw)
        if not raw then return nil end
        local node=by_raw[raw]
        if not node then node={snapshot};by_raw[raw]=node;by_node[node]=raw end
        return node
    end
    local function raw(node)
        local value=by_node[node]
        if not value then error("syntax: node belongs to another snapshot",3) end
        return value
    end
    local function refs(values)
        local result={}
        for i,value in ipairs(values or {}) do result[i]=ref(value) end
        return result
    end
    function snapshot.owns(node) return by_node[node]~=nil end
    function snapshot.input(node,text,lexed)
        return by_node[node]==root and source==text and tokens==lexed
    end
    function snapshot.is(node,role) return raw(node).kind==role end
    function snapshot.identifier(node)
        local n=raw(node)
        if n.kind=="name" or n.kind=="binding" then return n.name,n.kind=="binding" end
    end
    function snapshot.range(node)
        local n=raw(node);return n.first,n.last,n.content_last or n.last
    end
    function snapshot.statements(node)
        local n=raw(node)
        if n.kind~="chunk" and n.kind~="block" then error("syntax: statement sequence required",3) end
        return refs(n.body)
    end
    local function call(n)
        return {node=ref(n),callee=ref(n.callee),args=refs(n.args),method=n.method==true}
    end
    function snapshot.match(node,pattern)
        local n=raw(node)
        if pattern=="declaration" then
            if n.kind=="local" then return {names=refs(n.names),values=refs(n.values),self_visible=false} end
            if n.kind=="local_function" then return {names=refs(n.names),values={ref(n.fn)},self_visible=true} end
        elseif pattern=="assignment" then
            if n.kind=="assign" then return {targets=refs(n.targets),values=refs(n.values)} end
        elseif pattern=="definition" then
            local target,fn,method,self_visible,form
            if n.kind=="local_function" then target,fn,self_visible,form=n.names[1],n.fn,true,"local-function"
            elseif n.kind=="function_statement" then target,fn,method,form=n.target,n.fn,n.method,"function-statement"
            elseif n.kind=="local" and #n.names==1 and #n.values==1 and n.values[1].kind=="function" then
                target,fn,form=n.names[1],n.values[1],"local-initializer"
            elseif n.kind=="assign" and #n.targets==1 and #n.values==1 and n.values[1].kind=="function" then
                target,fn,form=n.targets[1],n.values[1],"assignment"
            end
            if fn then return {target=ref(target),fn=ref(fn),method=method==true,
                self_visible=self_visible==true,form=form} end
        elseif pattern=="member" then
            if n.kind=="member" then return {base=ref(n.base),name=n.name,separator=n.separator} end
        elseif pattern=="index" then
            if n.kind=="index" then return {base=ref(n.base),key=ref(n.key)} end
        elseif pattern=="call" then
            if n.kind=="call" then return call(n) end
        elseif pattern=="call_statement" then
            if n.kind=="call_statement" then return call(n.expression) end
        elseif pattern=="literal" then
            if n.kind=="literal" then return {category=n.literal_kind,value=n.value,raw=n.raw} end
        elseif pattern=="unary" then
            if n.kind=="unary" then return {operator=n.operator,operand=ref(n.operand)} end
        elseif pattern=="table" then
            if n.kind=="table" then
                local fields={}
                for i,f in ipairs(n.fields) do fields[i]={node=ref(f),key=ref(f.key),name=f.name,
                    array=f.array,value=ref(f.value)} end
                return {fields=fields}
            end
        elseif pattern=="function" then
            if n.kind=="function" then return {params=refs(n.params),body=ref(n.body),vararg=n.vararg} end
        elseif pattern=="return" then
            if n.kind=="return" then return {values=refs(n.values)} end
        end
    end
    function snapshot.walk(node,visit)
        local function walk(n,parent,functions,calls)
            if n.kind=="function" then functions=functions+1 end
            if n.kind=="call" then calls=calls+1 end
            if visit(ref(n),ref(parent),functions,calls)==false then return end
            for _,child in ipairs(n.children) do walk(child,n,functions,calls) end
        end
        walk(raw(node),nil,0,0)
    end
    function snapshot.text(node)
        local n=raw(node)
        if n.first>n.last then return "" end
        return source:sub(tokens[n.first].pos,tokens[n.last].pos+#tokens[n.last].value-1)
    end
    local function signature(first,last)
        local parts={}
        for i=first,last do
            local t=tokens[i];parts[#parts+1]=t.kind..":"..#t.value..":"..t.value
        end
        return table.concat(parts,"|")
    end
    function snapshot.signature(node)
        local n=raw(node);return signature(n.first,n.content_last or n.last)
    end
    function snapshot.display(node)
        local n,parts=raw(node),{}
        for i=n.first,n.last do parts[#parts+1]=tokens[i].value end
        return table.concat(parts)
    end
    function snapshot.function_text(node,method,as_signature)
        local fn=raw(node)
        if fn.kind~="function" then error("syntax: function required",3) end
        if as_signature then
            local prefix="word:8:function|symbol:1:("
            if method then
                prefix=prefix.."|word:4:self"
                if #fn.params>0 or fn.vararg then prefix=prefix.."|symbol:1:," end
            end
            return prefix.."|"..signature(fn.open+1,fn.last)
        end
        local tail=source:sub(tokens[fn.open].pos+1,tokens[fn.last].pos+#tokens[fn.last].value-1)
        if method then tail="self"..((#fn.params>0 or fn.vararg) and "," or "")..tail end
        return "function("..tail
    end
    snapshots[snapshot]=true
    return ref(root)
end
function M.Match(node,pattern)
    if not patterns[pattern] then error("syntax: unknown match pattern "..tostring(pattern),2) end
    if node==nil then return nil end
    return owner(node).match(node,pattern)
end
function M.Is(node,role)
    if not roles[role] then error("syntax: unknown node role "..tostring(role),2) end
    if node==nil then return false end
    return owner(node).is(node,role)
end
function M.Identifier(node)
    if node==nil then return nil end
    return owner(node).identifier(node)
end
function M.IsName(node,name)
    return M.Is(node,"name") and M.Identifier(node)==name or false
end
function M.String(node)
    local literal=M.Match(node,"literal")
    if literal and literal.category=="string" then return literal.value end
end
function M.Range(node) return owner(node).range(node) end
function M.ContentLast(node) local _,_,last=M.Range(node);return last end
function M.Statements(node) return owner(node).statements(node) end
-- Preorder, stable parent identity, root-relative function/call depth, false prunes.
function M.Walk(node,visit)
    if node==nil then return end
    assert(type(visit)=="function","syntax visitor required")
    return owner(node).walk(node,visit)
end
function M.Names(node)
    local names={}
    M.Walk(node,function(n) if M.Is(n,"name") then names[#names+1]=n end end)
    return names
end
function M.Path(node)
    if M.Is(node,"name") then local name=M.Identifier(node);return name end
    local member=M.Match(node,"member")
    if member then
        local base=M.Path(member.base)
        if base then return base..member.separator..member.name end
    end
end
function M.Root(node)
    if M.Is(node,"name") then local name=M.Identifier(node);return name end
    local index=M.Match(node,"member") or M.Match(node,"index")
    if index then return M.Root(index.base) end
end
function M.SingleAssignment(node)
    local assignment=M.Match(node,"assignment")
    if assignment and #assignment.targets==1 and #assignment.values==1 then
        return assignment.targets[1],assignment.values[1]
    end
end
function M.Text(node) return owner(node).text(node) end
function M.Display(node) return owner(node).display(node) end
function M.Signature(node) return owner(node).signature(node) end
function M.FunctionSignature(node,method) return owner(node).function_text(node,method,true) end
function M.FunctionSource(node,method) return owner(node).function_text(node,method,false) end
return M
