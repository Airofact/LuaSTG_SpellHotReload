local M = {}

function M.run(options)
    options = options or {}
    local Phase = options.phase or require("SpellHotReload.CommitPhase")
    local passed, failed = 0, 0
    local function check(value, label)
        if value then passed = passed + 1
        else failed = failed + 1; print("FAIL CommitPhase: " .. label) end
    end
    local function rejected(ok, err, code, label)
        check(ok == nil, label .. " refused")
        check(type(err) == "table" and err.phase == "commit" and err.code == code,
            label .. " structural error")
    end
    local function pack(...) return { n = select("#", ...), ... } end
    local gate = assert(Phase.New("session-A"))
    local peer = assert(Phase.New("session-A"))
    local foreign = assert(Phase.New("session-B"))
    local escaped, calls
    check(Phase.Kind == "SpellHotReload.CommitPhase" and Phase.Version == 1, "protocol")
    for _, id in ipairs({false, 0, {}, ""}) do
        local ok, err = Phase.New(id); rejected(ok, err, "phase", "invalid session")
    end
    local ok, err = Phase.New(nil); rejected(ok, err, "phase", "nil session")
    ok, err = gate:Check({}, "session-A"); rejected(ok, err, "stale", "outside scope")
    ok, err = gate:Consume({}, "session-A"); rejected(ok, err, "stale", "outside consume")
    ok, err = gate:Run({}); rejected(ok, err, "phase", "nonfunction callback")

    calls = 0
    local results = pack(gate:Run(function(token, ...)
        calls = calls + 1; escaped = token
        check(type(token) == "table" and next(token) == nil and getmetatable(token) == nil,
            "opaque token")
        check(gate:Check(token, "session-A") == true, "live scope")
        local bad, reason = peer:Check(token, "session-A")
        rejected(bad, reason, "stale", "other controller same session")
        bad, reason = foreign:Check(token, "session-B")
        rejected(bad, reason, "stale", "other session controller")
        bad, reason = gate:Check(token, "session-B")
        rejected(bad, reason, "stale", "changed session")
        bad, reason = gate:Check(token, {})
        rejected(bad, reason, "stale", "table session")
        bad, reason = gate:Check({}, "session-A")
        rejected(bad, reason, "stale", "forged token")
        local args = pack(...)
        check(args.n == 4 and args[1] == nil and args[2] == false
            and args[3] == 3 and args[4] == nil, "argument arity")
        return nil, false, 7, nil
    end, nil, false, 3, nil))
    check(calls == 1, "one callback call")
    check(results.n == 5 and results[1] == true and results[2] == nil
        and results[3] == false and results[4] == 7 and results[5] == nil, "return arity")
    ok, err = gate:Check(escaped, "session-A"); rejected(ok, err, "stale", "escaped token")
    ok, err = gate:Consume(escaped, "session-A"); rejected(ok, err, "stale", "escaped consume")
    results = pack(gate:Run(function() end))
    check(results.n == 1 and results[1] == true, "zero callback results")
    results = pack(gate:Run(function() return nil end))
    check(results.n == 2 and results[1] == true and results[2] == nil, "one nil result")

    local nested_calls = 0
    check(gate:Run(function(token)
        local bad, reason = gate:Run(function() nested_calls = nested_calls + 1 end)
        rejected(bad, reason, "phase", "same controller nested scope")
        bad, reason = peer:Run(function() nested_calls = nested_calls + 1 end)
        rejected(bad, reason, "phase", "other controller nested scope")
        check(nested_calls == 0, "nested callback never ran")
        check(gate:Check(token, "session-A") == true, "nested refusal preserves outer")
        check(gate:Consume(token, "session-A") == true, "first consume")
        bad, reason = gate:Consume(token, "session-A")
        rejected(bad, reason, "stale", "duplicate consume")
        bad, reason = gate:Check(token, "session-A")
        rejected(bad, reason, "stale", "consumed check")
        bad, reason = peer:Run(function() nested_calls = nested_calls + 1 end)
        rejected(bad, reason, "phase", "consumption does not end scope")
    end) == true, "consume scope returns")
    check(peer:Run(function(t) check(peer:Check(t, "session-A") == true, "next owner") end)
        == true, "next controller allowed after scope exit")

    local touched = 0
    local hostile = setmetatable({}, {
        __index = function() touched = touched + 1; error("index") end,
        __eq = function() touched = touched + 1; error("eq") end,
        __tostring = function() touched = touched + 1; error("string") end,
    })
    check(gate:Run(function(token)
        local bad, reason = gate:Check(hostile, "session-A")
        rejected(bad, reason, "stale", "hostile foreign token")
        token.extra = true
        bad, reason = gate:Check(token, "session-A")
        rejected(bad, reason, "phase", "token fields")
        token.extra = nil; setmetatable(token, getmetatable(hostile))
        bad, reason = gate:Consume(token, "session-A")
        rejected(bad, reason, "phase", "token metatable")
        setmetatable(token, nil)
        check(gate:Check(token, "session-A") == true, "clean token same identity")
        local old_check = gate.Check
        gate.Check = function() return true end
        bad, reason = gate:Consume({}, "session-A")
        gate.Check = old_check
        rejected(bad, reason, "stale", "Consume does not dispatch mutable Check")
    end) == true, "hostile tests return")
    ok, err = gate.Run(hostile, function() calls = calls + 100 end)
    rejected(ok, err, "phase", "foreign self")
    ok, err = gate.Check(hostile, escaped, "session-A")
    rejected(ok, err, "phase", "Check foreign self")
    ok, err = gate.Release(hostile); rejected(ok, err, "phase", "Release foreign self")
    check(touched == 0, "no metamethods")

    local thrown
    ok, err = gate:Run(function(token) thrown = token; error(hostile) end)
    rejected(ok, err, "phase", "dangerous thrown object")
    check(touched == 0, "thrown object not inspected")
    ok, err = gate:Check(thrown, "session-A"); rejected(ok, err, "stale", "throw expires")
    check(gate:Run(function(t) check(gate:Check(t, "session-A") == true, "recovery token") end)
        == true, "throw releases global scope")
    ok, err = gate:Run(function() coroutine.yield("not allowed") end)
    rejected(ok, err, "phase", "main callback yield")
    check(peer:Run(function() end) == true, "yield error releases scope")

    local co_calls = 0
    local resumed = coroutine.resume(coroutine.create(function()
        local bad, reason = gate:Run(function() co_calls = co_calls + 1 end)
        rejected(bad, reason, "phase", "coroutine Run")
        bad, reason = gate:Release(); rejected(bad, reason, "phase", "coroutine Release")
    end))
    check(resumed and co_calls == 0, "coroutine no callback or release")
    check(gate:Run(function(token)
        local resumed_inner = coroutine.resume(coroutine.create(function()
            local bad, reason = gate:Check(token, "session-A")
            rejected(bad, reason, "phase", "coroutine Check live token")
            bad, reason = gate:Consume(token, "session-A")
            rejected(bad, reason, "phase", "coroutine Consume live token")
            coroutine.yield()
        end))
        check(resumed_inner, "inner coroutine suspended")
        check(gate:Check(token, "session-A") == true, "coroutine refusal leaves token live")
    end) == true, "coroutine checks return")

    for i = 1, 12 do
        local previous = escaped
        check(gate:Run(function(token)
            check(not rawequal(token, previous), "fresh token " .. i)
            local bad, reason = gate:Check(previous, "session-A")
            rejected(bad, reason, "stale", "previous epoch " .. i)
            escaped = token
            check(gate:Consume(token, "session-A") == true, "consume epoch " .. i)
        end) == true, "scope epoch " .. i)
        local bad, reason = gate:Check(escaped, "session-A")
        rejected(bad, reason, "stale", "expired epoch " .. i)
    end

    local closing = assert(Phase.New("closing"))
    check(closing:Run(function(token)
        check(closing:Release() == true and closing:Release() == true, "idempotent release")
        local bad, reason = closing:Check(token, "closing")
        rejected(bad, reason, "stale", "release revokes token")
        bad, reason = peer:Run(function() nested_calls = nested_calls + 1 end)
        rejected(bad, reason, "phase", "release does not open reentry")
    end) == true, "release inside callback exits")
    ok, err = closing:Run(function() co_calls = co_calls + 1 end)
    rejected(ok, err, "stale", "released Run")
    ok, err = closing:Check({}, "closing"); rejected(ok, err, "stale", "released Check")
    check(peer:Run(function() end) == true, "released scope finally exits")

    -- Environment-owned capability cases use an isolated module, not global mutation.
    if options.module_path then
        for _, api in ipairs({false, {}, function() error(hostile) end}) do
            local env = setmetatable({ coroutine = { running = api } }, { __index = _G })
            local fresh = setfenv(assert(loadfile(options.module_path)), env)()
            local controller = assert(fresh.New("caps"))
            local count = 0
            local bad, reason = controller:Run(function() count = count + 1 end)
            rejected(bad, reason, "capability", "missing/throwing running API")
            check(count == 0, "capability refusal before callback")
            bad, reason = controller:Consume({}, "caps")
            rejected(bad, reason, "capability", "Consume capability")
        end
        check(touched == 0, "capability error object not inspected")
    end
    local weak = setmetatable({}, { __mode = "v" })
    check(gate:Run(function(token) weak[1] = token end) == true, "GC scope")
    collectgarbage("collect"); collectgarbage("collect")
    check(weak[1] == nil, "no expired token strong retention")
    gate:Release(); peer:Release(); foreign:Release()
    return { passed = passed, failed = failed }
end

return M
