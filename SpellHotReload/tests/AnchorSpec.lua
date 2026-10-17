--------------------------------------------------------------------------------
--- SpellHotReload tests/AnchorSpec.lua
---
--- Unit spec for the R2 anchor service. Anchor is the pure half of "one file,
--- one anchor": a capability gate over the runtime's debug facilities, a
--- read-only capture policy over the shared TopLevelIR/Binding snapshot, the
--- `return function() return <locals> end` trailer, real slot enumeration
--- (nil/false included), get/set-through on the anchor cell, and the
--- first-load-wins session store.
---
--- Files the policy refuses still load exactly as before: a top-level return, a
--- duplicate top-level local, an opaque statement, a slot limit or an incapable
--- runtime is executed once and its own return arity is preserved. Nothing here
--- asserts a live closure is joined, replaced or published - that is Apply.
---
--- Runs under plain Lua 5.1 and LuaJIT with no engine globals (see
--- anchor-capture/run-targeted.lua). Positive trailer-capture cases inject an
--- explicit capable capability so they run anywhere; the *default* verdict is
--- asserted separately, so a runtime without `debug.upvaluejoin` (vanilla Lua
--- 5.1) must honestly refuse to capture rather than fail the spec.
--------------------------------------------------------------------------------

local Anchor = require("SpellHotReload.Load.Anchor")

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

---Assert a `nil, reason` rejection, optionally that the reason mentions a fragment.
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
    local value = _G.__anchor_runs or 0
    _G.__anchor_runs = 0
    return value
end

function M.run()
    -- Read the real runtime's facilities exactly as the module does; the spec
    -- never asks Anchor to experiment on the runtime to prove them.
    local runtime = {
        getupvalue = type(debug.getupvalue) == "function",
        setupvalue = type(debug.setupvalue) == "function",
        upvaluejoin = type(debug.upvaluejoin) == "function",
        upvalueid = type(debug.upvalueid) == "function",
    }
    local joinable = runtime.upvaluejoin
    local identifiable = runtime.upvalueid
    local can_capture = select(1, Anchor.Supported(runtime))

    ----------------------------------------------------------------------------
    -- module identity
    ----------------------------------------------------------------------------
    eq(Anchor.Kind, "SpellHotReload.Anchor", "module kind")
    eq(type(Anchor.Version), "number", "module version is a number")
    eq(Anchor.DefaultSlotLimit, 60, "default slot limit")

    ----------------------------------------------------------------------------
    -- Supported: the debug facilities an anchor needs must be declared present
    ----------------------------------------------------------------------------
    falsy(select(1, Anchor.Supported(nil)), "supported rejects nil")
    falsy(select(1, Anchor.Supported("debug")), "supported rejects a non-table")
    truthy(select(1, Anchor.Supported(caps())), "supported accepts a full capability")
    for _, flag in ipairs({
        { "getupvalue", "getupvalue" }, { "setupvalue", "setupvalue" },
        { "upvaluejoin", "upvaluejoin" },
    }) do
        local supported, reason = Anchor.Supported(caps({ [flag[1]] = false }))
        falsy(supported, "supported requires " .. flag[1])
        contains(reason, flag[2], "supported reason names " .. flag[2])
    end

    ----------------------------------------------------------------------------
    -- The real runtime: presence only, nothing is built or joined to decide
    ----------------------------------------------------------------------------
    truthy(runtime.getupvalue, "runtime: debug.getupvalue is available")
    truthy(runtime.setupvalue, "runtime: debug.setupvalue is available")
    if joinable then
        truthy(can_capture, "runtime: every facility an anchor needs is present")
        truthy(runtime.upvalueid, "runtime: debug.upvalueid is available")
    else
        falsy(can_capture, "runtime: a runtime without join is not supported")
        local _, reason = Anchor.Supported(runtime)
        check(type(reason) == "string" and reason ~= "",
            "runtime: an unsupported runtime explains itself")
        contains(reason, "upvaluejoin", "runtime: the missing part is named")
    end

    ----------------------------------------------------------------------------
    -- Trailer
    ----------------------------------------------------------------------------
    eq(Anchor.Trailer({}), "return function() end", "trailer: no locals")
    eq(Anchor.Trailer({ "a" }), "return function() return a end", "trailer: one name")
    eq(Anchor.Trailer({ "a", "b", "c" }), "return function() return a, b, c end",
        "trailer: many names")
    do
        local trailer, reason = Anchor.Trailer(nil)
        reject(trailer, reason, "trailer: nil names", "dense array")
        trailer, reason = Anchor.Trailer("a")
        reject(trailer, reason, "trailer: a bare string", "dense array")
        trailer, reason = Anchor.Trailer({ [1] = "a", [3] = "c" })
        reject(trailer, reason, "trailer: a hole", "dense array")
        trailer, reason = Anchor.Trailer({ "a", 2 })
        reject(trailer, reason, "trailer: a non-string", "dense array")
        trailer, reason = Anchor.Trailer({ "" })
        reject(trailer, reason, "trailer: an empty name", "dense array")
        trailer, reason = Anchor.Trailer({ "a", kind = "extra" })
        reject(trailer, reason, "trailer: an extra key", "dense array")
    end

    ----------------------------------------------------------------------------
    -- Policy: read-only verdict, never executes
    ----------------------------------------------------------------------------
    local source = table.concat({
        "local counter = 0",
        "local config = { tag = 'c' }",
        "local function pattern(self)",
        "    return counter",
        "end",
    }, "\n") .. "\n"

    local policy, perr = Anchor.Policy(source)
    check(policy ~= nil, "policy: a normal file parses (" .. tostring(perr) .. ")")
    if policy ~= nil then
        truthy(policy.reloadable, "policy: a normal file is reloadable")
        eq(policy.reason, nil, "policy: a reloadable verdict has no reason")
        eq(table.concat(policy.names, ","), "counter,config,pattern", "policy: names in order")
        falsy(policy.has_return, "policy: no top-level return")
        falsy(policy.opaque, "policy: not opaque")
        eq(#policy.duplicates, 0, "policy: no duplicate locals")
        eq(policy.statements, 3, "policy: statement count")
        eq(policy.limit, Anchor.DefaultSlotLimit, "policy: default limit")
    end

    do
        local blocked = Anchor.Policy("local a = 1\nreturn a\n")
        check(blocked ~= nil, "policy: a returning file still analyzes")
        if blocked ~= nil then
            falsy(blocked.reloadable, "policy: a top-level return blocks capture")
            truthy(blocked.has_return, "policy: the return is reported")
            contains(blocked.reason, "top-level return", "policy: the return reason")
        end
    end

    do
        local blocked = Anchor.Policy("local a = 1\nlocal a = 2\n")
        check(blocked ~= nil, "policy: duplicates analyze")
        if blocked ~= nil then
            falsy(blocked.reloadable, "policy: a duplicate local blocks capture")
            eq(#blocked.duplicates, 1, "policy: one duplicate")
            eq(blocked.duplicates[1].name, "a", "policy: the duplicate name")
            contains(blocked.reason, "duplicate top-level local: a", "policy: the duplicate reason")
            eq(#blocked.names, 1, "policy: names deduplicate the repeated local")
        end
    end

    do
        -- Injecting the shared snapshot proves the opaque branch independently
        -- of whatever the lexer happens to classify today.
        local blocked = Anchor.Policy("local a = 1\n", {
            analysis = { nodes = {}, statements = {} },
            bindings = { names = { "a" }, duplicates = {}, opaque = true },
        })
        check(blocked ~= nil, "policy: an opaque snapshot analyzes")
        if blocked ~= nil then
            falsy(blocked.reloadable, "policy: an opaque statement blocks capture")
            truthy(blocked.opaque, "policy: opacity is reported")
            contains(blocked.reason, "unparsed top-level statement", "policy: the opaque reason")
        end
    end

    do
        local over = Anchor.Policy("local a = 1\nlocal b = 2\n", { limit = 1 })
        falsy(over.reloadable, "policy: the slot limit blocks capture")
        contains(over.reason, "slot limit exceeded: 2 > 1", "policy: the slot limit reason")
        eq(over.limit, 1, "policy: the supplied limit is reported")
        truthy(Anchor.Policy("local a = 1\n", { limit = 1 }).reloadable,
            "policy: an exact-fit limit is accepted")
        falsy(Anchor.Policy("local a = 1\n", { limit = 0 }).reloadable,
            "policy: a zero limit refuses a local")
        local fallback = Anchor.Policy("local a = 1\n", { limit = 1.5 })
        truthy(fallback.reloadable, "policy: a fractional limit falls back")
        eq(fallback.limit, Anchor.DefaultSlotLimit, "policy: the fallback is the default")
    end

    do
        -- The analyzer/binding pair may be injected, so a malformed one must be
        -- rejected instead of crashing the caller.
        local bad, reason = Anchor.Policy("local a = 1\n", {
            analysis = { nodes = {}, statements = {} },
            bindings = { names = { "a" } },
        })
        reject(bad, reason, "policy: bindings without duplicates", "duplicates")
        bad, reason = Anchor.Policy("local a = 1\n", { analysis = "snapshot" })
        reject(bad, reason, "policy: a non-table analysis", "nodes and statements")
        bad, reason = Anchor.Policy("local a = 1\n", { bindings = "declarations" })
        reject(bad, reason, "policy: a non-table bindings", "names and duplicates")
        bad, reason = Anchor.Policy(false)
        reject(bad, reason, "policy: a non-string content", "content must be a string")
    end

    do
        -- An injected snapshot replaces the lexer entirely, so policy and
        -- trailer use exactly the names it reports.
        local injected = Anchor.Policy("local x = 1\n", {
            analysis = { nodes = {}, statements = {} },
            bindings = { names = { "x" }, duplicates = {}, opaque = false },
        })
        truthy(injected.reloadable, "policy: an injected snapshot is reloadable")
        eq(table.concat(injected.names, ","), "x", "policy: injected names are used")
        eq(injected.statements, 0, "policy: injected statement count")
        falsy(injected.has_return, "policy: injected nodes have no return")
    end

    ----------------------------------------------------------------------------
    -- A hand-built anchor: real cells and a sibling closure, runtime-independent
    ----------------------------------------------------------------------------
    local hand_chunk = assert(compile(table.concat({
        "local counter = 0",
        "local config = { tag = 'c' }",
        "local function sibling() return counter end",
        "local function read_config() return config end",
        "return function() return counter, config end, sibling, read_config",
    }, "\n")))
    local hand_anchor, hand_sibling, hand_read_config = hand_chunk()
    local hand_slots, hand_order, hand_reason = Anchor.Slots(hand_anchor)
    check(hand_slots ~= nil, "slots: a hand-made anchor enumerates (" .. tostring(hand_reason) .. ")")
    local hand_entry = {
        captured = true, reloadable = true, missing = false,
        anchor = hand_anchor, slots = hand_slots, order = hand_order,
        names = { "counter", "config" },
    }
    if hand_slots ~= nil then
        truthy(hand_slots.counter ~= nil, "slots: counter is enumerated")
        truthy(hand_slots.config ~= nil, "slots: config is enumerated")
        eq(hand_slots.counter == hand_slots.config, false, "slots: distinct slots")
        eq(#hand_order, 2, "slots: order length")
        eq(type(hand_order[1]), "string", "slots: order is a name list")
    end
    hand_slots, hand_order, hand_reason = Anchor.Slots(hand_anchor, { "counter", "config" })
    check(hand_slots ~= nil, "slots: an exact expectation is accepted (" .. tostring(hand_reason) .. ")")
    hand_slots, hand_order, hand_reason = Anchor.Slots(hand_anchor, { "counter" })
    reject(hand_slots, hand_reason, "slots: a short expectation", "captured 2 upvalues for 1")
    hand_slots, hand_order, hand_reason = Anchor.Slots(hand_anchor, { "counter", "zzz" })
    reject(hand_slots, hand_reason, "slots: an unknown local", "did not capture local: zzz")
    hand_slots, hand_order, hand_reason = Anchor.Slots(hand_anchor, { "counter", "config", "config" })
    reject(hand_slots, hand_reason, "slots: a repeated expectation", "captured 2 upvalues for 3")
    hand_slots, hand_order, hand_reason = Anchor.Slots(hand_anchor, { [1] = "counter", [3] = "config" })
    reject(hand_slots, hand_reason, "slots: a sparse expectation", "dense array")
    hand_slots, hand_order, hand_reason = Anchor.Slots(nil)
    reject(hand_slots, hand_reason, "slots: a non-function anchor", "anchor must be a function")
    do
        local empty_anchor = assert(compile("return function() end"))()
        local empty_slots, empty_order, empty_reason = Anchor.Slots(empty_anchor)
        check(empty_slots ~= nil, "slots: a closure without upvalues enumerates (" ..
            tostring(empty_reason) .. ")")
        if empty_slots ~= nil then
            eq(next(empty_slots), nil, "slots: no upvalues to enumerate")
            eq(next(empty_order), nil, "slots: no order entries")
        end
    end

    ----------------------------------------------------------------------------
    -- Slot / Get / Set / Read read and write through the real cell
    ----------------------------------------------------------------------------
    local index, sreason = Anchor.Slot(hand_entry, "counter")
    eq(index, hand_entry.slots.counter, "slot: resolves a name")
    index, sreason = Anchor.Slot(hand_entry, "nope")
    reject(index, sreason, "slot: an unknown name", "unknown slot: nope")
    index, sreason = Anchor.Slot(hand_entry, "")
    reject(index, sreason, "slot: an empty name", "non-empty string")
    index, sreason = Anchor.Slot({}, "counter")
    reject(index, sreason, "slot: an entry without an anchor", "no captured anchor")
    index, sreason = Anchor.Slot(nil, "counter")
    reject(index, sreason, "slot: a nil entry", "no captured anchor")

    eq(Anchor.Get(hand_entry, "counter"), 0, "get: the initial value")
    truthy(Anchor.Set(hand_entry, "counter", 5), "set: counter")
    eq(Anchor.Get(hand_entry, "counter"), 5, "get: the written value")
    eq(Anchor.Get(hand_entry, "config").tag, "c", "get: the table identity is readable")
    eq(hand_sibling(), 5, "shared cell: the file's own closure sees the anchor write")
    local replacement = { tag = "x" }
    truthy(Anchor.Set(hand_entry, "config", replacement), "set: a whole-table replacement")
    eq(Anchor.Get(hand_entry, "config"), replacement, "get: the replacement is held")
    eq(hand_read_config(), replacement, "shared cell: the sibling sees the replaced table")
    truthy(Anchor.Set(hand_entry, "counter", false), "set: a false value is accepted")
    eq(Anchor.Get(hand_entry, "counter"), false, "get: a false value is readable")
    local value, greason = Anchor.Get(hand_entry, "nope")
    reject(value, greason, "get: an unknown slot", "unknown slot: nope")
    local values = Anchor.Read(hand_entry)
    check(values ~= nil, "read: a captured entry snapshots")
    eq(values.counter, false, "read: the current counter")
    eq(values.config, replacement, "read: the current table")
    local empty_read, ereason = Anchor.Read({})
    reject(empty_read, ereason, "read: an entry without slots", "no slots")

    do
        -- Fault injection: a stripped or duplicated name table must be refused,
        -- not silently mis-indexed.
        local real = debug.getupvalue
        local calls = 0
        debug.getupvalue = function()
            calls = calls + 1
            if calls <= 2 then return "dup" end
            return nil
        end
        local slots, order, reason = Anchor.Slots(hand_anchor)
        debug.getupvalue = real
        reject(slots, reason, "slots: duplicate names", "duplicate anchor slot: dup")
        calls = 0
        debug.getupvalue = function()
            calls = calls + 1
            if calls <= 1 then return "" end
            return nil
        end
        slots, order, reason = Anchor.Slots(hand_anchor)
        debug.getupvalue = real
        reject(slots, reason, "slots: stripped names", "debug info stripped")
    end

    ----------------------------------------------------------------------------
    -- Shared: identity aid only, the anchor stays the holder
    ----------------------------------------------------------------------------
    if identifiable then
        local foreign = (function(seed)
            local cell = seed
            return function() return cell end
        end)(1)
        local shared, reason = Anchor.Shared(hand_entry, "counter", foreign, 1)
        falsy(shared, "shared: an unrelated cell differs (" .. tostring(reason) .. ")")
        if joinable then
            debug.upvaluejoin(foreign, 1, hand_entry.anchor, hand_entry.slots.counter)
            truthy(Anchor.Shared(hand_entry, "counter", foreign, 1),
                "shared: a joined cell matches")
            eq(foreign(), Anchor.Get(hand_entry, "counter"),
                "shared: the joined closure reads the cell")
        end
    end
    do
        local shared, reason = Anchor.Shared(hand_entry, "counter", "not a function", 1)
        falsy(shared, "shared: a non-function")
        contains(reason, "fn must be a function", "shared: the non-function reason")
        shared, reason = Anchor.Shared(hand_entry, "counter", function() end, 0)
        falsy(shared, "shared: a non-positive index")
        contains(reason, "positive integer", "shared: the index reason")
        shared, reason = Anchor.Shared(hand_entry, "nope", function() end, 1)
        falsy(shared, "shared: an unknown slot")
        contains(reason, "unknown slot", "shared: the unknown slot reason")
    end

    ----------------------------------------------------------------------------
    -- Capture: the trailer path (an explicit capable capability, so this is
    -- deterministic on every runtime)
    ----------------------------------------------------------------------------
    local entry = Anchor.Capture(source, { capability = caps() })
    check(entry ~= nil, "capture: a normal file loads")
    if entry ~= nil then
        truthy(entry.captured, "capture: the trailer produced an anchor")
        truthy(entry.reloadable, "capture: the entry is reloadable")
        eq(entry.reason, nil, "capture: a captured entry has no reason")
        eq(entry.loaded_source, source, "capture: the loaded source is recorded")
        eq(table.concat(entry.names, ","), "counter,config,pattern", "capture: names")
        eq(#entry.order, 3, "capture: every slot is enumerated")
        eq(entry.ret.n, 0, "capture: the trailer chunk returns nothing else")
        eq(type(entry.slots.counter), "number", "capture: the counter slot index is a number")
        truthy(entry.slots.config ~= nil, "capture: the config slot index")
        truthy(entry.slots.pattern ~= nil, "capture: the pattern slot index")
        truthy(Anchor.Live(entry), "capture: a captured entry is live")
        eq(Anchor.Get(entry, "counter"), 0, "capture: the initial value is readable")
        truthy(Anchor.Set(entry, "counter", 7), "capture: the anchor cell is writable")
        local pattern = Anchor.Get(entry, "pattern")
        eq(type(pattern), "function", "capture: the function value")
        eq(pattern(), 7, "capture: the file's own closure sees the anchor write")
        local default_entry = Anchor.Capture(source)
        check(default_entry ~= nil, "capture: the default path loads once")
        if default_entry ~= nil then
            if can_capture then
                truthy(default_entry.captured, "capture: the real runtime captures")
                truthy(Anchor.Live(default_entry), "capture: the real runtime entry is live")
                truthy(Anchor.Set(default_entry, "counter", 11), "capture: the real cell is writable")
                eq(Anchor.Get(default_entry, "counter"), 11, "capture: the real cell reads back")
            else
                falsy(default_entry.captured, "capture: an incapable runtime refuses to capture")
                falsy(default_entry.reloadable, "capture: an incapable runtime is not reloadable")
                contains(default_entry.reason, "capability", "capture: the runtime reason is kept")
                contains(default_entry.reason, "upvaluejoin", "capture: the missing part is named")
                eq(default_entry.slots, nil, "capture: no slots without an anchor")
            end
        end
    end

    do
        local nil_entry = Anchor.Capture("local empty = nil\nlocal flag = false\n",
            { capability = caps() })
        check(nil_entry ~= nil, "capture: nil/false locals load")
        if nil_entry ~= nil and nil_entry.captured then
            truthy(nil_entry.captured, "capture: nils and falses are still captured")
            eq(#nil_entry.order, 2, "capture: nil/false slots are enumerated")
            local value, reason = Anchor.Get(nil_entry, "empty")
            eq(value, nil, "get: a nil slot reads nil")
            eq(reason, nil, "get: a nil value is a success, not an error")
            value, reason = Anchor.Get(nil_entry, "flag")
            eq(value, false, "get: a false slot reads false")
            eq(reason, nil, "get: a false value is a success")
            truthy(Anchor.Set(nil_entry, "empty", 42), "set: a nil slot can be written")
            eq(Anchor.Get(nil_entry, "empty"), 42, "get: the nil slot now holds 42")
            truthy(Anchor.Set(nil_entry, "flag", true), "set: a false slot can be written")
            eq(Anchor.Get(nil_entry, "flag"), true, "get: the false slot now holds true")
            local nil_values = Anchor.Read(nil_entry)
            eq(nil_values.flag, true, "read: the written false slot")
            eq(nil_values.empty, 42, "read: the written nil slot")
        end
    end

    ----------------------------------------------------------------------------
    -- Capture fallbacks: a file that cannot be captured still runs once
    ----------------------------------------------------------------------------
    _G.__anchor_runs = 0
    local blocked = Anchor.Capture(
        "local a = 1\n__anchor_runs = __anchor_runs + 1\nreturn 1, nil, 3\n")
    check(blocked ~= nil, "return: a returning file loads")
    falsy(blocked.captured, "return: not captured")
    falsy(blocked.reloadable, "return: not reloadable")
    contains(blocked.reason, "top-level return", "return: the policy reason is kept")
    eq(blocked.names[1], "a", "return: names are still reported")
    eq(blocked.ret.n, 3, "return: the return arity is preserved")
    eq(blocked.ret[1], 1, "return: the first value")
    eq(blocked.ret[2], nil, "return: the nil value survives")
    eq(blocked.ret[3], 3, "return: the third value")
    eq(runs(), 1, "return: executed exactly once")
    falsy(Anchor.Live(blocked), "return: not live")
    do
        local value, reason = Anchor.Get(blocked, "a")
        eq(value, nil, "return: no value to read")
        contains(reason, "no captured anchor", "return: reading explains the missing anchor")
    end

    local incapable = Anchor.Capture(
        "local a = 1\n__anchor_runs = __anchor_runs + 1\n",
        { capability = caps({ upvaluejoin = false }) })
    check(incapable ~= nil, "capability: an incapable runtime still loads")
    falsy(incapable.captured, "capability: not captured")
    contains(incapable.reason, "capability", "capability: the runtime reason is kept")
    contains(incapable.reason, "upvaluejoin", "capability: the missing part is named")
    eq(incapable.names[1], "a", "capability: names are still reported")
    eq(incapable.ret.n, 0, "capability: a file without a return yields nothing")
    eq(runs(), 1, "capability: executed exactly once")

    do
        -- The splitter can miss a return; the trailer then cannot compile and
        -- the file must fall back to a plain single load, not run twice.
        _G.__anchor_runs = 0
        local doctored = Anchor.Capture(
            "local x = 1\n__anchor_runs = __anchor_runs + 1\nreturn 5\n", {
                capability = caps(),
                analysis = { nodes = {}, statements = {} },
                bindings = { names = { "x" }, duplicates = {}, opaque = false },
            })
        check(doctored ~= nil, "trailer: the fallback loads")
        falsy(doctored.captured, "trailer: not captured")
        contains(doctored.reason, "trailer compile failed", "trailer: the fallback reason")
        eq(doctored.ret.n, 1, "trailer: the return arity is preserved")
        eq(doctored.ret[1], 5, "trailer: the return value")
        eq(runs(), 1, "trailer: executed exactly once")
    end

    do
        local loaded = Anchor.Capture("local who = ...\n",
            { capability = caps(), args = { n = 1, "world" } })
        check(loaded ~= nil, "args: a vararg file loads")
        truthy(loaded.captured, "args: captured")
        eq(Anchor.Get(loaded, "who"), "world", "args: the call arguments reach the file")
    end

    do
        local bad, reason, stage = Anchor.Capture("local x = (1\n")
        eq(bad, nil, "compile: a bad file fails")
        contains(reason, "Lua syntax:", "syntax: analysis reason")
        eq(stage, "analyze", "syntax: refused before compilation")
        local parameters={}
        for i=1,201 do parameters[i]="p"..i end
        bad,reason,stage=Anchor.Capture("function LIMIT("..table.concat(parameters,",")..") end")
        eq(bad,nil,"compiler limit has no result")
        contains(reason,"compile failed","compiler restriction still enforced")
        eq(stage,"compile","compiler limit remains compile failure")
        bad, reason, stage = Anchor.Capture("error('boom')\n")
        eq(bad, nil, "run: a failing file fails")
        contains(reason, "run failed", "run: the stage reason")
        contains(reason, "boom", "run: the underlying error is kept")
        eq(stage, "run", "run: the stage is reported")
        bad, reason, stage = Anchor.Capture(nil)
        eq(bad, nil, "analyze: a non-string content fails")
        contains(reason, "content must be a string", "analyze: the content reason")
        eq(stage, "analyze", "analyze: the stage is reported")
    end

    ----------------------------------------------------------------------------
    -- Session store: one anchor per file, first load wins
    ----------------------------------------------------------------------------
    do
        local second = Anchor.Capture("local other = 1\n", { capability = caps() })
        check(second ~= nil and second.captured == true, "store: a second file captures")
        local store = Anchor.NewStore()
        eq(store:Size(), 0, "store: starts empty")
        eq(#store:Files(), 0, "store: starts with no files")
        truthy(store:Set("A.lua", hand_entry), "store: register a file")
        truthy(store:Set("A.lua", hand_entry),
            "store: re-registering the same anchor is idempotent")
        local ok, reason = store:Set("A.lua", entry)
        falsy(ok, "store: a second anchor is refused")
        contains(reason, "already registered", "store: the refusal names the file")
        eq(store:Get("A.lua"), hand_entry, "store: the original anchor is kept")
        eq(store:Has("A.lua"), true, "store: has a registered file")
        eq(store:Has("nope.lua"), false, "store: has an unknown file")
        eq(store:Has(nil), false, "store: has refuses a non-string")
        truthy(store:Set("B.lua", entry), "store: a second file")
        eq(store:Size(), 2, "store: size counts files")
        eq(table.concat(store:Files(), ","), "A.lua,B.lua", "store: files are sorted")
        truthy(store:Set("0.lua", second), "store: a file that sorts first")
        eq(table.concat(store:Files(), ","), "0.lua,A.lua,B.lua", "store: files stay sorted")

        local setok, setreason = store:Set(nil, hand_entry)
        falsy(setok, "store: refuses a non-string file")
        contains(setreason, "non-empty string", "store: the file reason")
        setok, setreason = store:Set("C.lua", {})
        falsy(setok, "store: refuses an entry without an anchor")
        contains(setreason, "anchor", "store: the entry reason")
        setok, setreason = store:Set("C.lua", { anchor = hand_entry.anchor })
        falsy(setok, "store: refuses an entry without slots")
        contains(setreason, "slots", "store: the slots reason")
        eq(store:Has("C.lua"), false, "store: a refused entry is not registered")

        truthy(store:Missing("A.lua"), "store: mark a file missing")
        falsy(Anchor.Live(hand_entry), "store: a missing file is no longer live")
        truthy(store:Missing("A.lua"), "store: marking missing is idempotent")
        eq(store:Get("A.lua"), hand_entry, "store: the anchor is still held")
        local mok, mreason = store:Missing("nope.lua")
        falsy(mok, "store: marking an unknown file fails")
        contains(mreason, "unknown file", "store: the missing reason")
        falsy(store:Missing(nil), "store: marking a non-string fails")
        eq(store:Size(), 3, "store: missing does not drop the entry")

        truthy(store:Release(), "store: release")
        eq(store:Size(), 0, "store: released size")
        eq(#store:Files(), 0, "store: released file list")
        eq(store:Get("A.lua"), nil, "store: released get")
        eq(store:Has("B.lua"), false, "store: released has")
    end

    _G.__anchor_runs = nil

    print(string.format("[SpellHotReload anchor] %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do
        print("  FAIL: " .. label)
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
