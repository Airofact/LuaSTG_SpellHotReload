-- Full-file syntax facts. No Local policy, live state or publication.
local IR = require("SpellHotReload.Source.TopLevelIR")
local Tree = require("SpellHotReload.Source.SyntaxTree")
local M = {Kind="SpellHotReload.FileAnalysis", Version=4}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function compiler() return rawget(_G,"loadstring") or rawget(_G,"load") end
local function environment()
    local get = rawget(_G,"getfenv")
    return type(get)=="function" and get(0) or _G
end
local function fail(code, message)
    return nil,{phase="analyze",code=code,message=message}
end
-- Provenance only, never cached validation or publication permission. Values
-- contain no reference to their weak source key, so old snapshots can be freed.
local origins=setmetatable({}, {__mode="k"})
-- Trusted read-only objects, not a hostile-table sandbox. Check provenance of
-- the public components and the current compiler environment without rescanning.
function M.Validate(source)
    if not plain(source) or source.kind~=M.Kind or source.version~=M.Version
        or type(source.content)~="string" or not plain(source.analysis)
        or not plain(source.sites)
        or not plain(source.syntax_check) then
        return fail("unsupported","complete FileAnalysis required")
    end
    local a,stamp,origin=source.analysis,source.syntax_check,origins[source]
    if not origin or source.content~=origin.content or a~=origin.analysis
        or a.source~=origin.text or a.source_offset~=origin.offset
        or (not Tree.IsSnapshot(a.syntax) or a.syntax~=origin.syntax or not a.syntax.MatchesInput(a.source))
        or not plain(a.nodes) or not plain(a.statements)
        or not plain(a.declarations) or not plain(a.declaration_names) or not plain(a.declarations_by_name)
        or a.nodes~=origin.nodes or a.statements~=origin.statements
        or #a.statements~=origin.statement_count or #a.declarations~=origin.declaration_count
        or a.declarations~=origin.declarations or a.declaration_names~=origin.names
        or a.declarations_by_name~=origin.by_name or type(a.scope_complete)~="boolean"
        or source.sites~=origin.sites or source.sites.analysis~=a
        or source.sites[a.syntax]==nil then
        return fail("stale","source syntax/scope components disagree")
    end
    if stamp.compiler~=compiler() or stamp.runtime_key~=environment()
        or stamp.environment_api~=rawget(_G,"getfenv") then
        return fail("stale","syntax compiler or runtime environment changed")
    end
    return true
end
function M.Build(content, options, previous_source)
    if type(content)~="string" then return fail("unsupported","source must be a string") end
    if content:find("\0",1,true) or content:sub(1,1)=="\27" then
        return fail("unsupported","text Lua source required")
    end
    local offset=content:sub(1,3)=="\239\187\191" and 3 or 0
    local previous_syntax
    if previous_source~=nil then
        local valid,problem=M.Validate(previous_source)
        if not valid then return nil,problem end
        previous_syntax=previous_source.analysis.syntax
    end
    local nodes,err,analysis,code=IR.Analyze(content,options,previous_syntax)
    if not nodes then return fail(code or "unsupported",err or "source analysis failed") end
    local sites={analysis=analysis}
    local root={statement=false}
    sites[analysis.syntax]=root
    sites[analysis.syntax.root]=root
    sites[analysis.syntax.syntax_check]=root
    for index,statement in ipairs(analysis.statements) do
        local site={statement=index}
        sites[statement]=site
        sites[site]=root
        sites[statement.syntax]=site
    end
    for _,node in ipairs(analysis.nodes) do
        sites[node]=sites[node.syntax]
    end
    -- These are indexes of the same facts, not independently owned declarations.
    for _,value in ipairs({analysis,analysis.nodes,analysis.statements,
        analysis.declarations,analysis.declaration_names,analysis.declarations_by_name}) do
        sites[value]=root
    end
    for _,named in next,analysis.declarations_by_name do sites[named]=root end
    local source={kind=M.Kind,version=M.Version,content=content,
        analysis=analysis,sites=sites,
        syntax_check=analysis.syntax.syntax_check}
    origins[source]={content=content,text=analysis.source,offset=offset,analysis=analysis,syntax=analysis.syntax,
        nodes=analysis.nodes,statements=analysis.statements,declarations=analysis.declarations,
        statement_count=#analysis.statements,declaration_count=#analysis.declarations,
        names=analysis.declaration_names,by_name=analysis.declarations_by_name,sites=sites}
    local valid,problem=M.Validate(source)
    if not valid then analysis.syntax.Discard();return nil,problem end
    return source
end
-- Retain only mutable parser ownership. Old syntax remains readable after release.
function M.Retain(source)
    local valid,err=M.Validate(source)
    if not valid then return nil,err end
    local called,release,reason=pcall(source.analysis.syntax.RetainParser)
    if not called or type(release)~="function" then
        return fail("stale",called and tostring(reason) or tostring(release))
    end
    return release
end
-- Source membership is a snapshot-owned handle plus the original whole-file site.
function M.Owns(source,node)
    local valid=M.Validate(source)
    return valid and source.analysis.syntax.IsNode(node) or false
end
-- Resolve nested nodes against existing top-level statement spans. No whole-tree sites walk.
function M.Site(source,node)
    if not M.Owns(source,node) then return nil end
    if source.sites[node] then return source.sites[node] end
    local first,last=source.analysis.syntax.Range(node)
    local offset=source.analysis.source_offset;first,last=first+offset,last+offset
    local rows=source.analysis.statements;local low,high=1,#rows
    while low<=high do
        local mid=math.floor((low+high)/2);local row=rows[mid];local range=row.source_range
        if first<range.first then high=mid-1
        elseif first>range.last then low=mid+1
        else return last<=range.last and source.sites[row] or nil end
    end
end
-- Inclusive original-file byte range; the native snapshot already supplies bytes.
function M.ByteRange(source,node,view)
    local valid,err=M.Validate(source);if not valid then return nil,err end
    if not source.analysis.syntax.IsNode(node) then return fail("stale","source-owned node required") end
    local first,last
    if view==nil then first,last=source.analysis.syntax.Range(node)
    elseif view=="function" and source.analysis.syntax.Is(node,"function") then first,last=source.analysis.syntax.FunctionRange(node)
    else return fail("unsupported","unknown range view") end
    if first>last then return fail("unsupported","nonempty syntax range required") end
    return {first=first+source.analysis.source_offset,last=last+source.analysis.source_offset}
end
-- Borrowed read-only indexes. Every declaration is the original local IR node.
function M.Declarations(source)
    local ok,err=M.Validate(source);if not ok then return nil,err end
    return source.analysis.declarations
end
function M.DeclaredNames(source)
    local ok,err=M.Validate(source);if not ok then return nil,err end
    return source.analysis.declaration_names
end
function M.Declaration(source,name)
    local ok,err=M.Validate(source);if not ok then return nil,err end
    local named=source.analysis.declarations_by_name[name]
    return named and #named==1 and named[1] or nil
end
function M.Duplicates(source)
    local ok,err=M.Validate(source);if not ok then return nil,err end
    local a,result=source.analysis,{}
    for _,name in ipairs(a.declaration_names) do
        local named=a.declarations_by_name[name]
        if #named>1 then result[#result+1]={name=name,count=#named,declarations=named} end
    end
    return result
end
-- A statement's integer frontier excludes all its own declarations. It is
-- checked against the canonical sequence, including multi-name declarations.
function M.Statement(source,index)
    local ok,err=M.Validate(source);if not ok then return nil,err end
    if type(index)~="number" or index<1 or index>=math.huge or index~=math.floor(index) then
        return fail("stale","canonical statement index required")
    end
    local a=source.analysis
    local statement=a.statements[index]
    local site=statement and source.sites[statement]
    local frontier=statement and statement.scope_before
    if not plain(statement) or not site or site.statement~=index
        or not a.syntax.IsNode(statement.syntax)
        or type(frontier)~="number" or frontier~=math.floor(frontier)
        or frontier<0 or frontier>#a.declarations
        or frontier>0 and a.declarations[frontier].statement>=index
        or a.declarations[frontier+1] and a.declarations[frontier+1].statement<index then
        return fail("stale","canonical statement scope required")
    end
    return statement
end
function M.ResolveLocal(source,index,name)
    local statement,err=M.Statement(source,index);if not statement then return nil,err end
    local named=source.analysis.declarations_by_name[name]
    if not named then return nil end
    local low,high,found=1,#named,nil
    while low<=high do
        local mid=math.floor((low+high)/2)
        if named[mid].ordinal<=statement.scope_before then found=named[mid];low=mid+1
        else high=mid-1 end
    end
    return found
end
local function visible(source,statement,self_declaration)
    local a,names=source.analysis,{}
    for _,name in ipairs(a.declaration_names) do
        if a.declarations_by_name[name][1].ordinal<=statement.scope_before
            or self_declaration and self_declaration.name==name then names[#names+1]=name end
    end
    table.sort(names)
    return names
end
function M.VisibleBefore(source,index)
    local statement,err=M.Statement(source,index);if not statement then return nil,err end
    return visible(source,statement)
end
-- Definition-point TOP-LEVEL visibility, not a complete binding proof. The
-- original function AST lets Compose keep parameter/local/nested-scope semantics.
function M.Visible(source,node)
    local ok,err=M.Validate(source);if not ok then return nil,err end
    local site=M.Site(source,node)
    local statement=site and site.statement and M.Statement(source,site.statement)
    local direct
    if statement then local definition=source.analysis.syntax.Match(statement.syntax,"definition");direct=definition and definition.fn end
    if not statement or not source.analysis.syntax.Is(node,"function") or not source.analysis.syntax.SameNode(direct,node) then
        return fail("unsupported","direct top-level function with complete source context required")
    end
    return visible(source,statement,statement.self_declaration)
end
-- Used by the publication graph copier after validating the operation. A fact
-- is snapshot-owned even when it is an ordinary table rather than a syntax handle.
function M.ContainsFact(source,value)
    local origin=origins[source]
    return origin~=nil and (value==source or value==source.syntax_check or value==origin.sites
        or origin.sites[value]~=nil or origin.syntax.ContainsFact(value)) or false
end
return M
