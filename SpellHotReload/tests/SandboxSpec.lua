--------------------------------------------------------------------------------
--- SpellHotReload tests/SandboxSpec.lua
---
--- Ad-hoc in-engine test spec. Load it in a LuaSTG/LSTG environment (e.g. from the
--- debug console) or under a plain Lua interpreter for the pure-module sections.
--- It prints a PASS/FAIL summary and returns a summary table.
---
--- Sections:
---   1. SnapshotStore    (pure — runs under any Lua)
---   2. Scanner          (pure — runs under any Lua)
---   3. PracticeBinding  (pure — runs under any Lua with `debug`)
---   4. Loader           (requires `load(...,"t",env)` and mock engine globals)
---   5. ChangeLog        (pure)
--------------------------------------------------------------------------------

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

local function eq(a, b, label)
    check(a == b, label .. " (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")")
end

local function truthy(a, label)
    check(a ~= nil and a ~= false, label)
end

--------------------------------------------------------------------------------
-- 1. SnapshotStore
--------------------------------------------------------------------------------

local function test_store()
    local Store = require("SpellHotReload.SnapshotStore")
    local s = Store.New()

    local h1 = s.ContentHash("abc")
    local h2 = s.ContentHash("abc")
    local h3 = s.ContentHash("abd")
    eq(h1, h2, "ContentHash deterministic")
    check(h1 ~= h3, "ContentHash distinguishes content")
    check(#h1 > 0, "ContentHash non-empty")

    local c1 = s:BeginCandidate("A_Boss.lua", 1, "test")
    eq(c1.generation, 1, "BeginCandidate generation")
    local r = s:RecordFirstRead("A_Boss.lua", c1.generation, "hello", 2)
    truthy(r and r.first_content == "hello", "RecordFirstRead stores content")

    -- too-soon
    local acc, status = s:VerifyStable("A_Boss.lua", c1.generation, "hello", 3, 5)
    check(acc == nil and status == "too-soon", "VerifyStable too-soon")

    -- stable: kept as a pending candidate (no accepted baseline yet)
    acc, status = s:VerifyStable("A_Boss.lua", c1.generation, "hello", 10, 5)
    eq(status, "stable", "VerifyStable stable")
    truthy(acc and acc.first_hash == s.ContentHash("hello"), "stable candidate hash")
    truthy(s:GetCandidate("A_Boss.lua") ~= nil, "stable candidate stays pending")

    -- promote (simulate Apply): candidate becomes accepted and leaves the candidate set
    s:SetAccepted("A_Boss.lua", "hello", "published")
    s:CancelCandidate("A_Boss.lua")
    check(s:GetCandidate("A_Boss.lua") == nil, "CancelCandidate removes candidate")
    check(s:GetAccepted("A_Boss.lua") ~= nil, "promote sets accepted")

    -- unchanged: a fresh candidate equal to the accepted baseline is dropped
    local c2 = s:BeginCandidate("A_Boss.lua", 2, "test")
    s:RecordFirstRead("A_Boss.lua", c2.generation, "hello", 20)
    acc, status = s:VerifyStable("A_Boss.lua", c2.generation, "hello", 30, 5)
    eq(status, "unchanged", "VerifyStable unchanged when equal to accepted")
    check(s:GetCandidate("A_Boss.lua") == nil, "unchanged candidate dropped")

    -- changed: a differing second read supersedes the candidate
    local c3 = s:BeginCandidate("A_Boss.lua", 3, "test")
    s:RecordFirstRead("A_Boss.lua", c3.generation, "world", 40)
    acc, status = s:VerifyStable("A_Boss.lua", c3.generation, "other", 50, 5)
    eq(status, "changed", "VerifyStable changed on differing read")

    -- dismissal: rejected bytes are remembered and never resurrect
    s:SetAccepted("C_Boss.lua", "base-c", "baseline")
    local d1 = s:BeginCandidate("C_Boss.lua", 60, "test")
    s:RecordFirstRead("C_Boss.lua", d1.generation, "draft-c", 61)
    acc, status = s:VerifyStable("C_Boss.lua", d1.generation, "draft-c", 70, 5)
    eq(status, "stable", "dismissal setup candidate is stable")
    local rejected = s:DismissCandidate("C_Boss.lua")
    truthy(rejected ~= nil and rejected.content == "draft-c", "DismissCandidate remembers rejected bytes")
    check(s:GetCandidate("C_Boss.lua") == nil, "DismissCandidate removes candidate")
    check(s:IsDismissed("C_Boss.lua", "draft-c"), "IsDismissed matches rejected bytes")
    check(not s:IsDismissed("C_Boss.lua", "draft-c2"), "IsDismissed rejects other bytes")

    -- a drift rescan over the same bytes must not resurrect the candidate
    local d2 = s:BeginCandidate("C_Boss.lua", 80, "drift")
    s:RecordFirstRead("C_Boss.lua", d2.generation, "draft-c", 81)
    acc, status = s:VerifyStable("C_Boss.lua", d2.generation, "draft-c", 90, 5)
    check(acc == nil and status == "dismissed", "VerifyStable drops dismissed bytes")
    check(s:GetCandidate("C_Boss.lua") == nil, "dismissed candidate is not kept")

    -- a genuinely new edit clears the rejection and surfaces again
    local d3 = s:BeginCandidate("C_Boss.lua", 100, "drift")
    s:RecordFirstRead("C_Boss.lua", d3.generation, "draft-c2", 101)
    acc, status = s:VerifyStable("C_Boss.lua", d3.generation, "draft-c2", 110, 5)
    eq(status, "stable", "new bytes after dismissal surface again")
    check(not s:IsDismissed("C_Boss.lua", "draft-c2"), "rejection cleared for new bytes")

    -- publishing (Apply) also clears a stale rejection
    s:SetAccepted("C_Boss.lua", "published-c", "published")
    check(not s:IsDismissed("C_Boss.lua", "draft-c"), "SetAccepted clears rejection")

    -- SetAccepted / GetAcceptedFileNames
    s:SetAccepted("B_Boss.lua", "content-b", "baseline")
    local names = s:GetAcceptedFileNames()
    check(#names >= 1, "GetAcceptedFileNames non-empty")
end

--------------------------------------------------------------------------------
-- 2. Scanner (safety gate + class keys)
--------------------------------------------------------------------------------

local function test_scanner()
    local Scanner = require("SpellHotReload.GeneratedBossScanner")

    local VALID = table.concat({
        "-- Generated by LuaSTG Editor Sharp",
        '_author = "LuaSTG User"',
        '_editor_class["TestBoss:Easy"]=Class(boss)',
        '_editor_class["TestBoss:Easy"].cards={}',
        '_tmp_sc=boss.card.New("Test Spell",2,5,20,450,{0,0,0},false)',
        "function _tmp_sc:init()",
        "    TEST_SC(self,1)",
        "end",
        '_BOSS_ESCAPE("TestBoss:Easy",0,0,60)',
    }, "\n")

    local r = Scanner.Scan(VALID, "Test_Boss.lua")
    truthy(r.ok, "scanner accepts valid generated source: " .. tostring(r.error))
    check(r.sc_debug == false, "scanner does not flag valid source as SC Debug")

    local keys = Scanner.ClassKeys(VALID)
    truthy(keys["TestBoss:Easy"], "ClassKeys finds string class key")
    check(keys["Nope"] == nil, "ClassKeys does not invent keys")

    -- rejections
    local r2 = Scanner.Scan("hello world\n", "X_Boss.lua")
    check(r2.ok == false, "scanner rejects missing header")

    local r3 = Scanner.Scan("-- Generated by LuaSTG Editor Sharp\n\0\n", "X_Boss.lua")
    check(r3.ok == false, "scanner rejects NUL")

    local r4 = Scanner.Scan("-- Generated by LuaSTG Editor Sharp\n" .. "Include 'THlib\\\\UI\\\\scdebugger.lua'\n", "X_Boss.lua")
    check(r4.ok == true and r4.sc_debug == true, "scanner accepts and flags SC Debug output")
end

--------------------------------------------------------------------------------
-- 3. PracticeBinding (inspect + patch)
--------------------------------------------------------------------------------

local function test_binding()
    local PracticeBinding = require("SpellHotReload.PracticeBinding")

    local function make_card()
        local function spell(self, n) return n end
        local card = {}
        function card:init() return spell(self, 1) end
        return card
    end

    local card = make_card()
    local upvalues = PracticeBinding.InspectInitFunctions(card)
    eq(#upvalues, 1, "InspectInitFunctions finds one function upvalue")
    eq(upvalues[1].name, "spell", "InspectInitFunctions reports upvalue name")
    eq(card:init(), 1, "card init runs original function")

    local new_spell = function(self, n) return n + 100 end
    local patched = PracticeBinding.Patch(card, { spell = new_spell })
    eq(#patched, 1, "Patch patches matching name")
    eq(patched[1], "spell", "Patch reports patched name")
    eq(card:init(), 101, "patched init uses new function")

    -- name mismatch patches nothing
    local patched2 = PracticeBinding.Patch(card, { other = new_spell })
    eq(#patched2, 0, "Patch ignores non-matching names")
    eq(card:init(), 101, "unmatched patch leaves closure intact")

    -- non-card / no-init inputs are safe
    eq(#PracticeBinding.InspectInitFunctions({}), 0, "InspectInitFunctions empty for non-card")
    eq(#PracticeBinding.InspectInitFunctions({ init = 5 }), 0, "InspectInitFunctions empty for non-function init")
    eq(#PracticeBinding.Patch({}, { spell = new_spell }), 0, "Patch empty for non-card")

    -- current binding: normal Spell Practice first, SC Debugger as fallback
    local saved = {}
    for _, key in ipairs({ "lstg", "_editor_class", "_sc_table", "boss", "_boss", "IsValid" }) do
        saved[key] = rawget(_G, key)
    end

    local live_card = { name = "Debug Spell", is_combat = true }
    local move_card = { name = "", is_combat = false }
    local cards = { move_card, live_card }
    _editor_class = { ["DebugBoss:Normal"] = { cards = cards } }
    lstg = { var = { _boss_class_name = "DebugBoss:Normal" }, tmpvar = {} }
    boss = { GetCurrentCard = function(b) return b.current_card end }
    _boss = { cards = cards, card_num = 2, current_card = live_card }
    IsValid = function() return true end

    local current, cerr = PracticeBinding.CaptureCurrent()
    truthy(current, "debug capture resolves a binding: " .. tostring(cerr))
    eq(current.class_key, "DebugBoss:Normal", "debug capture class key")
    eq(current.mode, "debug", "debug capture reports debug mode")
    eq(current.slot, 2, "debug capture locates the slot by card identity")
    eq(current.card, live_card, "debug capture keeps the live card table")
    eq(current.name, "Debug Spell", "debug capture uses the live card name")
    eq(current.include_previous, false, "debug capture never includes the previous card")
    truthy(type(current.names) == "table" and #current.names == 2, "debug capture snapshots the live class names")
    eq(current.names[1], "", "name snapshot records unnamed move slots")
    eq(current.names[2], "Debug Spell", "name snapshot records the live card")

    -- falls back to boss.cards[card_num] when GetCurrentCard is unavailable
    boss.GetCurrentCard = nil
    _boss.current_card = nil
    local fallback = PracticeBinding.CaptureCurrent()
    truthy(fallback and fallback.slot == 2, "debug capture falls back to boss.cards[card_num]")

    -- a dead boss / unmatchable card cannot be captured
    IsValid = function() return false end
    local dead, derr = PracticeBinding.CaptureCurrent()
    check(dead == nil, "debug capture rejects an invalid boss")
    truthy(derr and derr:find("no longer valid", 1, true) ~= nil, "debug capture reports invalid boss")
    IsValid = function() return true end
    _boss.current_card = { name = "Not In Class" }
    boss.GetCurrentCard = function(b) return b.current_card end
    local stray = PracticeBinding.CaptureCurrent()
    check(stray == nil, "debug capture rejects a card outside the generated list")
    boss.GetCurrentCard = nil
    _boss.current_card = nil

    -- normal Spell Practice wins when both contexts are populated
    local practice_card = { name = "Practice Spell" }
    _editor_class["PracticeBoss:Lunatic"] = { cards = { practice_card } }
    lstg.var.sc_index = 1
    _sc_table = { { "PracticeBoss:Lunatic", "Practice Spell", practice_card, 1, true } }
    local both, berr = PracticeBinding.CaptureCurrent()
    truthy(both, "capture resolves when both contexts exist: " .. tostring(berr))
    eq(both.mode, "practice", "Spell Practice takes precedence over SC Debug")
    eq(both.card, practice_card, "practice capture keeps its own card")
    eq(both.include_previous, true, "practice capture keeps include_previous")
    eq(both.names[1], "Practice Spell", "practice capture snapshots the live class names")

    -- neither context: report a combined reason instead of guessing
    lstg.var.sc_index = nil
    lstg.var._boss_class_name = nil
    local none, nerr = PracticeBinding.CaptureCurrent()
    check(none == nil, "capture fails when no card context is active")
    truthy(nerr and nerr:find("SC Debugger", 1, true) ~= nil, "combined failure names SC Debugger")

    for _, key in ipairs({ "lstg", "_editor_class", "_sc_table", "boss", "_boss", "IsValid" }) do
        _G[key] = saved[key]
    end
end

--------------------------------------------------------------------------------
-- 4. UpvalueRegistry + Loader (fragment extract / build / capture)
--------------------------------------------------------------------------------

local function test_loader()
    local Loader = require("SpellHotReload.GeneratedBossLoader")
    local Registry = require("SpellHotReload.Load.UpvalueRegistry")

    -- ExtractFunction
    local SRC = table.concat({
        "-- Generated by LuaSTG Editor Sharp",
        "local function HELPER(v)",
        "    return v + 1",
        "end",
        "local function TEST_SC(self, diff)",
        "    return HELPER(diff) * 2",
        "end",
    }, "\n")

    local frag = Loader.ExtractFunction(SRC, "TEST_SC")
    truthy(frag, "ExtractFunction finds fragment")
    check(type(frag) == "string" and frag:find("local function TEST_SC", 1, true) ~= nil, "fragment is the definition")
    check(Loader.ExtractFunction(SRC, "MISSING") == nil, "ExtractFunction returns nil for missing name")

    -- ListFunctionNames
    local names = Loader.ListFunctionNames(SRC)
    eq(#names, 2, "ListFunctionNames finds two functions")
    eq(names[1], "HELPER", "ListFunctionNames preserves order")
    eq(names[2], "TEST_SC", "ListFunctionNames finds second name")

    -- BuildFunction without registry: fragment compiles to a function
    local fn1, err1 = Loader.BuildFunction(frag, "TEST_SC", nil)
    truthy(fn1, "BuildFunction compiles fragment: " .. tostring(err1))
    eq(type(fn1), "function", "BuildFunction returns a function")

    -- BuildFunction with registry: sibling upvalue is injected by name
    local reg = Registry.New()
    reg:SetAll("Test_Boss.lua", { HELPER = function(v) return v + 100 end })
    local entry = reg:Get("Test_Boss.lua")
    truthy(entry and entry.HELPER, "registry stores file -> name -> value")
    local fn2, err2 = Loader.BuildFunction(frag, "TEST_SC", entry)
    truthy(fn2, "BuildFunction with registry: " .. tostring(err2))
    eq(fn2(nil, 1), 202, "built function resolves injected sibling upvalue")

    -- trailer capture: appending `return {...}` and running collects the functions
    local chunk = (loadstring or load)(SRC .. "\n" .. Loader.BuildTrailer(names))
    local captured = chunk()
    truthy(captured ~= nil and type(captured["TEST_SC"]) == "function", "trailer captures top-level function")
    eq(captured["TEST_SC"](nil, 20), 42, "trailer-captured function runs")
end

--------------------------------------------------------------------------------
-- 5. ChangeLog
--------------------------------------------------------------------------------

local function test_changelog()
    local ChangeLog = require("SpellHotReload.ChangeLog")
    local log = ChangeLog.New()

    eq(log:Count(), 0, "ChangeLog starts empty")

    log:Add("info", "first")
    log:Add("ok", "second")
    eq(log:Count(), 2, "ChangeLog Count")
    eq(log:Entries()[1].text, "first", "ChangeLog preserves insertion order")
    eq(log:Entries()[2].level, "ok", "ChangeLog records level")
    truthy(log:Entries()[1].id < log:Entries()[2].id, "ChangeLog ids are monotonic")

    log:Clear()
    eq(log:Count(), 0, "ChangeLog Clear")
end

--------------------------------------------------------------------------------
-- runner
--------------------------------------------------------------------------------

function M.run()
    passed, failed = 0, 0
    failures = {}

    local ok, err = pcall(test_store)
    if not ok then failures[#failures + 1] = "test_store crashed: " .. tostring(err) end

    ok, err = pcall(test_scanner)
    if not ok then failures[#failures + 1] = "test_scanner crashed: " .. tostring(err) end

    ok, err = pcall(test_binding)
    if not ok then failures[#failures + 1] = "test_binding crashed: " .. tostring(err) end

    ok, err = pcall(test_loader)
    if not ok then failures[#failures + 1] = "test_loader crashed: " .. tostring(err) end

    ok, err = pcall(test_changelog)
    if not ok then failures[#failures + 1] = "test_changelog crashed: " .. tostring(err) end

    failed = failed + #failures
    for _, f in ipairs(failures) do
        print("[FAIL] " .. f)
    end
    print(string.format("[SpellHotReload tests] %d passed, %d failed", passed, failed))
    return { passed = passed, failed = failed, failures = failures }
end

return M
