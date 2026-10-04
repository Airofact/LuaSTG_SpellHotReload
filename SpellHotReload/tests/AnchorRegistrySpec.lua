--------------------------------------------------------------------------------
--- SpellHotReload tests/AnchorRegistrySpec.lua
---
--- Unit spec for the anchor-first file registry. AnchorRegistry keeps one anchor
--- per file and demotes the legacy `name -> value` map from state truth to a
--- read-through view of that anchor.
---
--- What is asserted here is the registry contract:
---
---   * the first anchor wins - registering the same anchor is idempotent, a
---     different anchor for an already-held file is refused, and a bare
---     `name -> value` map is not a registry entry;
---   * the legacy map surface (`Get`/`GetValue`/`SetAll`/`Names`) reads and
---     writes the real cells, so an external setter, a function reassignment
---     and a whole-table replacement are all observed, while `Get` is a fresh
---     snapshot no consumer can make stale by mutating it;
---   * nil and false cells have slots although a map cannot express them, and
---     `Names`/`Slot` tell them apart from a name the anchor never captured;
---   * a name the anchor cannot hold is kept in the pending overlay instead of
---     being silently dropped, so the legacy publication is not lossy;
---   * a vanished file loses its reload verdict while its cells stay readable,
---     and Release drops every strong reference.
---
--- Runs under plain Lua 5.1 and LuaJIT with no engine globals (see
--- anchor-registry/run-targeted.lua). Capture cases inject an explicit
--- capability so the anchor path is deterministic everywhere; a capability the
--- runtime lacks only withholds `reloadable`, it never removes the anchor, so a
--- non-reloadable file is still registrable and readable.
--------------------------------------------------------------------------------

local AnchorLoad = require("SpellHotReload.AnchorLoad")
local AnchorRegistry = require("SpellHotReload.AnchorRegistry")

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

---A capable-runtime capability table with selected flags overridden.
local function caps(overrides)
    local capability = {
        getupvalue = true, setupvalue = true, upvaluejoin = true,
        upvalueid = true,
    }
    for key, value in pairs(overrides or {}) do capability[key] = value end
    return capability
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

---Every shape the registry contract talks about: state, a function cell, a
---table cell, a false cell, a nil cell, and setters the file itself exposes.
local FIXTURE = table.concat({
    "local counter = 0",
    "local helper = function() return 1 end",
    "local config = { a = 1 }",
    "local flag = false",
    "local nothing = nil",
    "local function set_counter(v) counter = v end",
    "local function replace_helper() helper = function() return 9 end end",
    "local function reset_config() config = { a = 2 } end",
    "local function read_counter() return counter end",
    "local function read_helper() return helper() end",
    "local function read_flag() return flag end",
    "local function read_config() return config end",
}, "\n") .. "\n"

---Capture the fixture once, as the load path would.
local function capture(source, name, overrides)
    local entry, reason = AnchorLoad.Capture(source or FIXTURE,
        { name = name or "Fixture.lua", capability = caps(overrides) })
    assert(entry ~= nil, "fixture capture failed: " .. tostring(reason))
    assert(entry.captured == true, "fixture capture has no map: " .. tostring(entry.reason))
    assert(entry.anchor ~= nil, "fixture capture has no anchor: " .. tostring(entry.reason))
    return entry
end

function M.run()
    ----------------------------------------------------------------------------
    -- module identity
    ----------------------------------------------------------------------------
    eq(AnchorRegistry.Kind, "SpellHotReload.AnchorRegistry", "module kind")
    eq(type(AnchorRegistry.Version), "number", "module version is a number")

    ----------------------------------------------------------------------------
    -- registration: only an anchor-backed entry is state
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local ok, reason = reg:Set("", {})
        falsy(ok, "registration: an empty file name is refused")
        contains(reason, "non-empty string", "registration: and explains the file name")
        ok, reason = reg:Set("a.lua", nil)
        falsy(ok, "registration: a nil entry is refused")
        contains(reason, "anchor and its slots", "registration: and names what an entry needs")
        ok, reason = reg:Set("a.lua", { counter = 1 })
        falsy(ok, "registration: a plain name -> value map is not an entry")
        contains(reason, "anchor and its slots", "registration: the map is not the state")
        ok, reason = reg:Set("a.lua", { anchor = function() end })
        falsy(ok, "registration: an entry without slots is refused")
        contains(reason, "anchor and its slots", "registration: and names the slots")
        ok, reason = reg:Set("a.lua", { slots = {} })
        falsy(ok, "registration: an entry without an anchor is refused")
        contains(reason, "anchor and its slots", "registration: and names the anchor")
        eq(reg:Size(), 0, "registration: nothing was stored")
        eq(reg:Has("a.lua"), false, "registration: a refused file is not registered")
    end

    ----------------------------------------------------------------------------
    -- first anchor wins
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local first = capture()
        local second = capture()
        check(first.anchor ~= second.anchor, "first-load: two loads produce two anchors")
        local ok, reason = reg:Set("@A.lua", first)
        truthy(ok, "first-load: the first anchor is accepted")
        eq(reason, nil, "first-load: with no reason")
        ok, reason = reg:Set("@A.lua", first)
        truthy(ok, "first-load: registering the same anchor is idempotent")
        eq(reason, nil, "first-load: idempotently, with no reason")
        eq(reg:Entry("@A.lua"), first, "first-load: the entry is the registered one")
        eq(reg:Anchor("@A.lua"), first.anchor, "first-load: the anchor is held")
        ok, reason = reg:Set("@A.lua", second)
        falsy(ok, "first-load: a second anchor is refused")
        contains(reason, "already registered with another anchor", "first-load: and explains why")
        eq(reg:Anchor("@A.lua"), first.anchor, "first-load: the refused anchor replaced nothing")
        eq(reg:Entry("@A.lua"), first, "first-load: the held entry is unchanged")
        eq(reg:Size(), 1, "first-load: one file is held")
        ok, reason = reg:Set("@B.lua", second)
        truthy(ok, "first-load: a different file takes its own anchor")
        eq(reason, nil, "first-load: with no reason")
        eq(reg:Size(), 2, "first-load: two files are held")
    end

    ----------------------------------------------------------------------------
    -- the loaded source rides with the entry
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)
        eq(reg:GetSource("@A.lua"), FIXTURE, "source: registration adopts the loaded source")
        truthy(reg:SetSource("@A.lua", "replaced"), "source: SetSource overwrites")
        eq(reg:GetSource("@A.lua"), "replaced", "source: the new source is read back")
        eq(reg:GetSource("@B.lua"), nil, "source: an unknown file has no source")
        eq(reg:GetSource(""), nil, "source: an empty file name has no source")
    end

    ----------------------------------------------------------------------------
    -- queries
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        reg:Set("b.lua", capture("local b = 2\n", "B.lua"))
        reg:Set("a.lua", capture("local a = 1\n", "A.lua"))
        eq(reg:Size(), 2, "queries: two files are held")
        local files = reg:Files()
        eq(#files, 2, "queries: two file keys")
        eq(files[1], "a.lua", "queries: Files is sorted (a)")
        eq(files[2], "b.lua", "queries: Files is sorted (b)")
        eq(reg:Has("a.lua"), true, "queries: Has finds a file")
        eq(reg:Has("c.lua"), false, "queries: Has rejects an unknown file")
        local entry, reason = reg:Entry("c.lua")
        eq(entry, nil, "queries: an unknown file has no entry")
        contains(reason, "unknown file", "queries: and says so")
        local anchor, areason = reg:Anchor("c.lua")
        eq(anchor, nil, "queries: an unknown file has no anchor")
        contains(areason, "unknown file", "queries: and says so")
        entry, reason = reg:Entry("")
        eq(entry, nil, "queries: an empty file name has no entry")
        contains(reason, "non-empty string", "queries: and explains the name")
    end

    ----------------------------------------------------------------------------
    -- slots are the cell identity
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)
        local slots, sreason = reg:Slots("@A.lua")
        eq(slots, entry.slots, "slots: Slots is the entry's live slot table")
        eq(sreason, nil, "slots: with no reason")
        local index, ireason = reg:Slot("@A.lua", "counter")
        eq(index, entry.slots.counter, "slots: Slot answers the real index")
        check(type(index) == "number" and index >= 1, "slots: and it is a positive index")
        eq(ireason, nil, "slots: a known name has no reason")
        index, ireason = reg:Slot("@A.lua", "nope")
        eq(index, nil, "slots: an unknown name has no index")
        contains(ireason, "unknown slot", "slots: and names the missing slot")
        index, ireason = reg:Slot("@A.lua", "")
        eq(index, nil, "slots: an empty name has no index")
        contains(ireason, "non-empty string", "slots: and explains the name")
        index, ireason = reg:Slot("@B.lua", "counter")
        eq(index, nil, "slots: an unknown file has no index")
        contains(ireason, "unknown file", "slots: and says so")
        local missing_slots, mreason = reg:Slots("@B.lua")
        eq(missing_slots, nil, "slots: an unknown file has no slots")
        contains(mreason, "unknown file", "slots: and says so")
    end

    ----------------------------------------------------------------------------
    -- live read-through: the cells are the state
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)
        eq(reg:Legacy("@A.lua"), entry.map, "live: Legacy is the load-time map")
        eq(entry.map.counter, 0, "live: the load-time snapshot starts at the loaded value")
        eq(reg:Get("@A.lua").counter, 0, "live: Get starts at the loaded value")
        eq(reg:GetValue("@A.lua", "counter"), 0, "live: GetValue starts at the loaded value")

        -- An external write through the registry reaches the file's own closure.
        truthy(reg:Write("@A.lua", "counter", 7), "live: Write reaches the anchor cell")
        eq(entry.map.read_counter(), 7, "live: the file's closure sees the write")
        eq(reg:GetValue("@A.lua", "counter"), 7, "live: GetValue reads the cell")
        eq(reg:Get("@A.lua").counter, 7, "live: Get reads the cell")
        eq(reg:Legacy("@A.lua").counter, 0, "live: the load-time map does not move")

        -- A setter inside the file reaches the registry.
        entry.map.set_counter(11)
        eq(reg:GetValue("@A.lua", "counter"), 11, "live: a file setter is observed")
        eq(reg:Get("@A.lua").counter, 11, "live: and the snapshot follows")

        -- A function reassignment keeps the cell, not the old value.
        local old_helper = reg:GetValue("@A.lua", "helper")
        entry.map.replace_helper()
        local new_helper = reg:GetValue("@A.lua", "helper")
        check(new_helper ~= old_helper, "live: the helper cell was reassigned")
        eq(new_helper(), 9, "live: the replacement is the new function")
        eq(entry.map.read_helper(), 9, "live: the file's closure calls the replacement")

        -- A whole-table replacement swaps the cell contents.
        local before = reg:GetValue("@A.lua", "config")
        entry.map.reset_config()
        local after = reg:GetValue("@A.lua", "config")
        check(after ~= before, "live: the config table was replaced")
        eq(after.a, 2, "live: the replacement is the new table")
        eq(entry.map.read_config(), after, "live: the file's closure reads the new table")
    end

    ----------------------------------------------------------------------------
    -- nil and false cells are slots, not absences
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)

        local value, reason = reg:GetValue("@A.lua", "flag")
        eq(value, false, "false: a false cell reads false")
        eq(reason, nil, "false: and is a success")
        eq(reg:Get("@A.lua").flag, false, "false: the snapshot carries false")
        check(reg:Slot("@A.lua", "flag") ~= nil, "false: a false cell still has a slot")

        value, reason = reg:GetValue("@A.lua", "nothing")
        eq(value, nil, "nil: a nil cell reads nil")
        eq(reason, nil, "nil: and is a success, not an unknown slot")
        check(reg:Slot("@A.lua", "nothing") ~= nil, "nil: a nil cell still has a slot")
        eq(reg:Get("@A.lua").nothing, nil, "nil: a map cannot express the nil cell")

        local names = reg:Names("@A.lua")
        eq(#names, count_keys(entry.slots), "nil: Names covers every slot")
        local ordered, found_nothing, found_flag = true, false, false
        for i = 1, #names do
            if i > 1 and names[i] < names[i - 1] then ordered = false end
            if names[i] == "nothing" then found_nothing = true end
            if names[i] == "flag" then found_flag = true end
        end
        truthy(ordered, "nil: Names is sorted")
        truthy(found_nothing, "nil: Names lists the nil cell")
        truthy(found_flag, "nil: Names lists the false cell")

        value, reason = reg:GetValue("@A.lua", "nope")
        eq(value, nil, "nil: an unknown name reads nil")
        check(type(reason) == "string" and reason ~= "", "nil: an unknown name explains itself")
        contains(reason, "unknown slot", "nil: and names the missing slot")
    end

    ----------------------------------------------------------------------------
    -- Get is a snapshot, never a second source of truth
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)
        local snapshot = reg:Get("@A.lua")
        snapshot.counter = 99
        eq(reg:GetValue("@A.lua", "counter"), 0, "snapshot: mutating it does not write the cell")
        eq(entry.map.read_counter(), 0, "snapshot: the file still reads its own value")
        truthy(reg:Write("@A.lua", "counter", 3), "snapshot: Write still works")
        eq(reg:Get("@A.lua").counter, 3, "snapshot: a later Get reflects the write")
        eq(snapshot.counter, 99, "snapshot: the earlier table is left alone")
    end

    ----------------------------------------------------------------------------
    -- the legacy publication is redirected, not lossy
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)
        local replacement = function() return 42 end
        truthy(reg:SetAll("@A.lua", { counter = 5, helper = replacement }),
            "setall: the legacy publication is accepted")
        eq(reg:GetValue("@A.lua", "counter"), 5, "setall: a slot-backed name is live")
        eq(entry.map.read_counter(), 5, "setall: and the file's closure sees it")
        eq(reg:GetValue("@A.lua", "helper"), replacement, "setall: the function cell was updated")
        eq(entry.map.read_helper(), 42, "setall: and the file's closure calls it")
        eq(reg:Legacy("@A.lua").counter, 0, "setall: the load-time map is untouched")
        eq(count_keys(reg:Pending("@A.lua")), 0, "setall: nothing is pending yet")

        -- A name the anchor cannot hold goes to the pending overlay.
        local extra = function() return 1 end
        truthy(reg:SetAll("@A.lua", { added_by_candidate = extra }),
            "setall: a slotless name is not refused")
        eq(reg:Pending("@A.lua").added_by_candidate, extra, "setall: it is held in the overlay")
        eq(reg:GetValue("@A.lua", "added_by_candidate"), extra,
            "setall: GetValue answers from the overlay")
        eq(reg:Get("@A.lua").added_by_candidate, extra, "setall: Get merges the overlay")
        local names = reg:Names("@A.lua")
        local found = false
        for i = 1, #names do
            if names[i] == "added_by_candidate" then found = true end
        end
        truthy(found, "setall: Names lists the overlay name")

        -- Write follows the same rule.
        truthy(reg:Write("@A.lua", "another", 1), "setall: Write accepts a slotless name")
        eq(reg:GetValue("@A.lua", "another"), 1, "setall: it reads back from the overlay")

        local ok, reason = reg:SetAll("@A.lua", nil)
        falsy(ok, "setall: a nil map is refused")
        contains(reason, "map must be a table", "setall: and says so")
        ok, reason = reg:SetAll("@B.lua", {})
        falsy(ok, "setall: an unknown file is refused")
        contains(reason, "unknown file", "setall: and says so")
        ok, reason = reg:Write("@A.lua", "", 1)
        falsy(ok, "setall: an empty name is refused")
        contains(reason, "non-empty string", "setall: and explains the name")
        ok, reason = reg:Write("@B.lua", "counter", 1)
        falsy(ok, "setall: writing an unknown file is refused")
        contains(reason, "unknown file", "setall: and says so")
        ok, reason = reg:Legacy("@B.lua")
        eq(ok, nil, "setall: an unknown file has no load-time map")
        contains(reason, "unknown file", "setall: and says so")
    end

    ----------------------------------------------------------------------------
    -- a vanished file, and a file that is not reloadable
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)
        truthy(entry.reloadable, "live: the fixture is reloadable")
        eq(reg:Live("@A.lua"), true, "live: a captured file is live")
        eq(reg:Live("@B.lua"), false, "live: an unknown file is not live")
        truthy(reg:Write("@A.lua", "counter", 4), "live: the cell is writable before missing")
        truthy(reg:Missing("@A.lua"), "live: a vanished file is marked missing")
        eq(reg:Live("@A.lua"), false, "live: a missing file is not live")
        eq(reg:GetValue("@A.lua", "counter"), 4, "live: its cells stay readable")
        eq(entry.map.read_counter(), 4, "live: and its own closures keep working")
        local ok, reason = reg:Missing("@B.lua")
        falsy(ok, "live: an unknown file cannot be marked missing")
        contains(reason, "unknown file", "live: and says so")

        -- Registration requires an anchor, not a reload verdict, so a file the
        -- policy or the capability withheld is still held and readable.
        local capped = capture(FIXTURE, "Capped.lua", { upvaluejoin = false })
        eq(capped.reloadable, false, "live: a withheld capability means no reload")
        check(capped.anchor ~= nil, "live: but the anchor is still captured")
        truthy(reg:Set("capped.lua", capped), "live: a non-reloadable entry is still accepted")
        eq(reg:Live("capped.lua"), false, "live: and it is not live")
        eq(reg:GetValue("capped.lua", "counter"), 0, "live: while its cells still read")
    end

    ----------------------------------------------------------------------------
    -- release drops every strong reference
    ----------------------------------------------------------------------------
    do
        local reg = AnchorRegistry.New()
        local holder = setmetatable({}, { __mode = "v" })
        do
            local entry = capture()
            reg:Set("@A.lua", entry)
            truthy(reg:SetSource("@A.lua", FIXTURE), "release: with a source recorded")
            holder.entry = entry
            entry = nil
        end
        eq(reg:Size(), 1, "release: the file is held before Release")
        truthy(reg:Release(), "release: Release reports success")
        eq(reg:Size(), 0, "release: every file is dropped")
        eq(#reg:Files(), 0, "release: Files is empty")
        eq(reg:GetSource("@A.lua"), nil, "release: the source is dropped")
        local entry, reason = reg:Entry("@A.lua")
        eq(entry, nil, "release: the entry is gone")
        contains(reason, "unknown file", "release: and reads as an unknown file")
        truthy(reg:Release(), "release: Release is idempotent")
        collectgarbage("collect")
        collectgarbage("collect")
        eq(holder.entry, nil, "release: no strong reference to the entry survives")
    end

    ----------------------------------------------------------------------------
    -- no engine global
    ----------------------------------------------------------------------------
    do
        local before = global_count()
        local reg = AnchorRegistry.New()
        local entry = capture()
        reg:Set("@A.lua", entry)
        reg:Write("@A.lua", "counter", 1)
        reg:Get("@A.lua")
        reg:SetAll("@A.lua", { counter = 2 })
        reg:Missing("@A.lua")
        reg:Release()
        eq(_G.lstg, nil, "globals: no engine global is required")
        eq(global_count(), before, "globals: the registry adds no global")
    end

    if failed > 0 then
        for i = 1, math.min(#failures, 25) do
            print("[SpellHotReload anchor-registry] FAIL " .. failures[i])
        end
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
