--------------------------------------------------------------------------------
--- SpellHotReload.Pipeline.Adapter
---
--- The four-hook contract every carrier adapter implements, plus validation and
--- the shared declining fallback.
---
---   Locate(node, env)            -> handle | nil, reason
---   Inject(handle, node, env)    -> plan   | nil, reason
---   Commit(handle, plan, env)    -> ok, reason
---   Restart(handle, plan, env)   -> ok, reason        (optional)
---
--- Phase discipline (the reason the split exists):
---   * Locate only matches structural identity; it must not touch live objects.
---   * Inject only builds new values (fresh closures / freshly evaluated
---     expressions). It must not mutate anything the running game can observe.
---   * Commit is the single point where a live object changes, and it may only
---     be called from a frame boundary (the driver enforces the call site).
---   * Restart may fail; a failed restart leaves the committed definition in
---     place so it can be retried on its own.
---
--- `env` (assembled by the driver, never mutated by adapters except the capture
--- map that a `local` commit intentionally writes):
---   file      string            logical file key (basename)
---   content   string            the full new source text
---   map       table|nil         captured top-level locals for this file
---   registry  table|nil         UpvalueRegistry instance
---   previous  string|nil        baseline source text (change detection)
--------------------------------------------------------------------------------

local Adapter = {}

---Hooks a minimal adapter must provide.
Adapter.Required = { "Locate", "Inject", "Commit" }

---All hooks a full adapter may provide.
Adapter.Hooks = { "Locate", "Inject", "Commit", "Restart" }

---Check that `adapter` satisfies the contract.
---@param adapter table
---@return boolean
---@return string? reason
function Adapter.Validate(adapter)
    if type(adapter) ~= "table" then
        return false, "adapter must be a table"
    end
    for _, hook in ipairs(Adapter.Required) do
        if type(adapter[hook]) ~= "function" then
            return false, "adapter is missing required hook '" .. hook .. "'"
        end
    end
    return true
end

---Validate the explicit discovery contract without invoking adapter code.
---Legacy Validate remains independent; this does not register or run Match.
function Adapter.ValidateDiscovery(adapter)
    if type(adapter) ~= "table" then
        return false, "adapter must be a table"
    end
    if rawget(adapter, "ContractVersion") ~= 2 then
        return false, "discovery adapter requires ContractVersion = 2"
    end
    local id = rawget(adapter, "Id")
    if type(id) ~= "string" or not id:match("^[a-z][a-z0-9_.-]*$") then
        return false, "discovery adapter requires a valid lowercase Id"
    end
    for _, hook in ipairs({ "Match", "Locate", "Inject", "Commit" }) do
        if type(rawget(adapter, hook)) ~= "function" then
            return false, "adapter is missing required hook '" .. hook .. "'"
        end
    end
    local restartable = rawget(adapter, "Restartable")
    if restartable ~= nil and type(restartable) ~= "boolean" then
        return false, "Restartable must be a boolean"
    end
    local restart = rawget(adapter, "Restart")
    if restart ~= nil and type(restart) ~= "function" then
        return false, "Restart must be a function"
    end
    if restartable == true and restart == nil then
        return false, "restartable adapter requires Restart"
    end
    return true
end

---Declines every node, so an unregistered carrier degrades to a no-op instead of
---erroring. Installing it as a node registry's fallback is the intended use.
Adapter.Fallback = {
    name = "Fallback",
    Locate = function(node)
        local carrier = node ~= nil and node.carrier or "?"
        return nil, "no adapter registered for carrier '" .. tostring(carrier) .. "'"
    end,
    Inject = function() return nil, "fallback adapter cannot inject" end,
    Commit = function() return false, "fallback adapter cannot commit" end,
}

return Adapter
