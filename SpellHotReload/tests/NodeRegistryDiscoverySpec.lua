local Registry = require("SpellHotReload.NodeRegistry")
local Adapter = require("SpellHotReload.Adapter")
local M = {}

function M.run()
    local passed = 0
    local function eq(actual, expected, label)
        assert(actual == expected, label)
        passed = passed + 1
    end
    local function hook()
        error("registration and enumeration must not invoke hooks")
    end
    local function make(id)
        return {
            ContractVersion = 2, Id = id,
            Match = hook, Locate = hook, Inject = hook, Commit = hook,
        }
    end
    local registry = Registry.New()
    local function reject(adapter, fragment, label)
        local ok, reason = registry:RegisterDiscovery(adapter)
        eq(ok, false, label)
        assert(type(reason) == "string"
            and reason:find(fragment, 1, true), label .. ": reason")
    end

    eq(#registry:Discoveries(), 0, "initially empty")
    local legacy = { Locate = hook, Inject = hook, Commit = hook }
    eq(registry:Register("card", legacy), true, "legacy registration")
    eq(#registry:Discoveries(), 0, "legacy does not opt into discovery")
    reject(legacy, "ContractVersion", "legacy discovery rejected")
    reject(nil, "table", "nil discovery rejected")

    local z, a = make("z"), make("a")
    eq(registry:RegisterDiscovery(z), true, "register z")
    eq(registry:RegisterDiscovery(a), true, "register a")
    local adapters = registry:Discoveries()
    eq(#adapters, 2, "both adapters enumerated")
    eq(adapters[1], a, "sorted first, original reference")
    eq(adapters[2], z, "sorted last, original reference")
    reject(a, "already registered", "same object duplicate rejected")
    reject(make("a"), "already registered", "same Id duplicate rejected")
    eq(registry:Discoveries()[1], a, "duplicate does not replace adapter")

    local invalid = make("invalid")
    invalid.Match = nil
    reject(invalid, "Match", "invalid contract rejected")
    eq(#registry:Discoveries(), 2, "failed registration leaves map unchanged")
    eq(registry:For({ carrier = "card" }), legacy, "legacy routing preserved")
    eq(registry:For({ carrier = "host" }), Adapter.Fallback, "fallback preserved")
    eq(table.concat(registry:Carriers(), ","), "card", "carrier list unchanged")

    adapters[1] = nil
    adapters[3] = legacy
    eq(#registry:Discoveries(), 2, "returned array is independent")
    eq(registry:Discoveries()[1], a, "returned array cannot reorder registry")

    local other = Registry.New()
    eq(#other:Discoveries(), 0, "instances are independent")
    eq(other:Register("host", a), true, "v2 may use legacy explicitly")
    eq(#other:Discoveries(), 0, "legacy v2 registration does not opt in")
    eq(other:RegisterDiscovery(a), true, "separate discovery opt in")
    eq(other:For({ carrier = "host" }), a, "both routes coexist")
    local guarded = setmetatable(make("guarded"), { __index = hook })
    eq(other:RegisterDiscovery(guarded), true, "registration avoids __index")
    eq(other:Discoveries()[2], guarded, "enumeration avoids hooks")
    eq(#registry:Discoveries(), 2, "other instance cannot change registry")

    print(string.format("[SpellHotReload registry discovery] %d passed, 0 failed", passed))
    return { passed = passed, failed = 0 }
end

return M
