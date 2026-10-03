--------------------------------------------------------------------------------
--- SpellHotReload.Card
---
--- The card adapter: presents the card reload pipeline (CardCallbacks +
--- PracticeBinding) through the generic four-hook contract, so a card commit
--- travels the same Locate -> Inject -> Commit -> Restart path the driver
--- enforces for every other carrier.
---
--- Hook mapping:
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
local Loader = require("SpellHotReload.GeneratedBossLoader")
local Binding = require("SpellHotReload.PracticeBinding")

local compile = loadstring or load

local Card = {}

Card.name = "Card"
Card.Id = "card"
Card.ContractVersion = 2
Card.Restartable = true
Card.carriers = { card = true }

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
        local ok, layout, perr = pcall(CardCallbacks.Read, content, class.class_key)
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

---The single live mutation: publish the rebuilt callbacks onto the live card and
---record the restart context. The stage restart itself stays out of Commit so a
---failed restart can be retried without recompiling (see Card.Restart).
---@return boolean
---@return string? reason
function Card.Commit(handle, plan, env)
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

return Card
