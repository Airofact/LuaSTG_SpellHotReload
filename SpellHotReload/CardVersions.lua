--- R3 generated-card versions and explicit current-root planning.
--- PURE service: no source chunk/body, join, write, flush, publish or restart.
--- Seed(functions, initial, defaults) requires a genuine FIRST-load function
--- snapshot (revision 0) plus ALL discovered combat-card owners and all seven
--- genuine callback identities per owner. It does not manufacture load history.
--- initial = dense { {class_key, slot, card, callbacks={name->first function}} }
--- defaults = caller-owned standard callback identities, copied at first load.
--- Card tables must be plain; raw slots only. Metadata/functions must be genuine
--- first capture, not live reads after setter/Apply. LoadVersions owns production
--- capture. Callers must retain this snapshot and release all artifacts.
---
--- Compare(snapshot, complete_content) validates all saved raw callback identities
--- and real capture slots/sharing (when upvalueid exists); prepares analysis
--- closures by EACH callback definition point, never constructor-time locals.
--- Compare / CompareDiscovery require fixed first-load layout. CompareLocated
--- consumes ONE checked CardTarget location with fresh binding/capture/live.
--- Other changed-layout owners remain unmapped and pending, never guessed by key.
--- Absent candidate classes yield source tombstones, NOT live deletions; unclaimed
--- candidate cards stay unowned/pending_sources, NOT automatically seeded owners.
--- Only the located current root is selectable in a located report. All published
--- callbacks/captures are still checked, including absent/unmapped consumers.
--- New/deleted callbacks (except required init)
--- are modeled; deleted callbacks revert to the saved standard default identity.
--- No unknown RHS, generated wiring, alias initialization or state replay occurs.
---
--- Select(report, dense_card_keys) follows CHANGED callback candidate captures
--- and UNCHANGED callback actual saved captures to derive local-function roots.
--- FunctionVersions selects only required changed dependencies. Aliases terminate
--- the graph. Only changed callbacks of selected cards produce raw-slot proposals.
--- Unselected callback edits/local definitions remain pending in complete_content.
--- Helper-only propagation updates observations without compiling/publishing new
--- runtime consumers. Compare may compile all ANALYSIS literals; not a publish.
---
--- Next(selection) is only a proposed aggregate snapshot: R4 must atomically
--- install it AFTER all joins/cell writes/raw-slot publications succeed, or keep
--- the old snapshot. revision advances once for any nonempty definition group.
--- Local-function revision separately counts its own nonempty write groups.
--- Every callback source version and card definition version advance only on
--- that card's selected source publication; shared observations update separately.
--- loaded_source/layout/defaults never advance. Empty selection returns base.
---
--- No phase token/commit-time byte/session/target verification, journals, rollback,
--- poisoned sessions, restart contexts, Watcher acceptance, production Apply or
--- global mutable cache here. R4 must ALSO freeze/recheck class list/card ownership;
--- target table references alone do not prove live class slot identity.
--- Tables are read-only by contract, not a sandbox. upvalueid is optional, never
--- replaced with a Probe. Without it physical rejoin by outside code is unproved.
local Functions = require("SpellHotReload.FunctionVersions")
local Source = require("SpellHotReload.FunctionPlan")
local Card = require("SpellHotReload.Card")
local Compose = require("SpellHotReload.Compose")
local Lexer = require("SpellHotReload.Lexer")
local Target = require("SpellHotReload.CardTarget")
local M = { Kind = "SpellHotReload.CardVersions", Version = 1 }
local CALLBACKS = { "before", "init", "frame", "render", "beforedel", "del", "after" }
local allowed = {}
for _, name in ipairs(CALLBACKS) do allowed[name] = true end
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
    local r = {}
    for k, value in next, v do r[k] = value end
    return r
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function fail(code, message, state, key)
    return nil, { phase = "analyze", code = code, message = tostring(message),
        file = plain(state) and state.file or nil, unit_key = key }
end
local function key_of(class_key, slot)
    return "card:" .. #class_key .. ":" .. class_key .. ":" .. slot
end
local function signature(body)
    if body == nil then return "default" end
    local tokens = { "literal" }
    for _, t in ipairs(Lexer.Tokenize(body)) do
        tokens[#tokens + 1] = t.kind .. ":" .. #t.value .. ":" .. t.value
    end
    return table.concat(tokens, "|")
end
local function discover(content, state, snapshot)
    local scan, err
    if snapshot ~= nil then scan, err = Source.InspectDiscovery(snapshot)
    else scan, err = Source.Inspect(content) end
    if not scan then return nil, err end
    local match
    if snapshot ~= nil then
        local file_context = plain(snapshot.adapter_contexts)
            and snapshot.adapter_contexts.card or nil
        if not plain(file_context) or file_context.carrier ~= "card"
            or dense(snapshot.entries) == nil or not plain(snapshot.by_key) then
            return fail("unsupported", "complete registered Card discovery required", state)
        end
        local units = {}
        for _, entry in ipairs(snapshot.entries) do
            if not plain(entry) or not plain(entry.unit) then
                return fail("unsupported", "invalid discovery entry", state)
            end
            if entry.adapter == Card then
                local unit, ctx = entry.unit, entry.context
                if unit.carrier ~= "card" or not plain(unit.context)
                    or type(unit.context.class_key) ~= "string"
                    or unit.key ~= "card:" .. unit.context.class_key
                    or snapshot.by_key[unit.key] ~= entry or not plain(ctx)
                    or ctx.common ~= snapshot.common or not plain(ctx.adapter)
                    or ctx.adapter.file ~= file_context or ctx.adapter.unit ~= unit.context
                    or dense(unit.context.layout) == nil then
                    return fail("ownership", "Card discovery context disagrees", state)
                end
                units[#units + 1] = unit
            elseif entry.unit.carrier == "card" then
                return fail("ownership", "card unit not owned by registered Card", state)
            end
        end
        if #units ~= file_context.classes then
            return fail("unsupported", "incomplete Card discovery", state)
        end
        match = { units = units }
    else
        local merr
        match, merr = Card.Match(scan.analysis, { content = content })
        if not match then return fail(merr.code, merr.message, state, merr.unit_key) end
    end
    local layout, order, descriptors = {}, {}, {}
    for _, class in ipairs(match.units) do
        local ctx = class.context
        layout[ctx.class_key] = ctx.layout
        for slot, descriptor in ipairs(ctx.layout) do
            if descriptor.kind == "card" and descriptor.callbacks.init then
                local key = key_of(ctx.class_key, slot)
                order[#order + 1] = key
                descriptors[key] = { class_key = ctx.class_key, slot = slot,
                    descriptor = descriptor }
            end
        end
    end
    return { scan = scan, layout = layout, order = order, descriptors = descriptors }
end
local function fixed_layout(a, b)
    for class_key, layout in next, a do
        local newer = b[class_key]
        if not newer or #layout ~= #newer then return false end
        for i, desc in ipairs(layout) do
            local new = newer[i]
            if desc.kind ~= new.kind or desc.constructor ~= new.constructor
                or desc.perform ~= new.perform then return false end
        end
    end
    for class_key in next, b do if not a[class_key] then return false end end
    return true
end
local function prepare(discovery, descriptor, name, entry, defaults, state, key)
    local body = descriptor.callbacks[name]
    if not body then
        return { body = nil, signature = signature(nil), fn = defaults[name],
            dependencies = {}, visible = {}, join_plan = nil }
    end
    local point = descriptor.callback_points and descriptor.callback_points[name]
    local record
    for i, statement in ipairs(discovery.scan.analysis.statements) do
        if point and statement.source_range.first == point.first then
            record = discovery.scan.bindings.statements[i]; break
        end
    end
    if not record then return fail("unsupported", "callback definition point is not a top-level statement", state, key) end
    local visible = {}
    for local_name in next, record.visible do visible[#visible + 1] = local_name end
    table.sort(visible)
    local created, cerr = Compose.Create(body, nil, visible,
        { form = "expression", name = "CardVersions:" .. key .. ":" .. name })
    if not created then return fail("compile", cerr, state, key) end
    local plan, perr = Compose.Plan(created, entry)
    if not plan then return fail("unsupported", perr, state, key) end
    local dependencies = copy(created.used)
    table.sort(dependencies)
    return { body = body, signature = signature(body), fn = created.fn,
        dependencies = dependencies, visible = visible, join_plan = plan }
end
local function captures(record, entry, state, key)
    if record.body == nil then return {} end -- defaults are not file closures
    local live, err = Compose.Plan(record.fn, entry)
    if not live then return fail("stale", err, state, key) end
    local names = copy(live.names)
    table.sort(names)
    if not same(names, record.dependencies) then
        return fail("stale", "published callback captures changed", state, key)
    end
    for _, join in ipairs(live.joins) do
        if type(debug.upvalueid) == "function"
            and debug.upvalueid(join.fn, join.index) ~= debug.upvalueid(join.anchor, join.donor) then
            return fail("stale", "callback no longer shares the anchor cell", state, key)
        end
    end
    return live.joins
end
local function observed(unit, functions)
    local seen, result = {}, {}
    local function visit(name)
        if seen[name] then return end
        seen[name] = true
        local target = functions.units[name]
        if target then
            result[name] = target.definition_version
            for _, dep in ipairs(target.dependencies) do visit(dep) end
        end
    end
    for _, name in ipairs(CALLBACKS) do
        for _, dep in ipairs(unit.callbacks[name].dependencies) do visit(dep) end
    end
    return result
end
local function valid(state)
    if not plain(state) or state.kind ~= M.Kind or state.version ~= M.Version
        or not plain(state.functions) or state.functions.kind ~= Functions.Kind
        or state.entry ~= state.functions.entry or state.anchor ~= state.functions.anchor
        or state.loaded_source ~= state.functions.loaded_source
        or state.session_id ~= state.functions.session_id or state.file ~= state.functions.file
        or dense(state.order) == nil or not plain(state.units) or not plain(state.layout)
        or not plain(state.defaults) or type(state.revision) ~= "number"
        or state.revision < 0 or state.revision == math.huge
        or state.revision ~= math.floor(state.revision) then return false end
    local seen = {}
    for _, name in ipairs(CALLBACKS) do
        if type(state.defaults[name]) ~= "function" then return false end
    end
    for _, key in ipairs(state.order) do
        local unit = state.units[key]
        if type(key) ~= "string" or seen[key] or not plain(unit) or unit.key ~= key
            or not plain(unit.card) or not plain(unit.callbacks) or not plain(unit.observed)
            or type(unit.class_key) ~= "string" or type(unit.slot) ~= "number"
            or key ~= key_of(unit.class_key, unit.slot)
            or type(unit.definition_version) ~= "number" or unit.definition_version < 1 then return false end
        seen[key] = true
        for _, name in ipairs(CALLBACKS) do
            local cb = unit.callbacks[name]
            if not plain(cb) or type(cb.fn) ~= "function" or type(cb.signature) ~= "string"
                or dense(cb.dependencies) == nil or dense(cb.visible) == nil
                or type(cb.definition_version) ~= "number" or cb.definition_version < 1 then return false end
        end
    end
    for key in next, state.units do if not seen[key] then return false end end
    return true
end

---Seed only at trusted genuine first load. All discovered combat owners required.
function M.Seed(functions, initial, defaults)
    if not plain(functions) or functions.kind ~= Functions.Kind or functions.revision ~= 0
        or dense(initial) == nil or not plain(defaults) then
        return fail("unsupported", "first-load function snapshot, dense owners and defaults required", functions)
    end
    for _, name in ipairs(CALLBACKS) do
        if type(rawget(defaults, name)) ~= "function" then
            return fail("unsupported", "all seven standard defaults required", functions)
        end
    end
    local checked, ferr = Functions.Compare(functions, functions.loaded_source)
    if not checked then return nil, ferr end
    local discovery, derr = discover(functions.loaded_source, functions)
    if not discovery then return nil, derr end
    local owners, cards = {}, {}
    for _, owner in ipairs(initial) do
        if not plain(owner) or type(owner.class_key) ~= "string" or owner.class_key == ""
            or type(owner.slot) ~= "number" or owner.slot < 1 or owner.slot == math.huge
            or owner.slot ~= math.floor(owner.slot) or not plain(owner.card)
            or not plain(owner.callbacks) then
            return fail("unsupported", "invalid initial card owner", functions)
        end
        local key = key_of(owner.class_key, owner.slot)
        if owners[key] or cards[owner.card] or not discovery.descriptors[key] then
            return fail("ownership", "duplicate/unknown card owner", functions, key)
        end
        for name in next, owner.callbacks do
            if not allowed[name] then return fail("unsupported", "unknown initial callback", functions, key) end
        end
        owners[key], cards[owner.card] = owner, true
    end
    local state = { kind = M.Kind, version = M.Version, file = functions.file,
        functions = functions, entry = functions.entry, anchor = functions.anchor,
        loaded_source = functions.loaded_source, session_id = functions.session_id,
        revision = 0, layout = discovery.layout, order = copy(discovery.order),
        defaults = copy(defaults), units = {} }
    for _, key in ipairs(state.order) do
        local owner, desc = owners[key], discovery.descriptors[key]
        if not owner then return fail("ownership", "missing first-load card owner", functions, key) end
        local unit = { key = key, class_key = desc.class_key, slot = desc.slot,
            card = owner.card, callbacks = {}, definition_version = 1 }
        for _, name in ipairs(CALLBACKS) do
            local identity = rawget(owner.callbacks, name)
            if type(identity) ~= "function" or rawget(owner.card, name) ~= identity then
                return fail("stale", "genuine first callback identity required", functions, key)
            end
            local record, err = prepare(discovery, desc.descriptor, name, state.entry, defaults, state, key)
            if not record then return nil, err end
            if record.body == nil and identity ~= defaults[name] then
                return fail("stale", "first default callback identity mismatch", state, key)
            end
            record.fn, record.definition_version, record.join_plan = identity, 1, nil
            local actual, aerr = captures(record, state.entry, state, key)
            if not actual then return nil, aerr end
            unit.callbacks[name] = record
        end
        unit.observed = observed(unit, functions)
        state.units[key] = unit
    end
    return state
end

---Full candidate report; compares each actually published callback signature.
local function compare(state, content, snapshot, location)
    if not valid(state) then return fail("unsupported", "a valid card snapshot is required", state) end
    if snapshot ~= nil then
        local common = plain(snapshot) and snapshot.common or nil
        if not plain(common) or common.file ~= state.file
            or common.session_id ~= state.session_id or common.registry_entry ~= state.entry
            or common.loaded_source ~= state.loaded_source
            or common.base_revision ~= state.revision or common.published_units ~= state then
            return fail("stale", "discovery published baseline disagrees", state)
        end
    end
    local function_diff, ferr
    if snapshot ~= nil then function_diff, ferr = Functions.CompareDiscovery(state.functions, snapshot)
    else function_diff, ferr = Functions.Compare(state.functions, content) end
    if not function_diff then return nil, ferr end
    local discovery, derr = discover(content, state, snapshot)
    if not discovery then return nil, derr end
    if not location and (not fixed_layout(state.layout, discovery.layout)
        or not same(state.order, discovery.order)) then
        return fail("ambiguous", "fixed first-load card layout changed; restart/remapping required", state)
    end
    local report = { kind = M.Kind .. ".Diff", version = M.Version, base = state,
        content = content, discovery = snapshot, functions = function_diff, by_key = {}, changed = {},
        affected = {}, read_set = {}, capture_reads = {} }
    local claimed = {}
    if location then
        report.location, report.unmapped, report.unowned, report.tombstones = location, {}, {}, {}
    end
    local changed_functions = {}
    for _, name in ipairs(function_diff.affected) do changed_functions[name] = true end
    for _, key in ipairs(state.order) do
        local old, source = state.units[key], discovery.descriptors[key]
        if location then
            local before, after = state.layout[old.class_key], discovery.layout[old.class_key]
            -- Snapshot slot keys are lookup coordinates, not cross-version identity.
            if key == location.key then
                source = discovery.descriptors[key_of(old.class_key, location.candidate_slot)]
                if not source or source.descriptor ~= location.descriptor then
                    return fail("ownership", "located descriptor disagrees with full discovery", state, key)
                end
            elseif not after or not fixed_layout({[old.class_key]=before}, {[old.class_key]=after}) then
                source = nil
            end
        end
        local descriptor = source and source.descriptor
        local item = { key = key, previous = old, callbacks = {}, changed = false }
        if location then
            item.source_slot = source and source.slot
            item.source_key = source and ("card:" .. source.class_key)
            if source then
                local source_key = key_of(source.class_key, source.slot)
                if claimed[source_key] then
                    return fail("ownership", "candidate card has multiple published owners", state, key)
                end
                claimed[source_key] = key
            else
                item.pending = true
                item.source_status = discovery.layout[old.class_key] and "unmapped" or "source-absent"
                report.unmapped[#report.unmapped + 1] = key
                if item.source_status == "source-absent" then
                    report.tombstones[#report.tombstones + 1] = { key=key, previous=old,
                        definition_version=old.definition_version, action="restart-required",
                        reason="class absent from candidate; live owner retained" }
                end
            end
        end
        for _, name in ipairs(CALLBACKS) do
            local previous = old.callbacks[name]
            if rawget(old.card, name) ~= previous.fn then
                return fail("stale", "published raw callback was externally replaced", state, key)
            end
            report.read_set[#report.read_set + 1] = { target = old.card, key = name, value = previous.fn }
            local actual, aerr = captures(previous, state.entry, state, key)
            if not actual then return nil, aerr end
            for _, read in ipairs(actual) do report.capture_reads[#report.capture_reads + 1] = read end
            local candidate, cerr
            if descriptor then
                candidate, cerr = prepare(discovery, descriptor, name, state.entry, state.defaults, state, key)
                if not candidate then return nil, cerr end
            else
                -- Keep real published captures for impact/observations; no guessed Inject.
                candidate = copy(previous)
            end
            if previous.body and candidate.body and not same(previous.visible, candidate.visible) then
                return fail("unsupported", "callback definition-point binding changed", state, key)
            end
            candidate.changed = candidate.signature ~= previous.signature
            candidate.previous = previous
            item.callbacks[name] = candidate
            item.changed = item.changed or candidate.changed
        end
        local impacted = item.changed
        for _, name in ipairs(CALLBACKS) do
            for _, graph in ipairs({ old.callbacks[name], item.callbacks[name] }) do
                for _, dep in ipairs(graph.dependencies) do
                    if changed_functions[dep] then impacted = true end
                end
            end
        end
        item.action = item.source_status or (item.changed and "compile-publish"
            or (impacted and "shared-impact" or "keep-definition"))
        report.by_key[key] = item
        if item.changed then report.changed[#report.changed + 1] = key end
        if impacted then report.affected[#report.affected + 1] = key end
    end
    if location then
        for _, source_key in ipairs(discovery.order) do
            if not claimed[source_key] then
                local source = discovery.descriptors[source_key]
                report.unowned[#report.unowned + 1] = { source_key="card:" .. source.class_key,
                    candidate_slot=source.slot, descriptor=source.descriptor,
                    action="restart-required", reason="no proven captured owner" }
            end
        end
    end
    return report
end

---Explicit current cards; no automatic selection of other edited wrappers.
function M.Select(report, keys)
    if not plain(report) or report.kind ~= M.Kind .. ".Diff" or report.version ~= M.Version
        or not valid(report.base) or not plain(report.by_key) or dense(keys) == nil then
        return fail("unsupported", "card diff and dense card keys required")
    end
    local selected, root_set = {}, {}
    for _, key in ipairs(keys) do
        if type(key) ~= "string" or not report.by_key[key] or selected[key] then
            return fail("unsupported", "unknown or duplicate current card", report.base, key)
        end
        if report.location and (key ~= report.location.key or report.by_key[key].pending) then
            return fail("ambiguous", "only the proven current root may be selected", report.base, key)
        end
        selected[key] = true
        local item = report.by_key[key]
        for _, name in ipairs(CALLBACKS) do
            local cb = item.callbacks[name]
            local effective = cb.changed and cb or cb.previous
            for _, dep in ipairs(effective.dependencies) do
                if report.functions.by_name[dep] then root_set[dep] = true end
            end
        end
    end
    local roots = {}
    for _, name in ipairs(report.base.functions.names) do
        if root_set[name] then roots[#roots + 1] = name end
    end
    local functions, ferr = Functions.Select(report.functions, roots)
    if not functions then return nil, ferr end
    local result = { kind = M.Kind .. ".Selection", version = M.Version,
        base = report.base, base_revision = report.base.revision, report = report,
        discovery = report.discovery,
        content = report.content, entry = report.base.entry, anchor = report.base.anchor,
        session_id = report.base.session_id, roots = copy(keys), function_roots = roots,
        functions = functions, selected = {}, pending = {}, publications = {},
        joins = copy(functions.joins), writes = copy(functions.writes),
        read_set = copy(functions.read_set), capture_reads = copy(functions.capture_reads),
        restarts = {} }
    if report.location then
        result.location = report.location
        result.pending_sources = copy(report.unowned)
        result.tombstones = copy(report.tombstones)
    end
    for _, read in ipairs(report.read_set) do result.read_set[#result.read_set + 1] = read end
    for _, read in ipairs(report.capture_reads) do result.capture_reads[#result.capture_reads + 1] = read end
    for _, key in ipairs(report.base.order) do
        local item = report.by_key[key]
        if selected[key] then
            result.selected[#result.selected + 1] = key
            for _, name in ipairs(CALLBACKS) do
                local cb = item.callbacks[name]
                if cb.changed then
                    if cb.join_plan then
                        for _, join in ipairs(cb.join_plan.joins) do result.joins[#result.joins + 1] = join end
                    end
                    result.publications[#result.publications + 1] = {
                        unit_key = key, target = item.previous.card, key = name,
                        before = cb.previous.fn, value = cb.fn, callback = cb,
                    }
                end
            end
        elseif item.changed or item.pending then result.pending[#result.pending + 1] = key end
    end
    -- Compute actual observations under this selection, not pending graph edges.
    local next_functions, nerr = Functions.Next(functions)
    if not next_functions then return nil, nerr end
    result.affected = {}
    local written = {}
    for _, name in ipairs(functions.selected) do written[name] = true end
    for _, key in ipairs(report.base.order) do
        local item = report.by_key[key]
        local unit = { callbacks = {} }
        for _, name in ipairs(CALLBACKS) do
            local cb = item.callbacks[name]
            unit.callbacks[name] = selected[key] and cb.changed and cb or cb.previous
        end
        local impacted = selected[key] and item.changed
        for dep in next, observed(unit, next_functions) do
            if written[dep] then impacted = true end
        end
        if impacted then result.affected[#result.affected + 1] = key end
    end
    return result
end

---Propose versions only. Never install/reseed or read live as a new baseline.
function M.Next(selection)
    if not plain(selection) or selection.kind ~= M.Kind .. ".Selection"
        or selection.version ~= M.Version or not valid(selection.base)
        or dense(selection.publications) == nil or not plain(selection.functions) then
        return fail("unsupported", "a card selection is required")
    end
    local base = selection.base
    if #selection.publications == 0 and #selection.writes == 0 then return base end
    local functions, err = Functions.Next(selection.functions)
    if not functions then return nil, err end
    local result = copy(base)
    result.functions, result.revision, result.order = functions, base.revision + 1, copy(base.order)
    result.units = {}
    for _, key in ipairs(base.order) do
        local unit = copy(base.units[key])
        unit.callbacks = {}
        for _, name in ipairs(CALLBACKS) do
            unit.callbacks[name] = copy(base.units[key].callbacks[name])
            unit.callbacks[name].dependencies = copy(unit.callbacks[name].dependencies)
            unit.callbacks[name].visible = copy(unit.callbacks[name].visible)
        end
        result.units[key] = unit
    end
    local advanced = {}
    for _, publication in ipairs(selection.publications) do
        local key, name = publication.unit_key, publication.key
        local unit, cb = result.units[key], publication.callback
        unit.callbacks[name] = { body = cb.body, signature = cb.signature, fn = cb.fn,
            visible = copy(cb.visible), dependencies = copy(cb.dependencies),
            definition_version = base.units[key].callbacks[name].definition_version + 1 }
        if not advanced[key] then
            unit.definition_version = base.units[key].definition_version + 1
            advanced[key] = true
        end
    end
    for _, key in ipairs(result.order) do result.units[key].observed = observed(result.units[key], functions) end
    return result
end

function M.Compare(state, content) return compare(state, content) end
---Complete FileMatch snapshot carrying this actual publication baseline in
---common. Class keys are NOT the per-card publication keys in this report.
---Invalid/incomplete snapshots refuse; no hidden Match or legacy fallback.
function M.CompareDiscovery(state, snapshot)
    if not plain(snapshot) or not plain(snapshot.common) then
        return fail("stale", "discovery published baseline disagrees", state)
    end
    return compare(state, snapshot.common.content, snapshot)
end

---Explicit new entry: never overload legacy Compare or infer a location.
---Fresh reads are supplied by trusted orchestration; they are not an I/O proof.
function M.CompareLocated(state, location, binding, capture, live)
    if not valid(state) then return fail("unsupported", "a valid card snapshot is required", state) end
    local checked, err = Target.CheckDiscovery(location, binding, capture, live)
    if not checked then return nil, err end
    if location.target.snapshot ~= state then
        return fail("stale", "located publication baseline disagrees", state)
    end
    return compare(state, location.content, location.discovery, location)
end

return M
