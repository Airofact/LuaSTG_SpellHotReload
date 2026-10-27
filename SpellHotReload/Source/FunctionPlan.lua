-- Selected-function preparation over complete source and owner descriptors.
-- Local owns definition discovery, support, matching, versions and selection.
-- No whole-file compile/parse/index, cache, join, write, receipt or restart here.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Anchor=require("SpellHotReload.Load.Anchor")
local Compose=require("SpellHotReload.Source.Compose")
local M={Kind="SpellHotReload.FunctionPlan",Version=2}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function fail(code,message,file,name)
    return nil,{phase="inject",code=code,message=message,file=file,
        target=name}
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
    if not dense(a) or not dense(b) or #a~=#b then return false end
    for i=1,#a do if a[i]~=b[i] then return false end end
    return true
end
local function descriptor(source,d)
    if not plain(d) or d.source~=source or type(d.name)~="string"
        or not Source.Owns(source,d.syntax) or not source.analysis.syntax.Is(d.syntax,"function") then
        return fail("unsupported","selected source-owned function descriptor required")
    end
    local visible,err=Source.Visible(source,d.syntax)
    if not visible then return nil,err end
    if not same(visible,d.visible) then
        return fail("unsupported","descriptor disagrees with definition-point visibility",nil,d.name)
    end
    local Tree=source.analysis.syntax
    local site=Source.Site(source,d.syntax)
    local definition=Tree.Match(source.analysis.statements[site.statement].syntax,"definition")
    local target=definition and definition.target
    if not target or Tree.Identifier(target)~=d.name then
        return fail("unsupported","descriptor target disagrees with source",nil,d.name)
    end
    if Compose.CompilerIdentity()~=source.syntax_check.compiler then
        return fail("stale","closure compiler differs from complete source syntax check",nil,d.name)
    end
    local declaration=Compose.Declare({d.name})
    if not declaration then return fail("unsupported","valid target name required") end
    return true
end
-- A probe is operation-owned syntax evidence only, never a live permission.
-- Anonymous expression lowering preserves local-function self visibility by
-- using the FULL definition-point prefix supplied by Source, including self.
function M.Probe(source,definition)
    local valid,err=descriptor(source,definition)
    if not valid then return nil,err end
    local created,why=Compose.Create(source.analysis.syntax.FunctionSource(definition.syntax,false),
        nil,definition.visible,{form="expression",tree=source.analysis.syntax,syntax=definition.syntax,name="SelectedFunction:"..definition.name})
    if not created then return fail("compile",why,nil,definition.name) end
    local final,problem=Source.Validate(source)
    if not final then return nil,problem end
    local visible={}
    for i,name in ipairs(definition.visible) do visible[i]=name end
    return {kind=M.Kind..".Probe",version=M.Version,source=source,syntax=definition.syntax,
        visible=visible,created=created,compiler=source.syntax_check.compiler,
        runtime_key=source.syntax_check.runtime_key}
end
local function probe_valid(probe,source,definition)
    return plain(probe) and probe.kind==M.Kind..".Probe" and probe.version==M.Version
        and probe.source==source and probe.syntax==definition.syntax
        and same(probe.visible,definition.visible) and plain(probe.created)
        and type(probe.created.fn)=="function" and probe.compiler==source.syntax_check.compiler
        and probe.runtime_key==source.syntax_check.runtime_key
end
function M.Prepare(source,entry,definitions,published,probes)
    local file=plain(entry) and entry.file or nil
    local valid,err=Source.Validate(source)
    if not valid then return nil,err end
    if not plain(entry) or not Anchor.Live(entry) or type(entry.anchor)~="function"
        or not plain(entry.slots) or type(entry.loaded_source)~="string" then
        return fail("unsupported","live loaded Anchor entry required",file)
    end
    local capable,why=Anchor.Supported(Compose.Capability(debug))
    if not capable then return fail("capability",why,file) end
    if not dense(definitions) or not plain(published) or (probes~=nil and not plain(probes)) then
        return fail("unsupported","dense selected descriptors and published identities required",file)
    end
    local anchor,loaded_source=entry.anchor,entry.loaded_source
    local plan={kind=M.Kind,version=M.Version,source=source,content=source.content,
        entry=entry,anchor=anchor,loaded_source=loaded_source,
        functions={},joins={},writes={},read_set={}}
    local selected={}
    -- Validate the entire request before constructing ANY selected closure.
    for _,d in ipairs(definitions) do
        local ok,problem=descriptor(source,d)
        if not ok then return nil,problem end
        if selected[d.name] then return fail("unsupported","duplicate target",file,d.name) end
        selected[d.name]=true
        if type(rawget(published,d.name))~="function" then
            return fail("stale","published function identity required",file,d.name)
        end
        local current,read_error=Anchor.Get(entry,d.name)
        if read_error or current~=rawget(published,d.name) then
            return fail("stale",read_error or "published function was externally replaced",file,d.name)
        end
        if probes and rawget(probes,d)~=nil and not probe_valid(rawget(probes,d),source,d) then
            return fail("stale","foreign or stale candidate probe",file,d.name)
        end
    end
    for _,d in ipairs(definitions) do
        local probe=probes and rawget(probes,d)
        if not probe then
            local problem;probe,problem=M.Probe(source,d)
            if not probe then return nil,problem end
        end
        -- Re-enumerate physical captures on EVERY prepare, including probe hits.
        local join_plan,problem=Compose.Plan(probe.created,entry)
        if not join_plan then return fail("unsupported",problem,file,d.name) end
        local slot,slot_error=Anchor.Slot(entry,d.name)
        if not slot then return fail("stale",slot_error,file,d.name) end
        local before=rawget(published,d.name)
        plan.functions[#plan.functions+1]={name=d.name,definition=d,
            created=probe.created,join_plan=join_plan}
        plan.writes[#plan.writes+1]={name=d.name,anchor=anchor,index=slot,
            before=before,value=probe.created.fn}
        plan.read_set[#plan.read_set+1]={name=d.name,anchor=anchor,index=slot,value=before}
        for _,join in ipairs(join_plan.joins) do plan.joins[#plan.joins+1]=join end
    end
    local final,problem=Source.Validate(source)
    if not final then return nil,problem end
    if not Anchor.Live(entry) or entry.anchor~=anchor or entry.loaded_source~=loaded_source then
        return fail("stale","loaded Anchor scope changed during preparation",file)
    end
    for _,read in ipairs(plan.read_set) do
        local name,value=debug.getupvalue(read.anchor,read.index)
        if name~=read.name or value~=read.value then
            return fail("stale","published function changed during preparation",file,read.name)
        end
    end
    return plan
end
return M
