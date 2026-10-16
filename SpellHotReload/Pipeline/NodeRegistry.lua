-- Registry of current discovery adapters, keyed by unique Id.
local Adapter = require("SpellHotReload.Pipeline.Adapter")

local Registry = {}
Registry.__index = Registry

---@return table
function Registry.New()
    return setmetatable({
        _by_discovery_id = {},
    }, Registry)
end

---Register an explicit discovery adapter.
---The adapter's Id and contract fields must remain unchanged while registered.
function Registry:RegisterDiscovery(adapter)
    local ok, reason = Adapter.ValidateDiscovery(adapter)
    if not ok then return false, reason end
    local id = rawget(adapter, "Id")
    if self._by_discovery_id[id] ~= nil then
        return false, "discovery adapter Id already registered: " .. id
    end
    self._by_discovery_id[id] = adapter
    return true
end

---Return a fresh array of original adapter references, sorted by registered Id.
---Enumeration never invokes Match or any other adapter hook.
function Registry:Discoveries()
    local ids = {}
    for id in pairs(self._by_discovery_id) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local adapters = {}
    for i, id in ipairs(ids) do
        adapters[i] = self._by_discovery_id[id]
    end
    return adapters
end

return Registry
