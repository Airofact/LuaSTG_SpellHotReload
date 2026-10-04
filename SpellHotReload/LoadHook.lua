--------------------------------------------------------------------------------
--- SpellHotReload.LoadHook
---
--- Capture selected files at normal load time through AnchorLoad.Capture. The
--- selector belongs to the caller; the current bootstrap keeps its existing
--- Boss-file allowlist. No function-name extraction or legacy loader hook runs.
--- Successful capture returns the file's own results (including nil holes), not
--- the private map/anchor trailer. Refusals still load once and reach on_capture
--- with their reason. A run failure MUST NOT fall through and replay the body.
--------------------------------------------------------------------------------

local AnchorLoad = require("SpellHotReload.AnchorLoad")

local M = {}
local installed = setmetatable({}, { __mode = "k" })

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
    local original = engine.DoFile
    local select_file, reader = options.select, options.read
    -- Freeze configuration at install; mutating options cannot retarget a hook.
    local capability, limit, ir_options = options.capability, options.limit, options.ir_options
    local wrapper = function(filename, ...)
        local key = select_file(filename)
        if key == nil then return original(filename, ...) end
        local content
        if reader then
            content = reader(filename, key)
        else
            content = read_source(engine, filename, key)
        end
        if type(content) ~= "string" then return original(filename, ...) end
        local entry, reason, phase = AnchorLoad.Capture(content, {
            name = filename, args = { n = select("#", ...), ... },
            capability = capability, limit = limit, ir_options = ir_options,
        })
        if entry == nil then
            -- These phases precede execution. Let the engine handle its own
            -- loading/compile diagnostics. No retry once any body has run.
            if phase == "analyze" or phase == "compile" then
                return original(filename, ...)
            end
            -- Record failed/partially executed initialization too, so a second
            -- failing load cannot leave a previously held file reloadable.
            -- Instrumentation failure must not replace the script's error.
            local notified, notify_error = pcall(on_capture, key, {
                loaded_source = content, reloadable = false, failed = true,
                reason = reason, phase = phase,
            })
            if not notified and type(engine.Log) == "function" then
                pcall(engine.Log, 3, "[SpellHotReload.LoadHook] " .. tostring(notify_error))
            end
            error(tostring(reason), 0)
        end
        local accepted, diagnostic = on_capture(key, entry)
        if accepted == false and type(engine.Log) == "function" then
            pcall(engine.Log, 3, "[SpellHotReload.LoadHook] " .. tostring(diagnostic))
        end
        return AnchorLoad.ReturnValues(entry)
    end
    engine.DoFile = wrapper
    installed[engine] = wrapper
    return true
end

return M
