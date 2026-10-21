-- Object-specific AST matching. Public Source remains syntax/binding facts only.
local Source=require('SpellHotReload.Source.FileAnalysis')
local Tree=require('SpellHotReload.Source.SyntaxTree')
local M={Callbacks={'init','del','frame','render','colli','kill'}}
local allowed={};for i,name in ipairs(M.Callbacks) do allowed[name]=i end
local bases={_object=true,bullet=true,enemy=true,laser=true,laser_bent=true}
local function plain(v) return type(v)=='table' and getmetatable(v)==nil end
local function shadow(source,index,name)
    return source.bindings.statements[index].visible[name]~=nil
end
local function class_member(target)
    if target and target.kind=='member' then return Tree.ClassKey(target.base),target.name end
    if target and target.kind=='index' then return Tree.ClassKey(target.base),Tree.String(target.key) end
end
function M.Read(source)
    local ok,err=Source.Validate(source);if not ok then return nil,err end
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
        if ast.kind=='local' or ast.kind=='assign' then
            local related=false
            for _,value in ipairs(ast.values) do
                Tree.Walk(value,function(n)
                    if n.kind=='name' and (n.name=='_editor_class' or p.aliases[n.name]) then related=true end
                end)
            end
            if related then
                for _,name in ipairs(ast.kind=='local' and ast.names or ast.targets) do
                    if name.kind=='name' or name.kind=='binding' then p.aliases[name.name]=true end
                end
            end
        end
        local target,value=Tree.SingleAssignment(ast)
        local key=Tree.ClassKey(target)
        if key then
            local u=unit(key)
            local base=value and value.kind=='call' and not value.method
                and Tree.IsName(value.callee,'Class') and #value.args==1
                and value.args[1].kind=='name' and value.args[1].name
            local constructor={index=index,syntax=ast,base_name=base,
                signature=Tree.Signature(ast,source.analysis.tokens),range=statement.source_range,
                value=value}
            constructor.safe=base and not shadow(source,index,'Class')
                and not shadow(source,index,'_editor_class') and not shadow(source,index,base) or false
            u.constructors[#u.constructors+1]=constructor
            p.constructors[#p.constructors+1]=constructor
            u.ranges[#u.ranges+1]=statement.source_range
        end
        local ft,fn,method=Tree.Function(ast)
        local class,name=class_member(ft)
        if class and name then
            local u=unit(class)
            u.ranges[#u.ranges+1]=statement.source_range
            local defs=u.methods[name] or {};u.methods[name]=defs
            local visible=Source.Visible(source,fn)
            defs[#defs+1]={index=index,syntax=fn,method=method,visible=visible,
                body=Tree.FunctionSource(fn,source.analysis,method),
                signature=Tree.FunctionSignature(fn,source.analysis.tokens,method),range=statement.source_range,
                safe=allowed[name]~=nil and visible~=nil and not shadow(source,index,'_editor_class')}
        elseif class then p.unsafe=true
        end
        -- Direct class writes have a recognized owner. Other top-level mutation,
        -- aliases and calls mentioning the registry are not construction evidence.
        -- Card's own exact wiring grammar remains its responsibility.
        Tree.Walk(ast,function(n)
            if n.kind=='function' then return false end
            if n.kind=='assign' then
                for _,t in ipairs(n.targets) do
                    if Tree.Root(t)=='_editor_class' and not Tree.ClassKey(t) and not class_member(t) then p.unsafe=true end
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
