-- Opt-in real-engine smoke for the SC Debugger entry path.
--
-- Run it the same way as EngineSmoke.lua, but with generated mod output that
-- boots straight into SC Debugger (the bundle ends with
-- `Include 'THlib\UI\scdebugger.lua'`). It covers:
--   * the view installing on the mod's first `afterMod` dispatch, with
--     scdebugger's own second dispatch staying a no-op
--   * debug-side card capture (no `lstg.var.sc_index`)
--   * a no-change Apply whose candidate bytes are the already-loaded source:
--     callback references and the publication snapshot stay unchanged
--   * the handoff to normal Spell Practice, with the current card identity kept
--   * scdebugger wiring staying untouched (no re-entered SC Debugger group)
-- Calls the integration entry from layout; does not click a native Monitor button.
-- Does not cover changed definitions or bidirectional export conversion.
-- Writes only userdata/spell_hot_reload_smoke/result.txt; never edits mod files.

local output_root = "userdata/spell_hot_reload_smoke"
local MAX_FRAMES = 3600
local finished = false
local installed = false

local state = {
    frames = 0,
    phase = "activate",
    file_name = nil,
    class_key = nil,
    slot = nil,
    card = nil,
    selectable = nil,
    old_boss = nil,
    debugger_stages = nil,
    class_count = nil,
    sc_count = nil,
    callbacks_before = nil,
    capture = nil,
    snapshot_before = nil,
    last_wait = nil,
}

---Set by install(): reads the first-load FileAnalysis the production DoFile
---hook captured. The observer never reparses source or treats hints as ownership.
local captured_source

local function finish(ok, message)
    if finished then return end
    finished = true
    local text = (ok and "PASS " or "FAIL ") .. tostring(message)
    lstg.Log(ok and 2 or 4, "[SpellHotReload SC debug smoke] " .. text)
    local f = assert(io.open(output_root .. "/result.txt", "wb"))
    f:write(text, "\n"); f:close()
    lstg.quit_flag = true
end

---Find the generated file that mentions `class_key` in its first-load syntax.
---Return its base name and the same FileAnalysis used by the load hook. This
---is only observer routing; the real Apply still performs fresh Locate/Guard.
local function find_generated_file(class_key)
    local Scanner = require("SpellHotReload.Adapters.Card.GeneratedBossScanner")
    local ok, entries = pcall(lstg.FileManager.EnumFiles, "mod/" .. tostring(setting.mod) .. "/")
    if not ok or type(entries) ~= "table" then
        return nil, "cannot list the mod directory"
    end
    for _, item in ipairs(entries) do
        local name, is_dir = item[1], item[2]
        if not is_dir and type(name) == "string" then
            local base = name:match("([^/\\]+)$")
            if base ~= nil and base:lower():sub(-4) == ".lua" then
                local source,source_error = captured_source(base)
                if source_error then return nil,source_error end
                if source ~= nil then
                    local keys,why = Scanner.ClassKeys(source)
                    if not keys then return nil,"captured analysis: " .. tostring(why and why.message) end
                    if keys[class_key] then return base,source end
                end
            end
        end
    end
    return nil, "no captured source defines " .. tostring(class_key)
end

---Seed a same-byte candidate, then use the trusted layout integration entry.
---Keep the production watcher and capability/lifecycle state intact.
local function apply_loaded_source(live)
    local source,source_error = captured_source(state.file_name)
    assert(source,source_error or ("capture hook has no source for " .. tostring(state.file_name)))
    local bytes = source.content
    local p = live
    assert(p._watcher and p._watcher:ReadFile(state.file_name) == bytes,
        "physical source differs from the captured same-byte input")
    local candidate = p._store:BeginCandidate(state.file_name, 1, "sc debug smoke")
    assert(p._store:RecordFirstRead(state.file_name, candidate.generation, bytes, 2), "first read rejected")
    local stable = p._store:VerifyStable(state.file_name, candidate.generation, bytes, 4, 2)
    assert(stable ~= nil and stable.stable == true, "candidate did not stabilize")
    return p:ApplyFromUI()
end

---Wait until the SC Debugger boss is on a slot we can actually select.
local function capture_debug_binding(Binding, Card)
    if type(lstg.var._boss_class_name) ~= "string" then
        return nil, "not in SC Debugger (no lstg.var._boss_class_name)"
    end
    local current, err = Binding.CaptureCurrent()
    if current == nil then return nil, tostring(err) end
    if current.mode ~= "debug" then return nil, "expected a debug binding, got " .. tostring(current.mode) end
    if state.file_name == nil then
        local file_name, source = find_generated_file(current.class_key)
        if file_name == nil then return nil, tostring(source) end
        local Driver=require("SpellHotReload.Pipeline.Driver")
        local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
        local driver=Driver.New()
        assert(driver:RegisterDiscovery(require("SpellHotReload.Adapters.Local.Local")))
        assert(driver:RegisterDiscovery(require("SpellHotReload.Adapters.Class.Class")))
        assert(driver:RegisterDiscovery(Card))
        local discovery,why=driver:Discover(file_name,source,{})
        if not discovery then return nil,"layout: "..tostring(why and why.message) end
        local context=assert(FileMatch.ForOwner(discovery.snapshot,Card,source))
        local row=context.by_class[current.class_key]
        if not row then return nil,"layout: class has no matched card list" end
        local layout=row.layout
        local selectable = {}
        for i, entry in ipairs(layout) do
            if entry.kind == "card" and entry.callbacks.init ~= nil then selectable[i] = true end
        end
        state.file_name, state.selectable = file_name, selectable
    end
    if not state.selectable[current.slot] then
        return nil, nil -- real slot, just not a combat card yet
    end
    return current
end

local function run_step(live, Binding, Card)
    state.frames = state.frames + 1
    if state.frames > MAX_FRAMES then
        finish(false, string.format("timed out in phase %s (class=%s slot=%s waiting on %s)",
            state.phase, tostring(state.class_key), tostring(state.slot), tostring(state.last_wait)))
        return
    end

    if state.phase == "activate" then
        if not live:IsActivated() then return end
        assert(live:IsSupported(), "plugin unsupported: " .. tostring(live:GetUnsupportedReason()))
        state.phase = "capture"

    elseif state.phase == "capture" then
        local current, err = capture_debug_binding(Binding, Card)
        if current == nil then
            -- `err == nil` means a real slot that is not a combat card yet;
            -- both cases are transient, so wait and report on timeout instead.
            state.last_wait = err
            return
        end
        state.class_key, state.slot, state.card = current.class_key, current.slot, current.card
        assert(type(stage.groups["SC Debugger"]) == "table",
            "mod output does not register the SC Debugger stage group")
        state.debugger_stages = stage.groups["SC Debugger"].number
        state.old_boss = lstg.tmpvar.boss or _boss
        state.class_count, state.sc_count = #all_class, #_sc_table
        state.callbacks_before = {}
        for _, name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
            state.callbacks_before[#state.callbacks_before+1] = {name=name, fn=rawget(state.card,name)}
        end
        state.capture = assert(live:GetVersions(state.file_name), "first-load versions unavailable")
        state.snapshot_before = state.capture.snapshot
        state.phase = "apply" -- publication is requested by layout, never update

    elseif state.phase == "restarted" then
        if stage.current_stage == nil or stage.current_stage.name ~= "Spell Practice@Spell Practice" then
            return
        end
        local handoff = _sc_table["EXT_POS"]
        assert(type(handoff) == "table", "restart did not write _sc_table.EXT_POS")
        assert(handoff[1] == state.class_key and handoff[3] == state.card and handoff[4] == state.slot,
            "EXT_POS does not match the captured debug binding")
        assert(lstg.var.sc_index == "EXT_POS", "lstg.var.sc_index was not handed off")
        assert(stage.groups["SC Debugger"].number == state.debugger_stages,
            "SC Debugger wiring ran again during restart")
        assert(#all_class == state.class_count and #_sc_table == state.sc_count,
            "class or card registration count changed")
        local boss_now = lstg.tmpvar.boss or _boss
        if boss_now == state.old_boss or not IsValid(boss_now) then return end
        assert(not IsValid(state.old_boss), "the SC Debugger boss outlived the restart")
        if boss.GetCurrentCard(boss_now) ~= state.card then return end
        live:StopWatching()
        finish(true, string.format(
            "SC Debugger capture + apply + Spell Practice handoff kept card identity (%s slot %d)",
            state.class_key, state.slot))
    end
end

local function install()
    if installed then return end
    installed = true
    lstg.FileManager.CreateDirectory(output_root)
    local View = require("SpellHotReload.UI.View")
    local Binding = require("SpellHotReload.Adapters.Card.PracticeBinding")
    local Card = require("SpellHotReload.Adapters.Card.Card")
    local live = assert(View.plugin, "plugin view not initialized")
    captured_source = function(file_name)
        local entry = live:GetLoad(file_name)
        if not entry then return nil end
        if type(entry.source) ~= "table" or entry.source.content ~= entry.loaded_source then
            return nil,"first-load shared analysis unavailable for " .. tostring(file_name)
        end
        return entry.source
    end
    local view = {}
    function view:getWindowName() return "SpellHotReload SC debug smoke" end
    function view:getMenuGroupName() return "Tool" end
    local enabled = true
    function view:getEnable() return enabled end
    function view:setEnable(value) enabled = value end
    function view:layout()
        if finished or state.phase ~= "apply" then return end
        local ok, err = xpcall(function()
            local result = apply_loaded_source(live)
            assert(result:match("^applied") and result:find("no definition changes", 1, true),
                "same-byte Apply failed: " .. tostring(result))
            for _, callback in ipairs(state.callbacks_before) do
                assert(rawget(state.card,callback.name) == callback.fn,
                    "same-byte Apply replaced callback: " .. callback.name)
            end
            assert(live:GetVersions(state.file_name) == state.capture
                and state.capture.snapshot == state.snapshot_before,
                "same-byte Apply advanced the publication snapshot")
            state.phase = "restarted"
        end, debug.traceback)
        if not ok then live:StopWatching(); finish(false, err) end
    end
    function view:update()
        if finished then return end
        local ok, err = xpcall(function() run_step(live, Binding, Card) end, debug.traceback)
        if not ok then
            live:StopWatching()
            finish(false, err)
        end
    end
    require("lib.Ldebug").addView("spellHotReload.scDebugSmoke", view)
end

-- Chain the startup loader; register after the plugin manager exists.
local original = lstg.DoFile
lstg.DoFile = function(filename, ...)
    local result = original(filename, ...)
    if filename:gsub("\\", "/"):match("lib/Lplugin%.lua$") then
        lstg.plugin.RegisterEvent("afterMod", "spellHotReload.scDebugSmoke", 1000, function()
            local ok, err = xpcall(install, debug.traceback)
            if not ok then finish(false, err) end
        end)
    end
    return result
end
