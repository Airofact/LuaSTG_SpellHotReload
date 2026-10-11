-- Scoped permission for a trusted post-logic UI entry. No engine hooks here.
-- Run MUST be called only by that entry, not Tick/render/gameplay code.
-- This is a lifetime/reentrancy gate, NOT proof of engine phase or a sandbox.
-- Future transactions must Check, recheck live reads, then Consume immediately
-- before mutation, with no yield/user code until publication or rollback ends.
local M = { Kind = "SpellHotReload.CommitPhase", Version = 1 }
local active -- one scope across all controllers loaded from this module
local running = type(coroutine) == "table" and rawget(coroutine, "running")
local protected_call, unpack_values = pcall, unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

local function refuse(code, message)
    return nil, { phase = "commit", code = code, message = message }
end

local function main_thread()
    if type(running) ~= "function" then
        return refuse("capability", "coroutine.running unavailable")
    end
    local ok, thread, is_main = protected_call(running)
    if not ok then return refuse("capability", "coroutine.running failed") end
    if thread ~= nil and is_main ~= true then
        return refuse("phase", "commit scope requires the main thread")
    end
    return true
end

-- Session ids are Plugin's nonempty primitive strings, never caller tables.
-- Each New creates a distinct controller even for the same session id.
function M.New(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return refuse("phase", "nonempty session id required")
    end
    local gate, released = {}, false

    local function owner(self)
        if not rawequal(self, gate) then
            return refuse("phase", "wrong commit scope controller")
        end
        return main_thread()
    end

    local function check(self, token, current_session)
        local ok, err = owner(self)
        if not ok then return nil, err end
        if released then return refuse("stale", "commit scope released") end
        if type(current_session) ~= "string" or current_session ~= session_id then
            return refuse("stale", "commit scope session changed")
        end
        if active == nil or not rawequal(active.owner, gate)
            or not rawequal(active.token, token) then
            return refuse("stale", "commit scope token expired or foreign")
        end
        if type(token) ~= "table" or getmetatable(token) ~= nil or next(token) ~= nil then
            return refuse("phase", "commit scope token was modified")
        end
        if active.consumed then return refuse("stale", "commit scope token consumed") end
        return true
    end

    gate.Check = check

    function gate:Consume(token, current_session)
        local ok, err = check(self, token, current_session)
        if not ok then return nil, err end
        active.consumed = true
        return true
    end

    -- Return true followed by the callback's exact results (including nils).
    -- Error returns nil, a safe structural error; never stringify thrown objects.
    -- Callback failure does NOT undo mutation; rollback belongs to the transaction.
    function gate:Run(callback, ...)
        local ok, err = owner(self)
        if not ok then return nil, err end
        if released then return refuse("stale", "commit scope released") end
        if active ~= nil then return refuse("phase", "nested commit scope refused") end
        if type(callback) ~= "function" then return refuse("phase", "callback required") end
        local scope = { owner = gate, token = {}, consumed = false }
        active = scope
        local result = pack(protected_call(callback, scope.token, ...))
        active = nil -- expire even when callback throws or releases the controller
        if not result[1] then return refuse("phase", "commit scope callback failed") end
        return true, unpack_values(result, 2, result.n)
    end

    -- Does not end the dynamic scope early: reentry stays blocked until Run exits.
    -- Idempotent; caller must wire GameExit/session teardown in a later batch.
    function gate:Release()
        local ok, err = owner(self)
        if not ok then return nil, err end
        released, session_id = true, nil
        return true
    end

    return gate
end

return M
