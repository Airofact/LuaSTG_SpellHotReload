-- Complete candidate discovery, preparation and caller-bound atomic dispatch.
local NodeRegistry = require("SpellHotReload.Pipeline.NodeRegistry")
local FileMatch = require("SpellHotReload.Pipeline.FileMatch")
local UnitIndex = require("SpellHotReload.Pipeline.UnitIndex")
local Source = require("SpellHotReload.Source.FileAnalysis")

local scope_write=rawset
local Driver = {}
Driver.__index = Driver

---@param options table?  -- { adapters = NodeRegistry }
---@return table driver
function Driver.New(options)
    options = options or {}
    local adapters = options.adapters
    if adapters == nil then adapters = NodeRegistry.New() end
    return setmetatable({
        adapters = adapters,
    }, Driver)
end

local DISCOVERY_KIND = "SpellHotReload.Driver.Discovery"
local SELECTION_KIND = "SpellHotReload.Driver.DiscoverySelection"
local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end
local function discovery_error(phase, message, file, key)
    return nil, { phase = phase, code = "unsupported", message = message,
        file = file, unit_key = key }
end

---Register one current discovery adapter.
function Driver:RegisterDiscovery(adapter)
    return self.adapters:RegisterDiscovery(adapter)
end

---Analyze the COMPLETE file through all registered discovery adapters, then
---build the normalized/random-access index. supplied is copied, not mutated.
---All units (including unchanged/unselected ones) and adapter contexts survive.
---No cross-version identity, impact or publication decision is inferred here.
function Driver:Discover(file, source, supplied)
    if type(file) ~= "string" or file == "" or not Source.Validate(source)
        or (supplied ~= nil and not plain(supplied)) then
        return discovery_error("analyze", "file/shared source and plain common required")
    end
    if supplied and supplied.file ~= nil and supplied.file ~= file then
        return discovery_error("analyze", "common file disagrees with requested file", file)
    end
    local common = {}
    for key, value in next, supplied or {} do common[key] = value end
    common.file = file
    local snapshot, err = FileMatch.Discover(self.adapters, source, common)
    if not snapshot then return nil, err end
    local index, reason = UnitIndex.Build(snapshot)
    if not index then
        return discovery_error("match", reason, file)
    end
    return { kind = DISCOVERY_KIND, version = 1, owner = self, file = file,
        source = source, snapshot = snapshot, index = index }
end

---Explicit keys belong to ONE discovery snapshot, never to another revision.
---Validate the whole dense request before returning any selected entries.
---Return source-ordered entries with their original adapter/common/unit contexts;
---never re-Match, call Locate/Inject, use For/Fallback or filter the full snapshot.
---Artifacts are caller-owned and read-only by contract; drop them on session end.
function Driver:SelectDiscovery(discovery, keys)
    if not plain(discovery) or discovery.kind ~= DISCOVERY_KIND
        or discovery.version ~= 1 or discovery.owner ~= self
        or not plain(discovery.snapshot) or not plain(discovery.index)
        or discovery.index.snapshot ~= discovery.snapshot
        or discovery.index.kind ~= "SpellHotReload.UnitIndex"
        or discovery.index.version ~= 1 or not plain(discovery.snapshot.common)
        or discovery.snapshot.common.file ~= discovery.file
        or discovery.snapshot.common.source ~= discovery.source
        or not plain(keys) then
        return discovery_error("locate", "owned discovery and dense explicit keys required")
    end
    local count, maximum = 0, 0
    for key in next, keys do
        if type(key) ~= "number" or key < 1 or key == math.huge
            or key ~= math.floor(key) then
            return discovery_error("locate", "dense explicit keys required", discovery.file)
        end
        count, maximum = count + 1, math.max(maximum, key)
    end
    if count ~= maximum then
        return discovery_error("locate", "dense explicit keys required", discovery.file)
    end
    local selected = {}
    for _, key in ipairs(keys) do
        if type(key) ~= "string" or key == "" or selected[key]
            or discovery.index.by_key[key] == nil then
            return discovery_error("locate", "unknown or duplicate unit key", discovery.file,
                type(key) == "string" and key or nil)
        end
        selected[key] = true
    end
    local entries = {}
    for _, record in ipairs(discovery.index.list) do
        if selected[record.key] then entries[#entries + 1] = record.entry end
    end
    return { kind = SELECTION_KIND, version = 1, discovery = discovery,
        entries = entries, file = discovery.file, source = discovery.source }
end

-- Contract 5 has unit resolve and owner aggregation scopes within the same
-- five hooks. The owner envelope below is not a public dependency/claim unit.
-- All hooks are preparation/registration only; the common kernel publishes once.
function Driver:PrepareDiscovery(discovery,operation)
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Dependencies=require("SpellHotReload.Pipeline.Dependencies")
    local Adapter=require("SpellHotReload.Pipeline.Adapter")
    local function refuse(phase,message)
        return nil,{phase=phase,code="ownership",message=message,
            file=plain(operation) and operation.file},phase
    end
    if getmetatable(self)~=Driver then return refuse("locate","owned driver required") end
    local owned=self:SelectDiscovery(discovery,{})
    if not owned or not plain(operation)
        or not Files.Validate(operation.capture) or operation.base_snapshot~=operation.capture.snapshot
        or operation.source~=discovery.source or operation.file~=discovery.file
        or not plain(discovery.reconciliation) or not plain(discovery.reconciliation.groups)
        or discovery.snapshot.reconciliation~=discovery.reconciliation
        or discovery.snapshot.common.capture~=operation.capture
        or discovery.snapshot.common.session_id~=operation.session_id
        or discovery.snapshot.common.registry_entry~=operation.entry
        or discovery.snapshot.common.base_revision~=operation.base_snapshot.revision
        or discovery.snapshot.common.generation~=operation.generation then
        return refuse("locate","owned operation and fresh complete discovery required")
    end
    local report,records,by_owner=discovery.reconciliation,{},{}
    local available={}
    for _,owner in ipairs(self.adapters:Discoveries()) do available[owner]=true end
    -- Validate every original owner before even the first unit Locate. No same-ID
    -- replacement, omitted read-only owner or unregistered contributor can enter.
    for i,group in ipairs(operation.base_snapshot.owners) do
        local output=report.groups[i]
        if not plain(output) or output.owner~=group.owner or output.owner_id~=group.owner_id
            or output.reason~=nil or not available[group.owner] or rawget(group.owner,"Id")~=group.owner_id
            or not Adapter.ValidateDiscovery(group.owner)
            or not plain(discovery.snapshot.adapter_contexts[group.owner_id]) then
            return refuse("locate","complete original owner set unavailable")
        end
        local handle={kind="SpellHotReload.Driver.OwnerHandle",version=1,operation=operation,
            owner=group.owner,base_group=group,view=output.view,located={},by_ref={}}
        local record={owner=group.owner,base_group=group,handle=handle,output=output,
            hooks={Locate=rawget(group.owner,"Locate"),Inject=rawget(group.owner,"Inject"),Commit=rawget(group.owner,"Commit")}}
        records[i]=record;by_owner[group.owner]=record
    end
    local function context(record,phase,scope)
        return {common=discovery.snapshot.common,operation=operation,view=record.output.view,
            base_group=record.base_group,phase=phase,scope=scope,
            adapter={file=discovery.snapshot.adapter_contexts[record.base_group.owner_id]}}
    end
    -- Normalize exceptions at the dispatch boundary without invoking tostring on
    -- owner-controlled objects. Explicit refusals keep their diagnostic identity.
    local function invoke(record,name,phase,...)
        local called,value,err=pcall(record.hooks[name],...)
        if not called then return nil,{phase=phase,code="ownership",message="owner "..name.." threw",
            file=operation.file,cause=value} end
        return value,err
    end
    local resolution,reason=Dependencies.Resolve(operation,report,operation.roots,function(owner,unit,request)
        local record=by_owner[owner]
        if not record then return refuse("resolve","foreign resolver owner") end
        local located=record.handle.by_ref[unit.unit_ref]
        if not located then
            local ctx=context(record,"locate","unit");ctx.adapter.unit=unit.private_ref
            local handle,err=invoke(record,"Locate","locate",unit,ctx)
            if not plain(handle) then return nil,err end
            located={unit=unit,handle=handle,context=ctx}
            record.handle.by_ref[unit.unit_ref]=located
            record.handle.located[#record.handle.located+1]=located
        end
        local ctx=context(record,"resolve","unit")
        ctx.adapter.unit=unit.private_ref;ctx.request=request
        return invoke(record,"Inject","resolve",located.handle,unit,ctx)
    end)
    if not resolution then return nil,reason,plain(reason) and reason.phase or "resolve" end
    -- All business owners see only selected-source facts with root provenance.
    -- Constraints return root blocks/private evidence, never dependency expansion
    -- or writes. This also runs for a genuinely empty owner contribution.
    local blocks,constraints={},{}
    local roots={}
    for _,root in ipairs(resolution.safe_roots) do roots[root.root_id]=true end
    for i,record in ipairs(records) do
        local ctx=context(record,"resolve","owner");ctx.dependencies=resolution
        local result,err=invoke(record,"Inject","resolve",record.handle,nil,ctx)
        if not plain(result) or result.operation~=operation or result.owner~=record.owner
            or type(result.blocked_roots)~="table" or getmetatable(result.blocked_roots)~=nil then
            return nil,err or {phase="resolve",code="ownership",message="owner constraint result required",file=operation.file},"resolve"
        end
        local count,max,seen=0,0,{}
        for key in next,result.blocked_roots do
            if type(key)~="number" or key<1 or key>=math.huge or key~=math.floor(key) then
                return refuse("resolve","dense owner root constraints required")
            end
            count=count+1;max=math.max(max,key)
        end
        if count~=max then return refuse("resolve","dense owner root constraints required") end
        for _,block in ipairs(result.blocked_roots) do
            if not plain(block) or not roots[block.root_id] or seen[block.root_id]
                or not plain(block.reason) or type(block.reason.code)~="string" or type(block.reason.message)~="string" then
                return refuse("resolve","invalid owner root constraint")
            end
            seen[block.root_id]=true;blocks[#blocks+1]=block
        end
        constraints[i]=result
    end
    resolution,reason=Dependencies.Restrict(resolution,blocks)
    if not resolution then return nil,reason,"resolve" end
    for i,record in ipairs(records) do
        local ctx=context(record,"prepare","owner")
        ctx.selection=resolution.owners[i];ctx.dependencies=resolution;ctx.constraints=constraints[i]
        local fragment,err=invoke(record,"Inject","inject",record.handle,nil,ctx)
        if not plain(fragment) or fragment.operation~=operation or fragment.owner~=record.owner
            or fragment.base_group~=record.base_group then
            return nil,err or {phase="inject",code="ownership",message="exact owner fragment required",file=operation.file},"inject"
        end
        record.context,record.fragment=ctx,fragment
    end
    -- A hook cannot change the registry or dispatch target during preparation.
    local current={}
    for _,owner in ipairs(self.adapters:Discoveries()) do current[owner]=true end
    for _,record in ipairs(records) do
        if not current[record.owner] or rawget(record.owner,"Id")~=record.base_group.owner_id
            or rawget(record.owner,"Locate")~=record.hooks.Locate
            or rawget(record.owner,"Inject")~=record.hooks.Inject
            or rawget(record.owner,"Commit")~=record.hooks.Commit then
            return refuse("inject","owner dispatch changed during preparation")
        end
    end
    if operation.capture.snapshot~=operation.base_snapshot or not Source.Validate(operation.source) then
        return refuse("inject","publication/source changed during preparation")
    end
    return {kind="SpellHotReload.Driver.PreparedDiscovery",version=2,owner=self,discovery=discovery,
        operation=operation,dependencies=resolution,entries=records}
end

-- Register every owner fragment, then invoke exactly one neutral transaction.
-- A writer records only the exact tuple; it cannot consume a UI token or write.
function Driver:CommitDiscovery(prepared,transaction)
    local function refuse(code,detail)
        return nil,{phase="register",code=code,message=detail,
            file=plain(prepared) and prepared.file or nil}
    end
    local function dense(v)
        if not plain(v) then return false end
        local n,max=0,0
        for k in next,v do
            if type(k)~="number" or k<1 or k>=math.huge or k~=math.floor(k) then return false end
            n=n+1;max=math.max(max,k)
        end
        return n==max
    end
    if getmetatable(self)~=Driver or not plain(prepared) or prepared.owner~=self
        or prepared.kind~="SpellHotReload.Driver.PreparedDiscovery" or prepared.version~=2
        or not plain(prepared.operation) or not dense(prepared.entries)
        or type(transaction)~="function" or not plain(prepared.discovery)
        or prepared.discovery.owner~=self then return refuse("ownership","owned prepared operation required") end
    local op,discovery=prepared.operation,prepared.discovery
    local capture=op.capture
    if not require("SpellHotReload.Pipeline.FileVersions").Validate(capture)
        or op.base_snapshot~=capture.snapshot or #prepared.entries~=#capture.snapshot.owners
        or discovery.snapshot.common.source~=op.source or discovery.snapshot.common.file~=op.file then
        return refuse("ownership","complete actual owner set required")
    end
    local checked,fragments={},{}
    local available={}
    for _,owner in ipairs(self.adapters:Discoveries()) do available[owner]=true end
    for i,record in ipairs(prepared.entries) do
        local group=capture.snapshot.owners[i]
        if not plain(record) or record.owner~=group.owner or record.base_group~=group
            or not available[group.owner] or rawget(group.owner,"Id")~=group.owner_id
            or not require("SpellHotReload.Pipeline.Adapter").ValidateDiscovery(record.owner)
            or not plain(record.context) or record.context.common~=discovery.snapshot.common
            or not plain(record.context.adapter)
            or record.context.adapter.file~=discovery.snapshot.adapter_contexts[group.owner_id]
            or record.context.operation~=op or not record.handle or not plain(record.fragment)
            or record.fragment.operation~=op or record.fragment.owner~=group.owner
            or record.fragment.base_group~=group or rawget(record.context.adapter,"register")~=nil then
            return refuse("ownership","prepared owner identity changed")
        end
        checked[i]={owner=record.owner,handle=record.handle,fragment=record.fragment,
            context=record.context,scope=record.context.adapter,hook=rawget(record.owner,"Commit")}
    end
    -- A refusal in any later hook leaves all earlier registrations uncommitted.
    for i,record in ipairs(checked) do
        local h,f,c,scope,hook=record.handle,record.fragment,record.context,record.scope,record.hook
        local active,attempted,registered,violation=true,false,false,false
        local file=op.file
        local function writer_error(code,message)
            return nil,{phase="register",code=code,message=message,file=file}
        end
        local writer
        writer=function(handle,fragment,context)
            if not active then return writer_error("stale","registration writer expired") end
            if attempted then violation=true;return writer_error("stale","registration writer already used") end
            attempted=true
            if handle~=h or fragment~=f or context~=c then
                violation=true;return writer_error("ownership","foreign registration tuple")
            end
            registered=true;return true
        end
        scope_write(scope,"register",writer)
        local function pack(...) return {n=select("#",...),...} end
        local result=pack(pcall(hook,h,f,c))
        local inspected,unchanged=pcall(function()
            return rawget(scope,"register")==writer and record.owner.Commit==hook
                and record.context==c and c.adapter==scope and c.operation==op
                and c.common==discovery.snapshot.common and c.common.source==op.source
        end)
        active=false
        scope_write(scope,"register",nil)
        -- Retained expired closures must not keep operation/session/controller refs.
        h,f,c,scope,hook=nil,nil,nil,nil,nil
        if not result[1] then return refuse("ownership","owner Commit threw") end
        if result[2]~=true or result.n~=2 or not registered or violation or not inspected or not unchanged then
            return refuse("ownership","owner Commit must register its exact tuple once and return true")
        end
        fragments[i]=record.fragment
    end
    -- No callbacks above ever received this capability. Only one call here.
    return transaction(op,fragments)
end

---Complete two-sided read-only discovery. On source failure the THIRD result
---retains unresolved publications; nil/error stay failure, never empty success.
function Driver:DiscoverPublished(file,source,publication,supplied,source_error)
    local Reconciliation=require("SpellHotReload.Pipeline.Reconciliation")
    local common={}
    if supplied~=nil and not plain(supplied) then
        return discovery_error("reconcile","plain candidate context required",file)
    end
    for k,v in next,supplied or {} do common[k]=v end
    if not Reconciliation.ValidatePublication(publication) or file~=publication.file then
        return discovery_error("reconcile","matching actual publication required",file)
    end
    for _,key in ipairs({"file","session_id","loaded_source","registry_entry","base_revision"}) do
        local expected=key=="registry_entry" and publication.entry
            or key=="base_revision" and publication.revision or publication[key]
        if common[key]~=nil and common[key]~=expected then
            return discovery_error("reconcile","candidate context disagrees with publication",file)
        end
    end
    common.session_id,common.loaded_source=publication.session_id,publication.loaded_source
    common.registry_entry,common.base_revision=publication.entry,publication.revision
    local discovery,err
    if source_error~=nil then
        if source~=nil or not plain(source_error) or type(source_error.phase)~="string"
            or type(source_error.code)~="string" or type(source_error.message)~="string"
            or source_error.file~=nil and source_error.file~=file then
            return discovery_error("reconcile","failure diagnostic disagrees with source/file",file)
        end
        err=source_error
    else discovery,err=self:Discover(file,source,common) end
    local snapshot=discovery and discovery.snapshot
    local problem
    if not discovery then
        problem=source==nil and (not source_error or source_error.phase~="analyze") and "candidate bytes unavailable"
            or (plain(err) and err.phase=="match") and "candidate Match failed"
            or "candidate analysis failed"
    end
    local report,why=Reconciliation.Run(self.adapters,publication,snapshot,problem)
    if report and not discovery then report.source_error=err end
    if not report then return nil,why end
    if not discovery then return nil,err,report end
    discovery.reconciliation=report
    discovery.snapshot.reconciliation=report
    return discovery
end

return Driver
