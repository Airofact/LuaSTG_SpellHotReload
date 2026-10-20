-- Full-file syntax facts. No Local policy, live state, cache or publication.
local IR = require("SpellHotReload.Source.TopLevelIR")
local Binding = require("SpellHotReload.Source.Binding")
local Tree = require("SpellHotReload.Source.SyntaxTree")
local M = {Kind="SpellHotReload.FileAnalysis", Version=1}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function compiler() return rawget(_G,"loadstring") or rawget(_G,"load") end
local function environment()
    local get = rawget(_G,"getfenv")
    return type(get)=="function" and get(0) or _G
end
local function fail(code, message)
    return nil,{phase="analyze",code=code,message=message}
end
-- Trusted read-only objects, not a hostile-table sandbox. Check provenance of
-- the public components and the current compiler environment without rescanning.
function M.Validate(source)
    if not plain(source) or source.kind~=M.Kind or source.version~=M.Version
        or type(source.content)~="string" or not plain(source.analysis)
        or not plain(source.bindings) or not plain(source.sites)
        or not plain(source.syntax_check) then
        return fail("unsupported","complete FileAnalysis required")
    end
    local a,b,stamp=source.analysis,source.bindings,source.syntax_check
    local offset=source.content:sub(1,3)=="\239\187\191" and 3 or 0
    if a.source~=source.content:sub(offset+1) or a.source_offset~=offset
        or not plain(a.syntax) or not plain(a.tokens) or not plain(a.nodes)
        or not plain(a.statements) or b.analysis~=a or source.sites.analysis~=a
        or not plain(b.statements) or #b.statements~=#a.statements
        or not plain(b.by_name) or not plain(b.names) or not plain(b.declarations)
        or source.sites[a.syntax]==nil then
        return fail("stale","source syntax/binding components disagree")
    end
    if stamp.compiler~=compiler() or stamp.runtime_key~=environment()
        or stamp.environment_api~=rawget(_G,"getfenv") then
        return fail("stale","syntax compiler or runtime environment changed")
    end
    return true
end
function M.Build(content, options)
    if type(content)~="string" then return fail("unsupported","source must be a string") end
    if content:find("\0",1,true) or content:sub(1,1)=="\27" then
        return fail("unsupported","text Lua source required")
    end
    local compile,env,get=compiler(),environment(),rawget(_G,"getfenv")
    if type(compile)~="function" then return fail("capability","Lua compiler unavailable") end
    local offset=content:sub(1,3)=="\239\187\191" and 3 or 0
    local called,chunk,reason=pcall(compile,content:sub(offset+1),"@FileAnalysis:syntax")
    if not called or type(chunk)~="function" then
        return fail("compile",type(reason)=="string" and reason
            or (not called and type(chunk)=="string" and chunk) or "source compilation failed")
    end
    chunk=nil -- Never execute the candidate chunk.
    local nodes,err,analysis=IR.Analyze(content,options)
    if not nodes then return fail("unsupported",err or "source analysis failed") end
    local bindings,berr=Binding.Analyze(analysis)
    if not bindings then return fail("unsupported",berr or "binding analysis failed") end
    bindings.analysis=analysis -- Explicit AST provenance, not an input alias.
    local sites={analysis=analysis}
    sites[analysis.syntax]={statement=false}
    for index,statement in ipairs(analysis.statements) do
        local site={statement=index}
        Tree.Walk(statement.syntax,function(node) sites[node]=site end)
    end
    local source={kind=M.Kind,version=M.Version,content=content,
        analysis=analysis,bindings=bindings,sites=sites,
        syntax_check={compiler=compile,runtime_key=env,environment_api=get}}
    local valid,problem=M.Validate(source)
    if not valid then return nil,problem end
    return source
end
-- Definition-point TOP-LEVEL visibility, not a complete binding proof. The
-- original function AST lets Compose keep parameter/local/nested-scope semantics.
function M.Visible(source, node)
    local ok,err=M.Validate(source)
    if not ok then return nil,err end
    local site=plain(node) and source.sites[node]
    local statement=site and site.statement and source.analysis.statements[site.statement]
    local direct
    if statement then local target;target,direct=Tree.Function(statement.syntax) end
    -- Parent functions/blocks introduce lexical bindings not proved by the
    -- top-level model. Owners must not prepare those via this API.
    if not statement or node.kind~="function" or direct~=node then
        return fail("unsupported","direct top-level function with complete source context required")
    end
    local record=source.bindings.statements[site.statement]
    local names,set={},{}
    for name in next,record.visible do set[name]=true end
    if record.self_visible then
        for name in next,record.declares do set[name]=true end
    end
    for name in next,set do names[#names+1]=name end
    table.sort(names)
    return names
end
return M
