-- Local owns direct binding discovery, correspondence, domain selection and
-- versions. Generic Source builds facts/prepares closures; only FileCommit writes.
local Definitions=require("SpellHotReload.Adapters.Local.LocalDefinitions")
local Versions=require("SpellHotReload.Adapters.Local.LocalVersions")
local Files=require("SpellHotReload.Pipeline.FileVersions")
local Source=require("SpellHotReload.Source.FileAnalysis")
local M={Id="local",ContractVersion=7}
local VIEW="SpellHotReload.Local.View"
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function dense(v)
    if not plain(v) then return false end
    local n,max=0,0
    for k in next,v do
        if type(k)~="number" or k<1 or k>=math.huge or k~=math.floor(k) then return false end
        n=n+1;max=math.max(max,k)
    end
    return n==max
end
local function fail(phase,code,message,context)
    return nil,{phase=phase,code=code,message=message,
        file=plain(context) and plain(context.common) and context.common.file}
end
-- Match declarations/writes at the shared position; reuse the same candidate
-- binding unit when its definition follows a separate declaration.
function M.Match(cursor,common,accepted)
    local source=common.source;local row=cursor:Peek();local index=cursor:Mark()
    local Tree=source.analysis.syntax;local ast=row.syntax
    local declaration=Tree.Match(ast,"declaration")
    local names,seen={},{}
    local function add(name)
        if name and not seen[name] then names[#names+1]=name;seen[name]=true end
    end
    if declaration then
        for _,binding in ipairs(declaration.names) do add(Tree.Identifier(binding)) end
    else
        local assignment=Tree.Match(ast,"assignment")
        local definition=Tree.Match(ast,"definition")
        local targets=assignment and assignment.targets or definition and {definition.target} or {}
        for _,target in ipairs(targets) do
            local name=Tree.Identifier(target)
            if name and Source.ResolveLocal(source,index,name) then add(name) end
        end
    end
    if #names==0 then return nil end
    local units,claims,mappings={},{},{}
    for _,name in ipairs(names) do
        local key="local:"..name;local unit=accepted[key]
        if not unit then
            unit={key=key,carrier="local",context={name=name}}
            claims[#claims+1]={kind="declaration",key=key,unit_key=key}
        end
        units[#units+1]=unit;mappings[#mappings+1]={unit=unit,first=index,last=index}
    end
    cursor:Take()
    return {units=units,claims=claims,mappings=mappings}
end
function M.BuildContext(source,units,mappings)
    local projection,err=Definitions.Build(source,units,mappings)
    if not projection then return nil,err end
    local by_name={};for _,unit in ipairs(units) do by_name[unit.context.name]=unit end
    return {source=source,units=units,projection=projection,by_name=by_name}
end
-- Only the synchronous genuine-first-load caller may contribute a new owner.
function M.Capture(entry,session_id,snapshot)
    if not plain(entry) or not Source.Validate(entry.source) then
        return fail("versions","ownership","genuine first-load entry required")
    end
    local context,err=require("SpellHotReload.Pipeline.FileMatch").ForOwner(snapshot,M,entry.source)
    if not context then return fail("versions","ownership",err) end
    return Versions.Seed(M,entry,session_id,context.projection)
end
function M.Reconcile(previous,candidate,context)
    local file_context=context.adapter
    if not plain(file_context) or file_context.source~=candidate.common.source then
        return fail("reconcile","ownership","Local full-source match required",context)
    end
    local capture=candidate.common.capture
    local actual,initial=Files.Owner(capture,M)
    local owned=actual and previous.owner==M and previous.state==actual.state and previous.records==actual.records
    local view={kind=VIEW,version=1,source=file_context.source,projection=file_context.projection,
        base_group=owned and actual or nil,items={},by_name={},units={},choices={}}
    local rows,exports={},{}
    local entries={}
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==M then entries[entry.unit.context.name]=entry end
    end
    if not owned then
        if #previous.records~=0 or #previous.units~=0 then
            return fail("reconcile","ownership","original Local first-load history unavailable",context)
        end
        for _,entry in ipairs(candidate.entries) do
            if entry.adapter==M then
                view.units[#view.units+1]={candidate_entry=entry,previous_records={},status="candidate-only",private_ref=entry.unit.context}
                rows[#rows+1]={status="candidate-only",candidate={entry=entry},reason="binding has no original captured owner",
                    evidence={"candidate declaration only"},dependencies={},conditions={"restart game to establish history"}}
            end
        end
        return {rows=rows,view=view,units=view.units,exports=exports}
    end
    view.base=actual.state;view.initial=initial.evidence
    view.version_view,view.blocked=Versions.Compare(actual,initial.evidence,file_context.projection)
    view.read_view=view.version_view or {base=actual.state,base_group=actual}
    local records={}
    for _,record in ipairs(previous.records) do records[record.definition.unit_ref]=record end
    local matched={}
    for _,name in ipairs(actual.state.names) do
        local before=actual.state.by_name[name]
        local version_item=view.version_view and view.version_view.by_name[name]
        local entry=view.version_view and entries[name] or nil
        if entry then matched[entry]=true end
        local item={name=name,previous=before,version_item=version_item,token={},selector={},entry=entry}
        local status=entry and "corresponding" or "old-only"
        local unit={unit_ref=before.unit_ref,candidate_entry=entry,previous_records={records[before.unit_ref]},
            status=status,private_ref=item}
        item.unit=unit;view.items[before.unit_ref]=item;view.by_name[name]=item
        view.units[#view.units+1]=unit
        exports[#exports+1]={unit_ref=before.unit_ref,conditions={item.token}}
        local blocked=view.blocked or version_item and version_item.blocked
        rows[#rows+1]={status=entry and not blocked and "corresponding" or "unresolved",
            previous=records[before.unit_ref],candidate=entry and {entry=entry} or nil,
            reason=blocked and blocked.message or "original declaration/definition-point correspondence",
            evidence=entry and {"same unique original binding order, kind and lexical definition context"} or {},
            dependencies={},conditions={"fresh actual identity and common transaction guards required"}}
    end
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==M and not matched[entry] then
            view.units[#view.units+1]={candidate_entry=entry,previous_records={},status="candidate-only",private_ref=entry.unit.context}
            rows[#rows+1]={status="candidate-only",candidate={entry=entry},reason="candidate has no proven original binding correspondence",
                evidence={"complete candidate declaration only"},dependencies={},conditions={"restart game to adopt structural changes"}}
        end
    end
    return {rows=rows,view=view,units=view.units,exports=exports}
end
local function scope(context)
    if not plain(context) or not plain(context.operation) or not plain(context.view)
        or not plain(context.common) or context.view.kind~=VIEW or context.view.version~=1 or not plain(context.view.base_group)
        or context.view.source~=context.operation.source or context.common.source~=context.view.source then return false end
    local group=Files.Owner(context.operation.capture,M)
    return group==context.view.base_group and group==context.base_group
        and context.operation.base_snapshot==context.operation.capture.snapshot
end
function M.Locate(unit,context)
    if not scope(context) or context.scope~="unit" or context.phase~="locate" or not plain(unit)
        or context.view.items[unit.unit_ref]~=unit.private_ref or unit.private_ref.unit~=unit then
        return fail("locate","ownership","original Local unit and operation scope required",context)
    end
    local item=unit.private_ref
    local reads,err=Versions.ReadUnit(context.view.base,item.name)
    if not reads then return nil,err end
    return {kind="SpellHotReload.Local.Handle",version=1,operation=context.operation,view=context.view,unit=unit,item=item,reads=reads}
end
-- Binding-to-unit mapping only. Card may map its actual captures through this
-- canonical declaration object; it cannot choose or prepare Local definitions here.
function M.Provider(view,binding)
    if not plain(view) or view.kind~=VIEW or not plain(binding)
        or Source.Declaration(view.source,binding.name)~=binding then return nil end
    local item=view.by_name[binding.name]
    if not item then return nil end
    return {unit_ref=item.unit.unit_ref,condition_ref=item.token}
end
-- First-load mapping returns ONLY an original stable provider reference.
function M.CapturedProvider(group,binding)
    local state=plain(group) and group.state
    if not plain(state) or group.owner~=M or state.owner~=M or not plain(binding)
        or not plain(state.entry) or not plain(state.entry.source)
        or Source.Declaration(state.entry.source,binding.name)~=binding then return nil end
    local unit=state.by_name[binding.name]
    return unit and unit.unit_ref
end
-- Runtime requests refer to the ORIGINAL provider, even when its candidate
-- declaration is absent/blocked. Local resolve retains the refusal semantics.
function M.Requirement(view,ref)
    if not plain(view) or view.kind~=VIEW or view.version~=1 or not plain(ref) then return nil end
    local item=view.items[ref]
    if not item or item.unit.unit_ref~=ref then return nil end
    return {unit_ref=ref,condition_ref=item.token}
end
function M.Roots(view)
    if not plain(view) or view.kind~=VIEW or not plain(view.base) then return {} end
    local roots={}
    for _,name in ipairs(view.base.names) do
        local item=view.by_name[name]
        if item.previous.binding_kind=="function" then
            roots[#roots+1]={root_id="local:"..name,unit_ref=item.unit.unit_ref,selector=item.selector}
        end
    end
    return roots
end
local function resolve(handle,unit,context)
    local view,request,item=context.view,context.request,unit.private_ref
    if not plain(handle) or handle.kind~="SpellHotReload.Local.Handle" or handle.operation~=context.operation
        or handle.view~=view or handle.unit~=unit or handle.item~=item
        or not plain(request) or request.operation~=context.operation or request.view~=view
        or request.unit_ref~=unit.unit_ref or type(request.root_id)~="string" or not dense(request.conditions)
        or request.selector~=nil and request.selector~=item.selector then
        return fail("resolve","ownership","Local exact handle/request required",context)
    end
    for _,condition in ipairs(request.conditions) do
        if condition~=item.token then return fail("resolve","ownership","foreign Local condition",context) end
    end
    if request.selector==nil and #request.conditions==0 then
        return fail("resolve","ownership","Local root selector or provider condition required",context)
    end
    local blocked=view.blocked or item.version_item and item.version_item.blocked
    if blocked then return {blocked=blocked,needs={},affected={},source_facts={}} end
    local evidence,err=Versions.Resolve(view.version_view,item.name)
    if not evidence then return {blocked=err,needs={},affected={},source_facts={}} end
    local choice={view=view,item=item,root_id=request.root_id,dependencies={},evidence=evidence}
    local needs={}
    for _,name in ipairs(evidence.dependencies) do
        local provider=view.by_name[name]
        if not provider then return fail("resolve","ownership","actual Local provider unavailable",context) end
        choice.dependencies[#choice.dependencies+1]=provider.unit.unit_ref
        needs[#needs+1]={root_id=request.root_id,provider_unit=provider.unit.unit_ref,
            condition_ref=provider.token,cause_ref=choice}
    end
    view.choices[request.root_id]=view.choices[request.root_id] or {}
    view.choices[request.root_id][unit.unit_ref]=choice
    return {selection_ref=choice,needs=needs,affected=evidence.changed and {unit.unit_ref} or {},
        source_facts=evidence.changed and {{source=view.source,node=evidence.node}} or {}}
end
local function owner_handle(handle,context)
    return plain(handle) and handle.kind=="SpellHotReload.Driver.OwnerHandle" and handle.version==1
        and handle.operation==context.operation and handle.owner==M and handle.base_group==context.base_group
        and handle.view==context.view and plain(handle.by_ref)
end
local function guard(fragment,capture,live)
    local view=fragment.local_view
    local group=Files.Owner(capture,M)
    if not plain(view) or group~=fragment.base_group or group~=view.base_group
        or fragment.owner~=M or fragment.operation.capture~=capture or fragment.operation.base_snapshot~=capture.snapshot
        or not plain(live) or live.entry~=view.base.entry or live.session_id~=view.base.session_id then
        return nil,{phase="commit",code="stale",message="Local actual owner/session changed"}
    end
    local reads,err=Versions.Reads(view.read_view)
    if not reads then return nil,err end
    local next_state=fragment.proposed_group.state
    local selected={}
    for _,name in ipairs(fragment.local_names) do selected[name]=true end
    for _,name in ipairs(view.base.names) do
        local old,new=view.base.by_name[name],next_state.by_name[name]
        local item=view.by_name[name]
        local changed=selected[name] and item.version_item.changed
        if not plain(new) or new.unit_ref~=old.unit_ref or new.binding_kind~=old.binding_kind
            or new.definition_version~=old.definition_version+(changed and 1 or 0)
            or changed and new.signature~=item.version_item.definition.signature
            or not changed and (new.fn~=old.fn or new.signature~=old.signature) then
            return nil,{phase="commit",code="ownership",message="Local proposed definition/version changed"}
        end
    end
    return true
end
function M.Inject(handle,unit,context)
    if not scope(context) then return fail("inject","ownership","Local operation view required",context) end
    if context.scope=="unit" and context.phase=="resolve" then
        if not plain(unit) or context.view.items[unit.unit_ref]~=unit.private_ref then
            return fail("resolve","ownership","Local original unit required",context)
        end
        return resolve(handle,unit,context)
    end
    if context.scope~="owner" or unit~=nil or not owner_handle(handle,context) then
        return fail("inject","ownership","Local owner aggregation scope required",context)
    end
    if context.phase=="resolve" then
        return {operation=context.operation,owner=M,blocked_roots={}}
    end
    local selection,view=context.selection,context.view
    if context.phase~="prepare" or not plain(selection) or selection.owner~=M
        or selection.base_group~=view.base_group or selection.view~=view or not dense(selection.units) then
        return fail("inject","ownership","Local final owner selection required",context)
    end
    local chosen,by_root={},{}
    for _,selected in ipairs(selection.units) do
        local item=plain(selected) and view.items[selected.unit_ref]
        local located=item and handle.by_ref[selected.unit_ref]
        if not item or selected.unit_view~=item.unit or not located or located.unit~=item.unit
            or chosen[selected.unit_ref] or not dense(selected.roots) or #selected.roots==0 then
            return fail("inject","ownership","Local selected unit lacks exact location",context)
        end
        chosen[selected.unit_ref]=true
        for _,root in ipairs(selected.roots) do
            local choice=plain(root) and root.selection_ref
            if not plain(choice) or choice.view~=view or choice.item~=item or choice.root_id~=root.root_id
                or not view.choices[root.root_id] or view.choices[root.root_id][selected.unit_ref]~=choice then
                return fail("inject","ownership","Local private selection changed",context)
            end
            by_root[root.root_id]=by_root[root.root_id] or {}
            by_root[root.root_id][selected.unit_ref]=choice
        end
    end
    for _,choices in next,by_root do
        for _,choice in next,choices do
            for _,provider in ipairs(choice.dependencies) do
                if not choices[provider] then return fail("inject","ownership","Local root dependency missing from final union",context) end
            end
        end
    end
    local names={}
    for _,name in ipairs(view.base.names) do if chosen[view.base.by_name[name].unit_ref] then names[#names+1]=name end end
    local plan,err
    if view.version_view then plan,err=Versions.Prepare(view.version_view,names)
    elseif #names==0 then
        local reads;reads,err=Versions.Reads(view.read_view)
        if reads then plan={view=view.read_view,names={},joins={},cell_writes={},raw_writes={},
            read_set=reads.read_set,capture_reads=reads.capture_reads} end
    end
    if not plan then return nil,err or {phase="inject",code="unsupported",message="Local support unavailable"} end
    local proposed,why=Versions.Next(plan)
    if not proposed then return nil,why end
    local coverage,cerr=Versions.Coverage(view.base_group,view.initial,view.projection,view.version_view,view.blocked)
    if not coverage then return nil,cerr end
    return {operation=context.operation,owner=M,base_group=view.base_group,proposed_group=proposed,
        file_evidence=coverage,joins=plan.joins,cell_writes=plan.cell_writes,raw_writes=plan.raw_writes,
        read_set=plan.read_set,capture_reads=plan.capture_reads,owner_guard=guard,local_view=view,local_names=names}
end
function M.Commit(handle,fragment,context)
    if not scope(context) or not owner_handle(handle,context) or not plain(fragment)
        or fragment.owner~=M or fragment.operation~=context.operation or fragment.base_group~=context.base_group
        or type(context.adapter.register)~="function" then
        return fail("register","ownership","Local exact fragment registration required",context)
    end
    return context.adapter.register(handle,fragment,context)
end

-- Private domain query, not a Driver hook or publication capability.
function M.Describe(fragment,inspection)
    if not plain(fragment) or fragment.owner~=M then return fail("describe","ownership","original Local fragment required") end
    return Versions.Describe(fragment,inspection)
end

return M
