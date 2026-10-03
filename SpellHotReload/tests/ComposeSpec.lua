--------------------------------------------------------------------------------
--- SpellHotReload tests/ComposeSpec.lua
---
--- Unit spec for the anchor-cell composition service. Compose turns a fragment
--- into a new closure whose free top-level names are real upvalue slots, builds
--- the per-slot join plan against an anchor, and joins the new closure to the
--- anchor's existing cells.
---
--- What is asserted here is the wiring contract, not Apply:
---
---   * enumeration follows real upvalue indices, keeps nil/false values and
---     never mistakes a global for a capture;
---   * Create predeclares only the names the definition point proves visible, so
---     a name outside `visible` stays a late-bound global;
---   * a nested closure shares its outer closure's cell, so a capture made only
---     inside the nested function is still reachable through the outer join;
---     only an inner shadow of a prefix name, which leaves no joinable upvalue,
---     is refused;
---   * Join/Attach only add an alias to an existing cell - they never write the
---     cell and never replace the anchor, which is why an unwired fragment reads
---     empty cells and why recursion propagates through the anchor cell only
---     after Commit writes it;
---   * a runtime without `debug.upvaluejoin` is refused honestly by Join/Attach
---     while enumeration and Create still work.
---
--- Runs under plain Lua 5.1 and LuaJIT with no engine globals (see
--- anchor-compose/run-targeted.lua). Fixtures capture with an explicit capable
--- capability so the anchor phases run on both runtimes; the join phases branch
--- on what the *real* runtime reports, so vanilla Lua 5.1 must honestly refuse
--- instead of failing the spec.
--------------------------------------------------------------------------------

local Compose = require("SpellHotReload.Compose")
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
    if fragment ~= nil and type(reason) == "string" then
        contains(reason, fragment, label .. ": reason")
    end
end

---A capable-runtime capability table with selected flags overridden.
local function caps(overrides)
    local capability = {
        getupvalue = true, setupvalue = true, upvaluejoin = true, upvalueid = true,
    }
    for key, value in pairs(overrides or {}) do capability[key] = value end
    return capability
end

---Sorted copy of a name list, for order-insensitive set assertions.
local function sorted(list)
    local copy = {}
    for i = 1, #list do copy[i] = list[i] end
    table.sort(copy)
    return table.concat(copy, ",")
end

local function same_set(actual, expected, label)
    check(type(actual) == "table", label .. ": a list")
    if type(actual) == "table" then
        eq(sorted(actual), sorted(expected), label)
    end
end

---The index of the upvalue named `name` on `fn`, or nil.
local function upvalue_index(fn, name)
    local index = 1
    while true do
        local uname = debug.getupvalue(fn, index)
        if uname == nil then return nil end
        if uname == name then return index end
        index = index + 1
    end
end

---A normal side-effect file for the state phases.
local STATE = table.concat({
    "local counter = 0",
    "local config = { tag = 'c' }",
    "local function pattern(self)",
    "    return counter, config.tag",
    "end",
    "local spell = nil",
}, "\n") .. "\n"

---A self-recursive file, so the self-reference must resolve to one cell.
local RECUR = table.concat({
    "local function recur(n)",
    "    if n <= 0 then return 0 end",
    "    return 1 + recur(n - 1)",
    "end",
}, "\n") .. "\n"

---A minimal file used where only one slot is needed.
local ONE = "local counter = 0\n"

---Capture a fixture with a capable capability so the anchor phase runs
---everywhere. A fixture failure is an infrastructure error, not a behaviour
---failure, so it aborts the spec loudly.
local function capture(content, file)
    local entry, err = Anchor.Capture(content, { name = file, capability = caps() })
    assert(entry ~= nil, "fixture capture failed: " .. tostring(err))
    assert(type(entry.anchor) == "function", "fixture produced no anchor")
    return entry
end

function M.run()
    -- Read the real runtime's facilities exactly as the module does; the spec
    -- never asks Compose to experiment on the runtime to prove capabilities.
    local runtime = Compose.Capability(debug)
    local joinable = runtime.upvaluejoin == true

    ----------------------------------------------------------------------------
    -- module identity
    ----------------------------------------------------------------------------
    eq(Compose.Kind, "SpellHotReload.Compose", "module kind")
    eq(Compose.Version, 1, "module version")

    ----------------------------------------------------------------------------
    -- capability: a presence contract with an honest split
    ----------------------------------------------------------------------------
    do
        truthy(Compose.Supported(caps()), "capability: a full runtime is supported")

        local none, none_reason = Compose.Supported(nil)
        falsy(none, "capability: a missing runtime reports unsupported")
        contains(none_reason, "must be a table", "capability: nil reason")

        local no_get, get_reason = Compose.Supported(caps({ getupvalue = false }))
        falsy(no_get, "capability: no getupvalue")
        contains(get_reason, "getupvalue", "capability: no getupvalue reason")

        local no_join, join_reason = Compose.Supported(caps({ upvaluejoin = false }))
        falsy(no_join, "capability: no upvaluejoin")
        contains(join_reason, "upvaluejoin", "capability: no upvaluejoin reason")

        truthy(Compose.Supported(caps({ upvalueid = false })),
            "capability: upvalueid is a verification aid, not a requirement")

        local probed = Compose.Capability({ getupvalue = function() end })
        truthy(probed.getupvalue, "capability: a reported facility is read")
        falsy(probed.upvaluejoin, "capability: an absent facility is false")
        falsy(Compose.Capability(nil).getupvalue, "capability: a missing runtime reports nothing")
    end

    ----------------------------------------------------------------------------
    -- Upvalues / Names: real slots by index, nil values kept, globals excluded
    ----------------------------------------------------------------------------
    do
        local none, none_reason = Compose.Upvalues(42)
        reject(none, none_reason, "upvalues: non-function", "fn must be a function")

        local nnone, nnone_reason = Compose.Names(nil)
        reject(nnone, nnone_reason, "names: non-function", "fn must be a function")

        local function bare() return 1 end
        local empty, empty_reason = Compose.Upvalues(bare)
        truthy(empty ~= nil, "upvalues: an upvalue-free closure enumerates ("
            .. tostring(empty_reason) .. ")")
        if empty ~= nil then eq(#empty, 0, "upvalues: no slots") end

        local shared = { tag = "s" }
        local marker = 7
        local function uses() return shared, marker, __compose_global end
        local list, list_reason = Compose.Upvalues(uses)
        truthy(list ~= nil, "upvalues: a closure with captures enumerates ("
            .. tostring(list_reason) .. ")")
        if list ~= nil then
            eq(#list, 2, "upvalues: a global is not an upvalue")
            local byname = {}
            for i = 1, #list do
                eq(list[i].index, i, "upvalues: index is the real slot " .. i)
                eq(list[i].name, debug.getupvalue(uses, i),
                    "upvalues: name matches the runtime slot " .. i)
                byname[list[i].name] = list[i]
            end
            eq(byname.shared and byname.shared.value, shared,
                "upvalues: a table value keeps its identity")
            eq(byname.marker and byname.marker.value, marker, "upvalues: a scalar value")
            eq(byname.__compose_global, nil, "upvalues: a global name never appears")

            local names = Compose.Names(uses)
            eq(type(names), "table", "names: returns a list")
            if type(names) == "table" then
                eq(#names, 2, "names: one entry per slot")
                eq(names[1], debug.getupvalue(uses, 1), "names: follows index order")
            end
        end

        local nothing
        local function holds_nil() return nothing end
        local nil_list, nil_reason = Compose.Upvalues(holds_nil)
        truthy(nil_list ~= nil, "upvalues: a nil-valued cell still enumerates ("
            .. tostring(nil_reason) .. ")")
        if nil_list ~= nil then
            eq(#nil_list, 1, "upvalues: one slot")
            eq(nil_list[1].name, "nothing", "upvalues: the name survives a nil value")
            eq(nil_list[1].value, nil, "upvalues: the value is nil")
            check(nil_list[1].index ~= nil, "upvalues: the nil slot still has an index")
        end
    end

    ----------------------------------------------------------------------------
    -- Declare
    ----------------------------------------------------------------------------
    do
        eq(Compose.Declare({}), "", "declare: empty is no statement")
        eq(Compose.Declare({ "a" }), "local a", "declare: one name")
        eq(Compose.Declare({ "a", "b" }), "local a, b", "declare: two names")

        local none, none_reason = Compose.Declare(nil)
        reject(none, none_reason, "declare: non-table", "dense array")

        local hole, hole_reason = Compose.Declare({ "a", nil, "c" })
        reject(hole, hole_reason, "declare: a hole", "dense array")

        local extra, extra_reason = Compose.Declare({ "a", tail = 1 })
        reject(extra, extra_reason, "declare: an extra key", "dense array")

        local digit, digit_reason = Compose.Declare({ "1a" })
        reject(digit, digit_reason, "declare: a leading digit", "not an identifier")

        local keyword, keyword_reason = Compose.Declare({ "end" })
        reject(keyword, keyword_reason, "declare: a keyword", "not an identifier")

        local space, space_reason = Compose.Declare({ "a b" })
        reject(space, space_reason, "declare: whitespace", "not an identifier")

        local dup, dup_reason = Compose.Declare({ "a", "a" })
        reject(dup, dup_reason, "declare: a duplicate", "duplicate declaration")
    end

    ----------------------------------------------------------------------------
    -- Create (statement form): only the visible names are predeclared
    ----------------------------------------------------------------------------
    local entry = capture(STATE, "Boss.lua")
    eq(table.concat(entry.names, ","), "counter,config,pattern,spell",
        "fixture: the anchor captures every top-level local in order")
    local anchor_identity = entry.anchor
    local original_pattern = Anchor.Get(entry, "pattern")

    local state_body = table.concat({
        "local function pattern(self)",
        "    counter = counter + 1",
        "    return counter, config.tag",
        "end",
    }, "\n")
    local created, create_reason = Compose.Create(state_body, "pattern",
        { "counter", "config", "pattern" }, { name = "frag:Boss" })
    truthy(created ~= nil, "create: a statement fragment compiles ("
        .. tostring(create_reason) .. ")")
    if created ~= nil then
        eq(created.form, "statement", "create: form")
        eq(created.target, "pattern", "create: target")
        eq(table.concat(created.declared, ","), "counter,config,pattern",
            "create: declared is the visible set")
        eq(table.concat(created.prefix, ","), "counter,config",
            "create: the target is not predeclared")
        same_set(created.used, { "counter", "config" }, "create: used is the real upvalue set")
        falsy(created.nested, "create: no nested function is flagged")
        contains(created.source, "local counter, config",
            "create: the source predeclares the visible names")
        contains(created.source, "\nreturn pattern", "create: the source returns the definition")
        eq(type(created.fn), "function", "create: a function was produced")

        eq(Anchor.Get(entry, "counter"), 0, "create: the anchor counter is unchanged")
        eq(entry.anchor, anchor_identity, "create: the anchor is never replaced")
        eq(Anchor.Get(entry, "pattern"), original_pattern, "create: nothing is published")

        -- The prefix cells are fresh: an unwired fragment cannot see the file.
        local called, call_error = pcall(created.fn, nil)
        falsy(called, "create: an unwired fragment does not read the file's cells ("
            .. tostring(call_error) .. ")")
        eq(Anchor.Get(entry, "counter"), 0, "create: the refused call left the anchor alone")

        local plan, plan_reason = Compose.Plan(created, entry)
        truthy(plan ~= nil, "plan: a live anchor plans (" .. tostring(plan_reason) .. ")")
        if plan ~= nil then
            eq(plan.fn, created.fn, "plan: keeps the closure")
            eq(plan.anchor, entry.anchor, "plan: targets the anchor")
            eq(#plan.joins, 2, "plan: one join per used name")
            eq(table.concat(plan.names), "counterconfig", "plan: the read-set is recorded")
            for i = 1, #plan.joins do
                local join = plan.joins[i]
                eq(join.fn, created.fn, "plan: join " .. i .. " carries the closure")
                eq(join.anchor, entry.anchor, "plan: join " .. i .. " carries the anchor")
                eq(join.index, upvalue_index(created.fn, join.name),
                    "plan: join " .. i .. " uses the real upvalue slot")
                eq(join.donor, Anchor.Slot(entry, join.name),
                    "plan: join " .. i .. " uses the anchor's slot")
                eq(join.anchor_name, join.name, "plan: no mapping means the same name")
            end
        end

        if joinable then
            local attached, attached_plan, attach_reason =
                Compose.Attach(created, entry, { capability = runtime })
            truthy(attached ~= nil, "attach: wires the new closure ("
                .. tostring(attach_reason) .. ")")
            if attached ~= nil then
                eq(attached, created.fn, "attach: returns the same closure")
                truthy(attached_plan.joined, "attach: the plan records the join")
                eq(Anchor.Get(entry, "pattern"), original_pattern,
                    "attach: joining publishes nothing")
                eq(Compose.Join(attached_plan, runtime), 2,
                    "join: re-running a joined plan is a harmless no-op")

                local count, tag = created.fn(nil)
                eq(count, 1, "attach: the fragment increments the file's counter")
                eq(tag, "c", "attach: the fragment reads the file's config")
                eq(Anchor.Get(entry, "counter"), 1,
                    "attach: the write went through the anchor cell")
                eq(original_pattern(nil), 1, "attach: the file's own closure sees the new value")

                truthy(Anchor.Set(entry, "counter", 41),
                    "attach: an external setter writes the cell")
                eq(select(1, created.fn(nil)), 42,
                    "attach: the fragment sees the external setter")
                Anchor.Set(entry, "config", { tag = "z" })
                eq(select(2, created.fn(nil)), "z",
                    "attach: a whole-table replacement is seen through the cell")

                if runtime.upvalueid then
                    truthy(Anchor.Shared(entry, "counter", created.fn,
                        upvalue_index(created.fn, "counter")),
                        "attach: the fragment's counter cell is the anchor's cell")
                end
            end
        else
            local attached, attached_plan, attach_reason =
                Compose.Attach(created, entry, { capability = runtime })
            eq(attached, nil, "attach: refuses without upvaluejoin")
            eq(attached_plan, nil, "attach: no plan is returned on refusal")
            contains(attach_reason, "capability", "attach: the refusal names the capability")
            eq(Anchor.Get(entry, "counter"), 0,
                "attach: a refused wiring leaves the anchor untouched")
        end
    end

    ----------------------------------------------------------------------------
    -- recursion: the self-reference is one cell, joined to the anchor slot
    ----------------------------------------------------------------------------
    local recur_entry = capture(RECUR, "Recur.lua")
    local old_recur = Anchor.Get(recur_entry, "recur")
    eq(old_recur(4), 4, "recursion: the file's own closure recurses")

    local recur_body = table.concat({
        "local function recur(n)",
        "    if n <= 0 then return 0 end",
        "    return 10 + recur(n - 1)",
        "end",
    }, "\n")
    local recreated, recur_reason = Compose.Create(recur_body, "recur", { "recur" },
        { name = "frag:recur" })
    truthy(recreated ~= nil, "recursion: the fragment compiles ("
        .. tostring(recur_reason) .. ")")
    if recreated ~= nil then
        eq(#recreated.prefix, 0, "recursion: the target is not predeclared")
        eq(table.concat(recreated.used, ","), "recur",
            "recursion: the self-reference is a real upvalue")
        if joinable then
            local attached, recur_plan, attach_reason =
                Compose.Attach(recreated, recur_entry, { capability = runtime })
            truthy(attached ~= nil, "recursion: the fragment is wired ("
                .. tostring(attach_reason) .. ")")
            if attached ~= nil then
                eq(#recur_plan.joins, 1, "recursion: a single join")
                eq(recur_plan.joins[1].anchor_name, "recur", "recursion: joined by name")
                eq(recur_plan.joins[1].donor, Anchor.Slot(recur_entry, "recur"),
                    "recursion: joined to the anchor's slot")
                if runtime.upvalueid then
                    truthy(Anchor.Shared(recur_entry, "recur", recreated.fn,
                        upvalue_index(recreated.fn, "recur")),
                        "recursion: the self-reference shares the anchor cell")
                end

                -- Joined but not yet published: recursion runs through the
                -- anchor cell, which still holds the file's own function.
                eq(recreated.fn(4), 13,
                    "recursion: the join routes recursion through the anchor cell")
                eq(Anchor.Get(recur_entry, "recur"), old_recur,
                    "recursion: Attach publishes nothing")

                -- Commit writes the new function into the shared cell.
                truthy(Anchor.Set(recur_entry, "recur", recreated.fn),
                    "recursion: commit writes the anchor cell")
                eq(recreated.fn(4), 40,
                    "recursion: after commit the new function recurses to itself")
                eq(old_recur(4), 31,
                    "recursion: the old closure now recurses through the new function")
            end
        else
            local attached, _, attach_reason =
                Compose.Attach(recreated, recur_entry, { capability = runtime })
            eq(attached, nil, "recursion: refuses without upvaluejoin")
            contains(attach_reason, "capability", "recursion: the refusal names the capability")
            eq(Anchor.Get(recur_entry, "recur"), old_recur,
                "recursion: the file's closure is untouched")
        end
    end

    ----------------------------------------------------------------------------
    -- expression form, and a name outside `visible` stays a global
    ----------------------------------------------------------------------------
    if joinable then
        local expression, expression_reason = Compose.Create(
            "function(self)\n    return spell\nend", nil, { "spell" },
            { form = "expression", name = "frag:spell" })
        truthy(expression ~= nil, "expression: compiles ("
            .. tostring(expression_reason) .. ")")
        if expression ~= nil then
            eq(expression.form, "expression", "expression: form")
            eq(table.concat(expression.prefix, ","), "spell",
                "expression: the visible name is predeclared")
            same_set(expression.used, { "spell" }, "expression: used")
            truthy(Compose.Attach(expression, entry, { capability = runtime }) ~= nil,
                "expression: wired")
            truthy(Anchor.Set(entry, "spell", 9), "expression: an external setter writes the cell")
            eq(expression.fn(nil), 9, "expression: reads the anchor cell")
            Anchor.Set(entry, "spell", 11)
            eq(expression.fn(nil), 11, "expression: the cell stays live")
        end
    end

    do
        local global_body = table.concat({
            "local function pattern(self)",
            "    __compose_ran = (__compose_ran or 0) + 1",
            "    return counter, helper_tag",
            "end",
        }, "\n")
        local globals, globals_reason = Compose.Create(global_body, "pattern",
            { "counter", "pattern" }, { name = "frag:global" })
        truthy(globals ~= nil, "global: compiles (" .. tostring(globals_reason) .. ")")
        if globals ~= nil then
            same_set(globals.used, { "counter" }, "global: only the visible name is captured")
            if joinable then
                local attached, global_plan, attach_reason =
                    Compose.Attach(globals, entry, { capability = runtime })
                truthy(attached ~= nil, "global: wired (" .. tostring(attach_reason) .. ")")
                if attached ~= nil then
                    eq(#global_plan.joins, 1, "global: a single join")
                    eq(_G.__compose_ran, nil, "global: Create/Attach never calls the body")
                    _G.helper_tag = "H"
                    eq(select(2, globals.fn(nil)), "H",
                        "global: a name outside visible is read as a global")
                    _G.helper_tag = "H2"
                    eq(select(2, globals.fn(nil)), "H2", "global: the global is late-bound")
                    eq(_G.__compose_ran, 2, "global: the body ran only when called")
                    _G.helper_tag = nil
                    _G.__compose_ran = nil
                end
            else
                local attached, _, attach_reason =
                    Compose.Attach(globals, entry, { capability = runtime })
                eq(attached, nil, "global: refuses without upvaluejoin")
                contains(attach_reason, "capability", "global: the refusal names the capability")
            end
        end
    end

    ----------------------------------------------------------------------------
    -- nested scopes: an inner closure shares the outer cell; an inner shadow is
    -- the case with no joinable upvalue
    ----------------------------------------------------------------------------
    do
        local nested_only = table.concat({
            "local function pattern(self)",
            "    return function() return counter end",
            "end",
        }, "\n")
        local alone, alone_reason = Compose.Create(nested_only, "pattern",
            { "counter", "config", "pattern" })
        truthy(alone ~= nil, "nested: a nested-only capture is still reachable ("
            .. tostring(alone_reason) .. ")")
        if alone ~= nil then
            truthy(alone.nested, "nested: the nested function is flagged")
            same_set(alone.used, { "counter" },
                "nested: the outer closure carries the one cell the inner also reads")
            if joinable then
                local nested_entry = capture(ONE, "Nested.lua")
                local attached, nested_plan, attach_reason =
                    Compose.Attach(alone, nested_entry, { capability = runtime })
                truthy(attached ~= nil, "nested: the outer closure is wired ("
                    .. tostring(attach_reason) .. ")")
                if attached ~= nil then
                    eq(#nested_plan.joins, 1,
                        "nested: one join through the outer closure")
                    eq(attached(nil)(), 0,
                        "nested: joining the outer cell wires the inner closure too")
                    truthy(Anchor.Set(nested_entry, "counter", 5),
                        "nested: the shared cell stays live")
                    eq(attached(nil)(), 5,
                        "nested: the inner closure follows the outer cell")
                end
            end
        end

        local nested_shared = table.concat({
            "local function pattern(self)",
            "    counter = counter + 1",
            "    return function() return counter end",
            "end",
        }, "\n")
        local shared, shared_reason = Compose.Create(nested_shared, "pattern",
            { "counter", "config", "pattern" })
        truthy(shared ~= nil, "nested: a shared capture is allowed ("
            .. tostring(shared_reason) .. ")")
        if shared ~= nil then
            truthy(shared.nested, "nested: the nested function is flagged")
            same_set(shared.used, { "counter" },
                "nested: the outer closure carries the shared cell")
        end

        local field_only = table.concat({
            "local function pattern(self)",
            "    return function() return self.counter end",
            "end",
        }, "\n")
        local field, field_reason = Compose.Create(field_only, "pattern",
            { "counter", "config", "pattern" })
        truthy(field ~= nil, "nested: a field access is not a capture ("
            .. tostring(field_reason) .. ")")
        if field ~= nil then
            eq(#field.used, 0, "nested: a field access captures nothing")
        end

        local record_key = table.concat({
            "local function pattern(self)",
            "    return function() return { counter = 1 } end",
            "end",
        }, "\n")
        local record, record_reason = Compose.Create(record_key, "pattern",
            { "counter", "config", "pattern" })
        truthy(record ~= nil, "nested: a record key is not a capture ("
            .. tostring(record_reason) .. ")")

        -- Conservative on purpose: an inner shadow is refused, never guessed.
        local shadow = table.concat({
            "local function pattern(self)",
            "    return function() local counter = 1 return counter end",
            "end",
        }, "\n")
        local shaded, shaded_reason = Compose.Create(shadow, "pattern",
            { "counter", "config", "pattern" })
        reject(shaded, shaded_reason, "nested: an inner shadow is refused", "nested scope captures")
    end

    ----------------------------------------------------------------------------
    -- Create refusals
    ----------------------------------------------------------------------------
    do
        local body, body_reason = Compose.Create(42, "pattern", {})
        reject(body, body_reason, "create: non-string body", "body must be a string")

        local visible, visible_reason = Compose.Create("return 1", "pattern", "x")
        reject(visible, visible_reason, "create: non-array visible", "dense array")

        local target, target_reason = Compose.Create("return 1", "1bad", {})
        reject(target, target_reason, "create: invalid target", "target must be an identifier")

        local form, form_reason = Compose.Create("return 1", "pattern", {}, { form = "chunk" })
        reject(form, form_reason, "create: unknown form", "form must be")

        local options, options_reason = Compose.Create("return 1", "pattern", {}, "x")
        reject(options, options_reason, "create: non-table options", "options must be a table")

        local broken, broken_reason = Compose.Create(
            "local function pattern(self) return ) end", "pattern", {})
        reject(broken, broken_reason, "create: compile failure", "compile failed")

        local absent, absent_reason = Compose.Create("local other = 1", "pattern", {})
        reject(absent, absent_reason, "create: no function produced",
            "did not produce a function")

        local incapable, incapable_reason = Compose.Create("local function pattern() end",
            "pattern", {}, { capability = caps({ getupvalue = false }) })
        reject(incapable, incapable_reason, "create: capability refusal", "capability")

        local keyword, keyword_reason = Compose.Create("local function pattern() end",
            "pattern", { "end" })
        reject(keyword, keyword_reason, "create: a keyword in visible", "identifier")

        local duplicate, duplicate_reason = Compose.Create("local function pattern() end",
            "pattern", { "a", "a" })
        reject(duplicate, duplicate_reason, "create: a duplicate in visible",
            "duplicate declaration")
    end

    ----------------------------------------------------------------------------
    -- Plan / Join refusals
    ----------------------------------------------------------------------------
    do
        local one_entry = capture(ONE, "One.lua")
        local fragment = Compose.Create(
            "local function pattern(self)\n    return counter\nend", "pattern",
            { "counter", "pattern" }, { name = "frag:one" })
        truthy(fragment ~= nil, "plan: the fixture compiles")

        local fn, fn_reason = Compose.Plan("nope", one_entry)
        reject(fn, fn_reason, "plan: a non-function", "fn must be a function")

        local plainness, plainness_reason = Compose.Plan(fragment, setmetatable({}, {}))
        reject(plainness, plainness_reason, "plan: a non-plain entry", "anchor entry")

        local dead, dead_reason = Compose.Plan(fragment, {})
        reject(dead, dead_reason, "plan: an entry without an anchor", "not live")

        local missing_file = capture(ONE, "Missing.lua")
        missing_file.missing = true
        local vanished, vanished_reason = Compose.Plan(fragment, missing_file)
        reject(vanished, vanished_reason, "plan: a vanished file", "not live")

        local ghost = Compose.Create(
            "local function pattern(self)\n    return ghost_name\nend", "pattern",
            { "ghost_name", "pattern" })
        truthy(ghost ~= nil, "plan: the ghost fixture compiles")
        local orphan, orphan_reason = Compose.Plan(ghost, one_entry)
        reject(orphan, orphan_reason, "plan: a name with no slot",
            "no anchor slot for upvalue 'ghost_name'")

        local alias = Compose.Create(
            "local function pattern(self)\n    return n\nend", "pattern",
            { "n", "pattern" })
        truthy(alias ~= nil, "plan: the alias fixture compiles")
        local mapped, mapped_reason = Compose.Plan(alias, one_entry,
            { mapping = { n = "counter" } })
        truthy(mapped ~= nil, "plan: a mapping builds (" .. tostring(mapped_reason) .. ")")
        if mapped ~= nil then
            eq(#mapped.joins, 1, "plan: a mapping produces one join")
            eq(mapped.joins[1].name, "n", "plan: the fragment name is kept")
            eq(mapped.joins[1].anchor_name, "counter", "plan: the donor name is the mapping target")
            eq(mapped.joins[1].donor, Anchor.Slot(one_entry, "counter"),
                "plan: the donor is the mapped slot")
        end

        local unknown, unknown_reason = Compose.Plan(alias, one_entry,
            { mapping = { n = "missing_slot" } })
        reject(unknown, unknown_reason, "plan: a mapping to a missing slot", "no anchor slot")

        local badname, badname_reason = Compose.Plan(alias, one_entry,
            { mapping = { n = "1bad" } })
        reject(badname, badname_reason, "plan: a mapping must be a name", "mapping must name")

        local nottable, nottable_reason = Compose.Plan(alias, one_entry, { mapping = "x" })
        reject(nottable, nottable_reason, "plan: a non-table mapping", "mapping must be a table")

        local plan, plan_reason = Compose.Plan(fragment, one_entry)
        truthy(plan ~= nil, "join: the plan exists (" .. tostring(plan_reason) .. ")")

        local noplan, noplan_reason = Compose.Join(nil, caps())
        reject(noplan, noplan_reason, "join: no plan", "plan must be a join plan")

        local unjoined, unjoined_reason = Compose.Join(plan, caps({ upvaluejoin = false }))
        reject(unjoined, unjoined_reason, "join: without upvaluejoin", "capability")

        local bad_record = {
            fn = fragment.fn,
            joins = { { fn = fragment.fn, index = 999, anchor = one_entry.anchor,
                donor = 1, name = "counter" } },
        }
        local bad, bad_reason = Compose.Join(bad_record, caps())
        eq(bad, nil, "join: an impossible slot is refused")
        contains(bad_reason, "join", "join: the refusal names the step")

        if joinable then
            eq(Compose.Join(plan, runtime), 1, "join: the real runtime joins one slot")
            truthy(plan.joined, "join: the plan records the join")
            if runtime.upvalueid then
                truthy(Anchor.Shared(one_entry, "counter", fragment.fn,
                    upvalue_index(fragment.fn, "counter")),
                    "join: the cells are identical after joining")
            end
            eq(fragment.fn(nil), 0, "join: the wired closure reads the anchor cell")
        else
            local default, default_reason = Compose.Join(plan)
            eq(default, nil, "join: the default capability refuses on a join-less runtime")
            contains(default_reason, "capability", "join: and names the capability")
        end
    end

    if failed > 0 then
        for i = 1, math.min(#failures, 25) do
            print("[SpellHotReload compose] FAIL " .. failures[i])
        end
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
