-- Object-specific AST matching. Public Source remains syntax/binding facts only.
local Source=require('SpellHotReload.Source.FileAnalysis')
local M={Callbacks={'init','del','frame','render','colli','kill'}}
local allowed={};for i,name in ipairs(M.Callbacks) do allowed[name]=i end
local bases={_object=true,bullet=true,enemy=true,laser=true,laser_bent=true}
local function plain(v) return type(v)=='table' and getmetatable(v)==nil end
local function shadow(source,index,name)
    return Source.ResolveLocal(source,index,name)~=nil
end
local function class_key(Tree,target)
    local index=Tree.Match(target,'index')
    if index and Tree.IsName(index.base,'_editor_class') then return Tree.String(index.key) end
end
local function class_member(Tree,target)
    local member=Tree.Match(target,'member')
    if member then return class_key(Tree,member.base),member.name end
    local index=Tree.Match(target,'index')
    if index then return class_key(Tree,index.base),Tree.String(index.key) end
end
function M.Read(source)
    local ok,err=Source.Validate(source);if not ok then return nil,err end
    local Tree=source.analysis.syntax
    local p={source=source,order={},by_key={},constructors={},aliases={},unsafe=false}
    local function unit(key)
        local u=p.by_key[key]
        if not u then
            u={key=key,constructors={},methods={},ranges={}}
            p.by_key[key]=u;p.order[#p.order+1]=key
        end
        return u
    end
    for index,statement in ipairs(source.analysis.statements) do
        local ast=statement.syntax
        -- Conservative top-level alias provenance, including containers/calls.
        -- A local retaining a registry-derived value is not reconstructed when
        -- candidate Class wiring remains pending.
        local declaration=Tree.Is(ast,'local') and Tree.Match(ast,'declaration')
        local assignment=declaration or Tree.Match(ast,'assignment')
        if assignment then
            local related=false
            for _,value in ipairs(assignment.values) do
                Tree.Walk(value,function(n)
                    local name=Tree.Is(n,'name') and Tree.Identifier(n)
                    if name and (name=='_editor_class' or p.aliases[name]) then related=true end
                end)
            end
            if related then
                for _,target in ipairs(declaration and declaration.names or assignment.targets) do
                    local name=Tree.Identifier(target)
                    if name then p.aliases[name]=true end
                end
            end
        end
        local target,value=Tree.SingleAssignment(ast)
        local key=class_key(Tree,target)
        if key then
            local u=unit(key)
            local call=Tree.Match(value,'call')
            local base=call and not call.method and Tree.IsName(call.callee,'Class')
                and #call.args==1 and Tree.Is(call.args[1],'name') and Tree.Identifier(call.args[1])
            local constructor={index=index,syntax=ast,base_name=base,
                signature=Tree.Signature(ast),range=statement.source_range,
                value=value}
            constructor.safe=base and not shadow(source,index,'Class')
                and not shadow(source,index,'_editor_class') and not shadow(source,index,base) or false
            u.constructors[#u.constructors+1]=constructor
            p.constructors[#p.constructors+1]=constructor
            u.ranges[#u.ranges+1]=statement.source_range
        end
        local definition=Tree.Match(ast,'definition')
        local class,name=class_member(Tree,definition and definition.target)
        if class and name then
            local fn,method=definition.fn,definition.method
            local u=unit(class)
            u.ranges[#u.ranges+1]=statement.source_range
            local defs=u.methods[name] or {};u.methods[name]=defs
            local visible=Source.Visible(source,fn)
            defs[#defs+1]={index=index,syntax=fn,method=method,visible=visible,
                body=Tree.FunctionSource(fn,method),
                signature=Tree.FunctionSignature(fn,method),range=statement.source_range,
                safe=allowed[name]~=nil and visible~=nil and not shadow(source,index,'_editor_class')}
        elseif class then p.unsafe=true
        end
        -- Direct class writes have a recognized owner. Other top-level mutation,
        -- aliases and calls mentioning the registry are not construction evidence.
        -- Card's own exact wiring grammar remains its responsibility.
        Tree.Walk(ast,function(n)
            if Tree.Is(n,'function') then return false end
            local assigned=Tree.Match(n,'assignment')
            if assigned then
                for _,t in ipairs(assigned.targets) do
                    if Tree.Root(t)=='_editor_class' and not class_key(Tree,t) and not class_member(Tree,t) then p.unsafe=true end
                    if Tree.IsName(t,'_editor_class') or Tree.IsName(t,'Class') then p.unsafe=true end
                end
            end
        end)
    end
    for _,key in ipairs(p.order) do
        local u=p.by_key[key];local c=u.constructors[1]
        u.constructor=c
        u.supported=key~='' and #u.constructors==1 and c.safe and bases[c.base_name]==true and not p.unsafe
        u.reason=not u.supported and 'class needs one unshadowed supported constructor and bounded registry writes' or nil
        for name,defs in next,u.methods do
            if allowed[name] and (#defs~=1 or not defs[1].safe or not c or defs[1].index<c.index) then
                u.reason='duplicate, shadowed, nested or unsupported class method structure'
            end
        end
    end
    return p
end
function M.Pair(initial,candidate,key)
    local a,b=initial.by_key[key],candidate.by_key[key]
    if not a or not b or not a.supported or not b.supported
        or a.constructor.signature~=b.constructor.signature or a.reason or b.reason then
        return nil,'class identity, base or method structure changed'
    end
    return b
end
-- Exact class construction is retained as structure, never acknowledged as code.
-- Explicit method statements are excluded from top-level preflight; unsupported
-- additions/deletions stay pending and cannot silently complete the candidate.
function M.Side(p,owned)
    local out={scan=p.source,claims={},excluded={},structures={},binding_reads={},wiring=''}
    for _,key in ipairs(p.order) do
        local u=p.by_key[key]
        if #u.constructors==1 and u.constructor.safe and bases[u.constructor.base_name] then
            out.excluded[u.constructor.index]=true;out.structures[u.constructor.index]=true
        end
        if owned[key] then
            for name,defs in next,u.methods do
                if allowed[name] and #defs==1 and defs[1].safe then out.excluded[defs[1].index]=true end
            end
        end
    end
    return out
end
M.Allowed=allowed
M.Plain=plain
return M
