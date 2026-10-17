local Adapter = require("SpellHotReload.Pipeline.Adapter")
local M = {}

function M.run()
    local passed = 0
    local function hook()
        error("validation must not invoke hooks")
    end
    local function valid()
        return {
            ContractVersion = 4, Id = "card",
            Match = hook, Reconcile = hook, Locate = hook, Inject = hook, Commit = hook,
        }
    end
    local function expect(candidate, expected, label)
        local ok, reason = Adapter.ValidateDiscovery(candidate)
        assert(ok == expected, label .. ": " .. tostring(reason))
        if not expected then
            assert(type(reason) == "string" and reason ~= "", label)
        end
        passed = passed + 1
    end

    expect(valid(), true, "minimal discovery adapter")
    expect(nil, false, "nil adapter")
    expect(42, false, "non-table adapter")
    local candidate = valid()
    candidate.ContractVersion = nil
    expect(candidate, false, "missing version")
    for _, version in ipairs({ false, 1, 2, 3, "4" }) do
        candidate = valid()
        candidate.ContractVersion = version
        expect(candidate, false, "unsupported version")
    end
    candidate = valid()
    candidate.Id = nil
    expect(candidate, false, "missing Id")
    for _, id in ipairs({ false, "", "Card", "bad id", {}, 42 }) do
        candidate = valid()
        candidate.Id = id
        expect(candidate, false, "invalid Id")
    end
    candidate = valid()
    candidate.Id = "card.callback-v2_1"
    expect(candidate, true, "valid Id punctuation")
    for _, name in ipairs({ "Match", "Reconcile", "Locate", "Inject", "Commit" }) do
        candidate = valid()
        candidate[name] = nil
        expect(candidate, false, "missing " .. name)
        candidate[name] = true
        expect(candidate, false, "non-function " .. name)
    end
    assert(table.concat(Adapter.Hooks,",")=="Match,Reconcile,Locate,Inject,Commit")
    passed=passed+1

    local mt = { __index = function() error("must not invoke __index") end }
    expect(setmetatable(valid(), mt), true, "explicit fields only")
    expect(setmetatable({}, mt), false, "no inherited contract")
    local legacy = { Locate = hook, Inject = hook, Commit = hook }
    expect(legacy, false, "legacy is not silently upgraded")
    print(string.format("[SpellHotReload discovery] %d passed, 0 failed", passed))
    return { passed = passed, failed = 0 }
end

return M
