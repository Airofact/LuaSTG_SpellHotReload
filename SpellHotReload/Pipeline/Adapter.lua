-- The sole discovery/publication adapter contract. Validation never executes hooks.
local Adapter = {}
Adapter.Hooks = { "Match", "Locate", "Inject", "Commit" }

function Adapter.ValidateDiscovery(adapter)
    if type(adapter) ~= "table" then
        return false, "adapter must be a table"
    end
    if rawget(adapter, "ContractVersion") ~= 3 then
        return false, "discovery adapter requires ContractVersion = 3"
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
    return true
end

return Adapter
