--------------------------------------------------------------------------------
--- SpellHotReload.Load.LoadHook
---
--- Capture selected files at normal load time through AnchorLoad.Capture. The
--- selector belongs to the caller; the current bootstrap keeps its existing
--- Boss-file allowlist. No function-name extraction or legacy loader hook runs.
--- Successful capture returns the file's own results (including nil holes), not
--- the private map/anchor trailer. Refusals still load once and reach on_capture
--- with their reason. A run failure MUST NOT fall through and replay the body.
--------------------------------------------------------------------------------

local AnchorLoad = require("SpellHotReload.Load.AnchorLoad")

local M = {}
-- The wrapper owns its state; the index must not root an engine/wrapper cycle
-- on Lua 5.1 (weak keys alone are not ephemerons there).
local installed = setmetatable({}, { __mode = "kv" })

---Compatibility selection policy, not the capture mechanism. Watcher still
---tracks only these basenames; widening the monitored files is a separate step.
function M.BossFile(filename)
    if type(filename) ~= "string" then return nil end
    local base = filename:match("([^/\\]+)$") or filename
    if base:match("^[A-Za-z0-9_%%%-]+_Boss%.lua$") then return base end
end

local function read_source(engine, filename, base)
    local ok, content = pcall(engine.LoadTextFile, filename)
    if ok and type(content) == "string" then return content end
    local mod = setting and setting.mod
    if type(mod) == "string" and mod ~= "" and mod ~= "launcher" then
        local path = "mod/" .. mod .. "/" .. base
        local ok2, content2 = pcall(engine.LoadTextFile, path)
        if ok2 and type(content2) == "string" then return content2 end
        local handle = io.open(path, "rb")
        if handle then
            local source = handle:read("*a")
            handle:close()
            return source
        end
    end
end

---Install once for this engine table. A repeated install is an idempotent
---success, never a retarget or a second wrapper. on_capture receives the FULL
---capture entry, including policy/names/slots/reloadable/reason/loaded_source.
---Options: select(filename)->key|nil, read(filename,key)->source|nil, capability,
---limit, ir_options. select is explicit so installing never broadens the scope.
function M.Install(engine, on_capture, options)
    if type(engine) ~= "table" or type(engine.DoFile) ~= "function" then
        return false, "engine.DoFile must be a function"
    end
    if installed[engine] then return true end
    options = options or {}
    if type(options) ~= "table" then return false, "options must be a table" end
    if type(on_capture) ~= "function" or type(options.select) ~= "function" then
        return false, "on_capture and select must be functions"
    end
    -- Freeze configuration at install; mutating options cannot retarget a hook.
    local state = {
        original = engine.DoFile, engine = engine, on_capture = on_capture,
        select_file = options.select, reader = options.read,
        capability = options.capability, limit = options.limit,
        ir_options = options.ir_options,
    }
    local wrapper = function(filename, ...)
        if state.retired then return state.original(filename, ...) end
        local key = state.select_file(filename)
        if state.retired or key == nil then return state.original(filename, ...) end
        local content
        if state.reader then
            content = state.reader(filename, key)
        else
            content = read_source(state.engine, filename, key)
        end
        if state.retired or type(content) ~= "string" then return state.original(filename, ...) end
        local entry, reason, phase = AnchorLoad.Capture(content, {
            name = filename, args = { n = select("#", ...), ... },
            capability = state.capability, limit = state.limit, ir_options = state.ir_options,
        })
        if entry == nil then
            -- These phases precede execution. Let the engine handle its own
            -- loading/compile diagnostics. No retry once any body has run.
            if phase == "analyze" or phase == "compile" then
                return state.original(filename, ...)
            end
            -- Record failed/partially executed initialization too, so a second
            -- failing load cannot leave a previously held file reloadable.
            -- Instrumentation failure must not replace the script's error.
            if not state.retired then
                local notified, notify_error = pcall(state.on_capture, key, {
                    loaded_source = content, reloadable = false, failed = true,
                    reason = reason, phase = phase,
                })
                if not notified and not state.retired and type(state.engine.Log) == "function" then
                    pcall(state.engine.Log, 3, "[SpellHotReload.LoadHook] " .. tostring(notify_error))
                end
            end
            error(tostring(reason), 0)
        end
        if not state.retired then
            local accepted, diagnostic = state.on_capture(key, entry)
            if accepted == false and not state.retired and type(state.engine.Log) == "function" then
                pcall(state.engine.Log, 3, "[SpellHotReload.LoadHook] " .. tostring(diagnostic))
            end
        end
        return AnchorLoad.ReturnValues(entry)
    end
    engine.DoFile = wrapper
    state.wrapper = wrapper
    installed[engine] = state
    return true
end

---Retire capture and drop callback/configuration references. Restore DoFile only
---when it is still ours; a later plugin's outer hook must remain intact. An old
---wrapper retained by that plugin becomes a transparent original-DoFile forwarder.
---Idempotent; a later explicit Install can begin a fresh capture session.
function M.Release(engine)
    if type(engine) ~= "table" then return false, "engine must be a table" end
    local state = installed[engine]
    if state == nil then return true end
    state.retired = true
    installed[engine] = nil
    if engine.DoFile == state.wrapper then engine.DoFile = state.original end
    state.engine, state.on_capture, state.select_file, state.reader = nil, nil, nil, nil
    state.capability, state.limit, state.ir_options, state.wrapper = nil, nil, nil, nil
    return true
end

return M
