-- Card owns generated callback/member rules and live practice identity.
-- Local owns its bindings; Driver resolves finite unit demands; FileCommit is
-- the ONLY publisher. No nested Local ledger or single-owner transaction path.
local Source=require("SpellHotReload.Source.FileAnalysis")
local Versions=require("SpellHotReload.Adapters.Card.CardVersions")
local Files=require("SpellHotReload.Pipeline.FileVersions")
local Binding=require("SpellHotReload.Adapters.Card.PracticeBinding")
local Card={name="Card",Id="card",ContractVersion=7}
local CALLBACKS={"before","init","frame","render","beforedel","del","after"}
local VIEW="SpellHotReload.Card.View"
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function integer(v) return type(v)=="number" and v>=1 and v<math.huge and v==math.floor(v) end
local function dense(v)
    if not plain(v) then return nil end
    local count,max=0,0
    for key in next,v do if not integer(key) then return nil end;count=count+1;max=math.max(max,key) end
    if count==max then return count end
end
local function fail(phase,code,message,context)
    return nil,{phase=phase,code=code,message=message,file=plain(context) and plain(context.common) and context.common.file}
end
local function names_of(map)
    local names = {}
    if type(map) == "table" then
        for name in pairs(map) do names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

-- Source keys belong to this discovery; actual identity comes from capture.
function Card.Match(cursor,common)
    local desc,err=require("SpellHotReload.Adapters.Card.CardCallbacks").Match(cursor,common.source)
    if not desc then return nil,err end
    local key="card:@"..desc.first
    local unit={key=key,carrier="card",context={descriptor=desc}}
    local claims={{kind="constructor",key=key,unit_key=key}}
    for _,name in ipairs(names_of(desc.callbacks)) do claims[#claims+1]={kind="callback",key=key..":"..name,unit_key=key} end
    return {units={unit},claims=claims,mappings={{unit=unit,first=desc.first,last=desc.last}}}
end
function Card.BuildContext(source,units)
    return require("SpellHotReload.Adapters.Card.CardCallbacks").Layout(source,units)
end

function Card.FreezeBinding(current)
    local names
    if type(current.names) == "table" then
        names = {};for i,value in ipairs(current.names) do names[i] = value end
    end
    return {class_key=current.class_key,card=current.card,slot=current.slot,name=current.name,
        mode=current.mode,names=names,include_previous=current.include_previous}
end

function Card.InspectionBindingMatches(record, current, classes)
    local binding = record.binding
    local valid = current ~= nil and classes == record.classes
        and rawget(record.classes,binding.class_key) == record.class
        and rawget(record.class,"cards") == record.list and rawget(record.list,binding.slot) == binding.card
    if valid then
        for _, field in ipairs({"class_key","card","slot","name","mode","include_previous"}) do
            if current[field] ~= binding[field] then valid = false;break end
        end
        if valid then
            if type(current.names) ~= "table" or #current.names ~= #binding.names then valid = false
            else
                for i,name in ipairs(binding.names) do
                    if current.names[i] ~= name then valid = false;break end
                end
            end
        end
    end
    return valid
end

function Card.CaptureOwnership(match, classes, entry)
    local function fail(code, detail, e, key)
        return nil, {phase="capture", code=code, message=detail,
            file=plain(e) and rawget(e,"file") or nil, unit_key=key}
    end
    local owners, ownership, seen = {}, {}, {}
    for _, ctx in ipairs(match.classes) do
        local cls = rawget(classes, ctx.class_key)
        local list = plain(cls) and rawget(cls, "cards") or nil
        if not plain(cls) or dense(list) ~= #ctx.layout then
            return fail("ownership", "first-load class/list layout unavailable", entry, ctx.class_key)
        end
        local slots = {}
        ownership[#ownership + 1] = {
            class_key = ctx.class_key, class = cls, list = list, slots = slots }
        for slot, descriptor in ipairs(ctx.layout) do
            local card = rawget(list, slot)
            if not plain(card) or seen[card] then
                return fail("ownership", "invalid or multiply owned first-load card", entry, ctx.class_key)
            end
            seen[card], slots[slot] = true, card
            if descriptor.kind == "card" and descriptor.callbacks.init then
                if rawget(card, "is_combat") ~= true then
                    return fail("ownership", "combat descriptor does not own a combat card", entry, ctx.class_key)
                end
                local callbacks = {}
                for _, name in ipairs(CALLBACKS) do callbacks[name] = rawget(card, name) end
                owners[#owners + 1] = { class_key = ctx.class_key, slot = slot,
                    card = card, callbacks = callbacks }
            end
        end
    end
    return owners, ownership
end


-- Called only by genuine first-load orchestration. It contributes Card's
-- records; the caller atomically adopts the COMPLETE owner contribution set.
function Card.Capture(entry,session,local_group,class_group,classes,defaults,snapshot)
    if not plain(entry) or not Source.Validate(entry.source) then return fail("capture","ownership","genuine complete load required") end
    local match,err=require("SpellHotReload.Pipeline.FileMatch").ForOwner(snapshot,Card,entry.source)
    if not match then return fail("capture","ownership",err) end
    if #match.classes==0 then return Versions.Empty(Card,entry,session,match) end
    if not plain(classes) or not plain(defaults) then return fail("capture","ownership","first-load registry and defaults required") end
    local owners,ownership=Card.CaptureOwnership(match,classes,entry)
    if not owners then return nil,ownership end
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Class=require("SpellHotReload.Adapters.Class.Class")
    return Versions.Seed(Card,entry,session,match,owners,ownership,classes,defaults,
        function(binding) return Local.CapturedProvider(local_group,binding) end,
        function(key) return Class.CapturedProvider(class_group,key) end)
end
function Card.CaptureCurrent() return Binding.CaptureCurrent() end
function Card.IsReplay() return Binding.IsReplay() end
function Card.CheckCandidateSource(content,file)
    return require("SpellHotReload.Adapters.Card.GeneratedBossScanner").Scan(content,file)
end
function Card.DefinesCurrent(discovery,current,capture)
    -- Candidate keys route new definitions; captured ownership keeps old-only
    -- classes visible to reconciliation. Neither route is live Locate permission.
    local matched=discovery.snapshot.adapter_contexts.card
    if matched and matched.by_class[current.class_key] then return true end
    local group=Files.GetAdapterRecords(capture,Card)
    if group then
        for _,key in ipairs(group.state.order) do
            local unit=group.state.units[key]
            if unit.class_key==current.class_key and unit.slot==current.slot and unit.card==current.card then return true end
        end
    end
    return false
end
function Card.Reconcile(previous,candidate,context)
    return require("SpellHotReload.Adapters.Card.CardReconcile").Run(previous,candidate,context)
end
function Card.Roots(view)
    if not plain(view) or view.kind~=VIEW or not plain(view.base) then return {} end
    local roots={}
    for _,key in ipairs(view.base.order) do
        roots[#roots+1]={root_id=key,unit_ref=view.by_key[key].unit_ref,selector=view.selectors[key]}
    end
    return roots
end
-- Caller freezes this target for the operation; live candidate_slot is never
-- treated as identity or as a restart slot. CurrentRestart consumes a later proof.
function Card.CurrentRoot(view,binding,capture,live)
    if not plain(view) or view.kind~=VIEW or not plain(view.base_group) then return fail("locate","ownership","original Card view required") end
    local target,err=require("SpellHotReload.Adapters.Card.CardTarget").Resolve(binding,capture,live)
    if not target then return nil,err end
    local item=view.by_key[target.key]
    if target.card_group~=view.base_group or not item then return fail("locate","ownership","current target is outside original Card view") end
    return {root_id=target.key,unit_ref=item.unit_ref,selector=view.selectors[target.key]},target
end
local function scope(context)
    if not plain(context) or not plain(context.common) or not plain(context.operation) or not plain(context.view)
        or context.view.kind~=VIEW or context.view.version~=1 or context.view.source~=context.operation.source
        or context.common.source~=context.view.source or context.view.discovery.common~=context.common then return false end
    local group=Files.GetAdapterRecords(context.operation.capture,Card)
    return group==context.view.base_group and group==context.base_group
        and context.operation.base_snapshot==context.operation.capture.snapshot
end
-- Operation-lifetime LIVE correspondence proof, never a reusable scan cache.
-- It is revalidated in both final Guards even for a read-only/empty Card owner.
local function locate(view,op)
    if view.runtime then
        if view.runtime.operation~=op then return fail("locate","ownership","Card view already belongs to another operation") end
        return view.runtime
    end
    local input=op.card
    if not plain(input) or type(input.refresh)~="function"
        or (op.mode~="file" and op.mode~="current" and op.mode~="inspect")
        or (op.mode=="file" and input.target~=nil) or (op.mode~="file" and not plain(input.target)) then
        return fail("locate","ownership","explicit Card operation and trusted fresh read required")
    end
    local live,err=input.refresh()
    if not live then return nil,err end
    if not plain(live) or live.content~=op.source.content or live.generation~=op.generation then
        return fail("locate","stale","fresh Card candidate bytes or generation changed")
    end
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local file_location,why=Target.LocateFileDiscovery(view.discovery,op.capture,live)
    if not file_location then return nil,why end
    local current_location
    if input.target then
        current_location,why=Target.LocateDiscovery(input.target,view.discovery,live.binding,op.capture,live)
        if not current_location then return nil,why end
        local row=file_location.by_key[input.target.key]
        if not row or row.status~="located" or row.descriptor~=current_location.descriptor
            or row.candidate_slot~=current_location.candidate_slot then
            return fail("locate","ambiguous","current candidate has no unique file correspondence")
        end
    end
    local rows,rerr=require("SpellHotReload.Adapters.Card.CardReconcile").Index(op.capture,view.discovery)
    if not rows then return nil,rerr end
    local compared,cerr=Versions.Compare(view.base_group,view.initial,view.source,view.match,file_location,rows)
    if not compared then return nil,cerr end
    local runtime={operation=op,mode=op.mode,input=input,refresh=input.refresh,target=input.target,live=live,
        file_location=file_location,current_location=current_location,version_view=compared}
    view.runtime=runtime;return runtime
end
function Card.Locate(unit,context)
    if not scope(context) or context.scope~="unit" or context.phase~="locate" or not plain(unit)
        or context.view.by_ref[unit.unit_ref]~=unit.private_ref or unit.private_ref.unit~=unit then
        return fail("locate","ownership","original single-card unit and scope required",context)
    end
    local runtime,err=locate(context.view,context.operation)
    if not runtime then return nil,err end
    return {kind="SpellHotReload.Card.Handle",version=1,operation=context.operation,view=context.view,
        unit=unit,item=unit.private_ref,runtime=runtime}
end
local function resolve(handle,unit,context)
    local view,request,item=context.view,context.request,unit.private_ref
    if not plain(handle) or handle.kind~="SpellHotReload.Card.Handle" or handle.operation~=context.operation
        or handle.view~=view or handle.unit~=unit or handle.item~=item or handle.runtime~=view.runtime
        or not plain(request) or request.operation~=context.operation or request.view~=view or request.unit_ref~=unit.unit_ref
        or type(request.root_id)~="string" or dense(request.conditions)~=0 then
        return fail("resolve","ownership","exact Card unit handle and finite private selector required",context)
    end
    local key=item.selectors[request.selector]
    local runtime=view.runtime
    if not key or runtime.target and runtime.target.key~=key then return fail("resolve","ownership","foreign Card member selector",context) end
    local selected,err=Versions.Resolve(runtime.version_view,key)
    if not selected then return {blocked=err,needs={},affected={},source_facts={}} end
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Class=require("SpellHotReload.Adapters.Class.Class")
    local local_view,class_view
    for _,group in ipairs(view.discovery.reconciliation.groups) do
        if group.owner==Local and not group.reason then local_view=group.view end
        if group.owner==Class and not group.reason then class_view=group.view end
    end
    local choice={view=view,item=item,key=key,root_id=request.root_id,resolved=selected,demands={}}
    local needs,facts={},{}
    local parent=Class.Requirement(class_view,selected.item.previous.class_ref)
    if not parent then return {blocked={code="ownership",message="original Spell Class provider unavailable"},needs={},affected={},source_facts={}} end
    local parent_need={root_id=request.root_id,provider_unit=parent.unit_ref,condition_ref=parent.condition_ref,cause_ref=choice}
    needs[#needs+1]=parent_need;choice.demands[#choice.demands+1]=parent_need
    for _,ref in ipairs(selected.providers) do
        local provider=Local.Requirement(local_view,ref)
        if not provider then return fail("resolve","ownership","original callback provider domain unavailable",context) end
        local demand={root_id=request.root_id,provider_unit=provider.unit_ref,condition_ref=provider.condition_ref,cause_ref=choice}
        needs[#needs+1]=demand;choice.demands[#choice.demands+1]=demand
    end
    for _,name in ipairs(CALLBACKS) do
        local cb=selected.callbacks[name]
        if cb~=selected.item.previous.callbacks[name] and cb.syntax then facts[#facts+1]={source=view.source,node=cb.syntax} end
    end
    view.choices[request.root_id]=view.choices[request.root_id] or {}
    view.choices[request.root_id][unit.unit_ref]=choice
    return {selection_ref=choice,needs=needs,affected=selected.changed and {unit.unit_ref} or {},source_facts=facts}
end
local function owner_handle(handle,context)
    return plain(handle) and handle.kind=="SpellHotReload.Driver.OwnerHandle" and handle.version==1
        and handle.operation==context.operation and handle.owner==Card and handle.base_group==context.base_group
        and handle.view==context.view and plain(handle.by_ref)
end
local function same(a,b)
    if not plain(a) or not plain(b) or #a~=#b then return false end
    for i,v in ipairs(a) do if v~=b[i] then return false end end;return true
end
local function guard(fragment,capture,live)
    local view,runtime,plan=fragment.card_view,fragment.card_runtime,fragment.card_plan
    local group=Files.GetAdapterRecords(capture,Card);local op=fragment.operation
    if not plain(view) or not plain(runtime) or not plain(plan) or group~=view.base_group or group~=fragment.base_group
        or plan.view~=runtime.version_view or view.runtime~=runtime or fragment.owner~=Card
        or not plain(op) or op.capture~=capture or op.base_snapshot~=capture.snapshot or op.source~=view.source
        or op.mode~=runtime.mode or op.generation~=runtime.file_location.generation
        or op.card~=runtime.input or op.card.refresh~=runtime.refresh or op.card.target~=runtime.target
        or not plain(live) or live.entry~=view.base.entry or live.session_id~=view.base.session_id then
        return fail("commit","stale","Card original scope, operation or runtime changed")
    end
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local ok,err=Target.CheckFileDiscovery(runtime.file_location,capture,live)
    if not ok then return nil,err end
    if runtime.current_location then
        ok,err=Target.CheckDiscovery(runtime.current_location,live.binding,capture,live)
        if not ok then return nil,err end
    end
    ok,err=Versions.Guard(plan,live.classes)
    if not ok then return nil,err end
    -- The public unit is one card; callbacks remain its private members. Read the separate semantic publications, not
    -- the caller's raw_writes array, so sealing still isolates later mutation.
    if dense(fragment.raw_writes)==nil or dense(plan.publications)==nil
        or #fragment.raw_writes~=#plan.publications then
        return fail("commit","ownership","Card callback action set changed",{common=op})
    end
    local positions={}
    for i,pub in ipairs(plan.publications) do
        local unit=plain(pub) and view.base.units[pub.unit_key]
        local old=plain(unit) and plain(unit.callbacks) and unit.callbacks[pub.key]
        local cb=plain(pub) and pub.callback
        local selected=plain(pub) and plan.selected[pub.unit_key]
        local write=fragment.raw_writes[i]
        if not plain(pub) or not plain(write) or not plain(old) or not plain(cb)
            or not plain(selected) or selected.callbacks[pub.key]~=cb
            or pub.target~=unit.card or pub.before~=old.fn or cb.previous~=old or pub.value~=cb.fn
            or write.owner~=Card or write.unit_ref~=unit.unit_ref
            or write.target~=pub.target or write.key~=pub.key
            or write.before~=pub.before or write.value~=pub.value then
            return fail("commit","ownership","Card callback publication action changed",{common=op})
        end
        local keys=positions[unit.card]
        if not keys then keys={};positions[unit.card]=keys end
        if keys[pub.key] then return fail("commit","ownership","duplicate Card callback action",{common=op}) end
        keys[pub.key]=true
    end
    ok,err=require("SpellHotReload.Adapters.Card.CardReconcile").CheckPublications(plan,capture,live,view.discovery)
    if not ok then return nil,err end
    if plan.requires_file_check then
        -- The full FileApply proof is produced only after every owner prepared.
        local FileApply=require("SpellHotReload.Apply.FileApply")
        ok,err=FileApply.CheckDeletions(op,plan,live)
        if not ok then return nil,err end
    end
    -- Compare the sealed proposal with the already prepared selections. Do not
    -- rebuild a complete Card projection during either final Guard pass.
    local actual=fragment.proposed_group
    if not plain(actual) or actual.owner~=Card or #actual.units~=#view.base_group.units
        or #actual.records~=#view.base_group.records then return fail("commit","ownership","Card proposed projection changed",{common=op}) end
    for _,key in ipairs(view.base.order) do
        local old=view.base.units[key];local unit=actual.state.units[key]
        local selected=plan.selected[key];local advanced=false
        if not plain(unit) or unit.card~=old.card or unit.unit_ref~=old.unit_ref or unit.class_ref~=old.class_ref then
            return fail("commit","ownership","Card proposed unit changed",{common=op})
        end
        for _,name in ipairs(CALLBACKS) do
            local previous=old.callbacks[name]
            local expected=selected and selected.callbacks[name] or previous
            local changed=expected~=previous;advanced=advanced or changed
            local callback=unit.callbacks[name]
            if not plain(callback) or callback.fn~=expected.fn or callback.body~=expected.body or callback.signature~=expected.signature
                or callback.definition_version~=previous.definition_version+(changed and 1 or 0)
                or not same(callback.dependencies,expected.dependencies) or not same(callback.visible,expected.visible) then
                return fail("commit","ownership","Card proposed callback changed",{common=op})
            end
            for _,dep in ipairs(expected.dependencies) do
                if callback.providers[dep]~=expected.providers[dep] then return fail("commit","ownership","Card proposed provider changed",{common=op}) end
            end
        end
        if unit.definition_version~=old.definition_version+(advanced and 1 or 0) then return fail("commit","ownership","Card proposed unit changed",{common=op}) end
    end
    return true
end
function Card.Inject(handle,unit,context)
    if not scope(context) then return fail("inject","ownership","Card operation view required",context) end
    if context.scope=="unit" and context.phase=="resolve" then
        if not plain(unit) or context.view.by_ref[unit.unit_ref]~=unit.private_ref then return fail("resolve","ownership","original Card unit required",context) end
        return resolve(handle,unit,context)
    end
    if context.scope~="owner" or unit~=nil or not owner_handle(handle,context) then
        return fail("inject","ownership","Card exact owner aggregation required",context)
    end
    local runtime,err=locate(context.view,context.operation)
    if not runtime then return nil,err end
    if context.phase=="resolve" then
        local proof,why=Versions.Constraints(runtime.version_view,context.dependencies)
        if not proof then return nil,why end
        return {operation=context.operation,owner=Card,blocked_roots=proof.blocked_roots,evidence=proof}
    end
    local selection,view=context.selection,context.view
    if context.phase~="prepare" or not plain(selection) or selection.owner~=Card or selection.view~=view
        or selection.base_group~=view.base_group or dense(selection.units)==nil or not plain(context.constraints)
        or context.constraints.operation~=context.operation or context.constraints.owner~=Card then
        return fail("inject","ownership","Card final pruned selection and constraints required",context)
    end
    local selected,seen_refs={},{}
    for _,record in ipairs(selection.units) do
        local item=plain(record) and view.by_ref[record.unit_ref]
        local location=item and handle.by_ref[record.unit_ref]
        if not item or record.unit_view~=item.unit or not location or location.unit~=item.unit or seen_refs[record.unit_ref]
            or dense(record.roots)==nil or #record.roots==0 then return fail("inject","ownership","Card final unit lacks exact location",context) end
        seen_refs[record.unit_ref]=true
        for _,root in ipairs(record.roots) do
            local choice=plain(root) and root.selection_ref
            if not plain(choice) or choice.view~=view or choice.item~=item or choice.root_id~=root.root_id
                or root.selector~=view.selectors[choice.key] or not view.choices[root.root_id]
                or view.choices[root.root_id][record.unit_ref]~=choice then return fail("inject","ownership","Card private selection changed",context) end
            -- Every originally routed provider must survive for this SAME root.
            for _,demand in ipairs(choice.demands) do
                local found=false
                for _,owner in ipairs(context.dependencies.owners) do
                    for _,provider in ipairs(owner.units) do
                        if provider.unit_ref==demand.provider_unit then
                            for _,path in ipairs(provider.roots) do
                                if path.root_id==root.root_id then
                                    for _,token in ipairs(path.conditions) do if token==demand.condition_ref then found=true end end
                                end
                            end
                        end
                    end
                end
                if not found then return fail("inject","ownership","Card root lost required provider",context) end
            end
            selected[choice.key]=true
        end
    end
    local keys={};for _,key in ipairs(view.base.order) do if selected[key] then keys[#keys+1]=key end end
    local registry_reads,why=Versions.RetainConstraints(runtime.version_view,context.constraints.evidence,context.dependencies)
    if not registry_reads then return nil,why end
    local plan,perr=Versions.Prepare(runtime.version_view,keys,registry_reads)
    if not plan then return nil,perr end
    local proposed=Versions.Next(plan)
    local coverage,cerr=Versions.Coverage(runtime.version_view,plan)
    if not coverage then return nil,cerr end
    return {operation=context.operation,owner=Card,base_group=view.base_group,proposed_group=proposed,
        file_evidence=coverage,joins=plan.joins,cell_writes=plan.cell_writes,raw_writes=plan.raw_writes,read_set=plan.read_set,capture_reads=plan.capture_reads,
        owner_guard=guard,card_view=view,card_runtime=runtime,card_plan=plan}
end
function Card.Commit(handle,fragment,context)
    if not scope(context) or not owner_handle(handle,context) or not plain(fragment) or fragment.owner~=Card
        or fragment.operation~=context.operation or fragment.base_group~=context.base_group
        or type(context.adapter.register)~="function" then return fail("register","ownership","Card exact fragment registration required",context) end
    return context.adapter.register(handle,fragment,context)
end

-- Private description of Card's final member selection, never Local records.
function Card.Describe(fragment,inspection)
    if not plain(fragment) or fragment.owner~=Card or not plain(inspection) or not plain(fragment.operation)
        or not plain(fragment.card_view) or not plain(fragment.card_plan) or not plain(fragment.card_runtime)
        or inspection.operation~=fragment.operation or inspection.snapshot~=fragment.operation.base_snapshot
        or fragment.base_group~=fragment.card_view.base_group
        or fragment.card_plan.view~=fragment.card_runtime.version_view then
        return fail("describe","ownership","original Card inspection fragment required")
    end
    return Versions.Describe(fragment.card_plan,inspection.snapshot,inspection.impact,inspection.dependencies)
end

return Card
