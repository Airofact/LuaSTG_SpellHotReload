-- One public unit per class; callback selectors and versions stay owner-private.
local D=require('SpellHotReload.Adapters.Class.ClassDefinitions')
local V=require('SpellHotReload.Adapters.Class.ClassVersions')
local Files=require('SpellHotReload.Pipeline.FileVersions')
local Local=require('SpellHotReload.Adapters.Local.Local')
local Compose=require('SpellHotReload.Source.Compose')
local Source=require('SpellHotReload.Source.FileAnalysis')
local M={Id='class',ContractVersion=7}
local plain,copy,fail=D.Plain,V.Copy,V.Fail
local function dense(t)
    if not plain(t) then return false end
    local n,max=0,0
    for k in next,t do
        if type(k)~='number' or k<1 or k~=math.floor(k) or k==math.huge then return false end
        n=n+1;max=math.max(max,k)
    end
    return n==max
end
function M.Match(cursor,common,accepted)
    local source=common.source;local Tree=source.analysis.syntax
    local start=cursor:Mark();local key=D.StatementKey(Tree,cursor:Peek().syntax)
    if key==nil then return nil end
    local id="class:"..key;local unit=accepted[id]
    local claims={}
    if not unit then
        unit={key=id,carrier="class",context={key=key}}
        claims[1]={kind="constructor",key=id,unit_key=id}
    end
    repeat cursor:Take() until cursor:AtEnd() or D.StatementKey(Tree,cursor:Peek().syntax)~=key
    return {units={unit},claims=claims,mappings={{unit=unit,first=start,last=cursor:Mark()-1}}}
end
function M.BuildContext(source,units,mappings)
    local p,err=D.Build(source,units,mappings);if not p then return nil,err end
    return {source=source,units=units,projection=p}
end
function M.Capture(entry,session,local_group,snapshot)
    if not plain(entry) or not Source.Validate(entry.source) then return fail("genuine Class load required") end
    local context,err=require("SpellHotReload.Pipeline.FileMatch").ForOwner(snapshot,M,entry.source)
    if not context then return fail(err) end
    return V.Seed(M,entry,session,local_group,context.projection)
end
function M.CapturedProvider(group,key)
    local state=plain(group) and group.owner==M and group.state
    local item=state and state.by_key[key]
    return item and item.unit_ref
end
function M.Requirement(view,ref)
    local item=plain(view) and view.kind=="SpellHotReload.Class.View" and view.items[ref]
    if not item or item.unit.unit_ref~=ref then return nil end
    return {unit_ref=ref,condition_ref=item.definition_condition}
end
function M.Reconcile(previous,candidate,context)
    local actual,initial=Files.GetAdapterRecords(candidate.common.capture,M)
    local p=context.adapter and context.adapter.projection
    if not p or p.source~=candidate.common.source then return fail('Class source projection required') end
    local owned=actual and previous.owner==M and previous.state==actual.state and previous.records==actual.records
    local view={kind='SpellHotReload.Class.View',source=p.source,projection=p,discovery=candidate,
        base_group=owned and actual or nil,items={},units={},choices={},selectors={}}
    local entries,rows,exports={},{},{}
    for _,entry in ipairs(candidate.entries) do if entry.adapter==M then entries[entry.unit.context.key]=entry end end
    local matched={}
    if owned then
        view.versions=V.Compare(actual,initial.evidence,p);view.base=actual.state;view.initial=initial.evidence
        for _,key in ipairs(actual.state.order) do
            local old=actual.state.by_key[key];local entry=entries[key];local records={}
            for _,r in ipairs(previous.records) do if r.class_key==key then records[#records+1]=r end end
            local item={key=key,previous=old,selectors={},definition_condition={}}
            local unit={unit_ref=old.unit_ref,candidate_entry=entry,previous_records=records,
                status=entry and 'corresponding' or 'old-only',private_ref=item}
            item.unit=unit;view.items[old.unit_ref]=item;view.units[#view.units+1]=unit
            for _,name in ipairs(D.Callbacks) do
                if old.callbacks[name].owned then
                    local selector={};item.selectors[selector]=name;view.selectors[key..':'..name]=selector
                end
            end
            exports[#exports+1]={unit_ref=old.unit_ref,conditions={item.definition_condition}}
            if entry then matched[entry]=true end
            for _,record in ipairs(records) do
                rows[#rows+1]={status=entry and 'corresponding' or 'unresolved',previous=record,
                    candidate=entry and {entry=entry},reason='original class key and observed construction identity',
                    evidence={'genuine Class observation and original callback provenance'},dependencies={},
                    conditions={'fresh paired dispatch and inheritance guards required'}}
            end
        end
    elseif #previous.records>0 or #previous.units>0 then return fail('original Class owner history unavailable') end
    for _,entry in ipairs(candidate.entries) do
        if entry.adapter==M and not matched[entry] then
            view.units[#view.units+1]={candidate_entry=entry,previous_records={},status='candidate-only',private_ref=entry.unit.context}
            rows[#rows+1]={status='candidate-only',candidate={entry=entry},reason='class has no genuine first-load owner',
                evidence={'candidate only'},dependencies={},conditions={'restart to adopt new classes'}}
        end
    end
    return {rows=rows,view=view,units=view.units,exports=exports}
end
function M.Roots(view)
    local roots={}
    if not plain(view) or not view.base then return roots end
    for _,key in ipairs(view.base.order) do
        local old=view.base.by_key[key]
        for _,name in ipairs(D.Callbacks) do
            local selector=view.selectors[key..':'..name]
            if selector then roots[#roots+1]={root_id='class:'..#key..':'..key..':'..name,unit_ref=old.unit_ref,selector=selector} end
        end
    end
    return roots
end
local function scope(context)
    local op=context and context.operation;local view=context and context.view
    if not plain(op) or not plain(view) or view.kind~='SpellHotReload.Class.View'
        or not context.common or context.common.source~=view.source or op.source~=view.source then return false end
    return Files.GetAdapterRecords(op.capture,M)==view.base_group and context.base_group==view.base_group
        and op.base_snapshot==op.capture.snapshot
end
function M.Locate(unit,context)
    if not scope(context) or context.scope~='unit' or context.phase~='locate'
        or not plain(unit) or not plain(unit.private_ref)
        or context.view.items[unit.unit_ref]~=unit.private_ref then return fail('original Class unit scope required') end
    local ok,err=V.CheckUnit(context.view.base,unit.private_ref.key);if not ok then return nil,err end
    return {operation=context.operation,view=context.view,unit=unit,item=unit.private_ref}
end
local function resolve(handle,unit,context)
    local view,request=context.view,context.request;local item=unit.private_ref
    if not plain(request) or not plain(handle) or handle.operation~=context.operation or handle.view~=view
        or handle.unit~=unit or handle.item~=item or request.operation~=context.operation or request.view~=view
        or request.unit_ref~=unit.unit_ref or not dense(request.conditions) or type(request.root_id)~="string" then
        return fail("exact Class request and location required")
    end
    local whole=false
    for _,condition in ipairs(request.conditions) do
        if condition~=item.definition_condition then return fail("foreign Class definition condition") end
        whole=true
    end
    local name=request.selector and item.selectors[request.selector]
    if request.selector~=nil and not name then return fail("foreign Class method selector") end
    if not whole and (not name or context.operation.mode~="file") then return fail("Class root method or dependency condition required") end
    local selected,err
    if whole then selected,err=V.ResolveDefinition(view.versions,item.key)
    else
        local member;member,err=V.Resolve(view.versions,item.key,name)
        if member then
            selected={members={{name=name,resolved=member}},providers={},changed=member.changed}
            for _,dep in ipairs(member.callback.dependencies) do selected.providers[#selected.providers+1]=view.base.providers[dep] end
        end
    end
    if not selected then return {blocked=err,needs={},affected={},source_facts={}} end
    local local_view
    for _,group in ipairs(view.discovery.reconciliation.groups) do if group.owner==Local then local_view=group.view end end
    local choice={view=view,item=item,root_id=request.root_id,selector=request.selector,whole=whole,
        members=selected.members,demands={}}
    for _,ref in ipairs(selected.providers) do
        local provider=Local.Requirement(local_view,ref)
        if not provider then return fail("original Class Local provider unavailable",view.base,item.key) end
        choice.demands[#choice.demands+1]={root_id=request.root_id,provider_unit=provider.unit_ref,
            condition_ref=provider.condition_ref,cause_ref=choice}
    end
    local facts={}
    for _,member in ipairs(selected.members) do
        if member.resolved.changed then facts[#facts+1]={source=view.source,node=member.resolved.node} end
    end
    view.choices[request.root_id]=view.choices[request.root_id] or {}
    view.choices[request.root_id][unit.unit_ref]=choice
    return {selection_ref=choice,needs=choice.demands,affected=selected.changed and {unit.unit_ref} or {},source_facts=facts}
end
local function bindings(view,node)
    local Tree=view.source.analysis.syntax
    local reads,problem={},nil
    Tree.Walk(node,function(n,parent)
        if problem then return false end
        local name=Tree.Is(n,'name') and Tree.Identifier(n)
        if name=='_editor_class' then
            local index=Tree.Match(parent,'index')
            local key=index and Tree.SameNode(index.base,n) and Tree.String(index.key)
            if not key or view.versions.pending_classes[key] then
                problem='class registry read depends on unknown, dynamic or unpublished construction';return false
            end
            -- External/Card class identities keep their existing domain proof.
            -- Class guards only its original classes and pending constructors.
            if view.base.by_key[key] then
                local cls=view.initial.bindings[key]
                if not plain(cls) then problem='original Class dependency is unavailable';return false end
                reads[#reads+1]={registry=view.initial.registry,key=key,value=cls}
            end
        end
    end)
    if problem then return nil,problem end
    return reads
end
local function constraints(view,dependencies)
    local result={by_root={},blocked_roots={}}
    for _,root in ipairs(dependencies.safe_roots) do result.by_root[root.root_id]={reads={}} end
    for _,fact in ipairs(dependencies.source_facts) do
        local target=result.by_root[fact.root_id]
        if fact.source~=view.source or not target or not Source.Site(view.source,fact.node) then return fail('foreign Class binding source fact') end
        local reads,err=bindings(view,fact.node)
        if not reads then target.reason=err
        else for _,r in ipairs(reads) do target.reads[#target.reads+1]=r end end
    end
    for _,root in ipairs(dependencies.safe_roots) do
        local proof=result.by_root[root.root_id]
        if proof.reason then result.blocked_roots[#result.blocked_roots+1]={root_id=root.root_id,
            reason={phase='class',code='unsupported',message=proof.reason}} end
    end
    return result
end
local function coverage(view)
    local owned={};for _,key in ipairs(view.base.order) do owned[key]=true end
    local before=D.Side(view.initial.projection,owned);local after=D.Side(view.projection,owned)
    local evidence={kind='SpellHotReload.FileCoverage',version=1,owner=M,base_group=view.base_group,
        source=view.source,initial_source=view.base.entry.source,before=before,after=after,
        function_names={},pending={},requires_top_level=false}
    for _,key in ipairs(view.base.order) do
        local item=view.versions.by_key[key]
        for _,name in ipairs(D.Callbacks) do
            local old=view.initial.projection.by_key[key].methods[name]
            local current=view.projection.by_key[key];current=current and current.methods[name]
            local member='class:'..#key..':'..key..':'..name
            if view.base.by_key[key].writable and old and #old==1 and old[1].safe then before.claims[old[1].index]=member end
            if view.base.by_key[key].writable and current and #current==1 and current[1].safe then after.claims[current[1].index]=member end
            local cb=item.callbacks[name]
            if cb.changed or cb.blocked then
                evidence.pending[#evidence.pending+1]={kind='class-callback',key=member,
                    reason=cb.blocked or 'class callback definition not published',
                    first=current and current[1].range.first,last=current and current[1].range.last,
                    previous_first=old and old[1].range.first,previous_last=old and old[1].range.last}
            end
        end
    end
    return evidence
end
local function owner_handle(handle,context)
    return plain(handle) and handle.kind=='SpellHotReload.Driver.OwnerHandle' and handle.owner==M
        and handle.operation==context.operation and handle.view==context.view and handle.base_group==context.base_group
        and plain(handle.by_ref)
end
local function guard(fragment,capture,live)
    local view=fragment.class_view
    if Files.GetAdapterRecords(capture,M)~=fragment.base_group or fragment.base_group~=view.base_group
        or fragment.operation.capture~=capture or fragment.operation.base_snapshot~=capture.snapshot
        or not plain(live) or live.entry~=view.base.entry or live.session_id~=view.base.session_id then return fail('Class session changed') end
    local ok,err=V.CheckLive(view.base);if not ok then return nil,err end
    for _,read in ipairs(fragment.class_registry_reads) do
        if live.classes~=read.registry or rawget(read.registry,read.key)~=read.value then return fail('Class dependency registry identity changed') end
    end
    local pubs={}
    for _,pub in ipairs(fragment.class_publications) do
        local ok,why=V.Inheritance(view.base,pub.key,pub.name);if not ok then return nil,why end
        pubs[pub.key..':'..pub.name]=pub
    end
    for _,key in ipairs(view.base.order) do
        local old,new=view.base.by_key[key],fragment.proposed_group.state.by_key[key]
        local changed=false
        if not new or new.class~=old.class or new.base~=old.base or new.unit_ref~=old.unit_ref then return fail('Class proposed identity changed') end
        if new.writable~=old.writable or new.structure_signature~=old.structure_signature
            or new.readonly_signature~=old.readonly_signature or #new.fixed~=#old.fixed then
            return fail("Class proposed readonly definition changed")
        end
        for i,fixed in ipairs(old.fixed) do
            local copy=new.fixed[i]
            if not copy or copy.name~=fixed.name or copy.value~=fixed.value or copy.fn~=fixed.fn
                or #copy.dependencies~=#fixed.dependencies then return fail("Class readonly member evidence changed") end
            for j,name in ipairs(fixed.dependencies) do if copy.dependencies[j]~=name then return fail("Class readonly dependency changed") end end
        end
        for _,name in ipairs(D.Callbacks) do
            local a,b=old.callbacks[name],new.callbacks[name];local pub=pubs[key..':'..name]
            if pub then
                changed=true
                if b.fn~=pub.callback.fn or b.signature~=pub.callback.signature or not b.owned
                    or b.definition_version~=a.definition_version+1 then return fail('Class proposed callback/version changed') end
            elseif b~=a and (b.fn~=a.fn or b.signature~=a.signature or b.definition_version~=a.definition_version or b.owned~=a.owned) then
                return fail('Class retained callback changed')
            end
        end
        if new.definition_version~=old.definition_version+(changed and 1 or 0) then return fail('Class proposed class version changed') end
    end
    return true
end
function M.Inject(handle,unit,context)
    if not scope(context) then return fail('Class operation view required') end
    if context.scope=='unit' and context.phase=='resolve' then return resolve(handle,unit,context) end
    if context.scope~='owner' or unit~=nil or not owner_handle(handle,context) then return fail('exact Class owner aggregation required') end
    local view=context.view
    if context.phase=='resolve' then
        local proof,err=constraints(view,context.dependencies);if not proof then return nil,err end
        return {operation=context.operation,owner=M,blocked_roots=proof.blocked_roots,evidence=proof}
    end
    local selection=context.selection
    if context.phase~='prepare' or not plain(selection) or selection.owner~=M or selection.view~=view
        or selection.base_group~=view.base_group or not dense(selection.units)
        or not plain(context.constraints) or context.constraints.owner~=M then return fail('Class final selection and constraints required') end
    local pubs,selected={},{}
    for _,record in ipairs(selection.units) do
        local item=view.items[record.unit_ref]
        if not item or not handle.by_ref[record.unit_ref] or record.unit_view~=item.unit or not dense(record.roots) then return fail('Class selected unit lacks location') end
        for _,root in ipairs(record.roots) do
            local choice=root.selection_ref
            if not plain(choice) or not view.choices[root.root_id] or view.choices[root.root_id][record.unit_ref]~=choice
                or choice.item~=item or choice.selector~=root.selector then return fail("Class private selection changed") end
            if choice.whole then
                local found=false;for _,condition in ipairs(root.conditions) do if condition==item.definition_condition then found=true end end
                if not found then return fail("Class definition requirement was lost") end
            elseif not item.selectors[root.selector] then return fail("Class method selector was lost") end
            for _,demand in ipairs(choice.demands) do
                local found=false
                for _,owner in ipairs(context.dependencies.owners) do
                    for _,provider in ipairs(owner.units) do
                        if provider.unit_ref==demand.provider_unit then
                            for _,path in ipairs(provider.roots) do
                                if path.root_id==root.root_id then
                                    for _,condition in ipairs(path.conditions) do
                                        if condition==demand.condition_ref then found=true end
                                    end
                                end
                            end
                        end
                    end
                end
                if not found then return fail('Class root lost its required Local provider') end
            end
            for _,member in ipairs(choice.members) do
                local key=item.key..":"..member.name
                if member.resolved.changed and not selected[key] then
                    selected[key]=true;pubs[#pubs+1]={key=item.key,name=member.name,callback=member.resolved.callback}
                end
            end
        end
    end
    local reads,err=V.Reads(view.base);if not reads then return nil,err end
    local joins,writes={},{}
    for _,pub in ipairs(pubs) do
        local old=view.base.by_key[pub.key];local slot=D.Allowed[pub.name]
        local proof,why=Compose.Plan(pub.callback.created,view.base.entry);if not proof then return fail(why) end
        for _,j in ipairs(proof.joins) do local r=copy(j);r.owner=M;r.unit_ref=old.unit_ref;joins[#joins+1]=r end
        for _,field in ipairs({pub.name,slot}) do
            writes[#writes+1]={owner=M,unit_ref=old.unit_ref,target=old.class,key=field,
                before=old.callbacks[pub.name].fn,value=pub.callback.fn}
        end
    end
    local registry_reads={}
    for _,root in ipairs(context.dependencies.safe_roots) do
        local proof=context.constraints.evidence.by_root[root.root_id]
        if proof then for _,r in ipairs(proof.reads) do registry_reads[#registry_reads+1]=r end end
    end
    return {operation=context.operation,owner=M,base_group=view.base_group,proposed_group=V.Next(view.versions,pubs),
        joins=joins,cell_writes={},raw_writes=writes,read_set=reads.read_set,capture_reads=reads.capture_reads,
        file_evidence=coverage(view),owner_guard=guard,class_view=view,
        class_publications=pubs,class_registry_reads=registry_reads}
end
function M.Commit(handle,fragment,context)
    if not scope(context) or not owner_handle(handle,context) or not plain(fragment) or fragment.owner~=M
        or fragment.operation~=context.operation or fragment.base_group~=context.base_group
        or type(context.adapter.register)~='function' then return fail('exact Class fragment registration required') end
    return context.adapter.register(handle,fragment,context)
end
function M.Describe(fragment,inspection)
    if not plain(fragment) or fragment.owner~=M or not plain(inspection) or inspection.operation~=fragment.operation then return fail('Class inspection scope required') end
    return {objects={}}
end
return M
