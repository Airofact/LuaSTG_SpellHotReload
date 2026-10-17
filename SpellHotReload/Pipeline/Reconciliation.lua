-- Interpret actual publications against ONE complete successful discovery.
-- Tables are read-only by contract. This is evidence, never commit authority.
local Adapter=require("SpellHotReload.Pipeline.Adapter")
local M={Kind="SpellHotReload.Reconciliation",Version=1}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function text(v) return type(v)=="string" and v~="" end
local function integer(v,min) return type(v)=="number" and v>=min and v<math.huge and v==math.floor(v) end
local function dense(v)
    if not plain(v) then return nil end
    local n,max=0,0
    for k in next,v do if not integer(k,1) then return nil end;n=n+1;max=math.max(max,k) end
    if n==max then return n end
end
local function strings(v)
    if dense(v)==nil then return false end
    for _,s in ipairs(v) do if not text(s) then return false end end
    return true
end
local function failure(message,file)
    return nil,{phase="reconcile",code="unsupported",message=message,file=file}
end
local function validate(publication)
    if not plain(publication) or publication.kind~="SpellHotReload.Publication" or publication.version~=1
        or not text(publication.file) or not text(publication.session_id)
        or not integer(publication.revision,0) or type(publication.loaded_source)~="string"
        or not plain(publication.entry) or dense(publication.groups)==nil then return false end
    local owners,ids={},{}
    for _,group in ipairs(publication.groups) do
        -- Do not inspect current owner.Id: an unavailable/changed owner must
        -- retain its captured Id and records instead of becoming another owner.
        if not plain(group) or type(group.owner)~="table" or not text(group.owner_id)
            or owners[group.owner] or ids[group.owner_id] or not plain(group.state)
            or dense(group.records)==nil then return false end
        owners[group.owner],ids[group.owner_id]=true,true
        local keys={}
        for _,record in ipairs(group.records) do
            if not plain(record) or not text(record.key) or keys[record.key]
                or not text(record.kind) or not plain(record.definition)
                or not integer(record.definition_version,1)
                or record.definition.definition_version~=record.definition_version then return false end
            keys[record.key]=true
        end
    end
    return true
end
function M.ValidatePublication(publication) return validate(publication) end
local function unresolved(group,reason)
    local rows={}
    for _,record in ipairs(group.records) do
        rows[#rows+1]={status="unresolved",previous=record,reason=reason,
            evidence={},dependencies={},conditions={"resolve source and ownership before planning"}}
    end
    return rows
end
local function checked_rows(rows,group,snapshot)
    if dense(rows)==nil then return false end
    local old,seen={},{}
    for _,record in ipairs(group.records) do old[record]=true end
    for _,row in ipairs(rows) do
        if not plain(row) or not strings(row.evidence) or not strings(row.dependencies)
            or not strings(row.conditions) or not text(row.reason) then return false end
        local previous,candidate=row.previous,row.candidate
        if previous~=nil then
            if not old[previous] or seen[previous] then return false end
            seen[previous]=true
        end
        if candidate~=nil then
            local entry=plain(candidate) and candidate.entry
            if not plain(entry) or entry.adapter~=group.owner or not plain(entry.unit)
                or snapshot.by_key[entry.unit.key]~=entry then return false end
        end
        if row.status=="corresponding" then
            if not previous or not candidate or #row.evidence==0 or row.tombstone~=nil then return false end
        elseif row.status=="candidate-only" then
            if previous or not candidate or row.tombstone~=nil or #row.evidence==0 then return false end
        elseif row.status=="deleted" then
            local tombstone=row.tombstone
            if not previous or #row.evidence==0 or not plain(tombstone)
                or tombstone.owner~=group.owner or tombstone.owner_id~=group.owner_id
                or tombstone.previous~=previous
                or tombstone.definition_version~=previous.definition_version then return false end
        elseif row.status=="unresolved" or row.status=="ambiguous" then
            if not previous and not candidate then return false end
            if row.tombstone~=nil then return false end
        else return false end
    end
    for record in next,old do if not seen[record] then return false end end
    return true
end
---On analyze/Match/read failure, call with snapshot=nil and a nonempty problem.
---No hook runs; all previous records survive as unresolved. Missing file is an
---input failure, never a successful empty source. No publication cache lives here.
function M.Run(registry,publication,snapshot,problem)
    if not validate(publication) then return failure("complete actual publication required") end
    local file=publication.file
    local common=plain(snapshot) and snapshot.common
    if snapshot~=nil and (not plain(snapshot) or not plain(common) or problem~=nil
        or common.file~=file or common.session_id~=publication.session_id
        or common.registry_entry~=publication.entry or common.loaded_source~=publication.loaded_source
        or common.base_revision~=publication.revision or not plain(snapshot.by_key)
        or dense(snapshot.entries)==nil or not plain(snapshot.adapter_contexts)
        or common.analysis~=snapshot.analysis or type(common.content)~="string") then
        return failure("candidate and publication scope disagree",file)
    end
    if snapshot==nil and not text(problem) then return failure("explicit source failure required",file) end
    local ok,adapters=pcall(function() return registry:Discoveries() end)
    if not ok or dense(adapters)==nil then return failure("registered adapter enumeration required",file) end
    local registered={}
    for _,adapter in ipairs(adapters) do
        local id=type(adapter)=="table" and rawget(adapter,"Id")
        if text(id) then
            if registered[id] then return failure("duplicate registered owner",file) end
            registered[id]=adapter
        end
    end
    local groups,known={},{}
    for _,group in ipairs(publication.groups) do groups[#groups+1]=group;known[group.owner]=true end
    -- New adapters may interpret candidate additions, but never inherit another
    -- adapter's publications even when their registered Id/text is identical.
    if snapshot then
        for _,adapter in ipairs(adapters) do
            if not known[adapter] then groups[#groups+1]={owner=adapter,owner_id=rawget(adapter,"Id"),
                state={},records={}} end
        end
    end
    local report={kind=M.Kind,version=M.Version,file=file,publication=publication,
        snapshot=snapshot,problem=problem,revision=publication.revision,groups={},rows={},published=false}
    for _,group in ipairs(groups) do
        local available=registered[group.owner_id]==group.owner and Adapter.ValidateDiscovery(group.owner)
        local reason,rows
        if not snapshot then reason=problem
        elseif not available then reason="original adapter unavailable"
        else
            local context={common=common,publication=publication,previous=group,
                adapter=snapshot.adapter_contexts[group.owner_id]}
            local called,result=pcall(rawget(group.owner,"Reconcile"),group,snapshot,context)
            if called and checked_rows(result,group,snapshot) then rows=result
            else reason=called and "invalid reconciliation result" or "adapter reconciliation failed" end
        end
        if not rows then rows=unresolved(group,reason) end
        local output={owner=group.owner,owner_id=group.owner_id,previous=group,rows=rows,reason=reason}
        report.groups[#report.groups+1]=output
        for _,row in ipairs(rows) do
            report.rows[#report.rows+1]={owner=group.owner,owner_id=group.owner_id,result=row}
        end
    end
    return report
end
return M
