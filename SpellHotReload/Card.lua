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
--- Card env (the shared adapter env, with these fields):
---   file      string        logical file key (diagnostics only)
---   original  string        source as loaded at mod load (Select side A)
---   content   string        newly generated source (Select side B, Build input)
---   registry  table|nil     UpvalueRegistry:Get(file) (captured local functions)
--- `env.previous` / `env.source` are accepted as fallbacks for `env.original`.
---
--- The restart switch stays on the driver call (Driver:Commit(run, { restart =
--- false })), matching every other restartable adapter.
--------------------------------------------------------------------------------

local CardCallbacks = require("SpellHotReload.CardCallbacks")
local Binding = require("SpellHotReload.PracticeBinding")

local Card = {}

Card.name = "Card"
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

---Locate the live card in the candidate source. Structure only: the running
---card object is never touched.
---@return table? handle
---@return string? reason
function Card.Locate(request, env)
    if type(request) ~= "table" then
        return nil, "Locate expects a card request"
    end
    env = env or {}
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
---Generated wiring is never executed and no callback body runs.
---@return table? plan
---@return string? reason
function Card.Inject(handle, request, env)
    env = env or {}
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
