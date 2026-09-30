--------------------------------------------------------------------------------
--- SpellHotReload.Driver
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

local LoadCapture = require("SpellHotReload.LoadCapture")
local NodeRegistry = require("SpellHotReload.NodeRegistry")

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
