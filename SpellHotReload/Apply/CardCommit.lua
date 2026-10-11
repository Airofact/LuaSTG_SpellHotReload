-- Atomic CardVersions commit kernel. Trusted plans/fresh live views, not a sandbox.
-- One owner per Plugin session; Run is for trusted post-logic UI ONLY.
-- No source/body execution, restart or watcher ACK. Production may supply one
-- trusted refresh callback: after cache flush, BEFORE final checks/Consume only.
-- Commit installs capture.snapshot only after all joins/cells/raw callbacks.
-- Failure restores attempted writes (including throw-after-write) in reverse.
-- Failed restoration poisons the session id for this module's VM lifetime.
-- New same-id controllers cannot bypass poison; new game session needs a new id.
-- Fresh candidate closures may be discarded after failed joins; NEVER reuse a
-- failed selection. OOM/hostile debug hooks/native side effects are not atomic.
local Phase = require("SpellHotReload.Apply.CommitPhase")
local Guard = require("SpellHotReload.Apply.CommitCheck")
local Card = require("SpellHotReload.Adapters.Card.Card")
local Cache = require("SpellHotReload.Source.CodeCache")
local M = { Kind = "SpellHotReload.CardCommit", Version = 1 }
local phase_new, guard_check, next_version, invalidate =
    Phase.New, Guard.Check, Card.ProposeVersion, Cache.Invalidate
local check_destinations = Card.CheckJoinDestinations
local raw_write, protected_call = rawset, pcall
local busy, poisoned = nil, {} -- only poisoned primitive ids, never business refs
local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function fail(code, message, file)
    return nil, { phase="commit", code=code, message=message, file=file }
end
local function copy(v)
    local out = {}
    for k, value in next, v do out[k] = value end
    return out
end
-- Freeze action records before any cache callback. Plans remain read-only by
-- contract; no re-read of mutable action arrays after token consumption.
local function seal(selection)
    local out = copy(selection)
    for _, key in ipairs({"joins", "writes", "publications", "read_set", "capture_reads"}) do
        out[key] = {}
        for i, record in ipairs(selection[key]) do out[key][i] = copy(record) end
    end
    return out
end
local function prepare(selection, capture)
    local frozen = seal(selection)
    local snapshot, err = next_version(frozen)
    if not snapshot then return nil, err end
    local valid, destination_error = check_destinations(frozen)
    if not valid then return nil, destination_error end
    local journal = {}
    for _, op in ipairs(frozen.writes) do
        journal[#journal+1] = { anchor=op.anchor, index=op.index, name=op.name,
            before=op.before, value=op.value }
    end
    for _, op in ipairs(frozen.publications) do
        journal[#journal+1] = { target=op.target, key=op.key, before=op.before, value=op.value }
    end
    if snapshot ~= selection.base then
        journal[#journal+1] = {target=capture, key="snapshot", before=selection.base, value=snapshot}
    end
    return {selection=frozen, snapshot=snapshot, journal=journal}
end

function M.New(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return fail("unsupported", "nonempty session id required")
    end
    if poisoned[session_id] then return fail("poisoned", "session requires restart") end
    local gate, err = phase_new(session_id)
    if not gate then return nil, err end
    local gate_check, gate_consume, gate_run, gate_release =
        gate.Check, gate.Consume, gate.Run, gate.Release
    local controller, released = {}, false
    local function owner(self)
        if not rawequal(self, controller) then return fail("phase", "wrong commit controller") end
        if released then return fail("stale", "commit controller released") end
        if poisoned[session_id] then return fail("poisoned", "session requires restart") end
        if busy ~= nil then return fail("phase", "commit transaction is already active") end
        return true
    end
    function controller:Run(callback, ...)
        local ok, problem = owner(self)
        if not ok then return nil, problem end
        return gate_run(gate, callback, ...)
    end
    -- Read-only scope proof for production preflight and restart-only UI actions.
    function controller:Check(token)
        local ok, problem = owner(self)
        if not ok then return nil, problem end
        return gate_check(gate, token, session_id)
    end
    function controller:Poisoned() return poisoned[session_id] == true end
    function controller:Release()
        if not rawequal(self, controller) then return fail("phase", "wrong commit controller") end
        if busy ~= nil then return fail("phase", "release during transaction refused") end
        local ok, problem = gate_release(gate)
        if not ok then return nil, problem end
        released = true
        return true
    end

    function controller:Commit(token, selection, capture, live, refresh)
        local ok, problem = owner(self)
        if not ok then return nil, problem end
        if refresh ~= nil and type(refresh) ~= "function" then
            return fail("unsupported", "trusted live refresh callback required")
        end
        local file = plain(live) and plain(live.entry) and rawget(live.entry, "file") or nil
        if type(file) ~= "string" then file = nil end
        local function phase_check()
            return gate_check(gate, token, plain(live) and rawget(live, "session_id"))
        end
        ok, problem = phase_check()
        if not ok then
            return fail(plain(problem) and problem.code or "phase", "invalid commit scope", file)
        end
        busy = controller
        -- Preparation may allocate/build metadata. It MUST finish before
        -- consumption. Unknown thrown objects are never inspected/stringified.
        local prepared, get, set, join, id
        local pre_ok, result, reason = protected_call(function()
            local checked, err = guard_check(selection, capture, live)
            if not checked then return nil, err end
            local p, perr = prepare(selection, capture)
            if not p then return nil, perr end
            prepared = p
            get, set, join, id = debug.getupvalue, debug.setupvalue, debug.upvaluejoin, debug.upvalueid
            if #p.journal > 0 or #p.selection.joins > 0 then
                local flushed, ferr = invalidate()
                if not flushed then return fail("capability", type(ferr)=="string" and ferr or "cache invalidation failed", file) end
            end
            -- Disk/generation/binding may change during compilation or flush.
            -- Allocate/read now, never after final Guard or token consumption.
            if refresh then
                local fresh, ferr = refresh()
                if not fresh then return nil, ferr end
                live = fresh
            end
            -- Recheck AFTER flush/refresh, before Consume: no user callback follows.
            if debug.getupvalue ~= get or debug.setupvalue ~= set
                or debug.upvaluejoin ~= join or debug.upvalueid ~= id then
                return fail("capability", "debug APIs changed during preparation", file)
            end
            checked, err = phase_check()
            if not checked then return fail("phase", "commit scope changed during preparation", file) end
            checked, err = guard_check(p.selection, capture, live)
            if not checked then return nil, err end
            return true
        end)
        if not pre_ok or not result then
            busy = nil
            if pre_ok and plain(reason) then
                return fail(type(reason.code)=="string" and reason.code or "unsupported",
                    type(reason.message)=="string" and reason.message or "commit preparation failed", file)
            end
            return fail("unsupported", "commit preparation failed", file)
        end
        ok, problem = gate_consume(gate, token, live.session_id)
        if not ok then
            busy = nil
            return fail("phase", "commit scope consumption failed", file)
        end
        local p, attempted, stage = prepared, 0, "join"
        -- Every journal record is allocated before Consume. Only trusted
        -- native debug primitives/rawset below; no adapter/user callbacks.
        local function apply(op, value)
            if op.anchor then
                if set(op.anchor, op.index, value) ~= op.name then error("cell setter failed", 0) end
                local name, actual = get(op.anchor, op.index)
                if name ~= op.name or not rawequal(actual, value) then error("cell postimage failed", 0) end
            else
                raw_write(op.target, op.key, value) -- nil removes a missing raw key
                if not rawequal(rawget(op.target, op.key), value) then error("raw postimage failed", 0) end
            end
        end
        local committed = protected_call(function()
            for _, op in ipairs(p.selection.joins) do
                join(op.fn, op.index, op.anchor, op.donor)
                local name, value = get(op.fn, op.index)
                local donor_name, donor_value = get(op.anchor, op.donor)
                if name ~= op.name or donor_name ~= op.anchor_name
                    or not rawequal(value, donor_value) then error("join postimage failed", 0) end
                if type(id) == "function" then
                    local a, b = id(op.fn, op.index), id(op.anchor, op.donor)
                    if a == nil or b == nil or a ~= b then error("join identity failed", 0) end
                end
            end
            for i, op in ipairs(p.journal) do
                stage = op.anchor and "write" or (op.target == capture and "version" or "publish")
                attempted = i -- include primitives that mutate THEN throw
                apply(op, op.value)
            end
        end)
        if not committed then
            local restored = true
            for i=attempted,1,-1 do
                local op = p.journal[i]
                if not protected_call(apply, op, op.before) then restored = false end
            end
            if not restored then poisoned[session_id] = true end
            busy = nil
            if not restored then return fail("rollback", "rollback failed; session poisoned, restart required", file) end
            return fail(stage == "join" and "capability" or "publish",
                "commit " .. stage .. " failed; live writes restored, discard selection", file)
        end
        busy = nil
        return { kind=M.Kind..".Receipt", version=M.Version, file=file,
            snapshot=p.snapshot, changed=p.snapshot ~= p.selection.base }
    end
    return controller
end
return M
