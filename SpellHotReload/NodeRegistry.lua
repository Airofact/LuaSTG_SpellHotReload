--------------------------------------------------------------------------------
--- SpellHotReload.NodeRegistry
---
--- Routes a node to the adapter that owns its carrier. Unregistered carriers
--- fall back to Adapter.Fallback, so the driver can walk a whole file without
--- special-casing the carriers it does not understand yet.
--------------------------------------------------------------------------------

local Adapter = require("SpellHotReload.Adapter")

local Registry = {}
Registry.__index = Registry

---@return table
function Registry.New()
    return setmetatable({ _by_carrier = {}, _fallback = Adapter.Fallback }, Registry)
end

---Register `adapter` for one carrier name or a list of them.
---@param carrier string|string[]
---@param adapter table
---@return boolean
---@return string? reason
function Registry:Register(carrier, adapter)
    local ok, reason = Adapter.Validate(adapter)
    if not ok then return false, reason end

    if type(carrier) == "table" then
        if #carrier == 0 then return false, "carrier list is empty" end
        for _, name in ipairs(carrier) do
            if type(name) ~= "string" or name == "" then
                return false, "carrier list contains a non-string entry"
            end
        end
        for _, name in ipairs(carrier) do
            self._by_carrier[name] = adapter
        end
        return true
    end

    if type(carrier) ~= "string" or carrier == "" then
        return false, "carrier must be a non-empty string or a list"
    end
    self._by_carrier[carrier] = adapter
    return true
end

---Resolve the adapter for a node, degrading to the fallback when unregistered.
---@param node table
---@return table adapter
function Registry:For(node)
    local carrier = node ~= nil and node.carrier or nil
    if type(carrier) == "string" then
        local adapter = self._by_carrier[carrier]
        if adapter ~= nil then return adapter end
    end
    return self._fallback
end

---@return string[]  -- registered carrier names, sorted
function Registry:Carriers()
    local names = {}
    for name in pairs(self._by_carrier) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

return Registry
