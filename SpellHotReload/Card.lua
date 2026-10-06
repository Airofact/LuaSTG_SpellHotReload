--------------------------------------------------------------------------------
--- SpellHotReload.Card
---
--- Versioned runtime helpers below own current-root planning, frozen restart
--- and card-binding inspection rules. Versioned Locate/Inject/Commit consume
--- an explicit unit/context and caller-bound atomic transaction; Restart consumes
--- only a committed frozen handoff with a fresh lifecycle context.
--- Legacy entry points stay isolated and cannot bypass those requirements.
---
--- The legacy card adapter presents the card reload pipeline (CardCallbacks +
--- PracticeBinding) through the generic four-hook contract, so a card commit
--- travels the same Locate -> Inject -> Commit -> Restart path the driver
--- enforces for every other carrier.
---
--- Hook mapping (legacy):
---   Locate  -> CardCallbacks.Select(original, candidate, class_key, binding)
---   Inject  -> CardCallbacks.Build(descriptor, live_card, candidate, registry)
---   Commit  -> CardCallbacks.Publish(live_card, plan)           (live mutation)
---   Restart -> PracticeBinding.Restart(class_key, name, card, slot, include_previous)
---
--- A card is a unit, not a single statement: its identity spans a constructor
--- plus every callback statement, and the generated wiring must never run. The
--- "node" is therefore a request descriptor (see Card.Request), and Card.Plan
--- assembles a driver `run` holding one planned entry so the generic
--- Driver:Commit / Driver:Restart loop performs the live mutation and the stage
--- restart with the usual phase discipline.
---
--- Discovery (ContractVersion 2): Card also implements the file-level Match
--- contract, so one generated Boss file publishes one unit per card-list class
--- (`_editor_class["K"].cards = { ... }`) without depending on the current
--- practice. The unit context is the practice-independent descriptor (class
--- key, slot layout and the parsed CardCallbacks layout); Card.Bind adds the
--- live session binding and yields the request the legacy Locate/Inject pair
--- already consumes. Match compiles and tokenizes only - it never executes the
--- candidate wiring and never touches a live card.
---
--- Card env (the shared adapter env, with these fields):
---   file      string        logical file key (diagnostics only)
---   original  string        source as loaded at mod load (Select side A)
---   content   string        newly generated source (Select side B, Build input)
---   registry  table|nil     UpvalueRegistry:Get(file) (captured local functions)
--- `env.previous` / `env.source` are accepted as fallbacks for `env.original`.
--- Locate/Inject also accept the generic context shape
--- ({ common=..., adapter=... }); common supplies content, loaded_source,
--- registry and the live `binding` (see Card.Bind).
---
--- The restart switch stays on the driver call (Driver:Commit(run, { restart =
--- false })), matching every other restartable adapter.
--------------------------------------------------------------------------------

local CardCallbacks = require("SpellHotReload.CardCallbacks")
local Binding = require("SpellHotReload.PracticeBinding")

local compile = loadstring or load

local Card = {}

Card.name = "Card"
Card.Id = "card"
Card.ContractVersion = 2
Card.Restartable = true
Card.carriers = { card = true }

local RUNTIME_KIND = "SpellHotReload.Card.RuntimeContext"
local HANDLE_KIND = "SpellHotReload.Card.VersionedHandle"
local locate_versioned, inject_versioned, commit_versioned, restart_versioned
local function runtime_of(context)
    local adapter = type(context) == "table" and rawget(context, "adapter") or nil
    if type(adapter) == "table" then return rawget(adapter, "runtime") end
end
local function versioned_handle(handle)
    return type(handle) == "table" and rawget(handle, "kind") == HANDLE_KIND
end
local function versioned_refusal(handle, context, phase, detail)
    local common = type(context)=="table" and rawget(context,"common") or nil
    local unit = type(handle)=="table" and rawget(handle,"unit") or nil
    return false, {phase=phase, code="unsupported", message=detail,
        file=type(common)=="table" and rawget(common,"file") or nil,
        unit_key=type(unit)=="table" and rawget(unit,"key") or nil}
end

---Normalize a request from a captured binding (PracticeBinding.CurrentBinding)
---or from an explicit table. `binding` is what CardCallbacks.Select consumes;
---it defaults to the captured `{ slot, name, names }` triple, or to the numeric
---slot when the caller has no live name snapshot.
---@param fields table  -- { class_key, card, slot?, name?, names?, include_previous?, binding?, mode? }
---@return table? request
---@return string? reason
function Card.Request(fields)
    if type(fields) ~= "table" then
        return nil, "request fields must be a table"
    end
    local class_key = fields.class_key
    if type(class_key) ~= "string" or class_key == "" then
        return nil, "request needs a class_key"
    end
    if type(fields.card) ~= "table" then
        return nil, "request needs the live card object"
    end
    local binding = fields.binding
    if binding == nil then
        if type(fields.names) == "table" or fields.name ~= nil then
            binding = { slot = fields.slot, name = fields.name, names = fields.names }
        else
            binding = fields.slot
        end
    end
    return {
        class_key = class_key,
        card = fields.card,
        slot = fields.slot,
        name = fields.name,
        names = fields.names,
        include_previous = fields.include_previous == true,
        mode = fields.mode,
        binding = binding,
    }
end

---Synthetic node for the registry and for diagnostics. The card unit has no
---single IR statement, so this stands in for one and keeps a stable identity
---across edits (class key + restart slot).
---@param request table
---@return table node
function Card.Node(request)
    return {
        carrier = "card",
        kind = "card",
        name = request ~= nil and request.class_key or nil,
        slot = (request ~= nil and request.slot) or 0,
    }
end

---Mirror of Driver.Signature for the synthetic card node.
---@param request table
---@return string
function Card.Signature(request)
    local class_key = request ~= nil and request.class_key or ""
    local slot = (request ~= nil and request.slot) or 0
    return table.concat({ "card", "card", tostring(class_key), tostring(slot) }, "|")
end

---@param env table
---@return string? original
local function source_of(env)
    local original = env.original
    if original == nil then original = env.previous end
    if original == nil then original = env.source end
    return original
end

--------------------------------------------------------------------------------
--- discovery: unit / context alignment
--------------------------------------------------------------------------------

---Decode a string token into its literal value. The lexer already validated the
---literal, so this compiles a `return <literal>` chunk of that token only.
---@param token table?
---@return string?
local function string_token(token)
    if token == nil or token.kind ~= "string" then return nil end
    local chunk = compile("return " .. token.value)
    if not chunk then return nil end
    return chunk()
end

---Match `_editor_class["<key>"].cards = {` at token index `at`.
---@return string? class_key
local function cards_anchor(tokens, at)
    if tokens[at] == nil or tokens[at].value ~= "_editor_class" then return nil end
    if tokens[at + 1] == nil or tokens[at + 1].value ~= "[" then return nil end
    local key = string_token(tokens[at + 2])
    if key == nil then return nil end
    if tokens[at + 3] == nil or tokens[at + 3].value ~= "]" then return nil end
    if tokens[at + 4] == nil or tokens[at + 4].value ~= "." then return nil end
    if tokens[at + 5] == nil or tokens[at + 5].value ~= "cards" then return nil end
    if tokens[at + 6] == nil or tokens[at + 6].value ~= "=" then return nil end
    if tokens[at + 7] == nil or tokens[at + 7].value ~= "{" then return nil end
    return key
end

---Match `_editor_class["<key>"] = Class(` at token index `at`.
---@return boolean
local function class_anchor(tokens, at, key)
    if tokens[at] == nil or tokens[at].value ~= "_editor_class" then return false end
    if tokens[at + 1] == nil or tokens[at + 1].value ~= "[" then return false end
    if string_token(tokens[at + 2]) ~= key then return false end
    if tokens[at + 3] == nil or tokens[at + 3].value ~= "]" then return false end
    if tokens[at + 4] == nil or tokens[at + 4].value ~= "=" then return false end
    if tokens[at + 5] == nil or tokens[at + 5].value ~= "Class" then return false end
    if tokens[at + 6] == nil or tokens[at + 6].value ~= "(" then return false end
    return true
end

---Sorted keys of a `{ name = ... }` map, for a stable unit context.
---@param map table?
---@return string[]
local function names_of(map)
    local names = {}
    if type(map) == "table" then
        for name in pairs(map) do names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

---Enumerate the card-list classes of a shared TopLevelIR analysis.
---
---A class owns a unit when it publishes the `_editor_class["K"].cards = {` list
---anchor CardCallbacks.Read consumes. Classes without a card list (bullet and
---enemy classes) are not card units. The scan reads the shared lexer tokens, so
---`_editor_class` text inside a comment or a string never becomes a class.
---The window of a class runs from its creation statement (when present) to the
---statement before the next class window; every class publishes one valid,
---dense `source_ranges` entry and the windows never overlap.
---@param analysis table
---@return table[]? classes  -- { { class_key=, ranges={ {first,last}, ... } }, ... }
---@return string? reason
---@return string? code  -- "unsupported" input/malformed, "ambiguous" interleave
function Card.CardLists(analysis)
    if type(analysis) ~= "table" or type(analysis.tokens) ~= "table"
        or type(analysis.statements) ~= "table" then
        return nil, "card lists need the shared analysis", "unsupported"
    end
    local tokens, statements = analysis.tokens, analysis.statements
    local anchors, order = {}, {}
    for position, statement in ipairs(statements) do
        local key = cards_anchor(tokens, statement.tok.first)
        if key ~= nil then
            if key == "" then
                return nil, "card list class key is empty", "unsupported"
            end
            local entry = anchors[key]
            if entry == nil then
                entry = { class_key = key, first = position, last = position }
                anchors[key] = entry
                order[#order + 1] = entry
            end
            entry.last = position      -- a later `cards = {...}` rebuilds this list
        end
    end
    table.sort(order, function(a, b) return a.first < b.first end)
    -- Grow every window back over its class creation statement first, so a
    -- window never swallows the next class's `... = Class(...)` line.
    for _, entry in ipairs(order) do
        local previous = statements[entry.first - 1]
        if previous ~= nil and class_anchor(tokens, previous.tok.first, entry.class_key) then
            entry.first = entry.first - 1
        end
    end
    for i, entry in ipairs(order) do
        local stop = order[i + 1] ~= nil and order[i + 1].first or (#statements + 1)
        if entry.last >= stop then
            return nil, "card list blocks are interleaved: " .. entry.class_key, "ambiguous"
        end
        entry.last = stop - 1
        entry.ranges = { {
            first = statements[entry.first].source_range.first,
            last = statements[entry.last].source_range.last,
        } }
    end
    return order
end

---Assemble the practice-independent card unit for one card-list class. `layout`
---is the CardCallbacks.Read result; the context keeps it (the descriptor
---CardCallbacks.Build consumes) plus a slot summary, and never claims lexical
---binding safety.
---@param class_key string
---@param ranges table  -- dense { {first,last}, ... }
---@param layout table  -- CardCallbacks.Read entries
---@return table unit
function Card.Unit(class_key, ranges, layout)
    local slots, cards, others = {}, 0, 0
    for slot, entry in ipairs(layout) do
        slots[slot] = {
            slot = slot, kind = entry.kind, name = entry.name,
            callbacks = names_of(entry.callbacks),
        }
        if entry.kind == "card" then cards = cards + 1 else others = others + 1 end
    end
    return {
        key = "card:" .. class_key,
        carrier = "card",
        source_ranges = ranges,
        context = {
            class_key = class_key,
            slots = slots,
            cards = cards,
            others = others,
            layout = layout,
            binding_complete = false,
        },
    }
end

---Discovery Match: publish one unit per card-list class in the file. A file
---without card lists yields an empty success, but a class that owns a list and
---cannot be parsed fails the whole Match (never a silent skip).
---@param analysis table
---@param common table  -- { content = string, ... } from FileMatch
---@return table? result  -- { units, claims, context }
---@return table? error   -- { code, message, unit_key? }
function Card.Match(analysis, common)
    local content = type(common) == "table" and common.content or nil
    if type(content) ~= "string" then
        return nil, { code = "unsupported", message = "Match needs common.content" }
    end
    local classes, reason, code = Card.CardLists(analysis)
    if classes == nil then
        return nil, { code = code or "ambiguous", message = reason }
    end
    local units, claims = {}, {}
    for _, class in ipairs(classes) do
        local ok, layout, perr = pcall(CardCallbacks.Read, content, class.class_key, analysis)
        if not ok then
            return nil, { code = "unsupported",
                message = "card parse failed: " .. tostring(layout),
                unit_key = class.class_key }
        end
        if layout == nil then
            return nil, { code = "unsupported",
                message = "card parse failed: " .. tostring(perr),
                unit_key = class.class_key }
        end
        local unit = Card.Unit(class.class_key, class.ranges, layout)
        units[#units + 1] = unit
        for slot, entry in ipairs(layout) do
            if entry.kind == "card" then
                claims[#claims + 1] = {
                    kind = "constructor",
                    key = class.class_key .. ":" .. slot,
                    unit_key = unit.key,
                }
                for _, name in ipairs(names_of(entry.callbacks)) do
                    claims[#claims + 1] = {
                        kind = "callback",
                        key = class.class_key .. ":" .. slot .. ":" .. name,
                        unit_key = unit.key,
                    }
                end
            end
        end
    end
    return {
        units = units,
        claims = claims,
        context = { carrier = "card", classes = #units },
    }
end

---Normalize a generic context ({ common=..., adapter=... }) into the flat env
---the hooks already use. A legacy flat env passes through unchanged.
---@param value table?
---@return table env
local function env_of(value)
    if type(value) ~= "table" then return {} end
    local common = value.common
    if type(common) ~= "table" then return value end
    local original = common.loaded_source
    if original == nil then original = common.original end
    if original == nil then original = common.previous end
    return {
        file = common.file,
        content = common.content,
        original = original,
        registry = common.registry,
        binding = common.binding,
    }
end

---Bind a discovered unit to the live session, producing the practice-dependent
---request Locate/Inject consume. The unit context is the practice-independent
---half (class key + slot layout); `source.binding` is the live card snapshot
---(PracticeBinding.CaptureCurrent(): slot/name/names/card).
---@param unit table
---@param source table  -- { binding = { slot=, name=, names=, card=, include_previous=? } }
---@return table? request
---@return string? reason
function Card.Bind(unit, source)
    local context = type(unit) == "table" and unit.context or nil
    if type(context) ~= "table" or type(context.class_key) ~= "string"
        or context.class_key == "" then
        return nil, "Bind expects a card unit with a class_key"
    end
    local binding = type(source) == "table" and source.binding or nil
    if type(binding) ~= "table" then
        return nil, "no live card binding for " .. context.class_key
    end
    return Card.Request({
        class_key = context.class_key,
        card = binding.card,
        slot = binding.slot,
        name = binding.name,
        names = binding.names,
        include_previous = binding.include_previous,
        binding = binding,
    })
end

---Accept either the legacy (request, env) pair or the generic (unit, context)
---pair; return the request to locate plus the flat env the hooks use.
local function resolve(node, context)
    local env = env_of(context)
    if type(node) ~= "table" then
        return nil, env, "Locate expects a card request or unit"
    end
    if type(node.context) == "table" and type(node.context.class_key) == "string" then
        local request, reason = Card.Bind(node, env)
        if request == nil then return nil, env, reason end
        return request, env
    end
    return node, env
end

---Locate the live card in the candidate source. Structure only: the running
---card object is never touched. Accepts a legacy request or a discovered unit.
---@return table? handle
---@return string? reason
function Card.Locate(node, context)
    if runtime_of(context) ~= nil then return locate_versioned(node, context) end
    local request, env, rreason = resolve(node, context)
    if request == nil then
        return nil, rreason or "Locate expects a card request"
    end
    if type(request.class_key) ~= "string" or request.class_key == "" then
        return nil, "Locate expects a card request"
    end
    local original = source_of(env)
    if type(original) ~= "string" then
        return nil, "env.original (loaded source) is required to locate a card"
    end
    if type(env.content) ~= "string" then
        return nil, "env.content (candidate source) is required to locate a card"
    end
    local descriptor, reason = CardCallbacks.Select(original, env.content, request.class_key, request.binding)
    if descriptor == nil then
        return nil, reason
    end
    return { request = request, descriptor = descriptor, match = reason }, reason
end

---Rebuild the matched descriptor's callbacks without touching the live card.
---Generated wiring is never executed and no callback body runs. Accepts the
---legacy flat env or the generic context shape.
---@return table? plan
---@return string? reason
function Card.Inject(handle, request, env)
    if runtime_of(env) ~= nil or versioned_handle(handle) then
        return inject_versioned(handle, request, env)
    end
    env = env_of(env)
    if type(handle) ~= "table" or type(handle.descriptor) ~= "table" then
        return nil, "Inject expects a located card handle"
    end
    if type(env.content) ~= "string" then
        return nil, "env.content is required to rebuild card callbacks"
    end
    local plan, reason = CardCallbacks.Build(handle.descriptor, handle.request.card, env.content, env.registry)
    if plan == nil then return nil, reason end
    plan.descriptor = handle.descriptor
    plan.match = handle.match
    return plan, handle.match
end

---Versioned publication delegates only to the caller-bound atomic writer.
---Legacy publication remains isolated. Neither path restarts from Commit.
---@return boolean
---@return string|table? reason
---@return table? receipt -- versioned success only
function Card.Commit(handle, plan, env)
    if runtime_of(env) ~= nil or versioned_handle(handle)
        or (type(plan) == "table" and rawget(plan, "kind") == "SpellHotReload.CardVersions.Selection") then
        return commit_versioned(handle, plan, env)
    end
    if type(handle) ~= "table" or type(plan) ~= "table" then
        return false, "Commit expects a card handle and plan"
    end
    CardCallbacks.Publish(handle.request.card, plan)

    local request = handle.request
    local name = request.name
    local descriptor = plan.descriptor
    if type(descriptor) == "table" and type(descriptor.name) == "string" and descriptor.name ~= "" then
        name = descriptor.name
    end
    plan.restart = {
        class_key = request.class_key,
        name = name,
        card = request.card,
        slot = request.slot,
        include_previous = request.include_previous == true,
    }
    return true
end

---Start a fresh Spell Practice for the committed card. Safe to retry: a failed
---restart leaves the committed definitions in place.
---@return boolean
---@return string? reason
function Card.Restart(handle, plan, env)
    if (type(handle) == "table" and rawget(handle, "kind") == "versioned-card-restart")
        or (type(env) == "table" and type(rawget(env, "adapter")) == "table"
            and rawget(rawget(env, "adapter"), "restart") ~= nil) then
        return restart_versioned(handle, plan, env)
    end
    if runtime_of(env) ~= nil or versioned_handle(handle)
        or (type(plan) == "table" and rawget(plan, "kind") == "SpellHotReload.CardVersions.Selection") then
        return versioned_refusal(handle, env, "restart",
            "versioned restart requires the committed frozen handoff")
    end
    local context = (type(plan) == "table" and plan.restart)
        or (type(handle) == "table" and handle.restart)
    if context == nil then
        return false, "no restart context (Commit never ran)"
    end
    local ok, err = pcall(Binding.Restart, context.class_key, context.name,
        context.card, context.slot, context.include_previous)
    if not ok then
        return false, tostring(err)
    end
    return true
end

---Locate + Inject for one request, packaged as a driver run. Hand the run to
---Driver:Commit (live mutation + restart) and Driver:Restart (retry); nothing
---the running game can observe changes here.
---@param request table
---@param env table
---@return table? run
---@return string? error
function Card.Plan(request, env)
    env = env or {}
    local handle, lreason = Card.Locate(request, env)
    if handle == nil then return nil, lreason end
    local plan, ireason = Card.Inject(handle, request, env)
    if plan == nil then return nil, ireason end

    local entry = {
        node = Card.Node(request),
        signature = Card.Signature(request),
        adapter = Card,
        handle = handle,
        plan = plan,
        status = "planned",
    }
    return {
        file = env.file,
        content = env.content,
        env = env,
        request = request,
        handle = handle,
        plan = plan,
        entries = { entry },
        planned = 1,
        unchanged = 0,
        declined = 0,
    }
end

--------------------------------------------------------------------------------
--- versioned runtime: card-specific rules, explicit caller-owned context
---
--- Plugin owns fresh I/O/session views, the UI token/transaction, partial
--- bookkeeping, pending run and cache lifetime. These helpers do not accept a
--- Plugin receiver or store mutable adapter state. Only RestartVersioned calls
--- game code; preparation and inspection never publish, join or restart.
--- CardTarget/CardVersions import Card for source matching, so require those
--- services at call time after this module has finished loading.
--------------------------------------------------------------------------------

local function message(err)
    if type(err) == "string" then return err end
    if type(err) == "table" and getmetatable(err) == nil and type(rawget(err, "message")) == "string" then
        return rawget(err, "message")
    end
    return "operation refused"
end

function Card.FreezeBinding(current)
    local names
    if type(current.names) == "table" then
        names = {};for i,value in ipairs(current.names) do names[i] = value end
    end
    return {class_key=current.class_key,card=current.card,slot=current.slot,name=current.name,
        mode=current.mode,names=names,include_previous=current.include_previous}
end

---Same pure current-root path for Apply and explicit Inspect. The trusted
---refresh callback supplies real fresh bytes/binding; it is not a capability.
function Card.PrepareVersioned(capture, discovery, initial, proof, refresh)
    local unit, context = Card.RuntimeContext(capture, discovery, initial, proof, refresh)
    if not unit then return nil, "locate: " .. message(context) end
    local Driver = require("SpellHotReload.Driver")
    local prepared, err, phase = Driver.PrepareDiscovery(discovery.owner, discovery,
        {unit.key}, {[unit.key]=context})
    if not prepared then
        local stage = type(err)=="table" and getmetatable(err)==nil and rawget(err,"stage") or nil
        return nil, (type(stage)=="string" and stage or phase or "locate") .. ": " .. message(err)
    end
    local record = prepared.entries[1]
    local handle, selection = record.handle, record.plan
    return {target=handle.target, live=handle.live, location=handle.location, selection=selection,
        handle=handle, context=context, driver_prepared=prepared}
end

---One Card aggregate for the entire captured file, not one transaction per
---class. Fixed-layout comparison proves all owners; no current binding/restart.
function Card.PrepareFileVersioned(capture, discovery, proof, refresh)
    local owner = type(capture)=="table" and type(capture.ownership)=="table"
        and capture.ownership[1] or nil
    if type(owner)~="table" or type(owner.class_key)~="string" then
        return nil, "locate: captured card class required"
    end
    return Card.PrepareVersioned(capture,discovery,
        {class_key=owner.class_key,scope="file"},proof,refresh)
end

---Allocate the frozen handoff BEFORE commit. Candidate names/slots never
---replace the genuine live name/slot in the eventual EXT_POS handoff.
function Card.FreezeRestart(target, capture)
    return {kind="versioned-card-restart", file=target.file, session_id=target.session_id,
        entry=target.entry, anchor=target.entry.anchor, capture=capture, classes=target.classes,
        class_key=target.class_key, class=target.class, list=target.list, card=target.card,
        slot=target.slot, name=target.name, raw_name=rawget(target.card,"name"),
        include_previous=target.include_previous, key=target.key}
end

---Only a committed frozen run. Caller supplies its session/entry/lifecycle
---view, not current practice selection; Missing may still permit this retry.
function Card.RestartVersioned(run, live)
    if live.released or live.poisoned
        or live.publication_error or run.session_id ~= live.session_id
        or live.entry ~= run.entry or run.entry.anchor ~= run.anchor
        or (run.entry.reloadable ~= true and not run.entry.missing)
        or live.classes ~= run.classes
        or rawget(run.classes,run.class_key) ~= run.class
        or rawget(run.class,"cards") ~= run.list or rawget(run.list,run.slot) ~= run.card
        or rawget(run.card,"name") ~= run.raw_name or run.capture.snapshot ~= run.snapshot then
        return nil, "frozen restart target or session changed; restart game"
    end
    if Binding.IsReplay() then return nil, "replay mode not supported" end
    -- include_previous can consume preceding slots too. Check original complete
    -- ownership, not merely a still-present selected card in a changed list.
    for _, owner in ipairs(run.capture.ownership) do
        if rawget(run.classes,owner.class_key) ~= owner.class
            or getmetatable(owner.class) ~= nil or getmetatable(owner.list) ~= nil
            or rawget(owner.class,"cards") ~= owner.list or #owner.list ~= #owner.slots then
            return nil, "frozen class/list ownership changed; restart game"
        end
        local count = 0
        for slot in next, owner.list do
            if type(slot) ~= "number" or slot < 1 or slot > #owner.slots or slot ~= math.floor(slot)
                or rawget(owner.list,slot) ~= owner.slots[slot] then
                return nil, "frozen slot ownership changed; restart game"
            end
            count = count + 1
        end
        if count ~= #owner.slots then return nil, "frozen slot ownership changed; restart game" end
    end
    local unit = run.snapshot.units[run.key]
    for name, cb in next, unit.callbacks do
        if rawget(run.card,name) ~= cb.fn then return nil, "committed callback changed; restart game" end
    end
    local ok, err = pcall(Binding.Restart, run.class_key, run.name, run.card, run.slot, run.include_previous)
    if not ok then return nil, message(err) end
    return true
end

---Build scalar presentation, then revalidate after possible compiler/allocation
---callbacks. No commit authority is returned; callers own/cache the record.
function Card.InspectPrepared(prepared, capture, refresh)
    local Cards = require("SpellHotReload.CardVersions")
    local Target = require("SpellHotReload.CardTarget")
    local model, merr = Cards.Describe(prepared.selection)
    if not model then return nil, "describe: " .. message(merr) end
    local live, lerr = refresh()
    if not live then return nil, "inspection: " .. message(lerr) end
    local checked, cerr = Target.CheckDiscovery(prepared.location,live.binding,capture,live)
    if not checked then return nil, "inspection: " .. message(cerr) end
    return model, live
end

---Cheap card-binding part of a PAST inspection's validity. Caller separately
---checks bytes/generation/session/capture/revision and invalidates its cache.
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

---First-load card metadata is adapter-owned. Plugin calls this synchronously
---once per adopted file/session and owns the sticky success/refusal record.
---Never reseed from current live state. Capture does not depend on the legacy facade.
function Card.CaptureVersions(entry, session_id)
    local ok, capture, err = pcall(function()
        local classes = rawget(_G, "_editor_class")
        local boss_api = rawget(_G, "boss")
        local card_api = type(boss_api) == "table" and rawget(boss_api, "card") or nil
        local defaults = type(card_api) == "table" and rawget(card_api, "_default_card") or nil
        return Card.SeedVersions(entry, session_id, classes, defaults)
    end)
    local reason
    if not ok then
        reason = "first-load metadata failed: " .. (type(capture) == "string" and capture or "non-string error")
    elseif capture == nil then
        local detail = type(err) == "table" and rawget(err, "message") or err
        reason = type(detail) == "string" and detail or "first-load metadata unavailable"
    end
    return ok and capture or nil, reason
end

---Engine-facing queries stay behind Card. No freezing/cache here: callers
---choose the read boundary and FreezeBinding before discovery, as before.
function Card.CaptureCurrent()
    return Binding.CaptureCurrent()
end

function Card.IsReplay()
    return Binding.IsReplay()
end

---Generated-source support is Card's rule, not a generic file-store verdict.
---This format gate grants no runtime identity or publication authority.
function Card.CheckCandidateSource(content, file)
    return require("SpellHotReload.GeneratedBossScanner").Scan(content, file)
end

---Only consumes an already-complete discovery. The snapshot-local class key
---is adapter syntax, not cross-version live identity; PrepareVersioned rechecks.
function Card.DefinesCurrent(discovery, current)
    return discovery.snapshot.by_key["card:" .. current.class_key] ~= nil
end

--------------------------------------------------------------------------------
--- Card-owned first-load and commit policy. Trusted, already-validated inputs;
--- these helpers read raw identities only, never call business code or mutate.
--- Card validates its selection/capture metadata and proposes aggregate versions.
--- Transaction services own capability/cell checks, sealing, phase, cache
--- invalidation, joins/writes/version install and reverse recovery.
--------------------------------------------------------------------------------

local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function integer(v)
    return type(v) == "number" and v >= 1 and v < math.huge and v == math.floor(v)
end
local function dense(v)
    if not plain(v) then return nil end
    local count, maximum = 0, 0
    for k in next, v do
        if not integer(k) then return nil end
        count, maximum = count + 1, math.max(maximum, k)
    end
    if count == maximum then return count end
end
---Explicit Card-owned FIRST-load aggregate. Original trailer identities,
---complete Match/ownership and defaults are captured synchronously, never
---reseeded from current live values. Plugin owns sticky once-only bookkeeping.
---No source/body replay, join, setter, publication, restart or module cache.
---Dependencies are lazy to avoid the CardVersions -> Card cycle.
function Card.SeedVersions(entry, session_id, classes, defaults)
    local Source = require("SpellHotReload.FunctionPlan")
    local Functions = require("SpellHotReload.FunctionVersions")
    local Cards = require("SpellHotReload.CardVersions")
    local function fail(code, detail, e, key)
        return nil, {phase="capture", code=code, message=detail,
            file=plain(e) and rawget(e,"file") or nil, unit_key=key}
    end
    if not plain(entry) or type(rawget(entry, "file")) ~= "string" or entry.file == ""
        or entry.reloadable ~= true or entry.missing or not plain(entry.map)
        or type(session_id) ~= "string" or session_id == "" then
        return fail("unsupported", "genuine reloadable first load and session required", entry)
    end
    if not plain(classes) or not plain(defaults) then
        return fail("unsupported", "plain first-load class registry and standard defaults required", entry)
    end
    local scan, err = Source.Inspect(entry.loaded_source)
    if not scan then return nil, err end
    local initial = {}
    for name in next, scan.definitions do initial[name] = rawget(entry.map, name) end
    local functions, ferr = Functions.Seed(entry, session_id, initial)
    if not functions then return nil, ferr end
    local match, merr = Card.Match(scan.analysis, { content = entry.loaded_source })
    if not match then return nil, merr end
    local owners, ownership = Card.CaptureOwnership(match, classes, entry)
    if not owners then return nil, ownership end
    local snapshot, cerr = Cards.Seed(functions, owners, defaults)
    if not snapshot then return nil, cerr end
    return { kind = "SpellHotReload.LoadVersions", version = 1, snapshot = snapshot,
        classes = classes, ownership = ownership }
end

---Card-specific selection/capture shape, publication bases and located-root
---proof. Preserve the original guard's exact ordering and diagnostics. Called
---before sealing AND after flush/fresh by CommitCheck; not a phase capability.
---No source execution, compilation, joins, writes or version installation.
function Card.CheckCommitInput(selection, capture, live)
    local function fail(code, detail, file, key)
        return nil, {phase="commit", code=code, message=detail, file=file, unit_key=key}
    end
    if not plain(selection) or selection.kind ~= "SpellHotReload.CardVersions.Selection"
        or selection.version ~= 1 or not plain(selection.base)
        or not plain(capture) or capture.kind ~= "SpellHotReload.LoadVersions"
        or capture.version ~= 1 or not plain(live) then
        return fail("unsupported", "card selection, load capture and fresh live view required")
    end
    local base, entry = selection.base, live.entry
    local file = type(base.file) == "string" and base.file or nil
    if live.released or live.poisoned or not rawequal(live.capture, capture)
        or not rawequal(live.snapshot, base) or not rawequal(capture.snapshot, base)
        or live.session_id ~= base.session_id or selection.session_id ~= base.session_id
        or not plain(entry) or not rawequal(entry, base.entry) or not rawequal(selection.entry, entry)
        or entry.reloadable ~= true or entry.missing
        or entry.anchor ~= base.anchor or selection.anchor ~= base.anchor
        or type(base.anchor) ~= "function" or not plain(entry.slots)
        or entry.file ~= base.file or entry.loaded_source ~= base.loaded_source
        or selection.base_revision ~= base.revision
        or not plain(base.functions) or not plain(selection.functions)
        or not rawequal(selection.functions.base, base.functions)
        or selection.functions.base_revision ~= base.functions.revision then
        return fail("stale", "session, capture, anchor or publication revision changed", file)
    end
    if type(selection.content) ~= "string" or live.content ~= selection.content then
        return fail("stale", "candidate bytes changed", file)
    end
    if selection.location ~= nil then
        local Target = require("SpellHotReload.CardTarget")
        local checked, err = Target.CheckDiscovery(selection.location, live.binding, capture, live)
        if not checked then return fail(err.code, err.message, file, selection.location.key) end
    end
    return true
end

---Card owns the aggregate version format. This ONLY proposes the next snapshot;
---CardCommit still seals actions, journals and atomically installs it last.
---Lazy import avoids CardVersions -> Card initialization cycles.
function Card.ProposeVersion(selection)
    return require("SpellHotReload.CardVersions").Next(selection)
end

local callbacks = { before=true, init=true, frame=true, render=true,
    beforedel=true, del=true, after=true }
local CALLBACKS = { "before", "init", "frame", "render", "beforedel", "del", "after" }

---Called synchronously from the genuine first load's complete Card.Match.
---Returns fresh metadata, including placeholder ownership, never a live reseed.
function Card.CaptureOwnership(match, classes, entry)
    local function fail(code, detail, e, key)
        return nil, {phase="capture", code=code, message=detail,
            file=plain(e) and rawget(e,"file") or nil, unit_key=key}
    end
    local owners, ownership, seen = {}, {}, {}
    for _, unit in ipairs(match.units) do
        local ctx = unit.context
        local cls = rawget(classes, ctx.class_key)
        local list = plain(cls) and rawget(cls, "cards") or nil
        if not plain(cls) or dense(list) ~= #ctx.layout then
            return fail("ownership", "first-load class/list layout unavailable", entry, unit.key)
        end
        local slots = {}
        ownership[#ownership + 1] = {
            class_key = ctx.class_key, class = cls, list = list, slots = slots }
        for slot, descriptor in ipairs(ctx.layout) do
            local card = rawget(list, slot)
            if not plain(card) or seen[card] then
                return fail("ownership", "invalid or multiply owned first-load card", entry, unit.key)
            end
            seen[card], slots[slot] = true, card
            if descriptor.kind == "card" and descriptor.callbacks.init then
                if rawget(card, "is_combat") ~= true then
                    return fail("ownership", "combat descriptor does not own a combat card", entry, unit.key)
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

---Complete first-load ownership proof, not just the current selected slot.
---The returned set is transient; it grants no phase or mutation authority.
function Card.CheckOwnership(capture, base, classes)
    local file = type(base.file) == "string" and base.file or nil
    local function fail(code, detail, f, key)
        return nil, {phase="commit", code=code, message=detail, file=f, unit_key=key}
    end
    if not plain(classes) or not rawequal(classes, capture.classes)
        or dense(capture.ownership) == nil or not plain(base.units) then
        return fail("ownership", "class registry or ownership unavailable", file)
    end
    local owners, seen = {}, {}
    for _, owner in ipairs(capture.ownership) do
        if not plain(owner) or type(owner.class_key) ~= "string" or owners[owner.class_key]
            or not plain(owner.class) or not rawequal(rawget(classes, owner.class_key), owner.class)
            or not rawequal(rawget(owner.class, "cards"), owner.list)
            or dense(owner.slots) == nil or dense(owner.list) ~= #owner.slots then
            return fail("ownership", "first-load class/list ownership changed", file)
        end
        owners[owner.class_key] = owner
        for slot, card in ipairs(owner.slots) do
            if not plain(card) or seen[card] or not rawequal(rawget(owner.list, slot), card) then
                return fail("ownership", "first-load slot ownership changed", file)
            end
            seen[card] = true
        end
    end
    for key, unit in next, base.units do
        local owner = plain(unit) and owners[unit.class_key] or nil
        if not owner or not integer(unit.slot) or not rawequal(rawget(owner.slots, unit.slot), unit.card)
            or rawget(unit.card, "is_combat") ~= true then
            return fail("ownership", "published card no longer owns its combat slot", file, key)
        end
    end
    return seen
end

function Card.CheckCallbackRead(read, seen, file)
    local function fail(code, detail, f)
        return nil, {phase="commit", code=code, message=detail, file=f}
    end
    if not plain(read.target) or not seen[read.target] or not callbacks[read.key]
        or not rawequal(rawget(read.target, read.key), read.value) then
        return fail("stale", "raw callback read changed", file)
    end
    return true
end

---Only the seven supported callbacks on their captured raw combat card.
---Raw target/key values are checked before the transaction registers writes.
function Card.CheckPublications(publications, base, seen)
    local file = type(base.file) == "string" and base.file or nil
    local function fail(code, detail, f, key)
        return nil, {phase="commit", code=code, message=detail, file=f, unit_key=key}
    end
    local targets = {}
    for _, pub in ipairs(publications) do
        if not plain(pub) or not plain(pub.target) or not callbacks[pub.key]
            or type(pub.value) ~= "function" then
            return fail("unsupported", "raw callback publication required", file)
        end
        local unit = base.units[pub.unit_key]
        if not plain(unit) or not rawequal(pub.target, unit.card) or not seen[pub.target]
            or not rawequal(rawget(pub.target, pub.key), pub.before) then
            return fail("stale", "callback publication owner/preimage changed", file, pub.unit_key)
        end
        local keys = targets[pub.target] or {}
        if keys[pub.key] then return fail("ownership", "duplicate raw publication", file, pub.unit_key) end
        targets[pub.target], keys[pub.key] = keys, true
    end
    return true
end

---A candidate join may target only an unpublished closure selected for install.
---Defaults and unselected published callbacks are live too, not valid scratch.
function Card.CheckJoinDestinations(selection)
    local frozen = selection
    local function fail(code, detail, file)
        return nil, {phase="commit", code=code, message=detail, file=file}
    end
    local published, destinations = {[selection.anchor]=true}, {}
    for _, fn in next, selection.base.defaults do published[fn] = true end
    for _, unit in next, selection.base.functions.units do published[unit.fn] = true end
    for _, unit in next, selection.base.units do
        for _, cb in next, unit.callbacks do published[cb.fn] = true end
    end
    for _, op in ipairs(frozen.writes) do destinations[op.value] = true end
    for _, op in ipairs(frozen.publications) do destinations[op.value] = true end
    for _, op in ipairs(frozen.joins) do
        if published[op.fn] or not destinations[op.fn] then
            return fail("unsupported", "joins require unpublished destination closures", selection.base.file)
        end
    end
    return true
end

--------------------------------------------------------------------------------
--- Versioned Locate/Inject consume the SAME complete discovered unit/context.
--- A per-call runtime extension belongs to adapter context, never Match's common
--- or a module-level session cache. Legacy entry points stay distinct.
--------------------------------------------------------------------------------

local function stage_error(phase, stage, detail, file, key)
    local code = plain(detail) and rawget(detail, "code") or nil
    return nil, {phase=phase, code=type(code)=="string" and code or "unsupported",
        message=message(detail), file=file, unit_key=key, stage=stage}
end

---Bridge the complete discovery context to current-root runtime inputs.
---Do not mutate common/file/unit contexts or rediscover/filter the snapshot.
function Card.RuntimeContext(capture, discovery, initial, proof, refresh)
    local snapshot = plain(discovery) and rawget(discovery, "snapshot") or nil
    local common = plain(snapshot) and rawget(snapshot, "common") or nil
    local file = plain(common) and rawget(common, "file") or nil
    if not plain(capture) or not plain(discovery) or not plain(snapshot) or not plain(common)
        or not plain(snapshot.by_key) or not plain(capture.snapshot)
        or not plain(initial) or type(initial.class_key)~="string"
        or not plain(proof) or type(refresh)~="function" then
        return stage_error("locate", "locate", "complete discovery and explicit runtime inputs required", file)
    end
    local entry = rawget(snapshot.by_key, "card:" .. initial.class_key)
    if not plain(entry) or entry.adapter~=Card or not plain(entry.unit)
        or not plain(entry.context) or entry.context.common~=common or not plain(entry.context.adapter)
        or not plain(entry.unit.context) or not plain(entry.context.adapter.file)
        or entry.context.adapter.unit~=entry.unit.context then
        return stage_error("locate", "locate", "owned Card discovery entry required", file)
    end
    local runtime = {kind=RUNTIME_KIND, capture=capture, discovery=discovery, initial=initial,
        proof=proof, refresh=refresh, snapshot=capture.snapshot, file_scope=initial.scope=="file"}
    return entry.unit, {common=common, adapter={file=entry.context.adapter.file,
        unit=entry.context.adapter.unit, runtime=runtime}}
end

local function runtime_context(unit, context, phase)
    local runtime = runtime_of(context)
    local common = plain(context) and rawget(context, "common") or nil
    local file = plain(common) and rawget(common, "file") or nil
    if not plain(context) or not plain(common) or not plain(context.adapter)
        or not plain(runtime) or runtime.kind~=RUNTIME_KIND or not plain(runtime.discovery)
        or not plain(runtime.discovery.snapshot) or runtime.discovery.snapshot.common~=common
        or not plain(runtime.capture) or runtime.snapshot~=runtime.capture.snapshot
        or not plain(runtime.initial) or type(runtime.initial.class_key)~="string"
        or runtime.file_scope~=(runtime.initial.scope=="file")
        or not plain(runtime.proof) or type(runtime.refresh)~="function"
        or not plain(runtime.snapshot)
        or not plain(unit) or not plain(unit.context) or unit.carrier~="card"
        or unit.key~="card:" .. runtime.initial.class_key
        or unit.context.class_key~=runtime.initial.class_key
        or not plain(runtime.discovery.snapshot.by_key) then
        return stage_error(phase, phase, "versioned Card unit/context changed", file)
    end
    local entry = rawget(runtime.discovery.snapshot.by_key, unit.key)
    if not plain(entry) or entry.unit~=unit or entry.adapter~=Card or not plain(entry.context)
        or entry.context.common~=common or not plain(entry.context.adapter)
        or context.adapter.file~=entry.context.adapter.file
        or context.adapter.unit~=unit.context or entry.context.adapter.unit~=unit.context then
        return stage_error(phase, phase, "versioned Card unit/context ownership changed", file, unit.key)
    end
    return runtime, entry
end

locate_versioned = function(unit, context)
    local runtime, entry = runtime_context(unit, context, "locate")
    if not runtime then return nil, entry end
    local Target = require("SpellHotReload.CardTarget")
    local capture, file = runtime.capture, context.common.file
    if runtime.file_scope then
        local live, lerr = runtime.refresh()
        if not live then return stage_error("locate", "file preflight", lerr, file, unit.key) end
        local current, cerr = runtime_context(unit, context, "locate")
        if not current then return nil, cerr end
        if current~=runtime or not plain(live) or live.capture~=capture
            or live.snapshot~=runtime.snapshot or live.entry~=runtime.proof.entry
            or live.session_id~=context.common.session_id or live.content~=context.common.content
            or live.released or live.poisoned then
            return stage_error("locate", "file preflight", "file publication baseline changed", file, unit.key)
        end
        local owned, oerr = Card.CheckOwnership(capture,runtime.snapshot,live.classes)
        if not owned then return stage_error("locate", "file preflight", oerr, file, unit.key) end
        return {kind=HANDLE_KIND, unit=unit, context=context, runtime=runtime,
            capture=capture, snapshot=runtime.snapshot, discovery=runtime.discovery.snapshot, entry=entry,
            initial=runtime.initial, proof=runtime.proof, refresh=runtime.refresh, live=live}
    end
    local target, terr = Target.Resolve(runtime.initial, capture, runtime.proof)
    if not target then return stage_error("locate", "locate", terr, file, unit.key) end
    local live, lerr = runtime.refresh()
    if not live then return stage_error("locate", "versioned preflight", lerr, file, unit.key) end
    local current, cerr = runtime_context(unit, context, "locate")
    if not current then return nil, cerr end
    if current~=runtime or not plain(live) then
        return stage_error("locate", "locate", "versioned Card runtime changed during refresh", file, unit.key)
    end
    local checked, check_error = Target.Check(target, live.binding, capture, live)
    if not checked then return stage_error("locate", "locate", check_error, file, unit.key) end
    local location, why = Target.LocateDiscovery(target, runtime.discovery.snapshot, live.binding, capture, live)
    if not location then return stage_error("locate", "locate", why, file, unit.key) end
    return {kind=HANDLE_KIND, unit=unit, context=context, runtime=runtime,
        capture=capture, snapshot=runtime.snapshot, discovery=runtime.discovery.snapshot, entry=entry,
        initial=runtime.initial, proof=runtime.proof, refresh=runtime.refresh,
        target=target, live=live, location=location}
end

local function matching_handle(handle, unit, context, phase)
    local runtime, entry = runtime_context(unit, context, phase)
    if not runtime then return nil, entry end
    local file = context.common.file
    if not plain(handle) or handle.kind~=HANDLE_KIND or handle.unit~=unit or handle.context~=context
        or handle.runtime~=runtime or handle.capture~=runtime.capture or handle.snapshot~=runtime.snapshot
        or handle.discovery~=runtime.discovery.snapshot or handle.entry~=entry
        or handle.initial~=runtime.initial or handle.proof~=runtime.proof or handle.refresh~=runtime.refresh
        or not plain(handle.live)
        or (runtime.file_scope and (handle.target~=nil or handle.location~=nil))
        or (not runtime.file_scope and (not plain(handle.target) or not plain(handle.location)
            or handle.location.target~=handle.target or handle.location.discovery~=handle.discovery
            or handle.location.entry~=entry)) then
        return stage_error(phase, phase, "matching versioned Card handle required", file, unit.key)
    end
    return runtime, entry
end

inject_versioned = function(handle, unit, context)
    local runtime, err = matching_handle(handle, unit, context, "inject")
    if not runtime then return nil, err end
    local file = context.common.file
    local Cards = require("SpellHotReload.CardVersions")
    local report, rerr
    if runtime.file_scope then report, rerr = Cards.CompareDiscovery(runtime.snapshot,handle.discovery)
    else report, rerr = Cards.CompareLocated(runtime.snapshot, handle.location,
        handle.live.binding, runtime.capture, handle.live) end
    if not report then return stage_error("inject", "compare", rerr, file, unit.key) end
    local keys = runtime.file_scope and runtime.snapshot.order or {handle.target.key}
    local functions = runtime.file_scope and runtime.snapshot.functions.names or nil
    local selection, serr = Cards.Select(report,keys,functions)
    if not selection then return stage_error("inject", "select", serr, file, unit.key) end
    handle.selection = selection -- per-call output identity; not a module cache
    return selection
end

---The adapter consumes a caller-bound transaction, never publishes directly.
---The writer accepts only this exact handle/selection/context. It delegates to
---the existing atomic kernel; phase/cache/Guard/seal/rollback/poison remain there.
---Success preserves the boolean/error contract; result 3 is the trusted receipt.
commit_versioned = function(handle, plan, context)
    local unit = plain(handle) and rawget(handle, "unit") or nil
    local runtime, err = matching_handle(handle, unit, context, "commit")
    if not runtime then return false, err end
    if not plain(plan) or plan.kind~="SpellHotReload.CardVersions.Selection"
        or plan~=handle.selection or plan.base~=runtime.snapshot
        or plan.discovery~=handle.discovery or plan.location~=handle.location
        or plan.entry~=runtime.snapshot.entry or plan.anchor~=runtime.snapshot.anchor
        or plan.session_id~=runtime.snapshot.session_id then
        local _, why = stage_error("commit", "commit", "matching injected Card selection required",
            context.common.file, unit.key)
        return false, why
    end
    local transaction = rawget(context.adapter, "transaction")
    if type(transaction)~="function" then
        return versioned_refusal(handle, context, "commit",
            "versioned publication requires the atomic transaction")
    end
    local receipt, problem = transaction(handle, plan, context)
    if not receipt then return false, problem end
    return true, nil, receipt
end

---Retry consumes only the frozen run and an explicit current lifecycle view.
---No candidate unit/selection/discovery/compiler is retained in the handoff.
restart_versioned = function(run, plan, context)
    local common = plain(context) and rawget(context, "common") or nil
    local adapter = plain(context) and rawget(context, "adapter") or nil
    local live = plain(adapter) and rawget(adapter, "restart") or nil
    local file = plain(run) and rawget(run, "file") or nil
    local function refuse(detail)
        local _, err = stage_error("restart", "restart", detail, file)
        return false, err
    end
    if not plain(run) or run.kind~="versioned-card-restart" or plan~=nil
        or not plain(common) or not plain(adapter) or not plain(live)
        or runtime_of(context)~=nil or not plain(run.entry) or not plain(run.capture)
        or not plain(run.snapshot) or not plain(run.snapshot.units)
        or not plain(rawget(run.snapshot.units, run.key))
        or not plain(rawget(run.snapshot.units, run.key).callbacks)
        or not plain(run.classes) or not plain(run.class) or not plain(run.list) or not plain(run.card)
        or not plain(run.capture.ownership) then
        return refuse("committed frozen Card restart and explicit lifecycle context required")
    end
    if common.file~=file or common.session_id~=live.session_id
        or common.registry_entry~=live.entry or common.published_units~=run.snapshot then
        return refuse("frozen restart context changed; restart game")
    end
    local ok, err = Card.RestartVersioned(run, live)
    if not ok then return refuse(err) end
    return true
end

return Card
