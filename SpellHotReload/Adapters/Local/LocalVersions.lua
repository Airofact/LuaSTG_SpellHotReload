-- Local's actual definitions and lazy, selected-only dependency evidence.
-- Full source discovery/support belongs to LocalDefinitions; construction and
-- physical connection plans belong to FunctionPlan/Compose. No publication here.
local Definitions=require("SpellHotReload.Adapters.Local.LocalDefinitions")
local Plan=require("SpellHotReload.Source.FunctionPlan")
local Compose=require("SpellHotReload.Source.Compose")
local Anchor=require("SpellHotReload.Load.Anchor")
local Source=require("SpellHotReload.Source.FileAnalysis")
local M={Kind="SpellHotReload.LocalVersions",Version=2}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
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
    for i,v in ipairs(a) do if v~=b[i] then return false end end
    return true
end
local function fail(code,message,state,name)
    return nil,{phase="inject",code=code,message=message,file=plain(state) and state.file,
        unit_key=name and "local:"..name}
end
local function stored(definition,source)
    return {signature=definition.signature,visible=copy(definition.visible),form=definition.form,
        self_visible=definition.self_visible,source_range=copy(definition.source_range),
        body=source.analysis.syntax.FunctionSource(definition.syntax,false)}
end
local function names(fn)
    local result,err=Compose.Names(fn)
    if not result then return nil,err end
    table.sort(result);return result
end
local function sharing(fn,entry,dependencies,state,name)
    local plan,err=Compose.Plan(fn,entry)
    if not plan then return fail("stale",err,state,name) end
    local layout,why=Compose.CaptureLayout(plan,dependencies)
    if not layout then return fail("stale",why,state,name) end
    local ok,cerr=Compose.CheckShared(fn,entry,dependencies,layout)
    if not ok then return fail("stale",cerr,state,name) end
    return layout
end
local function observation(records,name)
    local seen,out={},{}
    local function visit(n)
        if seen[n] then return end;seen[n]=true
        local unit=records[n]
        if not unit or unit.binding_kind~="function" then return end
        for _,dep in ipairs(unit.dependencies) do
            local target=records[dep]
            if target and target.binding_kind=="function" then
                out[dep]=target.definition_version;visit(dep)
            end
        end
    end
    visit(name);return out
end
local function project(state)
    local units,records,functions,edges={},{},{},{}
    for _,name in ipairs(state.names) do
        local unit=state.by_name[name]
        units[#units+1]={unit_ref=unit.unit_ref,private_ref=unit}
        records[#records+1]={key="local:"..name,kind=unit.binding_kind,definition=unit,
            definition_version=unit.definition_version,name=name}
        if unit.binding_kind=="function" then
            functions[#functions+1]=unit.fn
            for _,dep in ipairs(unit.dependencies) do
                local provider=state.by_name[dep]
                if not provider then return fail("ownership","capture has no original binding provider",state,name) end
                edges[#edges+1]={consumer=unit.unit_ref,provider=provider.unit_ref}
            end
        end
    end
    return {owner=state.owner,owner_id=state.owner_id,state=state,units=units,
        records=records,functions=functions,edges=edges}
end
function M.Seed(owner,entry,session_id,loaded)
    if not plain(owner) or type(owner.Id)~="string" or not plain(entry)
        or entry.source~=loaded.source or not Anchor.Live(entry) or not plain(entry.map)
        or type(session_id)~="string" then
        return fail("ownership","genuine first-load source and owner required",entry)
    end
    local pair,err=Definitions.Pair(loaded,loaded)
    if not pair then return nil,err end
    local state={kind=M.Kind,version=M.Version,owner=owner,owner_id=owner.Id,file=entry.file,
        entry=entry,anchor=entry.anchor,loaded_source=entry.loaded_source,
        session_id=session_id,names=copy(Source.DeclaredNames(loaded.source)),by_name={}}
    local initial={projection=loaded}
    local authority={cells={},raws={},forbidden={}}
    for index,name in ipairs(state.names) do
        local definition=pair.by_name[name]
        local ref={owner=owner,id=index}
        local unit={name=name,unit_ref=ref,definition_version=1,dependencies={},observed={}}
        state.by_name[name]=unit
        if definition.status=="preserve-state" then
            unit.binding_kind="state"
            unit.signature=loaded.initializers[name]
            -- Alias/state values stay in their real cells; no setter authority.
            local value=entry.map[name]
            if type(value)=="function" then authority.forbidden[#authority.forbidden+1]=value end
        else
            if definition.status~="supported" then return fail("unsupported",definition.reason,state,name) end
            local actual=entry.map[name]
            if type(actual)~="function" or Anchor.Get(entry,name)~=actual then
                return fail("stale","first-published function identity unavailable",state,name)
            end
            local probe,why=Plan.Probe(loaded.source,definition.definition)
            if not probe then return nil,why end
            local dependencies,nerr=names(actual)
            if not dependencies then return fail("unsupported",nerr,state,name) end
            local expected=copy(probe.created.used);table.sort(expected)
            if not same(dependencies,expected) then return fail("stale","first-load source/capture mismatch",state,name) end
            local layout,rerr=sharing(actual,entry,dependencies,state,name)
            if not layout then return nil,rerr end
            unit.capture_layout=layout
            unit.binding_kind,unit.fn,unit.dependencies="function",actual,dependencies
            unit.definition=stored(definition.definition,loaded.source)
            unit.signature=unit.definition.signature
            local slot,serr=Anchor.Slot(entry,name)
            if not slot then return fail("stale",serr,state,name) end
            authority.cells[#authority.cells+1]={unit_ref=ref,anchor=entry.anchor,index=slot,name=name}
        end
    end
    for _,name in ipairs(state.names) do state.by_name[name].observed=observation(state.by_name,name) end
    local group,err=project(state)
    if not group then return nil,err end
    group.initial,group.authority,group.identity_objects=initial,authority,{}
    return group
end
-- Compare signatures against EACH actual published record. Pair only supplies
-- first-load lexical support. No candidate closure is constructed here.
function M.Compare(group,initial,candidate)
    local state=plain(group) and group.state
    if not plain(state) or state.kind~=M.Kind or state.version~=M.Version
        or not plain(initial) or not plain(initial.projection) then
        return fail("ownership","Local's actual group and initial evidence required",state)
    end
    local pair,err=Definitions.Pair(initial.projection,candidate)
    if not pair then return nil,err end
    local view={kind=M.Kind..".View",version=M.Version,base_group=group,base=state,
        source=candidate.source,projection=candidate,pair=pair,by_name={},changed={},probes={}}
    for _,name in ipairs(state.names) do
        local previous,match=state.by_name[name],pair.by_name[name]
        local item={name=name,unit_ref=previous.unit_ref,previous=previous,match=match}
        view.by_name[name]=item
        if previous.binding_kind=="function" then
            if match.status~="supported" then
                item.changed=true
                item.blocked={phase="inject",code="unsupported",message=match.reason or "function support changed",
                    file=state.file,unit_key="local:"..name}
            else
                item.definition=match.definition
                item.changed=match.definition.signature~=previous.signature
                -- Retained definitions follow SAVED real edges, never candidate guesses.
                if not item.changed then item.dependencies=previous.dependencies end
            end
            if item.changed then view.changed[#view.changed+1]=name end
        else
            if match.status~="preserve-state" then
                item.blocked={phase="inject",code="unsupported",message="state binding cannot become a function",
                    file=state.file,unit_key="local:"..name}
            end
            item.dependencies={}
            item.initializer_changed=candidate.initializers[name]~=previous.signature
        end
    end
    return view
end
-- Owner-private, operation-lifetime probe. It is syntax/capture evidence only.
-- Prepare re-enumerates live captures and checks actual identities on probe hits.
function M.Probe(view,name)
    local item=plain(view) and view.by_name[name]
    if not item then return fail("ownership","unknown Local binding",view and view.base,name) end
    if item.blocked then return nil,item.blocked end
    if item.previous.binding_kind~="function" or not item.changed then return item end
    if not item.probe then
        local probe,err=Plan.Probe(view.source,item.definition)
        if not probe then item.blocked=err;return nil,err end
        item.probe=probe;view.probes[item.definition]=probe
        item.dependencies=copy(probe.created.used);table.sort(item.dependencies)
        for _,dep in ipairs(item.dependencies) do
            if not view.by_name[dep] then return fail("ownership","candidate capture provider unavailable",view.base,name) end
        end
    end
    return item
end
-- One requested unit's domain result; public Dependencies routes real unit
-- conditions and owns root provenance/closure, not this name-indexed utility.
function M.Resolve(view,name)
    local item,err=M.Probe(view,name)
    if not item then return nil,err end
    return {item=item,dependencies=item.dependencies,
        changed=item.changed==true,node=item.changed and item.definition.syntax or nil,source=view.source}
end
-- Live checks share the same identity/slot walk with owner preparation. Only
-- preparation supplies a result and retains the reads needed by FileCommit.
local function check_unit(state,name,result)
    if not plain(state) or not Anchor.Live(state.entry) or state.anchor~=state.entry.anchor then
        return fail("stale","Local Anchor scope changed",state,name)
    end
    local unit=state.by_name[name]
    if not unit then return fail("ownership","original Local binding unavailable",state,name) end
    local slot,err=Anchor.Slot(state.entry,name)
    if not slot then return fail("stale",err,state,name) end
    if unit.binding_kind=="function" then
        local actual,why=Anchor.Get(state.entry,name)
        if why or actual~=unit.fn then return fail("stale",why or "published function was replaced",state,name) end
        local ok,cerr=Compose.CheckShared(unit.fn,state.entry,unit.dependencies,unit.capture_layout)
        if not ok then return fail("stale",cerr,state,name) end
        if result then
            result.read_set[#result.read_set+1]={owner=state.owner,unit_ref=unit.unit_ref,anchor=state.anchor,index=slot,name=name,value=unit.fn}
            for _,join in ipairs(unit.capture_layout) do
                local read=copy(join);read.owner=state.owner;read.unit_ref=unit.unit_ref
                result.capture_reads[#result.capture_reads+1]=read
            end
        end
    end
    return true
end
function M.CheckUnit(state,name) return check_unit(state,name) end
local function check_live(view,result)
    local state=view.base
    if not Anchor.Live(state.entry) or state.anchor~=state.entry.anchor then
        return fail("stale","Local Anchor scope changed",state)
    end
    for _,name in ipairs(state.names) do
        local ok,err=check_unit(state,name,result)
        if not ok then return nil,err end
    end
    return true
end
-- Ordinary state values may evolve. Names, slots and shared cells are re-read.
function M.CheckLive(view) return check_live(view) end
function M.Reads(view)
    local result={read_set={},capture_reads={}}
    local ok,err=check_live(view,result)
    if not ok then return nil,err end
    return result
end
-- Names are the FINAL selected union after root/dependency/owner constraints.
-- No recursive expansion, full-file scanning, joins or setters occur here.
function M.Prepare(view,names)
    if not dense(names) then return fail("ownership","dense selected Local names required",view.base) end
    local changed,identities,selected={}, {}, {}
    for _,name in ipairs(view.base.names) do
        local unit=view.base.by_name[name]
        if unit.binding_kind=="function" then identities[name]=unit.fn end
    end
    for _,name in ipairs(names) do
        if selected[name] then return fail("ownership","duplicate Local selection",view.base,name) end
        selected[name]=true
        local item,err=M.Probe(view,name)
        if not item then return nil,err end
        if item.changed then changed[#changed+1]=name end
    end
    local definitions,err=Definitions.Select(view.pair,changed)
    if not definitions then return nil,err end
    local prepared,why=Plan.Prepare(view.source,view.base.entry,definitions,identities,view.probes)
    if not prepared then return nil,why end
    local reads,rerr=M.Reads(view)
    if not reads then return nil,rerr end
    local plan={view=view,names=changed,selected=selected,prepared=prepared,
        joins={},cell_writes={},raw_writes={},read_set=reads.read_set,capture_reads=reads.capture_reads}
    for i,item in ipairs(prepared.functions) do
        local ref=view.base.by_name[item.name].unit_ref
        local write=copy(prepared.writes[i]);write.owner=view.base.owner;write.unit_ref=ref
        plan.cell_writes[#plan.cell_writes+1]=write
        for _,join in ipairs(item.join_plan.joins) do
            local action=copy(join);action.owner=view.base.owner;action.unit_ref=ref
            plan.joins[#plan.joins+1]=action
        end
    end
    return plan
end
function M.Next(plan)
    local view,state=plan.view,plan.view.base
    if #plan.names==0 then return view.base_group end
    local next_state=copy(state);next_state.by_name={}
    for _,name in ipairs(state.names) do next_state.by_name[name]=copy(state.by_name[name]) end
    for _,item in ipairs(plan.prepared.functions) do
        local old=state.by_name[item.name]
        local unit=copy(old)
        unit.fn=item.created.fn;unit.definition=stored(item.definition,view.source)
        unit.signature=unit.definition.signature
        unit.dependencies=copy(view.by_name[item.name].dependencies)
        local layout,err=Compose.CaptureLayout(item.join_plan,unit.dependencies)
        if not layout then return fail("stale",err,state,item.name) end
        unit.capture_layout=layout
        unit.definition_version=old.definition_version+1
        next_state.by_name[item.name]=unit
    end
    for _,name in ipairs(state.names) do
        next_state.by_name[name].observed=observation(next_state.by_name,name)
    end
    return project(next_state)
end
-- Whole-statement domain evidence only. Exclusion allows retained initializers
-- during preflight; claims plus actual-version pending drive completion.
function M.Coverage(group,initial,projection,view,blocked)
    local state=plain(group) and group.state
    if not plain(state) or state.kind~=M.Kind or not plain(initial) or not plain(initial.projection)
        or not plain(projection) or projection.source==nil or state.entry.source~=initial.projection.source
        or view and (view.base_group~=group or view.source~=projection.source) then
        return fail("ownership","Local actual group and full first/candidate projections required",state)
    end
    local function side(p)
        local result={scan=p.source,claims={},excluded={},structures={},binding_reads={},wiring=""}
        for _,declaration in ipairs(Source.Declarations(p.source)) do
            result.excluded[declaration.statement]=true
        end
        for _,definitions in next,p.definitions do
            for _,definition in ipairs(definitions) do result.excluded[definition.statement]=true end
        end
        return result
    end
    local result={kind="SpellHotReload.FileCoverage",version=1,owner=state.owner,base_group=group,source=projection.source,
        initial_source=initial.projection.source,before=side(initial.projection),after=side(projection),
        pending={},function_names={},requires_top_level=false}
    local function claim(side,definition,key)
        local Tree=side.scan.analysis.syntax
        local statement=side.scan.analysis.statements[definition.statement]
        local target,fn
        if statement then
            local definition=Tree.Match(statement.syntax,"definition")
            if definition then target,fn=definition.target,definition.fn end
        end
        if not target or not Tree.SameNode(fn,definition.syntax) or side.claims[definition.statement] then
            return fail("ownership","Local coverage requires one whole owned function statement",state,key)
        end
        side.claims[definition.statement]=key;return true
    end
    for _,name in ipairs(state.names) do
        local old=state.by_name[name]
        if old.binding_kind=="function" then
            result.function_names[name]=true
            local key="local:"..name
            local original=initial.projection.definitions[name]
            if not original or #original~=1 then return fail("ownership","original Local definition unavailable",state,name) end
            local ok,err=claim(result.before,original[1],key);if not ok then return nil,err end
            local item=view and view.by_name[name]
            local reason=blocked or item and item.blocked
            if not item or reason or item.changed then
                result.pending[#result.pending+1]={kind="function",key=key,
                    reason=plain(reason) and reason.message or "function definition not published",
                    first=item and item.definition and item.definition.source_range.first,
                    last=item and item.definition and item.definition.source_range.last,
                    previous_first=old.definition.source_range.first,previous_last=old.definition.source_range.last}
            end
            if item and item.match.status=="supported" then
                ok,err=claim(result.after,item.match.definition,key);if not ok then return nil,err end
            end
        end
    end
    return result
end


-- Local-only scalar presentation. No probes, live reads, source scans or
-- proposed versions: observations come from the actual Local owner records.
function M.Describe(fragment,inspection)
    local view=plain(fragment) and fragment.local_view
    local op=plain(fragment) and fragment.operation
    if not plain(view) or not plain(op) or fragment.base_group~=view.base_group
        or not plain(inspection) or inspection.operation~=op or inspection.snapshot~=op.base_snapshot
        or not plain(inspection.impact) or not plain(inspection.impact.affected)
        or not dense(fragment.local_names) or not plain(view.base)
        or not plain(inspection.dependencies) or not dense(inspection.dependencies.blocked_roots) then
        return fail("unsupported","prepared Local owner and actual inspection scope required")
    end
    local selected={};for _,name in ipairs(fragment.local_names) do selected[name]=true end
    local root_blocks={}
    for _,block in ipairs(inspection.dependencies.blocked_roots) do
        for ref in next,view.choices[block.root_id] or {} do root_blocks[ref]=block.reason end
    end
    local result={functions={},initializers={}}
    for _,name in ipairs(view.base.names) do
        local unit=view.base.by_name[name]
        local item=view.version_view and view.version_view.by_name[name]
        if unit.binding_kind=="function" then
            local blocked=view.blocked or item and item.blocked or (not selected[name] and root_blocks[unit.unit_ref] or nil)
            local changed=item and item.changed==true
            local affected=inspection.impact.affected[unit.unit_ref]==true
            local observed,order={},{}
            for dependency in next,unit.observed do order[#order+1]=dependency end;table.sort(order)
            for _,dependency in ipairs(order) do observed[#observed+1]={name=dependency,version=unit.observed[dependency]} end
            result.functions[#result.functions+1]={key="local:"..name,definition_version=unit.definition_version,
                action=blocked and "restart-required" or changed and "compile-publish" or affected and "shared-impact" or "keep-definition",
                selected=selected[name]==true,pending=(changed or blocked~=nil) and not selected[name] or false,
                affected=affected,observed=observed}
        elseif view.projection.initializers[name]~=unit.signature then
            result.initializers[#result.initializers+1]={name=name,action="preserve-state",requires_restart=true}
        end
    end
    return result
end

return M
