-- Single file publication ledger. Owners supply private records, never commits.
local Anchor=require("SpellHotReload.Load.Anchor")
local Source=require("SpellHotReload.Source.FileAnalysis")
local M={Kind="SpellHotReload.FileCapture",SnapshotKind="SpellHotReload.FileSnapshot",Version=1}
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
local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
local function fail(message,file)
    return nil,{phase="versions",code="ownership",message=message,file=file}
end
local function group_valid(group,owner)
    if type(owner)~="table" or not plain(group) or group.owner~=owner or type(group.owner_id)~="string"
        or group.owner_id=="" or not plain(group.state) or not dense(group.units)
        or not dense(group.records) or not dense(group.functions) or not dense(group.edges) then return false end
    local refs,ids,keys={},{},{}
    for _,unit in ipairs(group.units) do
        if not plain(unit) or not plain(unit.unit_ref) or unit.unit_ref.owner~=owner
            or refs[unit.unit_ref] or type(unit.unit_ref.id)~="number" or unit.unit_ref.id<1
            or unit.unit_ref.id>=math.huge or unit.unit_ref.id~=math.floor(unit.unit_ref.id)
            or ids[unit.unit_ref.id] then return false end
        refs[unit.unit_ref]=true;ids[unit.unit_ref.id]=true
    end
    for _,record in ipairs(group.records) do
        if not plain(record) or type(record.key)~="string" or keys[record.key]
            or type(record.kind)~="string" or not plain(record.definition)
            or type(record.definition_version)~="number" or record.definition_version<1
            or record.definition_version>=math.huge
            or record.definition_version~=math.floor(record.definition_version)
            or record.definition.definition_version~=record.definition_version then return false end
        keys[record.key]=true
    end
    for _,fn in ipairs(group.functions) do if type(fn)~="function" then return false end end
    return true
end
local function graph(groups)
    local owned,edges={},{}
    for _,group in ipairs(groups) do
        for _,unit in ipairs(group.units) do
            local ref=unit.unit_ref
            if owned[ref] then return fail("unit reference has multiple owners") end
            owned[ref]=true
        end
    end
    for _,group in ipairs(groups) do
        for _,edge in ipairs(group.edges) do
            if not plain(edge) or not owned[edge.consumer] or not owned[edge.provider]
                or edge.consumer.owner~=group.owner then return fail("invalid effective unit edge") end
            edges[#edges+1]={consumer=edge.consumer,provider=edge.provider}
        end
    end
    return edges
end
-- Called synchronously by the genuine first-load owner, once for a new entry.
-- A contributor failure is sticky at the caller; never reseed a live session.
function M.Capture(entry,session_id,contributions)
    if not plain(entry) or not Anchor.Live(entry) or not plain(entry.source)
        or type(entry.file)~="string" or entry.file==""
        or type(session_id)~="string" or session_id=="" or not dense(contributions) then
        return fail("first-load entry and complete owner contributions required")
    end
    local initial,groups,ids,owners={},{},{},{}
    for _,piece in ipairs(contributions) do
        if not plain(piece) or not group_valid(piece,piece.owner) or rawget(piece.owner,"Id")~=piece.owner_id or owners[piece.owner]
            or ids[piece.owner_id] or not plain(piece.authority)
            or not dense(piece.authority.cells) or not dense(piece.authority.raws)
            or not dense(piece.authority.forbidden) or not dense(piece.identity_objects) or not plain(piece.initial) then
            return fail("invalid first-load owner contribution",entry.file)
        end
        ids[piece.owner_id],owners[piece.owner]=true,true
        local metadata={[piece]=true,[piece.state]=true,[piece.units]=true,
            [piece.records]=true,[piece.functions]=true,[piece.edges]=true}
        for _,unit in ipairs(piece.units) do metadata[unit]=true end
        for _,record in ipairs(piece.records) do metadata[record]=true;metadata[record.definition]=true end
        local identities={}
        for _,object in ipairs(piece.identity_objects) do
            if type(object)~="table" or metadata[object] then
                return fail("first-load identity cannot be publication metadata",entry.file)
            end
            identities[#identities+1]=object
        end
        local authority={cells={},raws={},forbidden={}}
        for _,key in ipairs({"cells","raws"}) do
            for _,record in ipairs(piece.authority[key]) do
                if not plain(record) then return fail("invalid action authority",entry.file) end
                authority[key][#authority[key]+1]=copy(record)
            end
        end
        for _,fn in ipairs(piece.authority.forbidden) do
            if type(fn)~="function" then return fail("function exclusion required",entry.file) end
            authority.forbidden[#authority.forbidden+1]=fn
        end
        initial[#initial+1]={owner=piece.owner,owner_id=piece.owner_id,
            authority=authority,evidence=piece.initial,identity_objects=identities}
        groups[#groups+1]={owner=piece.owner,owner_id=piece.owner_id,state=piece.state,
            units=piece.units,records=piece.records,functions=piece.functions,edges=piece.edges}
    end
    local edges,err=graph(groups)
    if not edges then return nil,err end
    local snapshot={kind=M.SnapshotKind,version=M.Version,file=entry.file,
        session_id=session_id,entry=entry,anchor=entry.anchor,loaded_source=entry.loaded_source,
        revision=0,owners=groups,graph=edges}
    return {kind=M.Kind,version=M.Version,entry=entry,initial_owners=initial,snapshot=snapshot}
end
function M.Validate(capture)
    if not plain(capture) or capture.kind~=M.Kind or capture.version~=M.Version
        or not plain(capture.entry) or not dense(capture.initial_owners) then return false end
    local base=capture.snapshot
    if not plain(base) or base.kind~=M.SnapshotKind or base.version~=M.Version
        or base.entry~=capture.entry or base.file~=base.entry.file
        or base.anchor~=base.entry.anchor or base.loaded_source~=base.entry.loaded_source
        or type(base.session_id)~="string" or base.session_id==""
        or type(base.revision)~="number" or base.revision<0 or base.revision>=math.huge
        or base.revision~=math.floor(base.revision) or not dense(base.owners)
        or #base.owners~=#capture.initial_owners or not dense(base.graph) then return false end
    local ids,owners={},{}
    for i,group in ipairs(base.owners) do
        local initial=capture.initial_owners[i]
        if not plain(initial) or not group_valid(group,initial.owner)
            or group.owner_id~=initial.owner_id or ids[group.owner_id] or owners[group.owner] then return false end
        ids[group.owner_id],owners[group.owner]=true,true
    end
    return graph(base.owners)~=nil
end
function M.Owner(capture,owner)
    if not M.Validate(capture) then return fail("valid file capture required") end
    for i,group in ipairs(capture.snapshot.owners) do
        if group.owner==owner then return group,capture.initial_owners[i] end
    end
    return fail("original owner not captured",capture.entry.file)
end
-- Every actual owner contributes one fragment, including retained read-only owners.
-- No callback and no live mutation here. The kernel alone installs this snapshot.
function M.Propose(operation,fragments)
    local capture=plain(operation) and operation.capture
    if not M.Validate(capture) or not Source.Validate(operation.source)
        or operation.base_snapshot~=capture.snapshot or not dense(fragments)
        or #fragments~=#capture.snapshot.owners then return fail("complete file fragments required") end
    local base,groups,changed=capture.snapshot,{},false
    for i,old in ipairs(base.owners) do
        local f=fragments[i]
        if not plain(f) or f.operation~=operation or f.owner~=old.owner or f.base_group~=old
            or not group_valid(f.proposed_group,old.owner) or f.proposed_group.owner_id~=old.owner_id
            or not dense(f.cell_writes) or not dense(f.raw_writes) or not dense(f.joins) then
            return fail("foreign or incomplete owner fragment",base.file)
        end
        local units={}
        for _,unit in ipairs(old.units) do units[unit.unit_ref]=true end
        if #old.units~=#f.proposed_group.units then return fail("unit identities cannot change",base.file) end
        for _,unit in ipairs(f.proposed_group.units) do
            if not units[unit.unit_ref] then return fail("unit identity was replaced",base.file) end
        end
        if #f.cell_writes+#f.raw_writes>0 then changed=true
        elseif #f.joins>0 or f.proposed_group~=old then
            return fail("an owner without installation writes must retain its actual group",base.file)
        end
        groups[i]=f.proposed_group
    end
    -- Owner-private metadata is copied as ONE object graph. Explicit first-load
    -- identity objects (registry/class/list/card), owners, stable unit refs and
    -- entry/source retain identity. Candidate source/AST is never retained here.
    local identities={[base.entry]=true,[base.entry.source]=true}
    for i,group in ipairs(base.owners) do
        identities[group.owner]=true
        for _,unit in ipairs(group.units) do identities[unit.unit_ref]=true end
        for _,object in ipairs(capture.initial_owners[i].identity_objects) do
            if type(object)~="table" then return fail("invalid first-load identity object",base.file) end
            identities[object]=true
        end
    end
    local memo={}
    local function clone(value)
        if type(value)=="table" and identities[value] then return value end
        if Source.ContainsFact(operation.source,value) then
            error("publication cannot retain candidate source",0)
        end
        if type(value)~="table" then return value end
        if not plain(value) then error("publication metadata must be plain",0) end
        if memo[value] then return memo[value] end
        local out={};memo[value]=out
        for key,item in next,value do out[clone(key)]=clone(item) end
        return out
    end
    for i,group in ipairs(groups) do
        if group~=base.owners[i] then groups[i]=clone(group) end
    end
    local edges,err=graph(groups)
    if not edges then return nil,err end
    if not changed then
        for _,f in ipairs(fragments) do
            if #f.joins>0 or f.proposed_group~=f.base_group then
                return fail("no-op cannot carry joins or a new owner state",base.file)
            end
        end
        return base
    end
    return {kind=M.SnapshotKind,version=M.Version,file=base.file,session_id=base.session_id,
        entry=base.entry,anchor=base.anchor,loaded_source=base.loaded_source,
        revision=base.revision+1,owners=groups,graph=edges}
end
function M.Publication(capture)
    if not M.Validate(capture) then return fail("valid file capture required") end
    local base,groups=capture.snapshot,{}
    for _,group in ipairs(base.owners) do
        groups[#groups+1]={owner=group.owner,owner_id=group.owner_id,state=group.state,
            records=group.records,units=group.units}
    end
    return {kind="SpellHotReload.Publication",version=1,file=base.file,session_id=base.session_id,
        revision=base.revision,entry=base.entry,loaded_source=base.loaded_source,groups=groups}
end
return M
