-- Shared syntax-tree queries. They inspect node kinds, never reparse token shapes.
local M={}
function M.Walk(n,visit)
    if not n then return end
    if visit(n)==false then return end
    for _,child in ipairs(n.children) do M.Walk(child,visit) end
end
function M.IsName(n,name) return n and n.kind=="name" and n.name==name end
function M.String(n)
    if n and n.kind=="literal" and n.literal_kind=="string" then return n.value end
end
function M.Path(n)
    if not n then return nil end
    if n.kind=="name" then return n.name end
    if n.kind=="member" then
        local base=M.Path(n.base)
        if base then return base..n.separator..n.name end
    end
end
function M.Root(n)
    if not n then return nil end
    if n.kind=="name" then return n.name end
    if n.kind=="member" or n.kind=="index" then return M.Root(n.base) end
end
function M.Text(n,analysis)
    local t=analysis.tokens
    return analysis.source:sub(t[n.first].pos,t[n.last].pos+#t[n.last].value-1)
end
function M.Display(n,tokens)
    local parts={}
    for i=n.first,n.last do parts[#parts+1]=tokens[i].value end
    return table.concat(parts)
end
function M.Signature(n,tokens)
    local parts={}
    for i=n.first,n.content_last or n.last do
        local t=tokens[i];parts[#parts+1]=t.kind..":"..#t.value..":"..t.value
    end
    return table.concat(parts,"|")
end
function M.FunctionSignature(fn,tokens,method)
    local parts={}
    local function add(kind,value) parts[#parts+1]=kind..":"..#value..":"..value end
    add("word","function");add("symbol","(")
    if method then
        add("word","self")
        if #fn.params>0 or fn.vararg then add("symbol",",") end
    end
    for i=fn.open+1,fn.last do add(tokens[i].kind,tokens[i].value) end
    return table.concat(parts,"|")
end
function M.Names(n)
    local names={}
    M.Walk(n,function(x) if x.kind=="name" then names[#names+1]=x end end)
    return names
end
function M.ClassKey(n)
    if n and n.kind=="index" and M.IsName(n.base,"_editor_class") then return M.String(n.key) end
end
function M.CardList(n)
    if n and n.kind=="member" and n.separator=="." and n.name=="cards" then return M.ClassKey(n.base) end
end
function M.SingleAssignment(n)
    if n and n.kind=="assign" and #n.targets==1 and #n.values==1 then return n.targets[1],n.values[1] end
end
function M.Constructor(n)
    if not n or n.kind~="call" or n.method then return nil end
    local target=n.callee
    if target.kind~="member" or target.name~="New" or target.separator~="." then return nil end
    local owner=target.base
    if owner.kind=="member" and owner.separator=="." and M.IsName(owner.base,"boss") then return owner.name end
end
function M.Function(n)
    if n.kind=="local_function" then return n.names[1],n.fn,false,true end
    if n.kind=="function_statement" then return n.target,n.fn,n.method,false end
    if n.kind=="local" and #n.names==1 and #n.values==1 and n.values[1].kind=="function" then
        return n.names[1],n.values[1],false,false
    end
    local target,val=M.SingleAssignment(n)
    if target and val.kind=="function" then return target,val,false,false end
end
function M.Callback(n)
    local target,fn,method=M.Function(n)
    if target and target.kind=="member" and M.IsName(target.base,"_tmp_sc") then
        return target.name,fn,method
    end
end
function M.FunctionSource(fn,analysis,method)
    local t=analysis.tokens
    local tail=analysis.source:sub(t[fn.open].pos+1,t[fn.last].pos+#t[fn.last].value-1)
    if method then tail="self"..((#fn.params>0 or fn.vararg) and "," or "")..tail end
    return "function("..tail
end
return M
