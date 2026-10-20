-- Finite, root-attributed routing between owner-private unit selections.
-- No source scans, member names, closure construction or live publication here.
local Files=require("SpellHotReload.Pipeline.FileVersions")
local Source=require("SpellHotReload.Source.FileAnalysis")
local M={Kind="SpellHotReload.DependencySelection",Version=1}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function text(v) return type(v)=="string" and v~="" end
local function dense(v)
    if not plain(v) then return false end
    local n,max=0,0
    for k in next,v do
        if type(k)~="number" or k<1 or k>=math.huge or k~=math.floor(k) then return false end
        n=n+1;max=math.max(max,k)
    end
    return n==max
end
local function fail(op,code,message,root_id)
    return nil,{phase="resolve",code=code,message=message,
        file=plain(op) and op.file,root_id=root_id}
end
local function problem(v) return plain(v) and text(v.code) and text(v.message) end
local function append(t,v) t[#t+1]=v end
-- Views are operation-owned and read-only by contract. Original unit references
-- survive publication; candidate keys/names are never public graph identities.
local function domain(op,report)
    if not plain(op) or not Files.Validate(op.capture) or op.base_snapshot~=op.capture.snapshot
        or op.file~=op.base_snapshot.file or op.session_id~=op.base_snapshot.session_id
        or op.entry~=op.base_snapshot.entry or op.anchor~=op.base_snapshot.anchor
        or not Source.Validate(op.source) or not plain(report)
        or report.kind~="SpellHotReload.Reconciliation" or report.version~=1
        or report.problem~=nil or report.published~=false or not plain(report.snapshot)
        or report.snapshot.reconciliation~=report or not plain(report.snapshot.common)
        or report.snapshot.common.source~=op.source or report.revision~=op.base_snapshot.revision
        or report.file~=op.file or not plain(report.publication)
        or report.publication.entry~=op.entry or report.publication.session_id~=op.session_id
        or report.publication.revision~=op.base_snapshot.revision
        or not dense(report.groups) or #report.groups~=#op.base_snapshot.owners then
        return fail(op,"ownership","fresh complete operation reconciliation required")
    end
    local by_ref,owners,tokens={},{},{}
    for i,group in ipairs(op.base_snapshot.owners) do
        local output=report.groups[i]
        local previous=plain(output) and output.previous
        if not plain(output) or output.owner~=group.owner or output.owner_id~=group.owner_id
            or output.reason~=nil or not plain(previous) or previous.owner~=group.owner
            or previous.state~=group.state or previous.records~=group.records
            or not plain(output.view) or not dense(output.units) or not dense(output.exports) then
            return fail(op,"ownership","original owner view unavailable or replaced")
        end
        local owned,records,seen_records,seen_refs={},{},{},{}
        for _,unit in ipairs(group.units) do owned[unit.unit_ref]=true end
        for _,record in ipairs(group.records) do records[record]=true end
        local owner={owner=group.owner,base_group=group,view=output.view,output=output,units={}}
        owners[i]=owner
        for _,unit in ipairs(output.units) do
            if not plain(unit) or not plain(unit.private_ref) or not text(unit.status)
                or not dense(unit.previous_records) then
                return fail(op,"ownership","explicit owner unit correspondence required")
            end
            local ref,entry=unit.unit_ref,unit.candidate_entry
            if ref~=nil and (not owned[ref] or seen_refs[ref]) then
                return fail(op,"ownership","duplicate or foreign published unit")
            end
            if entry~=nil and (not plain(entry) or entry.adapter~=group.owner
                or not plain(entry.unit) or report.snapshot.by_key[entry.unit.key]~=entry) then
                return fail(op,"ownership","foreign candidate unit correspondence")
            end
            if ref==nil and (entry==nil or #unit.previous_records~=0) then
                return fail(op,"ownership","candidate-only unit cannot acquire original records")
            end
            for _,record in ipairs(unit.previous_records) do
                if not records[record] or seen_records[record] or ref==nil then
                    return fail(op,"ownership","unit record correspondence omitted or reused")
                end
                seen_records[record]=true
            end
            if ref~=nil then
                local previous_records={}
                for _,record in ipairs(unit.previous_records) do append(previous_records,record) end
                local item={unit_ref=ref,unit_view=unit,owner=owner,conditions={},condition_set={},
                    private_ref=unit.private_ref,status=unit.status,candidate_entry=entry,previous_records=previous_records}
                seen_refs[ref]=true;by_ref[ref]=item;append(owner.units,item)
            end
        end
        for ref in next,owned do
            if not seen_refs[ref] then return fail(op,"ownership","published unit omitted from owner view") end
        end
        for record in next,records do
            if not seen_records[record] then return fail(op,"ownership","published record omitted from owner units") end
        end
        local exported={}
        for _,export in ipairs(output.exports) do
            local ref=plain(export) and export.unit_ref
            local item=by_ref[ref]
            if not item or item.owner~=owner or exported[ref] or not dense(export.conditions) then
                return fail(op,"ownership","one finite export domain per provider required")
            end
            exported[ref]=true
            for _,condition in ipairs(export.conditions) do
                if not plain(condition) or tokens[condition] then
                    return fail(op,"ownership","condition tokens must belong to one exact provider")
                end
                tokens[condition]=ref;item.condition_set[condition]=true;append(item.conditions,condition)
            end
        end
        for ref in next,owned do
            if not exported[ref] then return fail(op,"ownership","provider finite domain omitted") end
        end
    end
    return {by_ref=by_ref,owners=owners,tokens=tokens,scope={
        file=op.file,session_id=op.session_id,entry=op.entry,anchor=op.anchor,source=op.source,
        capture=op.capture,base_snapshot=op.base_snapshot,generation=op.generation,mode=op.mode,
        report=report,snapshot=report.snapshot,publication=report.publication}}
end
local function same_list(a,b)
    if #a~=#b then return false end
    for i,v in ipairs(a) do if v~=b[i] then return false end end
    return true
end
local function same_domain(a,b)
    for key,value in next,a.scope do if b.scope[key]~=value then return false end end
    for key,value in next,b.scope do if a.scope[key]~=value then return false end end
    if #a.owners~=#b.owners then return false end
    for i,owner in ipairs(a.owners) do
        local other=b.owners[i]
        if owner.owner~=other.owner or owner.base_group~=other.base_group or owner.view~=other.view
            or owner.output~=other.output or #owner.units~=#other.units then return false end
        for n,item in ipairs(owner.units) do
            local current=other.units[n]
            if item.unit_ref~=current.unit_ref or item.unit_view~=current.unit_view
                or item.private_ref~=current.private_ref or item.status~=current.status
                or item.candidate_entry~=current.candidate_entry
                or not same_list(item.previous_records,current.previous_records)
                or not same_list(item.conditions,current.conditions) then return false end
        end
    end
    return true
end
-- resolve(owner, unit_view, request) dispatches the owner's explicit Inject
-- resolve phase through Driver. request.conditions is cumulative and finite;
-- cause_ref is routed evidence, never a callback/member selector interpreted here.
function M.Resolve(operation,report,roots,resolve)
    local index,err=domain(operation,report)
    if not index then return nil,err end
    if not dense(roots) or type(resolve)~="function" then
        return fail(operation,"ownership","dense explicit roots and resolver required")
    end
    local root_list,root_ids={},{}
    -- Validate ALL roots before the first owner hook. Snapshot the root envelope;
    -- selectors stay opaque, owner-private, read-only operation objects.
    for _,root in ipairs(roots) do
        if not plain(root) or not text(root.root_id) or root_ids[root.root_id]
            or not index.by_ref[root.unit_ref] or not plain(root.selector) then
            return fail(operation,"ownership","unique original root and private selector required")
        end
        local r={root_id=root.root_id,unit_ref=root.unit_ref,selector=root.selector,nodes={}}
        append(root_list,r);root_ids[root.root_id]=r
    end
    local queue,head={},1
    local function enqueue(root,ref,condition,consumer,cause)
        local node=root.nodes[ref]
        if not node then
            node={root=root,item=index.by_ref[ref],conditions={},causes={},queued=false,initial=false}
            root.nodes[ref]=node
        end
        local added=false
        if condition==nil then
            if not node.initial then node.initial=true;added=true end
        elseif not node.conditions[condition] then node.conditions[condition]=true;added=true end
        if consumer then append(node.causes,{consumer_unit=consumer,condition_ref=condition,cause_ref=cause}) end
        if added and not node.queued then node.queued=true;append(queue,node) end
        return node
    end
    for _,root in ipairs(root_list) do enqueue(root,root.unit_ref) end
    local edges,seeds={},{}
    while head<=#queue do
        local node=queue[head];head=head+1;node.queued=false
        local root,item=node.root,node.item
        if not root.blocked then
            local conditions={}
            for _,token in ipairs(item.conditions) do
                if node.conditions[token] then append(conditions,token) end
            end
            local causes={}
            for _,cause in ipairs(node.causes) do
                append(causes,{consumer_unit=cause.consumer_unit,condition_ref=cause.condition_ref,cause_ref=cause.cause_ref})
            end
            local request={operation=operation,view=item.owner.view,root_id=root.root_id,
                unit_ref=item.unit_ref,conditions=conditions,causes=causes,
                selector=item.unit_ref==root.unit_ref and root.selector or nil}
            local called,result,why=pcall(resolve,item.owner.owner,item.unit_view,request)
            if not called then return fail(operation,"ownership","owner resolve threw",root.root_id) end
            if result==nil then return nil,problem(why) and why
                or select(2,fail(operation,"ownership","owner resolve refused without diagnostic",root.root_id)) end
            if not plain(result) or not dense(result.needs) or not dense(result.affected)
                or not dense(result.source_facts or {})
                or result.blocked~=nil and not problem(result.blocked)
                or result.blocked==nil and not plain(result.selection_ref)
                or result.blocked~=nil and (result.selection_ref~=nil or #result.needs~=0) then
                return fail(operation,"ownership","invalid owner resolution",root.root_id)
            end
            -- Validate the entire result before routing any of it. A malformed
            -- unrelated endpoint cannot disappear behind a blocked root.
            for _,need in ipairs(result.needs) do
                if not plain(need) or need.root_id~=root.root_id
                    or not index.by_ref[need.provider_unit] or not plain(need.cause_ref)
                    or index.tokens[need.condition_ref]~=need.provider_unit then
                    return fail(operation,"ownership","foreign root/provider or out-of-domain condition",root.root_id)
                end
            end
            for _,ref in ipairs(result.affected) do
                if not index.by_ref[ref] then return fail(operation,"ownership","foreign affected unit",root.root_id) end
            end
            local facts={}
            for _,fact in ipairs(result.source_facts or {}) do
                if not plain(fact) or fact.source~=operation.source or not plain(fact.node)
                    or operation.source.sites[fact.node]==nil then
                    return fail(operation,"ownership","foreign selected syntax fact",root.root_id)
                end
                append(facts,{source=operation.source,node=fact.node,unit_ref=item.unit_ref,root_id=root.root_id})
            end
            node.source_facts=facts
            node.selection_ref=result.selection_ref
            if result.blocked then root.blocked=result.blocked end
            for _,ref in ipairs(result.affected) do seeds[ref]=true end
            for _,need in ipairs(result.needs) do
                append(edges,{consumer=item.unit_ref,provider=need.provider_unit,root_id=root.root_id})
                enqueue(root,need.provider_unit,need.condition_ref,item.unit_ref,need.cause_ref)
            end
        end
    end
    -- Input/capability identity can change during owner hooks; all final owner
    -- guards and mechanical reads still run at Commit, including no-write owners.
    local current,scope_error=domain(operation,report)
    if not current then return nil,scope_error end
    if not same_domain(index,current) then
        return fail(operation,"ownership","owner domain changed during resolution")
    end
    local owners,safe,blocked,source_facts={},{},{},{}
    for i,owner in ipairs(index.owners) do
        owners[i]={owner=owner.owner,base_group=owner.base_group,view=owner.view,units={}}
        for _,item in ipairs(owner.units) do
            local choices={}
            for _,root in ipairs(root_list) do
                local node=root.nodes[item.unit_ref]
                if not root.blocked and node then
                    if not plain(node.selection_ref) then return fail(operation,"ownership","unresolved required unit",root.root_id) end
                    local conditions={}
                    for _,token in ipairs(item.conditions) do if node.conditions[token] then append(conditions,token) end end
                    for _,fact in ipairs(node.source_facts) do append(source_facts,fact) end
                    append(choices,{root_id=root.root_id,selector=item.unit_ref==root.unit_ref and root.selector or nil,
                        selection_ref=node.selection_ref,conditions=conditions})
                end
            end
            if #choices>0 then append(owners[i].units,{unit_ref=item.unit_ref,unit_view=item.unit_view,roots=choices}) end
        end
    end
    for _,root in ipairs(root_list) do
        if root.blocked then append(blocked,{root_id=root.root_id,unit_ref=root.unit_ref,reason=root.blocked})
        else append(safe,{root_id=root.root_id,unit_ref=root.unit_ref,selector=root.selector}) end
    end
    -- Actual edges are complete. Candidate edges below cover requested paths
    -- only; affected observations never enlarge installation selections/versions.
    local reverse={}
    local function edge(e)
        local list=reverse[e.provider] or {};reverse[e.provider]=list;list[e.consumer]=true
    end
    for _,e in ipairs(operation.base_snapshot.graph) do edge(e) end
    for _,e in ipairs(edges) do edge(e) end
    local impact,work={},{}
    for ref in next,seeds do impact[ref]=true;append(work,ref) end
    local n=1
    while n<=#work do
        local ref=work[n];n=n+1
        for consumer in next,reverse[ref] or {} do
            if not impact[consumer] then impact[consumer]=true;append(work,consumer) end
        end
    end
    local affected={}
    for _,owner in ipairs(index.owners) do
        for _,item in ipairs(owner.units) do if impact[item.unit_ref] then append(affected,item.unit_ref) end end
    end
    return {kind=M.Kind,version=M.Version,operation=operation,report=report,
        owners=owners,safe_roots=safe,blocked_roots=blocked,affected=affected,
        candidate_edges=edges,candidate_scope="requested",source_facts=source_facts,stable=true}
end
-- Owner-wide business constraints may REMOVE roots only. Provider discovery is
-- already stable; no new dependency or synthetic public unit is admitted here.
function M.Restrict(selection,blocks)
    if not plain(selection) or selection.kind~=M.Kind or selection.version~=M.Version
        or selection.stable~=true or not dense(blocks) then
        return fail(nil,"ownership","stable selection and explicit root blocks required")
    end
    local known,dropped={},{}
    for _,root in ipairs(selection.safe_roots) do known[root.root_id]=root end
    for _,block in ipairs(blocks) do
        if not plain(block) or not known[block.root_id] or not problem(block.reason) then
            return fail(selection.operation,"ownership","constraint blocked a foreign/unsafe root")
        end
        if not dropped[block.root_id] then dropped[block.root_id]=block.reason end
    end
    local next_selection={}
    for key,value in next,selection do next_selection[key]=value end
    next_selection.owners={};next_selection.safe_roots={};next_selection.blocked_roots={};next_selection.source_facts={}
    for _,root in ipairs(selection.blocked_roots) do append(next_selection.blocked_roots,root) end
    for _,root in ipairs(selection.safe_roots) do
        if dropped[root.root_id] then append(next_selection.blocked_roots,
            {root_id=root.root_id,unit_ref=root.unit_ref,reason=dropped[root.root_id]})
        else append(next_selection.safe_roots,root) end
    end
    for _,owner in ipairs(selection.owners) do
        local group={owner=owner.owner,base_group=owner.base_group,view=owner.view,units={}}
        append(next_selection.owners,group)
        for _,unit in ipairs(owner.units) do
            local roots={}
            for _,root in ipairs(unit.roots) do if not dropped[root.root_id] then append(roots,root) end end
            if #roots>0 then append(group.units,{unit_ref=unit.unit_ref,unit_view=unit.unit_view,roots=roots}) end
        end
    end
    for _,fact in ipairs(selection.source_facts) do
        if not dropped[fact.root_id] then append(next_selection.source_facts,fact) end
    end
    return next_selection
end

-- Read-only presentation impact of the FINAL sealed publication proposal.
-- Resolve/Restrict observations can include paths later removed by owner rules;
-- final installation deltas and effective graph are the only seeds used here.
-- Public nodes remain units. Owners alone map class-units to private members.
function M.PublicationImpact(snapshot,deltas)
    if not plain(snapshot) or snapshot.kind~="SpellHotReload.FileSnapshot" or snapshot.version~=1
        or not dense(snapshot.owners) or not dense(snapshot.graph) or not dense(deltas)
        or #deltas~=#snapshot.owners then return fail(nil,"ownership","complete final publication graph/deltas required") end
    local owned,changed,affected,queue={},{},{},{}
    for i,group in ipairs(snapshot.owners) do
        local delta=deltas[i]
        if not plain(group) or not dense(group.units) or not plain(delta)
            or delta.owner~=group.owner or delta.owner_id~=group.owner_id or not dense(delta.unit_refs)
            or type(delta.changed)~="boolean" or delta.changed~=(#delta.unit_refs>0) then
            return fail(nil,"ownership","final owner delta disagrees with publication")
        end
        local local_refs={}
        for _,unit in ipairs(group.units) do
            local ref=plain(unit) and unit.unit_ref
            if not plain(ref) or ref.owner~=group.owner or owned[ref] then
                return fail(nil,"ownership","original publication units required")
            end
            owned[ref]=true;local_refs[ref]=true
        end
        for _,ref in ipairs(delta.unit_refs) do
            if not local_refs[ref] or changed[ref] then return fail(nil,"ownership","foreign or duplicate changed unit") end
            changed[ref],affected[ref]=true,true;append(queue,ref)
        end
    end
    local reverse={}
    for _,edge in ipairs(snapshot.graph) do
        if not plain(edge) or not owned[edge.consumer] or not owned[edge.provider] then
            return fail(nil,"ownership","foreign effective publication edge")
        end
        reverse[edge.provider]=reverse[edge.provider] or {};reverse[edge.provider][edge.consumer]=true
    end
    local head=1
    while head<=#queue do
        local ref=queue[head];head=head+1
        for consumer in next,reverse[ref] or {} do
            if not affected[consumer] then affected[consumer]=true;append(queue,consumer) end
        end
    end
    return {snapshot=snapshot,changed=changed,affected=affected}
end

return M
