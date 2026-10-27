-- Local-owned direct-definition projection and lexical support rules.
-- No versions/live identities, candidate execution, preparation or publication.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Anchor=require("SpellHotReload.Load.Anchor")
local M={Kind="SpellHotReload.LocalDefinitions",Version=1}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function fail(message,name)
    return nil,{phase="inject",code="unsupported",message=message,
        unit_key=name and "local:"..name or nil}
end
local function dense(v)
    if not plain(v) then return false end
    local count,max=0,0
    for k in next,v do
        if type(k)~="number" or k<1 or k>=math.huge or k~=math.floor(k) then return false end
        count=count+1;max=math.max(max,k)
    end
    return count==max
end
local function same(a,b)
    if #a~=#b then return false end
    for i=1,#a do if a[i]~=b[i] then return false end end
    return true
end
local function append(map,name,value)
    local list=map[name] or {};map[name]=list;list[#list+1]=value
end
function M.Match(source)
    local valid,err=Source.Validate(source)
    if not valid then return nil,err end
    local a=source.analysis;local Tree=a.syntax
    local policy,why=Anchor.Policy(source)
    if not policy then return fail(why or "capture policy unavailable") end
    local projection={kind=M.Kind,version=M.Version,source=source,policy=policy,
        definitions={},writes={},blocked={},initializers={}}
    -- Group existing IR nodes ONCE. Selected preparation never rebuilds this.
    local by_statement={}
    for _,node in ipairs(a.nodes) do
        local syntax=node.syntax
        local bucket=by_statement[syntax] or {};by_statement[syntax]=bucket
        bucket[#bucket+1]=node
    end
    for index,statement in ipairs(a.statements) do
        local ast=statement.syntax
        local definition=Tree.Match(ast,"definition")
        local target=definition and definition.target
        local name=Tree.Identifier(target)
        if name and not definition.method
            and (Tree.Match(ast,"declaration") or Source.ResolveLocal(source,index,name)) then
            local fn,self_visible=definition.fn,definition.self_visible
            local names,nerr=Source.Visible(source,fn)
            if not names then return nil,nerr end
            local form=definition.self_visible and "statement" or "expression"
            append(projection.definitions,name,{source=source,name=name,
                statement=index,syntax=fn,visible=names,form=form,self_visible=self_visible,
                signature=form=="statement" and Tree.Signature(ast)
                    or Tree.FunctionSignature(fn),
                source_range=statement.source_range})
        end
        for _,node in ipairs(by_statement[ast] or {}) do
            if node.carrier=="effect" and node.kind=="block" then
                for _,ref in ipairs(Tree.Names(ast)) do
                    local name=Tree.Identifier(ref)
                    if Source.ResolveLocal(source,index,name) then projection.blocked[name]=true end
                end
            end
            local name=(node.carrier=="local" and node.kind~="declare"
                or node.carrier=="global" and Source.ResolveLocal(source,index,node.name)) and node.name
            if name then append(projection.writes,name,index) end
        end
    end
    for _,declaration in ipairs(Source.Declarations(source)) do
        if projection.definitions[declaration.name]==nil then
            projection.initializers[declaration.name]=Tree.Signature(
                a.statements[declaration.statement].syntax)
        end
    end
    return projection
end
local function valid_projection(v)
    return plain(v) and v.kind==M.Kind and v.version==M.Version and Source.Validate(v.source)
        and plain(v.policy) and plain(v.definitions) and plain(v.writes) and plain(v.blocked)
end
-- This compares immutable first-load LEXICAL SUPPORT with candidate syntax.
-- It does NOT compare candidate signatures to actual published source versions.
function M.Pair(loaded,candidate)
    if not valid_projection(loaded) or not valid_projection(candidate) then
        return fail("two Local projections over complete source required")
    end
    if not loaded.policy.reloadable or not candidate.policy.reloadable then
        return fail(loaded.policy.reason or candidate.policy.reason or "capture unsupported")
    end
    local old,new=Source.DeclaredNames(loaded.source),Source.DeclaredNames(candidate.source)
    if not same(old,new) then return fail("top-level declaration order/set changed") end
    for _,name in ipairs(old) do
        local a,b=Source.Declaration(loaded.source,name),Source.Declaration(candidate.source,name)
        if not a or not b or a.kind~=b.kind or a.self_visible~=b.self_visible then
            return fail("declaration kind changed",name)
        end
    end
    local pair={kind=M.Kind..".Pair",version=M.Version,
        loaded=loaded,candidate=candidate,by_name={}}
    for _,name in ipairs(old) do
        local a,b=loaded.definitions[name],candidate.definitions[name]
        local item={name=name,status="preserve-state"}
        pair.by_name[name]=item
        if a or b then
            local reason
            if loaded.blocked[name] or candidate.blocked[name] then
                reason="top-level control block mentions selected local"
            elseif not a or not b or #a~=1 or #b~=1
                or #(loaded.writes[name] or {})~=1 or #(candidate.writes[name] or {})~=1 then
                reason="one direct function definition/write required"
            elseif a[1].form~=b[1].form or a[1].self_visible~=b[1].self_visible
                or not same(a[1].visible,b[1].visible) then
                reason="definition-point binding changed"
            end
            if reason then item.status,item.reason="blocked",reason
            else item.status,item.definition,item.initial="supported",b[1],a[1] end
        end
    end
    return pair
end
-- Explicit owner-selected names only. A version/selection owner must decide
-- which definitions changed or are required; this layer never chooses roots.
function M.Select(pair,names)
    if not plain(pair) or pair.kind~=M.Kind..".Pair" or pair.version~=M.Version
        or not valid_projection(pair.loaded) or not valid_projection(pair.candidate)
        or not plain(pair.by_name) or not dense(names) then
        return fail("Local pair and dense explicit names required")
    end
    local selected,seen={},{}
    for _,name in ipairs(names) do
        if type(name)~="string" or seen[name] then return fail("invalid or duplicate selected name") end
        seen[name]=true
        local item=pair.by_name[name]
        if not item or item.status~="supported" then
            return fail(item and item.reason or "selected binding is not a supported function",name)
        end
        selected[#selected+1]=item.definition
    end
    table.sort(selected,function(a,b) return a.statement<b.statement end)
    return selected
end
return M
