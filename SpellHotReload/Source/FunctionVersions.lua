--- R3 LOCAL-FUNCTION versions/diff/selection, not production Apply.
--- Seed requires genuine first-publication identities from the load owner.
--- Never reseed from current live values after a setter or partial Apply.
--- Compare is permitted to compile analysis closures for every definition;
--- Select publishes only changed definitions reachable from explicit roots.
--- Next only proposes an immutable-by-contract version snapshot: R4 must
--- install it atomically AFTER all cell/publication writes, or discard it.
--- No source chunk/body, join, write, cache flush, publication or restart here.
--- Card/Host/field identities, observations and tombstones are NOT modeled.
---
--- PUBLIC CONTRACT (all returned tables are read-only by contract):
---
--- Seed(entry, session_id, initial) -> snapshot | nil, error
---   entry          existing live first-load anchor entry, never reconstructed
---   session_id     explicit nonempty caller-owned session identity
---   initial        genuine first-published name -> function identities
---   snapshot       kind/version/file/session_id/entry/anchor/loaded_source
---                  revision/names/units/initializers
---   names          supported direct function names in initial source order
---   units[name]    fn/signature/body/definition/dependencies/definition_version
---                  observed (reachable function name -> definition version)
---   initializers   original non-function declaration token signatures
---
--- Seed is a trusted INITIAL-load boundary, not a way to repair a stale ledger.
--- Matching current identity and capture names cannot prove which source was
--- genuinely published: the load owner must supply that fact. Supplying a
--- freshly read replacement as `initial` violates this contract. R4 production
--- integration must seed immediately from its genuine first capture and retain
--- the resulting snapshot; this module does not integrate that lifecycle.
---
--- Compare(snapshot, content) -> report | nil, error
---   report.base             actual published snapshot, not loaded file text
---   report.content          COMPLETE candidate bytes for R4 stale checks
---   report.prepared         all-function ANALYSIS closure/connection plan
---   report.by_name[name]     changed/action/signature/dependencies/item/previous
---   report.changed          candidate definitions differing from each unit's
---                           own last published token signature
---   report.affected         reverse reachability over BOTH graph versions
---   report.initializers     preserve-state/requires_restart diagnostics only
---   report.capture_reads    actual old function/upvalue/donor slots, no frozen
---                           ordinary state values
---
--- Compare may compile every function for analysis even when Select later
--- replaces just one. Formatting/comments are ignored; different opaque string
--- and number spellings conservatively count as changes. This is not general
--- Lua equivalence, a semantic hash or complete Lua parsing. Plan.Prepare still
--- enforces fixed declarations, visibility, literal safety and live identities.
--- An externally replaced function anywhere in this local-function snapshot
--- conservatively refuses the whole comparison, including unrelated roots.
---
--- Select(report, roots) -> selection | nil, error
---   selected/pending        changed definitions to write vs not acknowledged
---   affected                actual effective post-selection graph impact
---   functions/joins/writes  filtered prepared artifacts in candidate order
---   read_set/capture_reads  old identities/bindings to recheck before R4 commit
---   publications/restarts   empty: local-function cells only in this module
---   base/base_revision      expected actual snapshot identity and revision
---
--- A changed root follows new capture edges. An unchanged definition follows
--- its SAVED actual capture edges, not still-pending candidate definitions.
--- The candidate report can mark a pending edge as affected for UI purposes,
--- but selection.affected never pretends that edge is already in the runtime.
--- Alias/state cells terminate traversal. Escaped old closures, copied table
--- fields, cards and host callbacks are outside this function-only graph.
---
--- Next(selection) -> proposed snapshot | nil, error
---   A selected definition increments its own source version; reachable shared
---   observations can advance without changing a consumer's fn/source version.
---   File revision increments once per nonempty selected group. An empty group
---   returns the original snapshot. Initializers and loaded_source NEVER move.
---   R4 must install the result atomically with all writes, never before them;
---   rollback must retain the previous snapshot. Next is NOT a commit receipt.
---
--- When upvalueid exists, real old closure/anchor sharing is rechecked. Without
--- it, capture slots/names are checked but externally changed physical sharing
--- cannot be proved. Optional identity support is not replaced by a Probe.
--- Lua 5.1 without join is refused; metadata presence stubs in tests do not
--- establish cell-sharing support. There is no legacy map fallback here.
---
--- There is no module-global mutable state or cache. The session owner must
--- release snapshots/reports/selections on session end and invalidate them on
--- missing files, source/target changes and successful publication. This module
--- neither owns the session nor advances Watcher accepted/Dismiss state.
local Plan = require("SpellHotReload.Source.FunctionPlan")
local Compose = require("SpellHotReload.Source.Compose")
local Anchor = require("SpellHotReload.Load.Anchor")
local Lexer = require("SpellHotReload.Source.Lexer")
local M = { Kind = "SpellHotReload.FunctionVersions", Version = 1 }

local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function dense(v)
    if not plain(v) then return nil end
    local count, maximum = 0, 0
    for k in next, v do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k)
            or k == math.huge then return nil end
        count, maximum = count + 1, math.max(maximum, k)
    end
    if count ~= maximum then return nil end
    return count
end
local function copy(v)
    local result = {}
    for k, item in next, v do result[k] = item end
    return result
end
local function fail(code, message, state, name)
    return nil, { phase = "analyze", code = code, message = tostring(message),
        file = plain(state) and state.file or nil,
        unit_key = type(name) == "string" and ("local:" .. name) or nil }
end
local function inspect(content, state, snapshot)
    local result, err
    if snapshot ~= nil then result, err = Plan.InspectDiscovery(snapshot)
    else result, err = Plan.Inspect(content) end
    if result == nil then return fail(err.code, err.message, state) end
    return result
end
-- Length-delimited TOKEN sequence, not a hash or full Lua equivalence test.
-- Ignore comments/formatting; preserve opaque strings, numeric spelling and
-- every operator. Any token change conservatively requires a new definition.
local function signature(body)
    local pieces = {}
    for _, token in ipairs(Lexer.Tokenize(body)) do
        pieces[#pieces + 1] = token.kind .. ":" .. #token.value .. ":" .. token.value
    end
    return table.concat(pieces, "|")
end
local function function_names(scan)
    local list = {}
    for name in next, scan.definitions do list[#list + 1] = name end
    table.sort(list, function(a, b)
        return scan.definitions[a][1].statement < scan.definitions[b][1].statement
    end)
    return list
end
local function state_signatures(scan, units)
    local result = {}
    for _, declaration in ipairs(scan.bindings.declarations) do
        if units[declaration.name] == nil then
            local statement = scan.analysis.statements[declaration.statement]
            result[declaration.name] = signature(scan.analysis.source:sub(
                statement.source_range.first, statement.source_range.last))
        end
    end
    return result
end
local function snapshot_problem(state)
    if not plain(state) or state.kind ~= M.Kind or state.version ~= M.Version
        or not plain(state.entry) or state.anchor ~= state.entry.anchor
        or state.loaded_source ~= state.entry.loaded_source or state.file ~= state.entry.file
        or type(state.session_id) ~= "string" or state.session_id == ""
        or dense(state.names) == nil or not plain(state.units)
        or not plain(state.initializers) or type(state.revision) ~= "number"
        or state.revision < 0 or state.revision ~= math.floor(state.revision)
        or state.revision == math.huge then return "a valid version snapshot is required" end
    local seen = {}
    for _, name in ipairs(state.names) do
        local unit = state.units[name]
        if type(name) ~= "string" or seen[name] or not plain(unit) or unit.name ~= name
            or type(unit.fn) ~= "function" or type(unit.signature) ~= "string"
            or dense(unit.dependencies) == nil or not plain(unit.observed)
            or type(unit.definition_version) ~= "number"
            or unit.definition_version < 1 or unit.definition_version == math.huge
            or unit.definition_version ~= math.floor(unit.definition_version) then
            return "invalid published function record"
        end
        seen[name] = true
        local deps = {}
        for _, dep in ipairs(unit.dependencies) do
            if type(dep) ~= "string" or dep == "" or deps[dep] then
                return "invalid published capture names"
            end
            deps[dep] = true
        end
    end
    for name in next, state.units do
        if not seen[name] then return "unexpected published function record" end
    end
end
-- Reachability is over real free-upvalue names, never IR token-name deps.
-- `other` optionally contributes the other side for removed/changed edges.
local function reaches(units, name, targets, other)
    local seen = {}
    local function visit(current)
        if seen[current] then return false end
        seen[current] = true
        if targets[current] then return true end
        for _, graph in ipairs(other and { units, other } or { units }) do
            local unit = graph[current]
            if unit then
                for _, dep in ipairs(unit.dependencies) do
                    if visit(dep) then return true end
                end
            end
        end
        return false
    end
    return visit(name)
end
local function observations(units, name)
    local seen, result = {}, {}
    local function visit(current)
        if seen[current] then return end
        seen[current] = true
        local unit = units[current]
        if unit then
            for _, dep in ipairs(unit.dependencies) do
                local target = units[dep]
                if target then
                    result[dep] = target.definition_version
                    visit(dep)
                end
            end
        end
    end
    visit(name)
    return result
end

local function capture_reads(state)
    local reads = {}
    for _, name in ipairs(state.names) do
        local unit = state.units[name]
        local live, reason = Compose.Plan(unit.fn, state.entry)
        if live == nil then return fail("stale", reason, state, name) end
        local names = copy(live.names)
        table.sort(names)
        if #names ~= #unit.dependencies then
            return fail("stale", "published capture set changed", state, name)
        end
        for i, dep in ipairs(names) do
            if dep ~= unit.dependencies[i] then
                return fail("stale", "published capture set changed", state, name)
            end
        end
        for _, join in ipairs(live.joins) do
            if type(debug.upvalueid) == "function" then
                if debug.upvalueid(join.fn, join.index) ~= debug.upvalueid(join.anchor, join.donor) then
                    return fail("stale", "published capture no longer shares the anchor cell", state, name)
                end
            end
            reads[#reads + 1] = join -- identity/slot read, not a frozen state value
        end
    end
    return reads
end

---Seed(entry, session_id, initial) -> snapshot. First load ONLY, by contract.
---initial is the exact name->function identity set supplied by the load owner,
---not entry.map or a fresh live read used to disguise an external replacement.
---Every direct definition must be unique/safe; nonliteral state/aliases remain
---outside the function graph. Unknown or extra initial names are refused.
function M.Seed(entry, session_id, initial)
    if not plain(entry) or type(entry.loaded_source) ~= "string"
        or type(session_id) ~= "string" or session_id == "" or not plain(initial) then
        return fail("unsupported", "loaded entry, session id and initial identities required", entry)
    end
    local scan, err = inspect(entry.loaded_source, entry)
    if scan == nil then return nil, err end
    local names = function_names(scan)
    local expected = {}
    for _, name in ipairs(names) do expected[name] = true end
    for name in next, initial do
        if not expected[name] then return fail("unsupported", "unexpected initial identity", entry, name) end
    end
    local plan, perr = Plan.Prepare(entry.loaded_source, entry, names, initial)
    if plan == nil then return nil, perr end
    local state = { kind = M.Kind, version = M.Version, file = entry.file,
        entry = entry, anchor = entry.anchor, loaded_source = entry.loaded_source,
        session_id = session_id, revision = 0, names = names, units = {} }
    for _, item in ipairs(plan.functions) do
        local name = item.name
        local actual, aerr = Compose.Names(initial[name])
        if actual == nil then return fail("unsupported", aerr, entry, name) end
        local expected_names = copy(item.created.used)
        table.sort(actual); table.sort(expected_names)
        if #actual ~= #expected_names then
            return fail("stale", "initial capture set disagrees with source", entry, name)
        end
        for i = 1, #actual do
            if actual[i] ~= expected_names[i] then
                return fail("stale", "initial capture set disagrees with source", entry, name)
            end
        end
        local actual_plan, aplan_error = Compose.Plan(initial[name], entry)
        if actual_plan == nil then return fail("stale", aplan_error, entry, name) end
        if type(debug.upvalueid) == "function" then
            for _, join in ipairs(actual_plan.joins) do
                if debug.upvalueid(join.fn, join.index) ~= debug.upvalueid(join.anchor, join.donor) then
                    return fail("stale", "initial closure does not share the anchor cell", entry, name)
                end
            end
        end
        state.units[name] = { name = name, fn = initial[name],
            signature = signature(item.definition.body), body = item.definition.body,
            dependencies = actual, definition_version = 1, definition = item.definition }
    end
    state.initializers = state_signatures(scan, state.units)
    for _, name in ipairs(names) do state.units[name].observed = observations(state.units, name) end
    return state
end

---Compare(snapshot, content) -> full local-function report and ANALYSIS plan.
---All candidate literals may be compiled for binding/capture inspection; this
---does NOT schedule all of them for publication. There is no global cache.
---Only exact candidate bytes go in content, never a token hash for stale checks.
local function compare(state, content, snapshot, partial)
    local problem = snapshot_problem(state)
    if problem then return fail("unsupported", problem, state) end
    local scan, err = inspect(content, state, snapshot)
    if scan == nil then return nil, err end
    local reads, rerr = capture_reads(state)
    if reads == nil then return nil, rerr end
    for name in next, scan.definitions do
        if state.units[name] == nil then
            return fail("unsupported", "new direct function in a state slot requires restart", state, name)
        end
    end
    local identities = {}
    for _, name in ipairs(state.names) do identities[name] = state.units[name].fn end
    local prepared, perr
    local blocked={}
    if partial then
        -- Empty selection still proves the complete fixed declaration/Anchor
        -- contract. Candidate definition failures below have per-name scope.
        local prepare_one, scope_error = Plan.DiscoveryPreparer(snapshot, state.entry)
        if not prepare_one then return nil, scope_error end
        prepared, perr = prepare_one({}, identities)
        if not prepared then return nil, perr end
        for _,name in ipairs(state.names) do
            local current,why=Anchor.Get(state.entry,name)
            if why or current~=identities[name] then
                return fail("stale",why or "published function was externally replaced",state,name)
            end
            local slot,slot_error=Anchor.Slot(state.entry,name)
            if not slot then return fail("stale",slot_error,state,name) end
            -- Include blocked and zero-capture functions in the final identity
            -- read-set too; old closures sharing cells is not a value check.
            prepared.read_set[#prepared.read_set+1]={name=name,anchor=state.entry.anchor,
                index=slot,value=current}
            local one,err=prepare_one({name},identities)
            if not one then blocked[name]=err
            else
                prepared.functions[#prepared.functions+1]=one.functions[1]
                prepared.writes[#prepared.writes+1]=one.writes[1]
            end
        end
    elseif snapshot ~= nil then
        prepared, perr = Plan.PrepareDiscovery(snapshot, state.entry, state.names, identities)
    else
        prepared, perr = Plan.Prepare(content, state.entry, state.names, identities)
    end
    if prepared == nil then return nil, perr end
    local report = { kind = M.Kind .. ".Diff", version = M.Version,
        base = state, content = content, prepared = prepared, by_name = {},
        changed = {}, affected = {}, initializers = {}, capture_reads = reads,
        scope = "local-functions", discovery = snapshot, scan = partial and scan or nil }
    local targets = {}
    for _,name in ipairs(state.names) do
        if blocked[name] then
            local previous=state.units[name]
            report.by_name[name]={name=name,previous=previous,blocked=blocked[name],changed=true,
                signature=previous.signature,dependencies=copy(previous.dependencies),action="binding-blocked"}
            report.changed[#report.changed+1]=name
            targets[name]=true
        end
    end
    for _, item in ipairs(prepared.functions) do
        local name, previous = item.name, state.units[item.name]
        local sig = signature(item.definition.body)
        local changed = sig ~= previous.signature
        local dependencies = copy(item.created.used)
        table.sort(dependencies)
        report.by_name[name] = { name = name, signature = sig,
            dependencies = dependencies, item = item, previous = previous, changed = changed,
            action = changed and "compile-write" or "keep-definition" }
        if changed then targets[name] = true; report.changed[#report.changed + 1] = name end
    end
    for _, name in ipairs(state.names) do
        if reaches(state.units, name, targets, report.by_name) then
            report.affected[#report.affected + 1] = name
            if not targets[name] then report.by_name[name].action = "shared-impact" end
        end
    end
    local candidate_initializers = state_signatures(scan, state.units)
    for _, name in ipairs(scan.bindings.names) do
        if candidate_initializers[name] ~= state.initializers[name] then
            report.initializers[#report.initializers + 1] = {
                name = name, action = "preserve-state", requires_restart = true }
        end
    end
    return report
end

---Select(report, roots) -> preparation containing only necessary cell writes.
---Roots are explicit local function names, not Card or Host unit keys. Walk
---candidate dependencies for changed functions, saved actual dependencies for
---unchanged ones. Independent aliases are terminal state cells. Cycles work.
---Unrelated changed definitions stay pending in the full candidate report.
function M.Select(report, roots)
    if not plain(report) or report.kind ~= M.Kind .. ".Diff"
        or report.version ~= M.Version or not plain(report.by_name)
        or snapshot_problem(report.base) or dense(roots) == nil then
        return fail("unsupported", "diff and dense roots required")
    end
    local seen, needed, root_set = {}, {}, {}
    local problem
    local function visit(name)
        if seen[name] then return end
        seen[name] = true
        local current = report.by_name[name]
        if not current then return end
        if current.blocked then problem=problem or current.blocked;return end
        if current.changed then needed[name] = true end
        local graph = current.changed and current or current.previous
        for _, dep in ipairs(graph.dependencies) do visit(dep) end
    end
    for _, name in ipairs(roots) do
        if type(name) ~= "string" or report.by_name[name] == nil or root_set[name] then
            return fail("unsupported", "unknown or duplicate function root", report.base, name)
        end
        root_set[name] = true; visit(name)
    end
    if problem then return nil,problem end
    local prepared, base = report.prepared, report.base
    local result = { kind = M.Kind .. ".Selection", version = M.Version,
        base = base, report = report, roots = copy(roots), content = report.content,
        discovery = report.discovery,
        entry = base.entry, anchor = base.anchor, loaded_source = base.loaded_source,
        session_id = base.session_id, base_revision = base.revision,
        functions = {}, joins = {}, writes = {}, read_set = copy(prepared.read_set),
        capture_reads = copy(report.capture_reads),
        publications = {}, restarts = {}, selected = {}, pending = {}, affected = {} }
    for i, item in ipairs(prepared.functions) do
        if needed[item.name] then
            result.selected[#result.selected + 1] = item.name
            result.functions[#result.functions + 1] = item
            result.writes[#result.writes + 1] = prepared.writes[i]
            for _, join in ipairs(item.join_plan.joins) do result.joins[#result.joins + 1] = join end
        end
    end
    for _,name in ipairs(base.names) do
        if report.by_name[name].changed and not needed[name] then result.pending[#result.pending+1]=name end
    end
    -- A committed change propagates through the actual post-selection graph,
    -- not through still-pending candidate edges that have never been published.
    local effective = {}
    for _, name in ipairs(base.names) do
        effective[name] = needed[name] and report.by_name[name] or base.units[name]
    end
    for _, name in ipairs(base.names) do
        if reaches(effective, name, needed) then result.affected[#result.affected + 1] = name end
    end
    return result
end

---Next(selection) -> proposed snapshot. PURE, never installs it or reads live
---functions as a new baseline. Caller must keep the original snapshot until
---R4 successfully commits every write AND this snapshot in one transaction.
---No writes means no revision advance; initialization diagnostics never advance.
function M.Next(selection)
    if not plain(selection) or selection.kind ~= M.Kind .. ".Selection"
        or selection.version ~= M.Version or snapshot_problem(selection.base)
        or dense(selection.selected) == nil or not plain(selection.report) then
        return fail("unsupported", "a function selection is required")
    end
    local base = selection.base
    if #selection.selected == 0 then return base end
    local result = copy(base)
    result.revision, result.names, result.units = base.revision + 1, copy(base.names), {}
    result.initializers = copy(base.initializers)
    for _, name in ipairs(base.names) do
        result.units[name] = copy(base.units[name])
        result.units[name].dependencies = copy(base.units[name].dependencies)
    end
    for _, name in ipairs(selection.selected) do
        local update, previous = selection.report.by_name[name], base.units[name]
        result.units[name] = { name = name, fn = update.item.created.fn,
            signature = update.signature, body = update.item.definition.body,
            definition = update.item.definition, dependencies = copy(update.dependencies),
            definition_version = previous.definition_version + 1 }
    end
    for _, name in ipairs(base.names) do
        result.units[name].observed = observations(result.units, name)
    end
    return result
end

function M.Compare(state, content) return compare(state, content) end
---Shared candidate analysis only, never a newly inferred publication baseline.
---The caller/aggregate service owns common session/revision scope validation.
function M.CompareDiscovery(state, snapshot)
    if not plain(snapshot) or not plain(snapshot.common) then
        return fail("unsupported", "complete discovery required", state)
    end
    return compare(state, snapshot.common.content, snapshot)
end
---File-only explicit entry. Fixed declarations and ALL actual old sharing/
---identities remain mandatory. Unsupported candidate definitions stay blocked;
---Select rejects every root whose effective capture closure reaches them.
---This is not permission to ignore changed unknown top-level effects.
function M.CompareFileDiscovery(state,snapshot)
    if not plain(snapshot) or not plain(snapshot.common) then
        return fail("unsupported","complete discovery required",state)
    end
    return compare(state,snapshot.common.content,snapshot,true)
end

return M
