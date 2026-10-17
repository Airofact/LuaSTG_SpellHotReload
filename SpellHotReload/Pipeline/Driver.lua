-- Complete candidate discovery, preparation and caller-bound atomic dispatch.
local NodeRegistry = require("SpellHotReload.Pipeline.NodeRegistry")
local FileMatch = require("SpellHotReload.Pipeline.FileMatch")
local UnitIndex = require("SpellHotReload.Pipeline.UnitIndex")

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
function Driver:Discover(file, content, supplied, options)
    if type(file) ~= "string" or file == "" or type(content) ~= "string"
        or (supplied ~= nil and not plain(supplied)) then
        return discovery_error("analyze", "file/content and plain common required")
    end
    if supplied and supplied.file ~= nil and supplied.file ~= file then
        return discovery_error("analyze", "common file disagrees with requested file", file)
    end
    local common = {}
    for key, value in next, supplied or {} do common[key] = value end
    common.file = file
    local snapshot, err = FileMatch.Discover(self.adapters, content, common, options)
    if not snapshot then return nil, err end
    local index, reason = UnitIndex.Build(snapshot)
    if not index then
        return discovery_error("match", reason, file)
    end
    return { kind = DISCOVERY_KIND, version = 1, owner = self, file = file,
        content = content, snapshot = snapshot, index = index }
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
        or discovery.snapshot.common.content ~= discovery.content
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
        entries = entries, file = discovery.file, content = discovery.content }
end

---Read-only versioned preparation over explicit discovered keys, in source order.
---Optional contexts are per-call adapter extensions, never a replacement for the
---snapshot's shared common/file/unit identities. Validate ALL inputs before hooks.
---No Match replay, legacy For/Plan, mutation, transaction, publication or restart.
---Failure returns the original adapter error plus its hook phase (third result);
---throws remain throws so callers retain their existing protected boundaries.
function Driver:PrepareDiscovery(discovery, keys, contexts)
    if getmetatable(self) ~= Driver or (contexts ~= nil and not plain(contexts)) then
        return discovery_error("locate", "owned driver and plain context extensions required")
    end
    local selected, err = self:SelectDiscovery(discovery, keys)
    if not selected then return nil, err, "locate" end
    local requested, prepared = {}, {}
    for _, entry in ipairs(selected.entries) do
        if not plain(entry) or not plain(entry.unit) or type(entry.unit.key) ~= "string" then
            return discovery_error("locate", "discovered entry/unit required", discovery.file)
        end
        requested[entry.unit.key] = true
    end
    for key in next, contexts or {} do
        if not requested[key] then
            return discovery_error("locate", "context for unselected unit", discovery.file,
                type(key) == "string" and key or nil)
        end
    end
    local Adapter = require("SpellHotReload.Pipeline.Adapter")
    for _, entry in ipairs(selected.entries) do
        local unit, base = entry.unit, entry.context
        local context = base
        if contexts and rawget(contexts, unit.key) ~= nil then context = rawget(contexts, unit.key) end
        local valid = Adapter.ValidateDiscovery(entry.adapter)
        if not valid or discovery.snapshot.by_key[unit.key] ~= entry
            or not plain(base) or not plain(base.adapter)
            or not plain(context) or not plain(context.adapter)
            or context.common ~= discovery.snapshot.common or context.common ~= base.common
            or context.adapter.file ~= base.adapter.file
            or context.adapter.unit ~= unit.context or base.adapter.unit ~= unit.context
            or base.adapter.file ~= discovery.snapshot.adapter_contexts[rawget(entry.adapter, "Id")] then
            return discovery_error("locate", "discovered adapter/unit/context ownership changed",
                discovery.file, unit.key)
        end
        prepared[#prepared+1] = {entry=entry, adapter=entry.adapter, unit=unit, context=context}
    end
    for _, record in ipairs(prepared) do
        local handle, reason = rawget(record.adapter, "Locate")(record.unit, record.context)
        if not handle then return nil, reason, "locate" end
        local plan, why = rawget(record.adapter, "Inject")(handle, record.unit, record.context)
        if not plan then return nil, why, "inject" end
        record.handle, record.plan = handle, plan
    end
    return {kind="SpellHotReload.Driver.PreparedDiscovery", version=1, owner=self,
        discovery=discovery, file=discovery.file, content=discovery.content, entries=prepared}
end


---Dispatch ONE prepared aggregate through an explicit atomic writer. This is
---not a multi-unit transaction: empty/multiple aggregates fail before any hook.
---The trusted writer owns phase/Guard/Consume/journal/rollback/version install.
---No Match/Locate/Inject replay, legacy Commit, automatic Restart or cache.
---Artifacts are caller-owned/read-only by contract, not unforgeable permissions.
---The temporary exact-input writer expires on return/throw and can be used once.
function Driver:CommitDiscovery(prepared, transaction)
    local function refuse(code, detail, key)
        return false, {phase="commit", code=code, message=detail,
            file=plain(prepared) and rawget(prepared,"file") or nil, unit_key=key}
    end
    if getmetatable(self)~=Driver or not plain(prepared)
        or prepared.kind~="SpellHotReload.Driver.PreparedDiscovery"
        or prepared.version~=1 or prepared.owner~=self or not plain(prepared.entries)
        or type(transaction)~="function" then
        return refuse("ownership", "owned prepared discovery and atomic writer required")
    end
    -- Do not accidentally publish one root at a time and claim group atomicity.
    local count=0
    for key in next,prepared.entries do
        if key~=1 then return refuse("unsupported", "single prepared aggregate required") end
        count=count+1
    end
    if count~=1 then return refuse("unsupported", "single prepared aggregate required") end
    local record=prepared.entries[1]
    if not plain(record) or not plain(record.unit) or type(record.unit.key)~="string" then
        return refuse("ownership", "prepared entry/unit required")
    end
    local unit, context, entry=record.unit,record.context,record.entry
    local selected=self:SelectDiscovery(prepared.discovery,{unit.key})
    if not selected or prepared.file~=selected.file or prepared.content~=selected.content
        or selected.entries[1]~=entry or not plain(entry) or entry.unit~=unit
        or entry.adapter~=record.adapter
        or not require("SpellHotReload.Pipeline.Adapter").ValidateDiscovery(record.adapter)
        or not plain(entry.context)
        or not plain(entry.context.adapter) or not plain(context) or not plain(context.adapter)
        or context.common~=entry.context.common or context.common~=prepared.discovery.snapshot.common
        or context.adapter.file~=entry.context.adapter.file
        or context.adapter.unit~=unit.context
        or entry.context.adapter.unit~=unit.context
        or entry.context.adapter.file~=prepared.discovery.snapshot.adapter_contexts[rawget(record.adapter,"Id")]
        or not record.handle or not record.plan or rawget(context.adapter,"transaction")~=nil then
        return refuse("ownership", "prepared adapter/unit/context ownership changed",unit.key)
    end
    local handle,plan,scope=record.handle,record.plan,context.adapter
    local hook=rawget(record.adapter,"Commit")
    local active,attempted=true,false
    local writer=function(h,p,c)
        if h~=handle or p~=plan or c~=context then
            local _,err=refuse("ownership", "foreign prepared transaction input",unit.key)
            return nil,err
        end
        if not active or attempted then
            local _,err=refuse("stale", "prepared transaction writer expired or already used",unit.key)
            return nil,err
        end
        attempted=true
        return transaction(h,p,c)
    end
    rawset(scope,"transaction",writer)
    local called,ok,err,receipt=pcall(hook,handle,plan,context)
    active=false
    transaction=nil -- retained expired writers cannot retain the caller capability
    rawset(scope,"transaction",nil)
    if not called then error(ok,0) end
    return ok,err,receipt
end

---Complete two-sided read-only discovery. On source failure the THIRD result
---retains unresolved publications; nil/error stay failure, never empty success.
function Driver:DiscoverPublished(file,content,publication,supplied,options)
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
    local discovery,err=self:Discover(file,content,common,options)
    local snapshot=discovery and discovery.snapshot
    local problem
    if not discovery then
        problem=type(content)~="string" and "candidate bytes unavailable"
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
