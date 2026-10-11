--------------------------------------------------------------------------------
--- SpellHotReload tests/DriverSpec.lua
---
--- Pure spec for the adapter contract, the node registry, the value adapter and
--- the driver. Runs under plain Lua 5.1 and LuaJIT with the game directory as
--- cwd (see tests/Run.lua).
--------------------------------------------------------------------------------

local Adapter = require("SpellHotReload.Adapter")
local NodeRegistry = require("SpellHotReload.NodeRegistry")
local Driver = require("SpellHotReload.Driver")
local Value = require("SpellHotReload.Value")
local IR = require("SpellHotReload.Source.TopLevelIR")

local M = {}
local passed, failed = 0, 0
local failures = {}

local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = label
    end
end

local function eq(actual, expected, label)
    check(actual == expected,
        label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

local function new_driver()
    local registry = NodeRegistry.New()
    assert(registry:Register({ "global", "field", "local" }, Value))
    return Driver.New({ adapters = registry }), registry
end

local function parse_slot(src, index)
    local nodes = IR.Analyze(src)
    return Value.Parse(nodes[index or 1])
end

--------------------------------------------------------------------------------
-- adapter contract
--------------------------------------------------------------------------------

do
    local ok, reason = Adapter.Validate({})
    eq(ok, false, "adapter: empty table rejected")
    check(tostring(reason):find("Locate", 1, true) ~= nil, "adapter: reason names the missing hook")

    local minimal = { Locate = function() end, Inject = function() end, Commit = function() end }
    eq(Adapter.Validate(minimal), true, "adapter: minimal contract accepted")
    eq(Adapter.Validate(Adapter.Fallback), true, "adapter: fallback satisfies the contract")
    eq(Adapter.Validate(42), false, "adapter: non-table rejected")
end

--------------------------------------------------------------------------------
-- node registry
--------------------------------------------------------------------------------

do
    local registry = NodeRegistry.New()
    eq(registry:Register("global", Value), true, "registry: register one carrier")
    eq(registry:Register({ "field", "local" }, Value), true, "registry: register a list")
    eq(table.concat(registry:Carriers(), ","), "field,global,local", "registry: carriers sorted")
    eq(registry:For({ carrier = "global" }), Value, "registry: routes by carrier")
    eq(registry:For({ carrier = "host" }), Adapter.Fallback, "registry: unknown carrier falls back")
    eq(registry:For(nil), Adapter.Fallback, "registry: nil node falls back")

    local ok, reason = registry:Register("effect", { Locate = function() end })
    eq(ok, false, "registry: invalid adapter rejected")
    check(tostring(reason):find("Inject", 1, true) ~= nil, "registry: rejection names the hook")
    eq(registry:Register({}, Value), false, "registry: empty carrier list rejected")
end

--------------------------------------------------------------------------------
-- value adapter: statement forms
--------------------------------------------------------------------------------

do
    local site = parse_slot("T.field = 1 + 2")
    eq(site.form, "expr", "parse: assignment form")
    eq(site.target, "T.field", "parse: assignment target")
    eq(site.rhs, "1 + 2", "parse: assignment rhs")
    eq(site.local_target, false, "parse: field is not a local target")

    site = parse_slot("G = { 1, 2 }")
    eq(site.target, "G", "parse: global table target")
    eq(site.rhs, "{ 1, 2 }", "parse: table constructor rhs")

    site = parse_slot("local function f() end")
    eq(site.form, "local_function", "parse: local function form")
    eq(site.target, "f", "parse: local function target")

    site = parse_slot("local x = 41")
    eq(site.local_target, true, "parse: local is a local target")
    eq(site.target, "x", "parse: local target name")
    eq(site.rhs, "41", "parse: local rhs")

    site = parse_slot("function G() end")
    eq(site.target, "G", "parse: global function target")
    eq(site.rhs, "function() end", "parse: global function rhs")

    site = parse_slot("function A.B.C(x) end")
    eq(site.target, "A.B.C", "parse: dotted function target")
    eq(site.rhs, "function(x) end", "parse: dotted function rhs")

    site = parse_slot("function A.B:C(x) end")
    eq(site.target, "A.B.C", "parse: method target desugared")
    eq(site.rhs, "function(self, x) end", "parse: method self injected")

    site = parse_slot("function A.B:C() end")
    eq(site.rhs, "function(self) end", "parse: empty method params")
end

do
    local nodes = IR.Analyze("local a, b = 1, 2")
    eq(Value.Parse(nodes[1]).rhs, "1", "parse: first multi-target rhs")
    eq(Value.Parse(nodes[2]).rhs, "2", "parse: second multi-target rhs")

    local single = IR.Analyze("local a, b = 1")
    eq(Value.Parse(single[2]).rhs, nil, "parse: missing rhs stays nil")
end

--------------------------------------------------------------------------------
-- driver: global and field values
--------------------------------------------------------------------------------

do
    local driver = new_driver()

    _G.DRV_TARGET = nil
    local run, err = driver:Plan("f.lua", "DRV_TARGET = 41")
    check(run ~= nil, "driver: plan succeeds (" .. tostring(err) .. ")")
    eq(run.planned, 1, "driver: one planned node")
    eq(_G.DRV_TARGET, nil, "driver: plan leaves the live value alone")

    local report = driver:Commit(run)
    eq(report.committed, 1, "driver: one commit")
    eq(_G.DRV_TARGET, 41, "driver: commit writes the live value")
    eq(Driver.Count(run, "committed"), 1, "driver: entry marked committed")
    _G.DRV_TARGET = nil
end

do
    local driver = new_driver()

    _G.DRV_TABLE = {}
    local result = assert(driver:Apply("f.lua", 'DRV_TABLE.k = "v"'))
    eq(result.report.committed, 1, "driver: field commit count")
    eq(_G.DRV_TABLE.k, "v", "driver: field commit writes the table")

    _G.DRV_CALLS = 0
    local content = "DRV_FN = function() DRV_CALLS = DRV_CALLS + 1 return DRV_CALLS end"
    assert(driver:Apply("f.lua", content))
    eq(_G.DRV_CALLS, 0, "driver: injecting a closure does not run its body")
    eq(_G.DRV_FN(), 1, "driver: committed closure runs normally")
    eq(_G.DRV_FN(), 2, "driver: committed closure keeps its upvalues")
    eq(_G.DRV_CALLS, 2, "driver: committed closure writes the real global, not the sandbox")
    _G.DRV_FN, _G.DRV_CALLS, _G.DRV_TABLE = nil, nil, nil
end

--------------------------------------------------------------------------------
-- driver: change detection against a baseline
--------------------------------------------------------------------------------

do
    local driver = new_driver()

    local same = assert(driver:Plan("f.lua", "DRV_A = 1", { previous = "DRV_A = 1" }))
    eq(Driver.Count(same, "unchanged"), 1, "change: identical statement detected")
    eq(same.planned, 0, "change: nothing planned for identical text")

    local edited = assert(driver:Plan("f.lua", "DRV_A = 2", { previous = "DRV_A = 1" }))
    eq(edited.planned, 1, "change: edited statement planned")

    local added = assert(driver:Plan("f.lua", "DRV_A = 1\nDRV_B = 2", { previous = "DRV_A = 1" }))
    eq(Driver.Count(added, "unchanged"), 1, "change: untouched statement detected")
    eq(added.planned, 1, "change: added statement planned")

    local no_baseline = assert(driver:Plan("f.lua", "DRV_A = 1"))
    eq(no_baseline.planned, 1, "change: no baseline plans everything")
end

--------------------------------------------------------------------------------
-- driver: local capture map and dependency order
--------------------------------------------------------------------------------

do
    local driver = new_driver()
    local store = {}
    local content = "local base = 5\nlocal function read() return base end"

    local run = assert(driver:Plan("f.lua", content, { map = store }))
    eq(run.planned, 2, "local: both locals planned")
    eq(next(store), nil, "local: plan does not write the capture map")

    local report = driver:Commit(run)
    eq(report.committed, 2, "local: both locals committed")
    eq(store.base, 5, "local: value committed")
    eq(type(store.read), "function", "local: function committed")
    eq(store.read(), 5, "local: dependent sees the newly planned sibling")
end

do
    local driver = new_driver()
    local run = assert(driver:Plan("f.lua", "local a = 1"))
    local report = driver:Commit(run)
    eq(report.committed, 0, "local: no capture map means no commit")
    eq(#report.failed, 1, "local: failure is reported")
    check(tostring(report.failed[1].reason):find("capture map", 1, true) ~= nil,
        "local: failure reason mentions the capture map")
end

--------------------------------------------------------------------------------
-- driver: fallback and restart plumbing
--------------------------------------------------------------------------------

do
    local driver = Driver.New()
    local run = assert(driver:Plan("f.lua", "DRV_UNROUTED = 1"))
    eq(Driver.Count(run, "declined"), 1, "fallback: unregistered carrier declined")
    eq(#Driver.Select(run, "planned"), 0, "fallback: nothing planned")
    local report = driver:Commit(run)
    eq(report.committed, 0, "fallback: nothing committed")
end

do
    local calls = { commit = 0, restart = 0 }
    local fake = {
        name = "Fake",
        Restartable = true,
        Locate = function() return { fake = true } end,
        Inject = function() return { value = 1 } end,
        Commit = function() calls.commit = calls.commit + 1 return true end,
        Restart = function()
            calls.restart = calls.restart + 1
            if calls.restart == 1 then return false, "not yet" end
            return true
        end,
    }
    local registry = NodeRegistry.New()
    assert(registry:Register("host", fake))
    local driver = Driver.New({ adapters = registry })

    local run = assert(driver:Plan("h.lua",
        "stage.group.DefStageFunc('A@Easy', 'init', function(self) end)",
        { host_calls = { ["stage.group.DefStageFunc"] = true } }))
    eq(run.planned, 1, "restart: host node planned")
    eq(run.entries[1].node.carrier, "host", "restart: routed to the host adapter")

    local report = driver:Commit(run)
    eq(report.committed, 1, "restart: committed")
    eq(calls.restart, 1, "restart: first attempt ran")
    eq(report.restarts[1].ok, false, "restart: first attempt failed")

    local retry = driver:Restart(run)
    eq(retry.retried, 1, "restart: retry attempted")
    eq(retry.ok, 1, "restart: retry succeeded")
    eq(run.entries[1].restart.ok, true, "restart: entry updated")
end

--------------------------------------------------------------------------------
-- node signature
--------------------------------------------------------------------------------

do
    local a = IR.Analyze("T.x = 1")[1]
    local b = IR.Analyze("T.y = 1")[1]
    check(Driver.Signature(a) ~= Driver.Signature(b), "signature: distinct paths differ")
    eq(Driver.Signature(a), Driver.Signature(IR.Analyze("T.x = 2")[1]),
        "signature: same slot keeps its identity")
end

--------------------------------------------------------------------------------

function M.run()
    print(string.format("[SpellHotReload driver] %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do
        print("  FAIL: " .. label)
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
