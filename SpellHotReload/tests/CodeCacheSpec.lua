--------------------------------------------------------------------------------
--- CodeCacheSpec: synthetic mutation/cache regressions, no engine or probes.
--- Warm real callers with normal JIT settings; never disable JIT to pass.
--- A task-local baseline mode uses unchanged Anchor/Compose to prove the hot
--- assertions detect the original defect. Lua 5.1 covers refusal/no-cache paths.
--------------------------------------------------------------------------------

local Cache = require("SpellHotReload.Source.CodeCache")
local Anchor = require("SpellHotReload.Load.Anchor")
local Compose = require("SpellHotReload.Source.Compose")
local M = {}
local compile = loadstring or load

function M.run()
    local passed, failed, failures = 0, 0, {}
    local function check(ok, label)
        if ok then passed = passed + 1
        else failed = failed + 1; failures[#failures + 1] = label end
    end
    local function eq(actual, expected, label)
        check(actual == expected, label .. " expected=" .. tostring(expected)
            .. " actual=" .. tostring(actual))
    end
    local function contains(value, part, label)
        check(type(value) == "string" and value:find(part, 1, true) ~= nil, label)
    end
    local real_jit = rawget(_G, "jit")
    local function with_jit(runtime, run)
        rawset(_G, "jit", runtime)
        local ok, err = pcall(run)
        rawset(_G, "jit", real_jit)
        assert(ok, err)
    end
    local capability = { getupvalue = true, setupvalue = true,
        upvaluejoin = true, upvalueid = true }
    local function capture(source)
        return assert(Anchor.Capture(source, {name = "CodeCacheSpec", capability = capability}))
    end
    local function value_cell(fn, name)
        local slots = assert(Anchor.Slots(fn))
        local index = assert(slots[name])
        return index, select(2, debug.getupvalue(fn, index))
    end
    local function id(fn, name)
        local index = value_cell(fn, name)
        return debug.upvalueid(fn, index)
    end

    -- No JIT present: no load/probe and no cache work.
    with_jit(nil, function()
        local ok, reason = Cache.Invalidate()
        eq(ok, true, "plain Lua no-cache success")
        eq(reason, nil, "plain Lua no-cache reason")
        local entry = capture("local counter=0\n")
        eq(Anchor.Set(entry, "counter", false), true, "plain write false")
        eq(Anchor.Get(entry, "counter"), false, "plain false preserved")
        eq(Anchor.Set(entry, "counter", nil), true, "plain write nil")
        local v, err = Anchor.Get(entry, "counter")
        eq(v, nil, "plain nil preserved")
        eq(err, nil, "plain nil has a slot")
    end)

    -- Read the real runtime on every operation. Full-cache flush gets NO args.
    local calls, nargs = 0, -1
    local runtime = {
        flush = function(...)
            calls, nargs = calls + 1, select("#", ...)
        end,
        off = function() error("must not disable JIT") end,
        on = function() error("must not toggle JIT") end,
    }
    with_jit(runtime, function()
        local loaded = package.loaded["SpellHotReload.Source.CodeCache"]
        package.loaded["SpellHotReload.Source.CodeCache"] = nil
        local cold = require("SpellHotReload.Source.CodeCache")
        package.loaded["SpellHotReload.Source.CodeCache"] = loaded
        eq(type(cold.Invalidate), "function", "cold module exposes operation")
        eq(calls, 0, "cold require does not flush/probe")
        eq(Cache.Invalidate(), true, "present cache flush")
        eq(calls, 1, "flush once")
        eq(nargs, 0, "no function/trace scope")
        local entry = capture("local counter=0\nlocal other=2\n")
        local before = calls
        eq(calls, 1, "Capture performs no cache operation")
        local original = entry.anchor
        runtime.flush = function(...)
            calls, nargs = calls + 1, select("#", ...)
            eq(Anchor.Get(entry, "counter"), 0, "flush precedes setupvalue")
        end
        eq(Anchor.Set(entry, "counter", 5), true, "set after flush succeeds")
        eq(calls, before + 1, "set invalidates once")
        eq(nargs, 0, "set invalidates whole cache")
        eq(Anchor.Get(entry, "counter"), 5, "set writes real value")
        eq(entry.anchor, original, "set never replaces anchor")
        before = calls
        eq(Anchor.Set(entry, "missing", 7), false, "invalid set refuses")
        eq(calls, before, "invalid set has no cache work")
        runtime.flush = function(...) calls, nargs = calls + 1, select("#", ...) end

        if type(debug.upvaluejoin) == "function" then
            local fn = assert(compile("local counter=-1; local other=-2; return function() return counter,other end"))()
            local plan = assert(Compose.Plan(fn, entry))
            eq(calls, before, "Plan performs no cache operation")
            local before_counter, before_other = id(fn, "counter"), id(fn, "other")
            runtime.flush = function(...)
                calls, nargs = calls + 1, select("#", ...)
                eq(id(fn, "counter"), before_counter, "flush before first join")
                eq(id(fn, "other"), before_other, "flush before all joins")
                eq(Anchor.Get(entry, "counter"), 5, "join flush never writes donor")
            end
            before = calls
            eq(Compose.Join(plan), 2, "multi-slot join succeeds")
            eq(calls, before + 1, "multi-slot join invalidates once")
            eq(nargs, 0, "join invalidates whole cache")
            eq(id(fn, "counter"), id(entry.anchor, "counter"), "counter shared")
            eq(id(fn, "other"), id(entry.anchor, "other"), "other shared")
            eq(plan.joined, true, "successful plan marked joined")
        end

        -- Empty joins and invalid requests do not discard code unnecessarily.
        runtime.flush = function() error("unexpected flush") end
        local fn = function() return 1 end
        local plan = assert(Compose.Plan(fn, entry))
        if type(debug.upvaluejoin) == "function" then
            eq(Compose.Join(plan), 0, "empty plan no cache work")
            eq(plan.joined, true, "empty plan completes")
        else
            local n, err = Compose.Join(plan)
            eq(n, nil, "no-join runtime still refuses")
            contains(err, "capability", "no-join refusal remains")
        end
        local n, err = Compose.Join({})
        eq(n, nil, "invalid join refuses")
        contains(err, "join plan", "invalid join reason")
    end)

    -- Missing, malformed, or throwing API must refuse BEFORE ANY mutation.
    local broken = { false, "not a table", {}, {flush = false},
        {flush = function() error("flush sentinel") end},
        setmetatable({}, {__index = function() error("no metatable lookup") end}) }
    for _, runtime in ipairs(broken) do
        with_jit(runtime, function()
            local ok, err = Cache.Invalidate()
            eq(ok, false, "broken cache refuses")
            contains(err, "code cache:", "broken cache names boundary")
            local entry = capture("local counter=0\nlocal other=2\n")
            local anchor = entry.anchor
            ok, err = Anchor.Set(entry, "counter", 5)
            eq(ok, false, "broken cache rejects set")
            contains(err, "code cache:", "set preserves cache error")
            eq(Anchor.Get(entry, "counter"), 0, "failed cache does not write")
            eq(entry.anchor, anchor, "failed cache preserves anchor")
            if type(debug.upvaluejoin) == "function" then
                local fn = assert(compile("local counter=-1; local other=-2; return function() return counter,other end"))()
                local plan = assert(Compose.Plan(fn, entry))
                local old_counter, old_other = id(fn, "counter"), id(fn, "other")
                local n
                n, err = Compose.Join(plan)
                eq(n, nil, "broken cache rejects join")
                contains(err, "code cache:", "join preserves cache error")
                eq(id(fn, "counter"), old_counter, "first alias untouched")
                eq(id(fn, "other"), old_other, "second alias untouched")
                eq(plan.joined, false, "failed cache not marked joined")
            end
        end)
    end

    -- Each hot caller is a fresh prototype so closure-count polymorphism does
    -- not make a supposedly hot constant-value test silently stop specialising.
    local function caller()
        return assert(compile([[
return function(fn)
    local sum=0
    for i=1,10000 do sum=sum+fn() end
    return sum/10000
end
]], "@CodeCacheSpec:hot-caller"))()
    end
    local active = type(real_jit) == "table" and type(real_jit.status) == "function"
        and real_jit.status() == true
    if active then
        local util = require("jit.util")
        local function has_trace()
            for i=1,1000 do if util.traceinfo(i) then return true end end
            return false
        end
        local function reset_cache()
            real_jit.flush() -- precondition ONLY; the mutation must invalidate itself
            eq(real_jit.status(), true, "precondition keeps JIT enabled")
        end
        -- Numbers and nil/false transitions share their original cells.
        for _, kind in ipairs({"number", "nil", "false"}) do
            reset_cache()
            local entry = capture("local counter=0\nlocal function reader() return counter end\n")
            local reader = Anchor.Get(entry, "reader")
            local read = caller()
            eq(read(reader), 0, "warm numeric caller")
            eq(has_trace(), true, "warm caller has compiled code")
            local replacement = 5
            if kind == "nil" then replacement = nil end
            if kind == "false" then replacement = false end
            local original_cell = id(reader, "counter")
            eq(Anchor.Set(entry, "counter", replacement), true, "hot set " .. kind)
            eq(Anchor.Get(entry, "counter"), replacement, "real cell " .. kind)
            eq(reader(), replacement, "direct reader " .. kind)
            if kind == "number" then
                eq(read(reader), 5, "inlined reader sees number")
            else
                -- Keep the old numeric caller: the new value MUST cause the
                -- normal Lua arithmetic error, not run the cached ADD +0.
                local ok = pcall(read, reader)
                eq(ok, false, "old numeric caller observes nonnumeric " .. kind)
            end
            eq(id(reader, "counter"), original_cell, "set preserves cell identity")
            eq(real_jit.status(), true, "hot set keeps JIT enabled")
        end

        -- An already hot old recursive closure must observe a function write.
        reset_cache()
        local entry = capture("local function recur(n)\n if n<=0 then return 0 end\n return 1+recur(n-1)\nend\n")
        local old = Anchor.Get(entry, "recur")
        local fresh = assert(Compose.Create(
            "local function recur(n) if n<=0 then return 0 end return 10+recur(n-1) end",
            "recur", {"recur"}))
        assert(Compose.Attach(fresh, entry))
        local sum = 0
        for i=1,10000 do sum=sum+old(4) end
        eq(sum, 40000, "warm old recursion")
        eq(has_trace(), true, "recursive code compiled")
        local original_cell = id(old, "recur")
        eq(Anchor.Set(entry, "recur", fresh.fn), true, "recursive cell write")
        eq(fresh.fn(4), 40, "new recursive closure sees itself")
        eq(old(4), 31, "hot old closure sees new recursive target")
        eq(id(old, "recur"), original_cell, "recursive cell identity unchanged")
        eq(real_jit.status(), true, "recursion keeps JIT enabled")

        -- Join a previously called closure: an unknown inlined caller must
        -- see the new alias, not its former constant. Plan itself is read-only.
        reset_cache()
        entry = capture("local counter=7\n")
        local fn = assert(compile("local counter=0; return function() return counter end"))()
        local read = caller()
        eq(read(fn), 0, "warm pre-join caller")
        eq(has_trace(), true, "pre-join caller compiled")
        local plan = assert(Compose.Plan(fn, entry))
        eq(read(fn), 0, "Plan does not change cell or invalidate")
        eq(Compose.Join(plan), 1, "hot closure join")
        eq(id(fn, "counter"), id(entry.anchor, "counter"), "joined real cell")
        eq(read(fn), 7, "unknown inlined caller sees joined donor")
        eq(real_jit.status(), true, "join keeps JIT enabled")
    else
        print("CodeCacheSpec: real hot-JIT cases not run (JIT unavailable/off)")
    end
    for _, label in ipairs(failures) do print("[CodeCacheSpec] FAIL " .. label) end
    return {passed=passed, failed=failed, failures=failures}
end

return M
