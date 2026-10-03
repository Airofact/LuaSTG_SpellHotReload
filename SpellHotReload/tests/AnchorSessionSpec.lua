--------------------------------------------------------------------------------
--- SpellHotReload tests/AnchorSessionSpec.lua
---
--- Unit spec for the R2 session service. AnchorSession owns the first load of a
--- supported file, keeps the anchor that load produced, and decides when the
--- registry is held and when it is released.
---
--- What is asserted here is the lifecycle contract, not Apply: a file runs at
--- most once per session, a file that cannot be captured still runs exactly
--- once and is remembered as non-reloadable, a vanished file only invalidates
--- reload while its cells stay readable, and a mod switch or a session end
--- drops the strong references.
---
--- Runs under plain Lua 5.1 and LuaJIT with no engine globals (see
--- anchor-session/run-targeted.lua). Positive capture cases inject an explicit
--- capable capability so they run anywhere; the *default* verdict is asserted
--- separately, so a runtime without `debug.upvaluejoin` (vanilla Lua 5.1) must
--- honestly refuse to capture rather than fail the spec.
--------------------------------------------------------------------------------

local AnchorSession = require("SpellHotReload.AnchorSession")
local Anchor = require("SpellHotReload.Anchor")

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
        getupvalue = true, setupvalue = true, upvaluejoin = true, upvalueid = true,
    }
    for key, value in pairs(overrides or {}) do capability[key] = value end
    return capability
end

---Read and clear the global the execution-counting fixtures increment.
local function runs()
    local value = _G.__session_runs or 0
    _G.__session_runs = 0
    return value
end

---A normal side-effect file: three top-level locals and one run marker.
local SIMPLE = table.concat({
    "__session_runs = (__session_runs or 0) + 1",
    "local counter = 0",
    "local config = { tag = 'c' }",
    "local function pattern(self)",
    "    return counter, config.tag",
    "end",
}, "\n") .. "\n"

---A module file: its own return must be preserved and capture skipped.
local RETURNING = "local a = 1\n__session_runs = __session_runs + 1\nreturn 1, nil, 3\n"

---A file with a duplicate top-level local: loaded normally, not reloadable.
local DUPLICATE = "local a = 1\nlocal a = 2\n"

---A file that takes chunk arguments, so Load's `args` forwarding is visible.
local VARARG = "local a = (...)\nlocal b = 2\n"

function M.run()
    -- Read the real runtime's facilities exactly as the module does; the spec
    -- never asks AnchorSession to experiment on the runtime to prove them.
    local runtime = {
        getupvalue = type(debug.getupvalue) == "function",
        setupvalue = type(debug.setupvalue) == "function",
        upvaluejoin = type(debug.upvaluejoin) == "function",
        upvalueid = type(debug.upvalueid) == "function",
    }

    ----------------------------------------------------------------------------
    -- module identity
    ----------------------------------------------------------------------------
    eq(AnchorSession.Kind, "SpellHotReload.AnchorSession", "module kind")
    eq(type(AnchorSession.Version), "number", "module version is a number")
    eq(AnchorSession.Version, 1, "module version")

    ----------------------------------------------------------------------------
    -- New: defaults, overrides and argument validation
    ----------------------------------------------------------------------------
    do
        local session, reason = AnchorSession.New()
        truthy(session ~= nil, "new: no options opens a session (" .. tostring(reason) .. ")")
        if session ~= nil then
            eq(session.id, "session", "new: default id")
            eq(session:Generation(), 1, "new: first generation")
            eq(session:Size(), 0, "new: empty")
            falsy(session:IsClosed(), "new: open")
            eq(session:Store():Size(), 0, "new: the store starts empty")
            eq(#session:Files(), 0, "new: no files")
        end

        local named = AnchorSession.New({ id = "boss-1" })
        check(named ~= nil, "new: a named session opens")
        if named ~= nil then eq(named.id, "boss-1", "new: custom id") end

        local bad, badreason = AnchorSession.New("x")
        reject(bad, badreason, "new: a non-table option set", "options must be a table")

        local empty, emptyreason = AnchorSession.New({ id = "" })
        reject(empty, emptyreason, "new: an empty id", "non-empty string")

        local nostore, storereason = AnchorSession.New({ store = {} })
        reject(nostore, storereason, "new: a store without the anchor API", "anchor store")
    end

    ----------------------------------------------------------------------------
    -- first load: runs exactly once and captures the anchor
    ----------------------------------------------------------------------------
    local session = AnchorSession.New({ id = "s1", capability = caps() })
    check(session ~= nil, "session: opens with a capable runtime")
    if session == nil then
        print("[SpellHotReload anchor session] session could not open")
        return { passed = passed, failed = failed + 1, failures = { "session open" } }
    end

    _G.__session_runs = 0
    local entry, lerr, lstage = session:Load("A.lua", SIMPLE)
    check(entry ~= nil, "load: a normal file loads (" .. tostring(lerr) .. "/" .. tostring(lstage) .. ")")
    eq(lstage, nil, "load: a successful load reports no stage")
    if entry ~= nil then
        eq(runs(), 1, "load: executed exactly once")
        truthy(entry.captured, "load: captured")
        truthy(entry.reloadable, "load: reloadable")
        eq(entry.reason, nil, "load: a captured entry has no reason")
        eq(entry.file, "A.lua", "load: the file is recorded")
        eq(entry.session_id, "s1", "load: the session id is recorded")
        eq(entry.generation, 1, "load: the generation is recorded")
        eq(entry.loaded_source, SIMPLE, "load: the exact bytes are kept")
        eq(table.concat(entry.names, ","), "counter,config,pattern", "load: names in order")
        eq(debug.getupvalue(entry.anchor, 1) ~= nil, true, "load: the anchor has real upvalues")
        eq(Anchor.Get(entry, "counter"), 0, "load: counter value")
        eq(Anchor.Get(entry, "config").tag, "c", "load: config value")
        local pattern = Anchor.Get(entry, "pattern")
        eq(type(pattern), "function", "load: pattern value")
        local c1, t1 = pattern(nil)
        eq(c1, 0, "load: the file's own closure reads its cell")
        eq(t1, "c", "load: the file's own closure reads a sibling cell")
        truthy(Anchor.Set(entry, "counter", 5), "load: an external setter writes the cell")
        eq(Anchor.Get(entry, "counter"), 5, "load: the setter is visible")
        local c2 = pattern(nil)
        eq(c2, 5, "load: the file's own closure sees the new value")
        truthy(session:Has("A.lua"), "load: has")
        eq(session:Size(), 1, "load: size")
        eq(table.concat(session:Files(), ","), "A.lua", "load: file list")
        eq(session:Get("A.lua"), entry, "load: get returns the entry")
        eq(session:Anchor("A.lua"), entry.anchor, "load: the anchor accessor")
        eq(session:Source("A.lua"), SIMPLE, "load: the source accessor")
        truthy(session:Live("A.lua"), "load: live")
        truthy(session:Store():Has("A.lua"), "load: registered in the anchor store")
        eq(session:Store():Get("A.lua"), entry, "load: the store holds the same entry")
        eq(AnchorSession.ReturnArity(entry), 0, "load: a captured file has no own return")
    end

    ----------------------------------------------------------------------------
    -- first load wins: identical bytes are a no-op, different bytes are refused
    ----------------------------------------------------------------------------
    _G.__session_runs = 0
    local again, areason = session:Load("A.lua", SIMPLE)
    eq(again, entry, "again: identical bytes return the same entry")
    eq(areason, nil, "again: identical bytes are not an error")
    eq(runs(), 0, "again: identical bytes never re-run the file")

    local refused, rreason, rstage = session:Load("A.lua", SIMPLE .. "-- changed\n")
    eq(refused, nil, "again: different bytes are refused")
    contains(rreason, "already loaded", "again: the refusal reason")
    eq(rstage, "lifecycle", "again: the refusal stage")
    eq(runs(), 0, "again: a refusal never runs anything")
    truthy(session:Has("A.lua"), "again: the original entry is kept")
    eq(session:Source("A.lua"), SIMPLE, "again: the original bytes are kept")

    ----------------------------------------------------------------------------
    -- a file that cannot be captured still runs once and is remembered
    ----------------------------------------------------------------------------
    _G.__session_runs = 0
    local returning = session:Load("B.lua", RETURNING)
    check(returning ~= nil, "return: a returning file loads")
    if returning ~= nil then
        eq(runs(), 1, "return: executed exactly once")
        falsy(returning.captured, "return: not captured")
        falsy(returning.reloadable, "return: not reloadable")
        contains(returning.reason, "top-level return", "return: the policy reason is kept")
        eq(returning.anchor, nil, "return: no anchor")
        eq(returning.session_id, "s1", "return: the session id is recorded")
        eq(AnchorSession.ReturnArity(returning), 3, "return: the return arity is preserved")
        local one, two, three = AnchorSession.ReturnValues(returning)
        eq(one, 1, "return: first value")
        eq(two, nil, "return: the nil is kept")
        eq(three, 3, "return: third value")
        eq(select("#", AnchorSession.ReturnValues(returning)), 3, "return: full arity")
        truthy(session:Has("B.lua"), "return: remembered by the session")
        falsy(session:Live("B.lua"), "return: not live")
        eq(session:Anchor("B.lua"), nil, "return: the anchor accessor is empty")
        falsy(session:Store():Has("B.lua"), "return: not in the anchor store")
    end

    _G.__session_runs = 0
    local same = session:Load("B.lua", RETURNING)
    eq(same, returning, "return: identical bytes return the same entry")
    eq(runs(), 0, "return: identical bytes never re-run the file")
    local dupref, dupreason = session:Load("B.lua", DUPLICATE)
    eq(dupref, nil, "return: different bytes are refused")
    contains(dupreason, "already loaded", "return: the refusal reason")

    local duplicate = session:Load("C.lua", DUPLICATE)
    check(duplicate ~= nil, "dup: a file with a duplicated local still loads")
    if duplicate ~= nil then
        falsy(duplicate.captured, "dup: not captured")
        contains(duplicate.reason, "duplicate top-level local", "dup: the reason")
        truthy(session:Has("C.lua"), "dup: remembered by the session")
        falsy(session:Store():Has("C.lua"), "dup: not in the anchor store")
    end

    ----------------------------------------------------------------------------
    -- Load forwards analysis/bindings and chunk args, and its own options guard
    ----------------------------------------------------------------------------
    local opaque = session:Load("D.lua", "local a = 1\n", {
        analysis = { nodes = {}, statements = {} },
        bindings = { names = { "a" }, duplicates = {}, opaque = true },
    })
    check(opaque ~= nil, "opaque: a doctored snapshot still loads")
    if opaque ~= nil then
        falsy(opaque.captured, "opaque: not captured")
        contains(opaque.reason, "unparsed", "opaque: the reason")
    end

    local vararg = session:Load("E.lua", VARARG, { args = { n = 1, "hello" } })
    check(vararg ~= nil, "args: a file taking ... loads")
    if vararg ~= nil then
        truthy(vararg.captured, "args: captured")
        eq(Anchor.Get(vararg, "a"), "hello", "args: the argument reached the file")
        eq(Anchor.Get(vararg, "b"), 2, "args: siblings still initialise")
    end

    eq(session:Size(), 5, "session: size counts every first load")
    eq(table.concat(session:Files(), ","), "A.lua,B.lua,C.lua,D.lua,E.lua",
        "session: the file list is sorted")
    eq(session:Store():Size(), 2, "session: only captured files reach the anchor store")

    ----------------------------------------------------------------------------
    -- a vanished file only invalidates reload
    ----------------------------------------------------------------------------
    truthy(session:Missing("A.lua"), "missing: mark a file missing")
    falsy(session:Live("A.lua"), "missing: no longer live")
    truthy(session:Missing("A.lua"), "missing: marking again is idempotent")
    eq(session:Get("A.lua"), entry, "missing: the entry is still held")
    eq(session:Anchor("A.lua"), entry.anchor, "missing: the anchor is still held")
    eq(Anchor.Get(entry, "counter"), 5, "missing: the cells are still readable")
    truthy(session:Store():Has("A.lua"), "missing: the store still holds it")
    eq(session:Size(), 5, "missing: the size is unchanged")
    local mok, mreason = session:Missing("nope.lua")
    falsy(mok, "missing: an unknown file fails")
    contains(mreason, "unknown file", "missing: the unknown-file reason")
    falsy(session:Missing(nil), "missing: a non-string file fails")

    ----------------------------------------------------------------------------
    -- the real runtime's own verdict, nothing injected
    ----------------------------------------------------------------------------
    do
        local real = AnchorSession.New({ id = "real" })
        check(real ~= nil, "real: a session without an injected capability opens")
        if real ~= nil then
            _G.__session_runs = 0
            local real_entry = real:Load("R.lua", SIMPLE)
            check(real_entry ~= nil, "real: the file still loads")
            if real_entry ~= nil then
                eq(runs(), 1, "real: executed exactly once")
                truthy(real:Has("R.lua"), "real: remembered by the session")
                eq(real_entry.session_id, "real", "real: the session id")
                if runtime.upvaluejoin then
                    truthy(real_entry.captured, "real: captured on a joinable runtime")
                    truthy(real_entry.reloadable, "real: reloadable on a joinable runtime")
                    truthy(real:Live("R.lua"), "real: live on a joinable runtime")
                else
                    falsy(real_entry.captured, "real: refused on a runtime without join")
                    falsy(real_entry.reloadable, "real: not reloadable")
                    contains(real_entry.reason, "capability", "real: the capability reason")
                    contains(real_entry.reason, "upvaluejoin", "real: the missing part is named")
                    falsy(real:Live("R.lua"), "real: not live")
                    falsy(real:Store():Has("R.lua"), "real: not in the anchor store")
                end
            end
            truthy(real:Release(), "real: release")
        end
    end

    ----------------------------------------------------------------------------
    -- a supported mod switch releases the old registry and moves on
    ----------------------------------------------------------------------------
    eq(session:Generation(), 1, "switch: the starting generation")
    truthy(session:SwitchMod(), "switch: releases the old registry")
    eq(session:Generation(), 2, "switch: a new generation")
    eq(session:Size(), 0, "switch: no entries are held")
    eq(#session:Files(), 0, "switch: no files")
    falsy(session:Has("A.lua"), "switch: the old entry is gone")
    falsy(session:Live("A.lua"), "switch: nothing is live")
    eq(session:Store():Size(), 0, "switch: the store was released")
    falsy(session:IsClosed(), "switch: the session stays open")

    _G.__session_runs = 0
    local reloaded = session:Load("A.lua", SIMPLE)
    check(reloaded ~= nil, "switch: the session is still usable")
    if reloaded ~= nil then
        eq(runs(), 1, "switch: the new generation runs the file again")
        eq(reloaded.generation, 2, "switch: the entry records the new generation")
        truthy(reloaded.captured, "switch: captured again")
    end

    ----------------------------------------------------------------------------
    -- session end drops every strong reference
    ----------------------------------------------------------------------------
    eq(session:Size(), 1, "release: one entry before the end")
    truthy(session:Release(), "release: ends the session")
    truthy(session:IsClosed(), "release: the session is closed")
    eq(session:Size(), 0, "release: no entries are held")
    eq(session:Store():Size(), 0, "release: the store was released")
    truthy(session:Release(), "release: ending again is idempotent")
    local closed_entry, closed_reason, closed_stage = session:Load("F.lua", SIMPLE)
    eq(closed_entry, nil, "release: a later load is refused")
    contains(closed_reason, "closed", "release: the refusal reason")
    eq(closed_stage, "lifecycle", "release: the refusal stage")
    local sok, sreason = session:SwitchMod()
    falsy(sok, "release: a closed session cannot switch mods")
    contains(sreason, "closed", "release: the switch reason")
    falsy(session:Live("A.lua"), "release: a closed session is not live")

    ----------------------------------------------------------------------------
    -- an injected store is owned by the caller, not the session
    ----------------------------------------------------------------------------
    do
        local store = Anchor.NewStore()
        local owner = AnchorSession.New({ id = "owner", store = store, capability = caps() })
        check(owner ~= nil, "inject: a session accepts a store")
        if owner ~= nil then
            eq(owner:Store(), store, "inject: the same store is used")
            local injected = owner:Load("I.lua", SIMPLE)
            check(injected ~= nil, "inject: the file loads")
            truthy(store:Has("I.lua"), "inject: the caller's store is filled")
            eq(store:Get("I.lua"), injected, "inject: the store holds the same entry")
            truthy(owner:Release(), "inject: release")
            eq(owner:Size(), 0, "inject: the session drops its entries")
            truthy(store:Has("I.lua"), "inject: the caller's store is left alone")
            eq(store:Get("I.lua"), injected, "inject: the caller still holds the anchor")
        end
    end

    ----------------------------------------------------------------------------
    -- sessions are independent
    ----------------------------------------------------------------------------
    do
        local first = AnchorSession.New({ id = "one", capability = caps() })
        local second = AnchorSession.New({ id = "two", capability = caps() })
        _G.__session_runs = 0
        local e1 = first:Load("S.lua", SIMPLE)
        local e2 = second:Load("S.lua", SIMPLE)
        check(e1 ~= nil and e2 ~= nil, "sessions: both sessions load the file")
        eq(runs(), 2, "sessions: each session runs the file once")
        check(e1 ~= e2, "sessions: separate entries")
        if e1 ~= nil then eq(e1.session_id, "one", "sessions: the first id") end
        if e2 ~= nil then eq(e2.session_id, "two", "sessions: the second id") end
        truthy(first:Release(), "sessions: release the first")
        truthy(second:Has("S.lua"), "sessions: the second is untouched")
    end

    ----------------------------------------------------------------------------
    -- argument validation and the return helpers on nothing
    ----------------------------------------------------------------------------
    local vsession = AnchorSession.New({ id = "v", capability = caps() })
    local no_file, file_reason, file_stage = vsession:Load(nil, SIMPLE)
    reject(no_file, file_reason, "load: a nil file", "non-empty string")
    eq(file_stage, "lifecycle", "load: the nil-file stage")
    local no_content, content_reason = vsession:Load("X.lua", nil)
    reject(no_content, content_reason, "load: nil content", "content must be a string")
    local bad_options, options_reason = vsession:Load("X.lua", SIMPLE, "nope")
    reject(bad_options, options_reason, "load: bad options", "options must be a table")
    eq(vsession:Size(), 0, "load: nothing was loaded")
    eq(vsession:Get(nil), nil, "load: get with no file")
    falsy(vsession:Has(nil), "load: has with no file")
    falsy(vsession:Live(nil), "load: live with no file")
    eq(vsession:Source("nope.lua"), nil, "load: the source of an unknown file")
    eq(vsession:Anchor("nope.lua"), nil, "load: the anchor of an unknown file")
    eq(AnchorSession.ReturnArity(nil), 0, "return: the arity of nothing")
    eq(AnchorSession.ReturnValues(nil), nil, "return: the values of nothing")

    _G.__session_runs = nil

    print(string.format("[SpellHotReload anchor session] %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do
        print("  FAIL: " .. label)
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
