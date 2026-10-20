--------------------------------------------------------------------------------
--- SpellHotReload tests/LoadCaptureSpec.lua
---
--- Pure spec for the generalized load-capture service. Runs under plain Lua 5.1
--- and LuaJIT with the game directory as cwd (see tests/Run.lua).
--------------------------------------------------------------------------------

local LC = require("SpellHotReload.Load.LoadCapture")

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

local function lines(...)
    return table.concat({ ... }, "\n")
end

--------------------------------------------------------------------------------
-- pure queries: capture names
--------------------------------------------------------------------------------

do
    local names = LC.LocalNames(lines(
        "local a = 1",
        "local b, c = 2, 3",
        "local function d() end",
        "local a = 5",
        "e = 6",
        "T.f = 7"))
    eq(table.concat(names, ","), "a,b,c,d", "names: only top-level locals, deduped")
end

do
    local names = LC.LocalNames(lines(
        "do",
        "    local hidden = 1",
        "end",
        "local visible = 2"))
    eq(table.concat(names, ","), "visible", "names: locals inside a block are not captured")
end

--------------------------------------------------------------------------------
-- pure queries: top-level return detection
--------------------------------------------------------------------------------

do
    check(LC.HasTopLevelReturn("local a = 1\nreturn a"), "return: bare top-level return")
    check(not LC.HasTopLevelReturn("local a = 1\nM.f = function() return 1 end"),
        "return: nested function return is not top level")
    check(not LC.HasTopLevelReturn("if x then return 1 end\nlocal a = 2"),
        "return: return inside a block is not top level")
end

--------------------------------------------------------------------------------
-- capture path (side-effect file, no top-level return)
--------------------------------------------------------------------------------

do
    _G.LC_LOGGED = nil
    local src = lines(
        "local counter = 0",
        "local function bump() counter = counter + 1 return counter end",
        "LC_LOGGED = (LC_LOGGED or 0) + 1")
    local result, err = LC.Run(src, "@spec:capture")
    check(result ~= nil, "capture: run succeeds (" .. tostring(err) .. ")")
    if result ~= nil then
        check(result.captured == true, "capture: marked captured")
        eq(result.ret.n, 0, "capture: file itself returns nothing")
        check(type(result.map) == "table", "capture: map produced")
        eq(result.map.counter, 0, "capture: local value harvested")
        eq(type(result.map.bump), "function", "capture: local function harvested")
        if type(result.map.bump) == "function" then
            eq(result.map.bump(), 1, "capture: harvested closure keeps its upvalue")
        end
        eq(table.concat(result.names, ","), "counter,bump", "capture: names recorded")
    end
    eq(_G.LC_LOGGED, 1, "capture: side effects ran exactly once")
    _G.LC_LOGGED = nil
end

do
    local src = lines(
        "local f = function() return 1 end",
        "local g = function()",
        "    if false then return 2 end",
        "    return 3",
        "end")
    local result = assert(LC.Run(src, "@spec:nested"))
    check(result.captured == true, "nested: multi-line locals still captured")
    eq(result.map.f(), 1, "nested: short local function")
    eq(result.map.g(), 3, "nested: long local function")
end

do
    local result = assert(LC.Run("local x = 1\nlocal x = 2", "@spec:shadow"))
    eq(table.concat(result.names, ","), "x", "shadow: single deduped name")
    eq(result.map.x, 2, "shadow: trailer binds the latest declaration")
end

--------------------------------------------------------------------------------
-- return path (module file, top-level return)
--------------------------------------------------------------------------------

do
    local src = lines(
        "local secret = 42",
        "local M = {}",
        "function M.get() return secret end",
        "return M")
    local result, err = LC.Run(src, "@spec:module")
    check(result ~= nil, "module: run succeeds (" .. tostring(err) .. ")")
    if result ~= nil then
        eq(result.captured, false, "module: capture skipped when a top-level return exists")
        eq(result.map, nil, "module: no capture map")
        eq(table.concat(result.names, ","), "secret,M", "module: names still analyzed")
        eq(LC.ReturnArity(result), 1, "module: one return value")
        local mod = LC.ReturnValues(result)
        eq(type(mod), "table", "module: returns the exported table")
        eq(mod.get(), 42, "module: exported closure keeps its upvalue")
    end
end

do
    local result = assert(LC.Run("return 1, nil, 3", "@spec:arity"))
    eq(LC.ReturnArity(result), 3, "arity: three values counted")
    local a, b, c = LC.ReturnValues(result)
    eq(a, 1, "arity: first value")
    eq(b, nil, "arity: embedded nil preserved")
    eq(c, 3, "arity: third value")
end

do
    local result = assert(LC.Run("local a = 1\nLC_SIDE = 7", "@spec:nocap", { capture = false }))
    eq(result.captured, false, "capture=false: disabled")
    eq(result.map, nil, "capture=false: no map")
    eq(LC.ReturnArity(result), 0, "capture=false: no return values")
    eq(_G.LC_SIDE, 7, "capture=false: file still executed")
    _G.LC_SIDE = nil
end

--------------------------------------------------------------------------------
-- failure staging
--------------------------------------------------------------------------------

do
    local result, err, stage = LC.Run("local x = = 1", "@spec:badcompile")
    eq(result, nil, "compile failure: no result")
    eq(stage, "analyze", "syntax failure: refused before compilation")
    check(tostring(err):find("Lua syntax:", 1, true) == 1, "syntax failure: message")
end

do
    local parameters={}
    for i=1,201 do parameters[i]="p"..i end
    local invalid,why,phase=LC.Run("function LIMIT("..table.concat(parameters,",")..") end")
    eq(invalid,nil,"compiler restriction has no result")
    eq(phase,"compile","compiler limit still enforced")
    check(tostring(why):find("compile failed",1,true)==1,"compiler reason retained")
    local result, err, stage = LC.Run("local a = 1\nerror('boom')", "@spec:badrun")
    eq(result, nil, "runtime failure: no result")
    eq(stage, "run", "runtime failure: staged as run")
    check(tostring(err):find("boom", 1, true) ~= nil, "runtime failure: message carries cause")
end

--------------------------------------------------------------------------------
-- BOM handling
--------------------------------------------------------------------------------

do
    local src = "\239\187\191local a = 1"
    local result, err = LC.Run(src, "@spec:bom")
    check(result ~= nil, "bom: run succeeds (" .. tostring(err) .. ")")
    if result ~= nil then
        eq(result.map.a, 1, "bom: capture works with a leading BOM")
    end
end

--------------------------------------------------------------------------------
-- real generated file (skipped when the runtime mod is absent)
--------------------------------------------------------------------------------

do
    local f = io.open("mod/DiMS/DiMS_Stage1_Boss.lua", "rb")
    if f ~= nil then
        local content = f:read("*a")
        f:close()
        check(not LC.HasTopLevelReturn(content), "real file: boss file has no top-level return")
        local names = LC.LocalNames(content)
        check(#names > 0, "real file: top-level locals discovered")
        check(names[1] ~= nil and type(names[1]) == "string", "real file: names are strings")
        eq(LC.Trailer(names):sub(1, 7), "return ", "real file: trailer is a return table")
    end
end

--------------------------------------------------------------------------------

function M.run()
    print(string.format("[SpellHotReload load capture] %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do
        print("  FAIL: " .. label)
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
