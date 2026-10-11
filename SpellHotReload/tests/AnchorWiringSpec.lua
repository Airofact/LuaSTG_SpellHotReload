--------------------------------------------------------------------------------
--- SpellHotReload tests/AnchorWiringSpec.lua
---
--- Wiring spec for R2's production load path: the DoFile hook's optional capture
--- extension, the dual trailer it uses, and the Plugin's anchor-first
--- resolution.
---
--- What is asserted here is the wiring contract:
---
---   * the dual trailer the hook asks for is AnchorLoad.Trailer's - the legacy
---     `name -> value` map stays the first result and the anchor closure the
---     second, byte-for-byte the same map half as the plain trailer;
---   * with a capture extension the hook runs the file exactly once, keeps
---     publishing the legacy map/source unchanged, and hands the two results to
---     the extension, which registers the anchor with the Plugin;
---   * the first installation still wins, so a second call cannot retarget the
---     hook at another registry;
---   * a Boss file the trailer cannot compile falls through to the original
---     DoFile and registers nothing;
---   * Plugin:CaptureAnchor registers first-load-wins and refuses an anchor
---     that cannot enumerate the captured names, so a later reload can never
---     replace the cells a live closure reads;
---   * Plugin:_LoadedSource / _LoadedValues prefer the anchor registry and fall
---     back to the legacy map, and the anchor view is live (a write through the
---     cell is observed) where the load-time map goes stale;
---   * Plugin:_Publish writes the rebuilt functions through the anchor cells as
---     well as the legacy map.
---
--- Runs under plain Lua 5.1 and LuaJIT with only a stubbed `lstg` global (see
--- anchor-wiring/run-targeted.lua). The hook is installed once per process, so
--- this spec is run from the task-local runner, never from the game's Run.lua.
--------------------------------------------------------------------------------

local Loader = require("SpellHotReload.GeneratedBossLoader")
local AnchorLoad = require("SpellHotReload.Load.AnchorLoad")
local UpvalueRegistry = require("SpellHotReload.Load.UpvalueRegistry")

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

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    return keys
end

local function same_keys(a, b)
    local ka, kb = sorted_keys(a), sorted_keys(b)
    if #ka ~= #kb then return false end
    for i = 1, #ka do
        if ka[i] ~= kb[i] then return false end
    end
    return true
end

local function compile(source, name)
    return (loadstring or load)(source, name)
end

---A capable-runtime capability table, so the anchor path is deterministic on
---vanilla Lua 5.1 (which lacks upvaluejoin) as well as on LuaJIT.
local CAPS = { getupvalue = true, setupvalue = true, upvaluejoin = true, upvalueid = true }

-- Three top-level `local function`s plus a plain local the legacy name list
-- never captures: the hook's anchor must cover exactly the function names.
local BOSS = table.concat({
    "-- synthetic generated boss file",
    "local function helper() return 41 end",
    "local function read() return helper() + 1 end",
    "local counter = 0",
    "local function bump() counter = counter + 1 return counter end",
}, "\n") .. "\n"

function M.run()
    local saved_lstg = rawget(_G, "lstg")
    local saved_boss_binding = rawget(_G, "boss")

    -- Plugin requires the Watcher, whose native module the plain runtime has no
    -- way to load; stub it exactly as the in-game specs do, then restore.
    local watcher_name = "SpellHotReload.Runtime.Watcher"
    local saved_watcher = package.loaded[watcher_name]
    package.loaded[watcher_name] = {}
    local Plugin = require("SpellHotReload.Runtime.Plugin")
    package.loaded[watcher_name] = saved_watcher

    ----------------------------------------------------------------------------
    -- the dual trailer
    ----------------------------------------------------------------------------
    do
        local names = { "helper", "read", "bump" }
        local plain = Loader.BuildTrailer(names)
        local dual = AnchorLoad.Trailer(names)
        eq(type(dual), "string", "the dual trailer builds")
        check(dual:sub(1, #plain) == plain,
            "the dual trailer keeps the legacy map bytes first")
        contains(dual, "function() return helper, read, bump end",
            "and appends the anchor closure")

        local plain_map = compile(BOSS .. "\n" .. plain, "@Plain_Boss.lua")()
        local dual_map, anchor = compile(BOSS .. "\n" .. dual, "@Dual_Boss.lua")()
        eq(type(dual_map), "table", "the dual trailer still returns a map first")
        eq(type(anchor), "function", "and the anchor second")
        check(same_keys(dual_map, plain_map), "both trailers harvest the same names")
        eq(type(dual_map.helper), "function", "the legacy map still carries the functions")
        eq(dual_map.counter, nil, "and never the plain locals")

        eq(type(AnchorLoad.Trailer({})), "string", "an empty name list still builds a trailer")
        local bad, reason = AnchorLoad.Trailer("helper")
        eq(bad, nil, "a non-array name list is refused")
        contains(reason, "dense array", "with the anchor's own reason")
    end

    local plugin = Plugin.New()
    local legacy = plugin:GetRegistry()
    local anchors = plugin:GetAnchors()
    truthy(anchors ~= nil, "the plugin owns an anchor registry")
    eq(anchors:Size(), 0, "it starts empty")

    ----------------------------------------------------------------------------
    -- production wiring: the hook registers the anchor with the plugin
    ----------------------------------------------------------------------------
    local sources = { ["Test_Boss.lua"] = BOSS }
    local fallthrough = 0
    do
        local fake = {
            LoadTextFile = function(name) return sources[name] end,
            DoFile = function(name) fallthrough = fallthrough + 1 return "orig:" .. name end,
        }
        _G.lstg = fake
        Loader.InstallDoFileHook(legacy, {
            trailer = AnchorLoad.Trailer,
            on_capture = function(base, content, names, results)
                plugin:CaptureAnchor(base, content, names, results[1], results[2])
            end,
        })
        local hooked = fake.DoFile
        check(hooked ~= nil, "the hook replaces lstg.DoFile")

        eq(fake.DoFile("Test_Boss.lua"), nil, "a captured Boss file returns nothing")
        eq(fallthrough, 0, "and the original DoFile is not called for it")
        check(legacy:GetSource("Test_Boss.lua") == BOSS, "the legacy source is still published")
        eq(type(legacy:GetValue("Test_Boss.lua", "helper")), "function",
            "and the legacy map still carries the functions")

        truthy(anchors:Has("Test_Boss.lua"), "the hook registered the file's anchor")
        check(anchors:GetSource("Test_Boss.lua") == BOSS, "with the exact loaded bytes")
        for _, name in ipairs({ "helper", "read", "bump" }) do
            check(anchors:Slot("Test_Boss.lua", name) ~= nil, "the anchor holds " .. name)
        end
        eq(#anchors:Names("Test_Boss.lua"), 3,
            "the hook's anchor covers exactly the legacy function names")
        eq(anchors:GetValue("Test_Boss.lua", "helper"), legacy:GetValue("Test_Boss.lua", "helper"),
            "the anchor and the legacy map name the same closure")
        eq(anchors:Legacy("Test_Boss.lua").helper, legacy:GetValue("Test_Boss.lua", "helper"),
            "the entry's load-time map is the map the hook harvested")

        Loader.InstallDoFileHook(UpvalueRegistry.New())
        check(fake.DoFile == hooked, "the first installation still wins")

        eq(fake.DoFile("Other_File.lua"), "orig:Other_File.lua",
            "a non-Boss file keeps the original DoFile")
        eq(fallthrough, 1, "the original runs for it")
        sources["Broken_Boss.lua"] = "local function f() return 1 end\nreturn {}\n"
        eq(fake.DoFile("Broken_Boss.lua"), "orig:Broken_Boss.lua",
            "a Boss file the trailer cannot compile falls through")
        falsy(anchors:Has("Broken_Boss.lua"), "and registers nothing")
        _G.lstg = saved_lstg
    end

    ----------------------------------------------------------------------------
    -- registration is first-load-wins and refuses an unusable anchor
    ----------------------------------------------------------------------------
    do
        local entry = assert(AnchorLoad.Capture(BOSS,
            { name = "Wired_Boss.lua", capability = CAPS }))
        truthy(plugin:CaptureAnchor("Wired_Boss.lua", BOSS, entry.names, entry.map, entry.anchor),
            "the plugin registers a load-time anchor")
        truthy(anchors:Has("Wired_Boss.lua"), "the anchor registry holds the file")
        check(anchors:GetSource("Wired_Boss.lua") == BOSS, "and the source is adopted")
        truthy(plugin:CaptureAnchor("Wired_Boss.lua", BOSS, entry.names, entry.map, entry.anchor),
            "re-registering the same anchor is idempotent")

        local other = assert(AnchorLoad.Capture(BOSS,
            { name = "Wired_Boss.lua", capability = CAPS }))
        falsy(plugin:CaptureAnchor("Wired_Boss.lua", BOSS, other.names, other.map, other.anchor),
            "a second anchor for the same file is refused")
        check(anchors:Anchor("Wired_Boss.lua") == entry.anchor, "the first anchor is kept")

        falsy(plugin:CaptureAnchor("Bad_Boss.lua", BOSS, { "helper" }, {}, function() return 1 end),
            "an anchor that does not capture the names is refused")
        falsy(anchors:Has("Bad_Boss.lua"), "and nothing is registered for it")
        falsy(plugin:CaptureAnchor("Nil_Boss.lua", BOSS, { "helper" }, {}, nil),
            "a missing anchor is refused")
        falsy(anchors:Has("Nil_Boss.lua"), "and registers nothing")
    end

    ----------------------------------------------------------------------------
    -- anchor-first resolution with a legacy fallback
    ----------------------------------------------------------------------------
    do
        legacy:SetAll("Wired_Boss.lua", { counter = 1, helper = legacy:GetValue("Test_Boss.lua", "helper") })
        legacy:SetSource("Wired_Boss.lua", BOSS)
        truthy(anchors:Write("Wired_Boss.lua", "counter", 7), "a write through the anchor cell")
        eq(plugin:_LoadedValues("Wired_Boss.lua").counter, 7, "is what the plugin resolves")
        eq(legacy:GetValue("Wired_Boss.lua", "counter"), 1, "while the load-time map stays stale")
        check(plugin:_LoadedSource("Wired_Boss.lua") == BOSS, "the anchor source is used")

        eq(plugin:_LoadedSource("Missing_Boss.lua"), nil, "an unknown file has no source")
        legacy:SetAll("Legacy_Boss.lua", { helper = 1 })
        legacy:SetSource("Legacy_Boss.lua", "legacy bytes")
        check(plugin:_LoadedSource("Legacy_Boss.lua") == "legacy bytes",
            "the legacy source is the fallback")
        eq(plugin:_LoadedValues("Legacy_Boss.lua").helper, 1, "as is the legacy map")
        check(plugin:_LoadedValues("Wired_Boss.lua").counter ~= legacy:GetValue("Wired_Boss.lua", "counter"),
            "the anchor wins over the legacy map")
    end

    ----------------------------------------------------------------------------
    -- publication reaches the anchor cells
    ----------------------------------------------------------------------------
    do
        local fn = function() return 99 end
        plugin:_Publish("Wired_Boss.lua", { helper = fn })
        eq(anchors:GetValue("Wired_Boss.lua", "helper"), fn,
            "the publication reached the anchor cell")
        eq(legacy:GetValue("Wired_Boss.lua", "helper"), fn, "and the legacy map")
        eq(anchors:Get("Wired_Boss.lua").helper, fn, "the snapshot reads through the cell")

        plugin:_Publish("Legacy_Boss.lua", { helper = fn })
        eq(legacy:GetValue("Legacy_Boss.lua", "helper"), fn,
            "a file with no anchor is still published to the legacy map")
        falsy(anchors:Has("Legacy_Boss.lua"), "and no anchor is invented for it")
    end

    ----------------------------------------------------------------------------
    -- no engine global beyond the stubbed lstg
    ----------------------------------------------------------------------------
    do
        eq(rawget(_G, "lstg"), saved_lstg, "the stubbed lstg global is restored")
        eq(rawget(_G, "boss"), saved_boss_binding, "no other engine global is created")
    end

    if failed > 0 then
        for i = 1, math.min(#failures, 25) do
            print("[SpellHotReload anchor-wiring] FAIL " .. failures[i])
        end
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
