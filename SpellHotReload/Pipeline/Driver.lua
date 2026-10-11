--------------------------------------------------------------------------------
--- SpellHotReload.Pipeline.Driver
---
--- Walks a file's top-level carrier nodes and turns them into commits:
---
---   Plan(file, content, options)  analyze + Locate + Inject (no live change)
---   Commit(run, options)          the single live mutation, safe phase only
---   Restart(run, options)         retry restarts that failed earlier
---   Apply(file, content, options)  Plan immediately followed by Commit
---
--- Plan never mutates anything the running game can observe: it only chooses an
--- adapter, matches structural identity and builds new values. Commit is the
--- only live write, so the caller is responsible for invoking it from a frame
--- boundary (the plugin's UI phase), never from inside an affected coroutine.
---
--- Change detection: when `options.previous` is supplied, a node whose statement
--- text is identical to a baseline statement with the same signature is marked
--- `unchanged` and never injected. Without a baseline every node is planned.
--------------------------------------------------------------------------------

local LoadCapture = require("SpellHotReload.Load.LoadCapture")
local NodeRegistry = require("SpellHotReload.Pipeline.NodeRegistry")
local FileMatch = require("SpellHotReload.Pipeline.FileMatch")
local UnitIndex = require("SpellHotReload.Pipeline.UnitIndex")

local Driver = {}
Driver.__index = Driver

---Stable identity of a node across edits; used to compare against a baseline.
---@param node table
---@return string
function Driver.Signature(node)
    local key = node.name or node.path or node.callee or ""
    return table.concat({
        tostring(node.carrier), tostring(node.kind), tostring(key), tostring(node.slot or 0),
    }, "|")
end

---Multiset of statement texts per signature, so duplicates compare correctly.
local function index_texts(nodes)
    local index = {}
    for _, node in ipairs(nodes) do
        local sig = Driver.Signature(node)
        local bucket = index[sig]
        if bucket == nil then
            bucket = {}
            index[sig] = bucket
        end
        bucket[#bucket + 1] = node.text
    end
    return index
end

---Consume one matching text from the bucket; true when the node is unchanged.
local function consume_text(index, sig, text)
    local bucket = index[sig]
    if bucket == nil or text == nil then return false end
    for i = 1, #bucket do
        if bucket[i] == text then
            table.remove(bucket, i)
            return true
        end
    end
    return false
end

---@param options table?  -- { adapters = NodeRegistry, capture = LoadCapture }
---@return table driver
function Driver.New(options)
    options = options or {}
    local adapters = options.adapters
    if adapters == nil then adapters = NodeRegistry.New() end
    return setmetatable({
        adapters = adapters,
        capture = options.capture or LoadCapture,
        signature = options.signature or Driver.Signature,
    }, Driver)
end

---Register an adapter for one carrier or a list of carriers.
---@param carrier string|string[]
---@param adapter table
---@return boolean
---@return string? reason
function Driver:Register(carrier, adapter)
    return self.adapters:Register(carrier, adapter)
end

-- Discovery and explicit selection are the versioned pipeline's read-only
-- front door. These artifacts are NOT legacy Plan runs and cannot authorize
-- Commit/Restart. No candidate chunk, adapter execution hook or live read runs.
local DISCOVERY_KIND = "SpellHotReload.Driver.Discovery"
local SELECTION_KIND = "SpellHotReload.Driver.DiscoverySelection"
local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end
local function discovery_error(phase, message, file, key)
    return nil, { phase = phase, code = "unsupported", message = message,
        file = file, unit_key = key }
end

---Explicit registration remains independent of legacy carrier routing.
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

---Analyze, locate and inject one file. No live object is touched.
---@param file string
---@param content string
---@param options table?  -- { previous, map, registry }
---@return table? run
---@return string? error
function Driver:Plan(file, content, options)
    options = options or {}

    local nodes, nerr = self.capture.Nodes(content, { host_calls = options.host_calls })
    if nodes == nil then
        return nil, tostring(nerr)
    end

    local baseline = nil
    if type(options.previous) == "string" then
        local prev_nodes = self.capture.Nodes(options.previous, { host_calls = options.host_calls })
        if prev_nodes ~= nil then baseline = index_texts(prev_nodes) end
    end

    local map = options.map
    if map == nil and options.registry ~= nil and file ~= nil then
        map = options.registry:Get(file)
    end

    -- Locals must be injected in dependency order. Lua top-level scoping makes
    -- source order a valid topological order, so a single forward pass over the
    -- nodes suffices - as long as each freshly planned local is visible to the
    -- ones that follow it. `working` provides that view without touching the
    -- real capture table, which Commit owns.
    local working = nil
    if type(map) == "table" then
        working = {}
        for key, value in pairs(map) do working[key] = value end
    end

    local env = {
        file = file,
        content = content,
        map = map,
        working = working or map,
        registry = options.registry,
        previous = options.previous,
    }

    local run = {
        file = file,
        content = content,
        env = env,
        entries = {},
        planned = 0,
        unchanged = 0,
        declined = 0,
    }

    for _, node in ipairs(nodes) do
        local entry = { node = node, signature = self.signature(node) }

        if baseline ~= nil and consume_text(baseline, entry.signature, node.text) then
            entry.status = "unchanged"
            entry.reason = "statement text identical to baseline"
        else
            local adapter = self.adapters:For(node)
            entry.adapter = adapter
            local handle, lreason = adapter.Locate(node, env)
            if handle == nil then
                entry.status = "declined"
                entry.reason = lreason or "Locate declined"
            else
                entry.handle = handle
                local plan, ireason = adapter.Inject(handle, node, env)
                if plan == nil then
                    entry.status = "declined"
                    entry.reason = ireason or "Inject declined"
                else
                    entry.status = "planned"
                    entry.plan = plan
                    run.planned = run.planned + 1
                    if node.carrier == "local" and node.name ~= nil
                        and type(env.working) == "table" then
                        env.working[node.name] = plan.value
                    end
                end
            end
        end

        if entry.status == "unchanged" then run.unchanged = run.unchanged + 1 end
        if entry.status == "declined" then run.declined = run.declined + 1 end
        run.entries[#run.entries + 1] = entry
    end

    return run
end

---Apply every planned entry. This is the only live mutation point.
---@param run table
---@param options table?  -- { restart = boolean (default true) }
---@return table report
function Driver:Commit(run, options)
    options = options or {}
    local report = { file = run.file, committed = 0, failed = {}, restarts = {} }

    for _, entry in ipairs(run.entries) do
        if entry.status == "planned" then
            local adapter = entry.adapter
            local ok, reason = adapter.Commit(entry.handle, entry.plan, run.env)
            if ok then
                entry.status = "committed"
                report.committed = report.committed + 1

                if adapter.Restartable == true and options.restart ~= false
                    and type(adapter.Restart) == "function" then
                    local rok, rreason = adapter.Restart(entry.handle, entry.plan, run.env)
                    entry.restart = { ok = rok, reason = rreason }
                    report.restarts[#report.restarts + 1] = { node = entry.node, ok = rok, reason = rreason }
                end
            else
                entry.status = "failed"
                entry.reason = reason
                report.failed[#report.failed + 1] = { node = entry.node, reason = reason }
            end
        end
    end

    report.planned = run.planned
    return report
end

---Retry the restarts that failed during Commit, leaving committed definitions in
---place so a restart can be retried on its own.
---@param run table
---@return table report
function Driver:Restart(run)
    local report = { retried = 0, ok = 0, failed = {} }

    for _, entry in ipairs(run.entries) do
        local restart = entry.restart
        if entry.status == "committed" and restart ~= nil and restart.ok ~= true then
            local adapter = entry.adapter
            if type(adapter.Restart) == "function" then
                report.retried = report.retried + 1
                local ok, reason = adapter.Restart(entry.handle, entry.plan, run.env)
                entry.restart = { ok = ok, reason = reason }
                if ok then
                    report.ok = report.ok + 1
                else
                    report.failed[#report.failed + 1] = { node = entry.node, reason = reason }
                end
            end
        end
    end

    return report
end

---Plan and commit in one call. The caller must already be in the safe phase.
---@return table? result  -- { run, report }
---@return string? error
function Driver:Apply(file, content, options)
    local run, err = self:Plan(file, content, options)
    if run == nil then return nil, err end
    local report = self:Commit(run, options)
    return { run = run, report = report }
end

---Count the entries in a given status.
---@param run table
---@param status string
---@return integer
function Driver.Count(run, status)
    local total = 0
    for _, entry in ipairs(run.entries) do
        if entry.status == status then total = total + 1 end
    end
    return total
end

---Collect the nodes in a given status, for diagnostics.
---@param run table
---@param status string
---@return table[]
function Driver.Select(run, status)
    local selected = {}
    for _, entry in ipairs(run.entries) do
        if entry.status == status then selected[#selected + 1] = entry.node end
    end
    return selected
end

return Driver
