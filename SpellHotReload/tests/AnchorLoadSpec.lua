--------------------------------------------------------------------------------
--- SpellHotReload tests/AnchorLoadSpec.lua
---
--- Unit spec for the joint load-path capture output. AnchorLoad.Capture runs a
--- generated file exactly once and reports both halves of that single
--- execution: the legacy `name -> value` map the current hook already stores and
--- the file anchor the model is going to keep.
---
--- What is asserted here is the capture contract:
---
---   * the dual trailer keeps the map bytes GeneratedBossLoader produced and
---     appends Anchor's trailer, so `results[1]` cannot drift and
---     `results[2]` is the anchor;
---   * the file body runs once - a policy refusal, a trailer that cannot be
---     appended and a missing anchor all still mean one execution, never two;
---   * the map survives every refusal (it is what the legacy consumers read,
---     including on vanilla Lua 5.1) while only the reload verdict degrades with
---     a clear reason;
---   * nil/false slots are real anchor slots, while the map snapshot cannot
---     tell nil from missing - which is why `Values`/`Get`/`Set` read through
---     the anchor and `entry.map` is only the load-time snapshot;
---   * an external setter, a function reassignment and a whole-table
---     replacement are all observed through the anchor cell by the file's own
---     closures and by a freshly composed closure joined onto the anchor.
---
--- Runs under plain Lua 5.1 and LuaJIT with no engine globals (see
--- anchor-load/run-targeted.lua). Capture cases inject an explicit capability so
--- the anchor path is deterministic everywhere, while the *default* verdict is
--- asserted separately: vanilla Lua 5.1 has no `debug.upvaluejoin`, so it must
--- honestly keep the map and refuse to reload instead of failing the spec.
--------------------------------------------------------------------------------

local Anchor = require("SpellHotReload.Anchor")
local AnchorLoad = require("SpellHotReload.AnchorLoad")
local Compose = require("SpellHotReload.Compose")
local Loader = require("SpellHotReload.GeneratedBossLoader")
local IR = require("SpellHotReload.TopLevelIR")
local Binding = require("SpellHotReload.Binding")

local M = {}
local passed, failed = 0, 0
local failures = {}

local compile = loadstring or load

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

local function truthy(value, label)
    check(value == true, label .. " (expected true, got " .. tostring(value) .. ")")
end

local function falsy(value, label)
    check(value == false, label .. " (expected false, got " .. tostring(value) .. ")")
end

local function contains(text, needle, label)
    check(type(text) == "string" and text:find(needle, 1, true) ~= nil,
        label .. " (missing " .. tostring(needle) .. " in " .. tostring(text) .. ")")
end

local function reject(value, reason, label, fragment)
    eq(value, nil, label .. ": no value")
    check(type(reason) == "string" and reason ~= "", label .. ": reason is a string")
    if fragment ~= nil then contains(reason, fragment, label .. ": reason") end
end

---A capable-runtime capability table with selected flags overridden.
local function caps(overrides)
    local capability = {
        getupvalue = true, setupvalue = true, upvaluejoin = true,
        upvalueid = true,
    }
    for key, value in pairs(overrides or {}) do capability[key] = value end
    return capability
end

---Read and clear the global the execution-counting fixtures increment.
local function runs()
    local value = _G.__anchor_load_runs or 0
    _G.__anchor_load_runs = 0
    return value
end

local function count_keys(map)
    local count = 0
    if type(map) == "table" then
        for _ in pairs(map) do count = count + 1 end
    end
    return count
end

local function global_count()
    local count = 0
    for _ in pairs(_G) do count = count + 1 end
    return count
end

---The joint fixture: every shape the read-through contract talks about.
local FIXTURE = table.concat({
    "local counter = 0",
    "local helper = function() return 1 end",
    "local config = { a = 1 }",
    "local function set_counter(v) counter = v end",
    "local function replace_helper() helper = function() return 9 end end",
    "local function reset_config() config = { a = 2 } end",
    "local function read_counter() return counter end",
    "local function read_helper() return helper() end",
}, "\n") .. "\n"

function M.run()
    -- Read the real runtime's facilities exactly as the module does; nothing
    -- here asks Anchor to experiment on the runtime to prove them.
    local runtime = {
        getupvalue = type(debug.getupvalue) == "function",
        setupvalue = type(debug.setupvalue) == "function",
        upvaluejoin = type(debug.upvaluejoin) == "function",
        upvalueid = type(debug.upvalueid) == "function",
    }
    local joinable = runtime.upvaluejoin

    ----------------------------------------------------------------------------
    -- module identity
    ----------------------------------------------------------------------------
    eq(AnchorLoad.Kind, "SpellHotReload.AnchorLoad", "module kind")
    eq(type(AnchorLoad.Version), "number", "module version is a number")

    ----------------------------------------------------------------------------
    -- Trailer: the legacy map bytes first, Anchor's trailer second
    ----------------------------------------------------------------------------
    do
        local names = { "a", "b", "c" }
        local dual, reason = AnchorLoad.Trailer(names)
        check(dual ~= nil, "trailer: three names build (" .. tostring(reason) .. ")")
        if dual ~= nil then
            local map_src = Loader.BuildTrailer(names)
            local anchor_src = assert(Anchor.Trailer(names))
            local map_body = assert(map_src:match("^return%s+(.*)$"))
            local anchor_body = assert(anchor_src:match("^return%s+(.*)$"))
            eq(dual, "return " .. map_body .. ", " .. anchor_body,
                "trailer: the dual form is map then anchor")
            eq(dual:sub(1, 7 + #map_body), "return " .. map_body,
                "trailer: the map half is the legacy bytes")
            eq(dual:sub(-#anchor_body), anchor_body,
                "trailer: the anchor half is Anchor's bytes")
            check(dual:find("\n", 1, true) == nil, "trailer: one statement, one line")
        end
        eq(AnchorLoad.Trailer({}), "return {}, function() end", "trailer: no locals")
        eq(AnchorLoad.Trailer({ "a" }), "return {[\"a\"]=a}, function() return a end",
            "trailer: one name")
        eq(AnchorLoad.Trailer({ "a", "b" }),
            "return {[\"a\"]=a,[\"b\"]=b}, function() return a, b end",
            "trailer: two names")
    end

    do
        for _, bad in ipairs({
            { nil, "nil" }, { "a", "a string" }, { { [1] = "a", [3] = "c" }, "a hole" },
            { { "a", 2 }, "a non-string" }, { { "" }, "an empty name" },
            { { "a", kind = "extra" }, "an extra key" },
        }) do
            local trailer, reason = AnchorLoad.Trailer(bad[1])
            reject(trailer, reason, "trailer: " .. bad[2] .. " is refused",
                "dense array of strings")
        end
    end

    do
        -- The trailer is the trailer's job; one execution produces both halves.
        _G.__anchor_load_runs = 0
        local source = table.concat({
            "local counter = 0",
            "local bump = function() counter = counter + 1 return counter end",
            "__anchor_load_runs = __anchor_load_runs + 1",
        }, "\n") .. "\n"
        local names = { "counter", "bump" }
        local trailer = assert(AnchorLoad.Trailer(names))
        local chunk = assert(compile(source .. "\n" .. trailer, "@spec:dual"))
        local call = function() return chunk() end

        -- Arity first, without keeping the values: one call, one execution.
        eq(select("#", call()), 2, "trailer: the chunk reports two results")
        eq(runs(), 1, "trailer: one call executes the file body once")

        -- Then the pair itself: the map first, the anchor second.
        local map, anchor = call()
        eq(runs(), 1, "trailer: a second call executes the body once more")
        eq(map.counter, 0, "trailer: the first result is the value map")
        eq(type(map.bump), "function", "trailer: map entries are the live closures")
        eq(type(anchor), "function", "trailer: the second result is the anchor")
        eq(select("#", (function() return map, anchor end)()), 2,
            "trailer: a dual trailer returns two values")
    end

    ----------------------------------------------------------------------------
    -- Capture: one execution, map and anchor together
    ----------------------------------------------------------------------------
    local fixture_entry = AnchorLoad.Capture(FIXTURE, { capability = caps() })
    check(fixture_entry ~= nil, "capture: the joint fixture loads")
    if fixture_entry ~= nil then
        eq(fixture_entry.loaded_source, FIXTURE, "capture: the loaded source is recorded")
        eq(table.concat(fixture_entry.names, ","),
            "counter,helper,config,set_counter,replace_helper,reset_config,"
                .. "read_counter,read_helper", "capture: names in declaration order")
        truthy(fixture_entry.captured, "capture: the value map was harvested")
        truthy(fixture_entry.reloadable, "capture: the entry is reloadable")
        eq(fixture_entry.reason, nil, "capture: a captured entry has no reason")
        eq(fixture_entry.ret.n, 0, "capture: a captured file returns nothing itself")
        eq(AnchorLoad.ReturnArity(fixture_entry), 0, "capture: the reported arity")
        eq(count_keys(fixture_entry.map), 8, "capture: every local is in the map")
        eq(fixture_entry.map.counter, 0, "capture: the map holds the loaded value")
        eq(type(fixture_entry.map.helper), "function", "capture: the map holds the closure")
        eq(type(fixture_entry.anchor), "function", "capture: the anchor is a closure")
        eq(#fixture_entry.order, 8, "capture: every real slot is enumerated")
        eq(type(fixture_entry.slots.counter), "number", "capture: the counter slot index")
        eq(Anchor.Get(fixture_entry, "counter"), 0, "capture: the anchor cell reads the value")
        eq(fixture_entry.policy.reloadable, true, "capture: the policy verdict is carried")
    end

    do
        -- The harvested map must equal the legacy trailer's map for the same
        -- source, so nothing about the existing consumers changes.
        local source = "local a = 1\nlocal f = function() return a end\n"
        local legacy = assert(compile(source .. "\n" .. Loader.BuildTrailer({ "a", "f" }),
            "@spec:legacy"))()
        local dual = assert(AnchorLoad.Capture(source, { capability = caps() }))
        eq(count_keys(dual.map), count_keys(legacy), "map: the same key count")
        eq(dual.map.a, legacy.a, "map: the same value")
        eq(dual.map.f(), legacy.f(), "map: the same closure result")
        eq(dual.map.a, 1, "map: and the recorded value")
    end

    do
        -- One execution even when the policy refuses capture. A duplicate
        -- top-level local is refused by the policy on every runtime - unlike a
        -- bare global assignment, which is a legitimate late-bound slot and the
        -- default capability verdict, which is runtime dependent.
        _G.__anchor_load_runs = 0
        local blocked = AnchorLoad.Capture(
            "local a = 1\nlocal a = 2\n__anchor_load_runs = __anchor_load_runs + 1\n")
        check(blocked ~= nil, "once: a policy-refused file loads")
        if blocked ~= nil then
            truthy(blocked.captured, "once: the map is still harvested")
            falsy(blocked.reloadable, "once: the reload verdict is withheld")
            contains(blocked.reason, "duplicate top-level local",
                "once: and the policy reason is kept")
        end
        eq(runs(), 1, "once: a policy-refused file executes once")

        _G.__anchor_load_runs = 0
        local doctored = AnchorLoad.Capture(
            "local x = 1\n__anchor_load_runs = __anchor_load_runs + 1\nreturn 5\n", {
                capability = caps(),
                analysis = { nodes = {}, statements = {} },
                bindings = { names = { "x" }, duplicates = {}, opaque = false },
            })
        check(doctored ~= nil, "once: the trailer fallback loads")
        if doctored ~= nil then
            falsy(doctored.captured, "once: the fallback has no map")
            contains(doctored.reason, "trailer compile failed", "once: the fallback reason")
            eq(doctored.ret.n, 1, "once: the own return arity is preserved")
            eq(doctored.ret[1], 5, "once: the own return value is preserved")
            eq(AnchorLoad.ReturnArity(doctored), 1, "once: the reported arity")
        end
        eq(runs(), 1, "once: the trailer fallback executes once")
    end

    ----------------------------------------------------------------------------
    -- nil / false slots: the anchor tells nil from missing, the map cannot
    ----------------------------------------------------------------------------
    do
        local entry = AnchorLoad.Capture("local empty = nil\nlocal flag = false\n",
            { capability = caps() })
        check(entry ~= nil, "nil: the fixture loads")
        if entry ~= nil then
            truthy(entry.captured, "nil: the map is harvested")
            eq(#entry.order, 2, "nil: both slots are enumerated")
            truthy(entry.slots.empty ~= nil, "nil: the nil slot exists")
            truthy(entry.slots.flag ~= nil, "nil: the false slot exists")
            local value, reason = AnchorLoad.Get(entry, "empty")
            eq(value, nil, "nil: a nil slot reads nil")
            eq(reason, nil, "nil: and nil is a success, not an error")
            value, reason = AnchorLoad.Get(entry, "flag")
            eq(value, false, "nil: a false slot reads false")
            eq(reason, nil, "nil: and false is a success")
            eq(entry.map.empty, nil, "nil: the map snapshot loses the nil local")
            eq(count_keys(entry.map), 1, "nil: so the map only has the false local")
            local values = assert(AnchorLoad.Values(entry))
            eq(values.flag, false, "nil: Values keeps the false value")
            eq(count_keys(values), 1, "nil: and cannot keep the nil one either")
        end
    end

    ----------------------------------------------------------------------------
    -- Read-through: external setter, reassignment, whole-table replacement
    ----------------------------------------------------------------------------
    if fixture_entry ~= nil and fixture_entry.anchor ~= nil then
        local map = fixture_entry.map
        local ok_set = pcall(map.set_counter, 7)
        truthy(ok_set, "read-through: the file's own setter runs")
        eq(AnchorLoad.Get(fixture_entry, "counter"), 7, "read-through: the cell changed")
        eq(map.read_counter(), 7, "read-through: the file's closure sees the new value")
        eq(map.counter, 0, "read-through: the snapshot is stale on purpose")
        eq(AnchorLoad.Values(fixture_entry).counter, 7, "read-through: Values is live")

        local before = AnchorLoad.Get(fixture_entry, "helper")
        map.replace_helper()
        local after = AnchorLoad.Get(fixture_entry, "helper")
        check(after ~= before, "read-through: the helper was reassigned")
        eq(after(), 9, "read-through: the new helper is the live one")
        eq(map.read_helper(), 9, "read-through: the file's closure reads the new helper")
        eq(AnchorLoad.Values(fixture_entry).helper(), 9, "read-through: Values sees it too")
        eq(before(), 1, "read-through: the old closure is unchanged")

        local old_config = AnchorLoad.Get(fixture_entry, "config")
        map.reset_config()
        local new_config = AnchorLoad.Get(fixture_entry, "config")
        check(new_config ~= old_config, "read-through: the whole table was replaced")
        eq(new_config.a, 2, "read-through: the replacement table")
        eq(old_config.a, 1, "read-through: the replaced table is untouched")
        eq(map.config.a, 1, "read-through: the snapshot still holds the old table")
        eq(AnchorLoad.Values(fixture_entry).config.a, 2, "read-through: Values holds the new one")

        truthy(AnchorLoad.Set(fixture_entry, "counter", 100), "read-through: set through")
        eq(map.read_counter(), 100, "read-through: the file's closure sees the write")
        eq(AnchorLoad.Get(fixture_entry, "counter"), 100, "read-through: and so does Get")
    end

    do
        local entry = AnchorLoad.Capture(FIXTURE, { capability = caps() })
        check(entry ~= nil and entry.anchor ~= nil, "compose: a fresh fixture captures")
        if entry ~= nil and entry.anchor ~= nil then
            local fragment, ferr = Compose.Create(
                "local function probe() return counter + helper() + config.a end",
                "probe", { "counter", "helper", "config" }, { capability = caps() })
            check(fragment ~= nil, "compose: the fragment assembles (" .. tostring(ferr) .. ")")
            if fragment ~= nil then
                local wired, plan = Compose.Attach(fragment, entry, { capability = caps() })
                if joinable then
                    check(wired ~= nil, "compose: the fragment joins the anchor")
                    if wired ~= nil then
                        eq(wired(), 2, "compose: the wired closure reads the anchor cells")
                        truthy(AnchorLoad.Set(entry, "counter", 10), "compose: write through")
                        eq(wired(), 12, "compose: the wired closure sees the write")
                        eq(entry.map.counter, 0, "compose: the snapshot did not move")
                    end
                    check(plan ~= nil, "compose: the join plan is returned")
                else
                    eq(wired, nil, "compose: a join-less runtime refuses")
                    local refused, refused_plan, refused_reason =
                        Compose.Attach(fragment, entry)
                    eq(refused, nil, "compose: the default capability refuses")
                    eq(refused_plan, nil, "compose: with no plan")
                    contains(refused_reason, "capability", "compose: and names the capability")
                end
            end
        end
    end

    ----------------------------------------------------------------------------
    -- Policy refusals: load once, map kept, reload withheld, reason recorded
    ----------------------------------------------------------------------------
    do
        _G.__anchor_load_runs = 0
        local entry = AnchorLoad.Capture(
            "local a = 1\n__anchor_load_runs = __anchor_load_runs + 1\nreturn 1, nil, 3\n")
        check(entry ~= nil, "return: a returning file loads")
        if entry ~= nil then
            falsy(entry.captured, "return: the map is not harvested")
            falsy(entry.reloadable, "return: not reloadable")
            eq(entry.map, nil, "return: no map")
            eq(entry.anchor, nil, "return: no anchor")
            contains(entry.reason, "top-level return", "return: the policy reason is kept")
            eq(entry.names[1], "a", "return: names are still reported")
            eq(entry.ret.n, 3, "return: the return arity is preserved")
            eq(entry.ret[1], 1, "return: the first value")
            eq(entry.ret[2], nil, "return: the nil value survives")
            eq(entry.ret[3], 3, "return: the third value")
            eq(AnchorLoad.ReturnArity(entry), 3, "return: the reported arity")
            eq(select("#", AnchorLoad.ReturnValues(entry)), 3,
                "return: ReturnValues keeps the arity")
            local v1, v2, v3 = AnchorLoad.ReturnValues(entry)
            eq(v1, 1, "return: the first value again")
            eq(v2, nil, "return: the trailing nil survives")
            eq(v3, 3, "return: and the last value")
        end
        eq(runs(), 1, "return: executed exactly once")
    end

    do
        local entry = AnchorLoad.Capture("local x = 1\nlocal x = 2\n",
            { capability = caps() })
        check(entry ~= nil, "duplicate: a shadowed file loads")
        if entry ~= nil then
            truthy(entry.captured, "duplicate: the legacy map is still harvested")
            eq(entry.map.x, 2, "duplicate: the trailer binds the latest declaration")
            falsy(entry.reloadable, "duplicate: the file is not reloadable")
            contains(entry.reason, "duplicate top-level local", "duplicate: the reason")
            eq(entry.anchor ~= nil, true, "duplicate: the anchor is still reported")
        end
    end

    do
        local entry = AnchorLoad.Capture("local a = 1\nlocal b = 2\n",
            { capability = caps(), limit = 1 })
        check(entry ~= nil, "limit: an over-limit file loads")
        if entry ~= nil then
            truthy(entry.captured, "limit: the map is harvested")
            falsy(entry.reloadable, "limit: the file is not reloadable")
            contains(entry.reason, "slot limit exceeded: 2 > 1", "limit: the reason")
        end
    end

    do
        local entry = AnchorLoad.Capture("local a = 1\n", {
            capability = caps(),
            bindings = { names = { "a" }, duplicates = {}, opaque = true },
        })
        check(entry ~= nil, "opaque: an opaque snapshot loads")
        if entry ~= nil then
            truthy(entry.captured, "opaque: the map is harvested")
            falsy(entry.reloadable, "opaque: the file is not reloadable")
            contains(entry.reason, "unparsed top-level statement", "opaque: the reason")
        end
    end

    ----------------------------------------------------------------------------
    -- Capability: the reload verdict degrades, the load never does
    ----------------------------------------------------------------------------
    do
        local entry = AnchorLoad.Capture("local a = 1\n",
            { capability = caps({ upvaluejoin = false }) })
        check(entry ~= nil, "capability: an incapable runtime still loads")
        if entry ~= nil then
            truthy(entry.captured, "capability: the map is harvested")
            truthy(entry.anchor ~= nil, "capability: the anchor is still enumerated")
            falsy(entry.reloadable, "capability: the reload verdict is withheld")
            contains(entry.reason, "capability", "capability: the reason is kept")
            contains(entry.reason, "upvaluejoin", "capability: the missing part is named")
            eq(AnchorLoad.Get(entry, "a"), 1, "capability: the cell still reads")
        end
    end

    do
        local entry = AnchorLoad.Capture("local a = 1\n")
        check(entry ~= nil, "default: the default capability loads")
        if entry ~= nil then
            truthy(entry.captured, "default: the map is harvested on the real runtime")
            if joinable then
                truthy(entry.reloadable, "default: a join-capable runtime reloads")
                eq(entry.reason, nil, "default: with no reason")
                truthy(Anchor.Live(entry), "default: and the entry is live")
            else
                falsy(entry.reloadable, "default: a join-less runtime does not reload")
                contains(entry.reason, "capability", "default: the reason is kept")
                eq(entry.reason:find("upvaluejoin", 1, true) ~= nil, true,
                    "default: and names upvaluejoin")
            end
        end
    end

    do
        -- `debug.getupvalue` is what enumeration needs. `Anchor.Slots` reads the
        -- *real* runtime, not the injected capability, so on a capable runtime
        -- the anchor is still enumerated; only the reload verdict is withheld
        -- with the missing part named.
        local entry = AnchorLoad.Capture("local a = 1\n",
            { capability = caps({ getupvalue = false }) })
        check(entry ~= nil, "capability: a runtime without getupvalue still loads")
        if entry ~= nil then
            truthy(entry.captured, "capability: the map is harvested")
            check(entry.anchor ~= nil,
                "capability: the anchor is still enumerated (Slots reads the real debug)")
            check(entry.slots ~= nil, "capability: and its slots with it")
            falsy(entry.reloadable, "capability: the reload verdict is withheld")
            contains(entry.reason, "capability", "capability: the reason is kept")
            contains(entry.reason, "getupvalue", "capability: and names the missing part")
            eq(AnchorLoad.Get(entry, "a"), 1, "capability: the cell still reads")
        end
    end

    ----------------------------------------------------------------------------
    -- Failure staging and inputs
    ----------------------------------------------------------------------------
    do
        local bad, reason, stage = AnchorLoad.Capture("local x = (1\n")
        reject(bad, reason, "compile: a bad file fails", "compile failed")
        eq(stage, "compile", "compile: the stage is reported")
        bad, reason, stage = AnchorLoad.Capture("error('boom')\n")
        reject(bad, reason, "run: a failing file fails", "run failed")
        contains(reason, "boom", "run: the underlying error is kept")
        eq(stage, "run", "run: the stage is reported")
        bad, reason, stage = AnchorLoad.Capture(nil)
        reject(bad, reason, "analyze: a non-string fails", "content must be a string")
        eq(stage, "analyze", "analyze: the stage is reported")
    end

    do
        local entry = AnchorLoad.Capture("\239\187\191local a = 1\n",
            { capability = caps() })
        check(entry ~= nil, "bom: a BOM file loads")
        if entry ~= nil then
            truthy(entry.captured, "bom: the map is harvested")
            eq(entry.map.a, 1, "bom: and the local is captured")
            eq(entry.names[1], "a", "bom: the BOM is not part of a name")
        end
    end

    do
        local entry = AnchorLoad.Capture("local who = ...\n",
            { capability = caps(), args = { n = 1, "world" } })
        check(entry ~= nil, "args: a vararg file loads")
        if entry ~= nil then
            truthy(entry.captured, "args: captured")
            eq(AnchorLoad.Get(entry, "who"), "world", "args: the arguments reach the file")
        end
    end

    do
        -- The caller can hand in the shared R1 analysis instead of re-analyzing.
        local nodes, err, snapshot = IR.Analyze(FIXTURE)
        check(nodes ~= nil and snapshot ~= nil, "analysis: the shared snapshot builds ("
            .. tostring(err) .. ")")
        if snapshot ~= nil then
            local bindings = assert(Binding.Analyze(snapshot))
            local entry = AnchorLoad.Capture(FIXTURE, {
                capability = caps(), analysis = snapshot, bindings = bindings,
            })
            check(entry ~= nil, "analysis: an injected snapshot captures")
            if entry ~= nil then
                truthy(entry.captured, "analysis: the map is harvested")
                eq(table.concat(entry.names, ","), table.concat(bindings.names, ","),
                    "analysis: the names come from the injected bindings")
            end
        end
    end

    ----------------------------------------------------------------------------
    -- The registry stub: one file, one anchor, first load wins
    ----------------------------------------------------------------------------
    do
        local file = "Fixture_Boss.lua"
        local first = AnchorLoad.Capture(FIXTURE, { capability = caps() })
        local second = AnchorLoad.Capture(FIXTURE, { capability = caps() })
        check(first ~= nil and second ~= nil, "store: two loads capture")
        if first ~= nil and second ~= nil then
            check(first.anchor ~= second.anchor,
                "store: each load has its own cells until the registry fixes one")
            local store = Anchor.NewStore()
            truthy(store:Set(file, first), "store: the first anchor registers")
            truthy(store:Set(file, first), "store: re-registering it is idempotent")
            local ok, reason = store:Set(file, second)
            falsy(ok, "store: a second anchor is refused")
            contains(reason, "already registered", "store: the refusal names the file")
            eq(store:Get(file), first, "store: the original anchor is kept")
            truthy(store:Missing(file), "store: a vanished file is marked")
            falsy(Anchor.Live(first), "store: the vanished file stops reloading")
            eq(AnchorLoad.Get(first, "counter"), 0,
                "store: but the live cells still read after the file vanished")
            truthy(store:Release(), "store: release ends the registry")
            eq(store:Size(), 0, "store: and drops every strong reference")
            eq(AnchorLoad.Get(first, "counter"), 0,
                "store: the caller still holding the entry keeps its cells")
        end
    end

    ----------------------------------------------------------------------------
    -- Accessors never invent an anchor and never touch an engine global
    ----------------------------------------------------------------------------
    do
        local value, reason = AnchorLoad.Get(nil, "a")
        eq(value, nil, "access: no entry reads nil")
        contains(reason, "capture result", "access: and explains the entry")
        value, reason = AnchorLoad.Get({}, "a")
        eq(value, nil, "access: an entry without an anchor reads nil")
        contains(reason, "no captured anchor", "access: and explains the anchor")
        local ok, sreason = AnchorLoad.Set({}, "a", 1)
        falsy(ok, "access: an entry without an anchor cannot be written")
        contains(sreason, "no captured anchor", "access: and explains the anchor")
        local values, vreason = AnchorLoad.Values({})
        eq(values, nil, "access: an entry without an anchor has no values")
        contains(vreason, "no captured anchor", "access: and explains the anchor")
        if fixture_entry ~= nil and fixture_entry.anchor ~= nil then
            value, reason = AnchorLoad.Get(fixture_entry, "missing")
            eq(value, nil, "access: an unknown name reads nil")
            contains(reason, "unknown slot", "access: and names the missing slot")
            value, reason = AnchorLoad.Get(fixture_entry, "")
            eq(value, nil, "access: an empty name reads nil")
            contains(reason, "non-empty string", "access: and explains the name")
            ok, sreason = AnchorLoad.Set(fixture_entry, "missing", 1)
            falsy(ok, "access: an unknown name cannot be written")
            contains(sreason, "unknown slot", "access: and names the missing slot")
        end
    end

    do
        local before = global_count()
        local entry = AnchorLoad.Capture(
            "local a = 1\nlocal f = function() return a end\n",
            { capability = caps() })
        check(entry ~= nil, "globals: the module captures without an engine")
        eq(_G.lstg, nil, "globals: no engine global is required")
        eq(global_count(), before, "globals: capture adds no global")
    end

    if failed > 0 then
        for i = 1, math.min(#failures, 25) do
            print("[SpellHotReload anchor-load] FAIL " .. failures[i])
        end
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
