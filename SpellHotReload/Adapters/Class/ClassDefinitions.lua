-- Class-owned definition syntax and support facts. No live state or publishing.
local Source=require("SpellHotReload.Source.FileAnalysis")
local M={Callbacks={"init","del","frame","render","colli","kill"}}
local allowed={};for i,name in ipairs(M.Callbacks) do allowed[name]=i end
local writable_bases={_object=true,bullet=true,enemy=true,laser=true,laser_bent=true}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function shadow(source,index,name) return Source.ResolveLocal(source,index,name)~=nil end
function M.Key(Tree,target)
    local index=Tree.Match(target,"index")
    if index and Tree.IsName(index.base,"_editor_class") then return Tree.String(index.key) end
end
function M.Member(Tree,target)
    local member=Tree.Match(target,"member")
    if member then return M.Key(Tree,member.base),member.name end
    local index=Tree.Match(target,"index")
    if index then return M.Key(Tree,index.base),Tree.String(index.key) end
end
function M.StatementKey(Tree,ast)
    local target=Tree.SingleAssignment(ast)
    local definition=Tree.Match(ast,"definition")
    if definition then target=definition.target end
    local key=M.Key(Tree,target)
    if key~=nil then return key end
    return (M.Member(Tree,target))
end
local function append(map,key,value)
    local list=map[key] or {};map[key]=list;list[#list+1]=value
end
local function signature(parts)
    local out={};for _,value in ipairs(parts) do out[#out+1]=#value..":"..value end
    return table.concat(out)
end
function M.Build(source,units,mappings)
    local ok,err=Source.Validate(source);if not ok then return nil,err end
    local Tree=source.analysis.syntax
    local p={source=source,order={},by_key={},constructors={},aliases={},unsafe=false}
    for _,unit in ipairs(units) do
        local key=unit.context.key
        p.order[#p.order+1]=key;p.by_key[key]={key=key,constructors={},methods={},members={},ranges=unit.source_ranges}
    end
    local visited={}
    for _,mapping in ipairs(mappings) do
        local u=p.by_key[mapping.unit.context.key]
        for index=mapping.first,mapping.last do
            if not visited[index] then
                visited[index]=true
                local statement=source.analysis.statements[index];local ast=statement.syntax
                local target,value=Tree.SingleAssignment(ast)
                local definition=Tree.Match(ast,"definition")
                if M.Key(Tree,target)~=nil then
                    local call=Tree.Match(value,"call")
                    local base=call and not call.method and Tree.IsName(call.callee,"Class") and #call.args==1
                        and Tree.Is(call.args[1],"name") and Tree.Identifier(call.args[1])
                    local c={index=index,syntax=ast,base_name=base,signature=Tree.Signature(ast),
                        range=statement.source_range,value=value}
                    c.safe=base and not shadow(source,index,"Class") and not shadow(source,index,"_editor_class")
                        and not shadow(source,index,base) or false
                    u.constructors[#u.constructors+1]=c;p.constructors[#p.constructors+1]=c
                else
                    if definition then target,value=definition.target,definition.fn end
                    local key,name=M.Member(Tree,target)
                    if key~=u.key or not name then return nil,"class mapping contains a foreign member" end
                    local member={index=index,name=name,syntax=ast,value=value,signature=Tree.Signature(ast),range=statement.source_range}
                    if definition then
                        local fn,method=definition.fn,definition.method
                        local visible=Source.Visible(source,fn)
                        member.definition={index=index,syntax=fn,method=method,visible=visible,
                            body=Tree.FunctionSource(fn,method),signature=Tree.FunctionSignature(fn,method),
                            range=statement.source_range,safe=visible~=nil and not shadow(source,index,"_editor_class")}
                        append(u.methods,name,member.definition)
                    end
                    u.members[#u.members+1]=member
                end
            end
        end
    end
    -- Safety depends on the full file, including syntax consumed by other owners.
    for index,statement in ipairs(source.analysis.statements) do
        local ast=statement.syntax
        local declaration=Tree.Is(ast,"local") and Tree.Match(ast,"declaration")
        local assignment=declaration or Tree.Match(ast,"assignment")
        if assignment then
            local related=false
            for _,value in ipairs(assignment.values) do
                for _,reference in ipairs(Tree.Names(value)) do
                    local name=Tree.Identifier(reference)
                    if name=="_editor_class" or p.aliases[name] then related=true end
                end
            end
            if related then
                for _,target in ipairs(declaration and declaration.names or assignment.targets) do
                    local name=Tree.Identifier(target);if name then p.aliases[name]=true end
                end
            end
        end
        Tree.Walk(ast,function(n)
            if Tree.Is(n,"function") then return false end
            local assigned=Tree.Match(n,"assignment")
            if assigned then for _,target in ipairs(assigned.targets) do
                if Tree.Root(target)=="_editor_class" and not M.Key(Tree,target) and not M.Member(Tree,target) then p.unsafe=true end
                if Tree.IsName(target,"_editor_class") or Tree.IsName(target,"Class") then p.unsafe=true end
            end end
        end)
    end
    for _,key in ipairs(p.order) do
        local u=p.by_key[key];local c=u.constructors[1];u.constructor=c
        u.supported=key~="" and #u.constructors==1 and c.safe and not p.unsafe or false
        u.writable=u.supported and writable_bases[c.base_name]==true or false
        u.reason=not u.supported and "one unshadowed named-base Class constructor and bounded registry writes required" or nil
        local all,fixed={},{}
        if c then all[1]=c.signature;fixed[1]=c.signature end
        for _,member in ipairs(u.members) do
            local definition=member.definition
            local sig=member.signature
            if definition then
                if not definition.safe or not c or definition.index<c.index or #u.methods[member.name]~=1 then
                    u.reason="duplicate, shadowed or unordered class method definition"
                end
                sig=sig.."@"..table.concat(definition.visible or {},",")
            end
            all[#all+1]=sig
            if not (u.writable and definition and allowed[member.name]) then fixed[#fixed+1]=sig end
        end
        u.definition_signature=signature(all);u.structure_signature=signature(fixed)
    end
    return p
end
function M.Pair(initial,candidate,key)
    local a,b=initial.by_key[key],candidate.by_key[key]
    if not a or not b or not a.supported or not b.supported or a.writable~=b.writable
        or a.constructor.signature~=b.constructor.signature or a.structure_signature~=b.structure_signature
        or a.reason or b.reason then return nil,"class identity, structure or support changed" end
    return b
end
function M.Side(p,owned)
    local out={scan=p.source,claims={},excluded={},structures={},binding_reads={},wiring=""}
    for _,key in ipairs(p.order) do
        local u=p.by_key[key]
        if #u.constructors==1 and u.constructor.safe then
            out.excluded[u.constructor.index]=true;out.structures[u.constructor.index]=true
        end
        if owned[key] and u.writable then for name,defs in next,u.methods do
            if allowed[name] and #defs==1 and defs[1].safe then out.excluded[defs[1].index]=true end
        end end
    end
    return out
end
function M.StructureWriteKey(Tree,ast)
    local target,value=Tree.SingleAssignment(ast)
    local member=Tree.Match(target,"member")
    if not member or member.separator~="." then return nil end
    local key=M.Key(Tree,member.base)
    if not key or key=="" then return nil end
    local name=member.name
    if (name=="init" or name=="frame" or name=="render" or name=="kill") and Tree.Is(value,"function") then return key end
    local literal=Tree.Match(value,"literal")
    if (name=="name" or name=="bgm" or name=="difficulty")
        and literal and literal.category=="string" then return key end
    local referenced=Tree.Is(value,"name") and Tree.Identifier(value)
    if name=="_bg" and (referenced and referenced~="_tmp_sc"
        and referenced~="_editor_class" and referenced~="_sc_table"
        or literal and literal.category=="nil") then return key end
end
M.Allowed=allowed
M.Plain=plain
return M
