--------------------------------------------------------------------------------
--- SpellHotReload tests/TopLevelIRSpec.lua
---
--- Pure spec for the generic reload model's top-level analyzer. Runs under plain
--- Lua 5.1 and LuaJIT with the game directory as cwd (see tests/Run.lua).
--------------------------------------------------------------------------------

local IR = require("SpellHotReload.Source.TopLevelIR")

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

local function analyze(src, options)
    local nodes, err = IR.Analyze(src, options)
    if nodes == nil then error("Analyze failed: " .. tostring(err)) end
    return nodes
end

local function by_name(nodes, name)
    for _, node in ipairs(nodes) do
        if node.name == name then return node end
    end
    return nil
end

local function lines(...)
    return table.concat({ ... }, "\n")
end

--------------------------------------------------------------------------------
-- statement splitting
--------------------------------------------------------------------------------

do
    local stmts = IR.SplitStatements(lines(
        "local function a()",
        "    return 1",
        "end",
        "b = 2",
        "T = {",
        "    1,",
        "    2,",
        "}"))
    eq(#stmts, 3, "split: three top-level statements")
    check(stmts[1].text:find("^local function a") == 1, "split: first is the function")
    check(stmts[2].text:find("^b = 2") == 1, "split: second is the assignment")
    check(stmts[3].text:find("^T = {") == 1, "split: table constructor kept whole")
    eq(stmts[1].line, 1, "split: first line")
    eq(stmts[2].line, 4, "split: second line")
    eq(stmts[3].line, 5, "split: third line")
end

do
    local stmts = IR.SplitStatements(lines(
        "_editor_class[\"Boss\"] = Class(boss)",
        "function _tmp_sc:init()",
        "    self.x = 1",
        "    if self.x then",
        "        self.y = 2",
        "    end",
        "end",
        "table.insert(_editor_class[\"Boss\"].cards, _tmp_sc)"))
    eq(#stmts, 3, "split: function body is not split")
end

do
    local nodes = analyze(lines(
        "-- a comment",
        "--[[ block",
        "comment ]]",
        "G = 1"))
    eq(#nodes, 1, "split: comments produce no nodes")
    eq(nodes[1].name, "G", "split: statement after a block comment")
end

--------------------------------------------------------------------------------
-- local carriers
--------------------------------------------------------------------------------

do
    local nodes = analyze("local function f() end")
    eq(#nodes, 1, "local function: one node")
    eq(nodes[1].carrier, "local", "local function: carrier")
    eq(nodes[1].kind, "function", "local function: kind")
    eq(nodes[1].name, "f", "local function: name")
end

do
    local nodes = analyze("local a, b = 1, 2")
    eq(#nodes, 2, "multi-local: two nodes")
    eq(by_name(nodes, "a").kind, "value", "multi-local: a is a value")
    eq(by_name(nodes, "b").kind, "value", "multi-local: b is a value")
end

do
    local nodes = analyze("local x")
    eq(by_name(nodes, "x").kind, "declare", "bare local: declare")
end

do
    local nodes = analyze("local x = function() end")
    eq(by_name(nodes, "x").carrier, "local", "local anonymous: carrier")
    eq(by_name(nodes, "x").kind, "value", "local anonymous: value")
end

do
    local nodes = analyze("local a, b = 1, 2")
    eq(by_name(nodes, "a").slot, 1, "slots: first local target")
    eq(by_name(nodes, "b").slot, 2, "slots: second local target")
    eq(by_name(nodes, "a").text, "local a, b = 1, 2", "text: full statement text")
end

do
    local nodes = analyze(lines(
        "local function f()",
        "    return 1",
        "end"))
    eq(nodes[1].text, "local function f()\n    return 1\nend", "text: multi-line span")
end

--------------------------------------------------------------------------------
-- global and field carriers
--------------------------------------------------------------------------------

do
    local nodes = analyze("G = 1")
    eq(nodes[1].carrier, "global", "global assign: carrier")
    eq(nodes[1].name, "G", "global assign: name")
end

do
    local nodes = analyze("function G() end")
    eq(nodes[1].carrier, "global", "global function: carrier")
    eq(nodes[1].name, "G", "global function: name")
end

do
    local nodes = analyze("T.field = 1")
    eq(nodes[1].carrier, "field", "field assign: carrier")
    eq(nodes[1].path, "T.field", "field assign: path")
end

do
    local nodes = analyze("_editor_class[\"X\"].init = function(self) end")
    eq(nodes[1].carrier, "field", "indexed field: carrier")
    eq(nodes[1].path, "_editor_class[\"X\"].init", "indexed field: path")
    eq(nodes[1].root, "_editor_class", "indexed field: root")
end

do
    local nodes = analyze("function A.B:C() end")
    eq(nodes[1].carrier, "field", "method function: carrier")
    eq(nodes[1].path, "A.B:C", "method function: path")
end

do
    local nodes = analyze("T = { 1, 2 }")
    eq(nodes[1].carrier, "global", "table rebuild: carrier")
    check(nodes[1].table_rebuild == true, "table rebuild: flagged")
end

--------------------------------------------------------------------------------
-- host, container and effect carriers
--------------------------------------------------------------------------------

do
    local nodes = analyze(
        "stage.group.DefStageFunc(\"A@Easy\", \"init\", function(self) end)",
        { host_calls = { ["stage.group.DefStageFunc"] = true } })
    eq(nodes[1].carrier, "host", "registered call: host")
    eq(nodes[1].callee, "stage.group.DefStageFunc", "registered call: callee")
end

do
    local nodes = analyze("stage.group.DefStageFunc(\"A@Easy\", \"init\", function(self) end)")
    eq(nodes[1].carrier, "effect", "unregistered call: effect")
end

do
    local nodes = analyze("table.insert(T, v)")
    eq(nodes[1].carrier, "container", "table.insert: container")
    eq(nodes[1].kind, "table.insert", "table.insert: kind")
end

do
    local nodes = analyze("T[#T+1] = v")
    eq(nodes[1].carrier, "container", "append index: container")
    eq(nodes[1].kind, "append", "append index: kind")
end

do
    local nodes = analyze("require('x')")
    eq(nodes[1].carrier, "effect", "require: effect")
end

do
    local nodes = analyze("Include'DiMS_Global.lua'")
    eq(nodes[1].carrier, "effect", "Include: effect")
    eq(nodes[1].callee, "Include", "Include: callee")
end

do
    local nodes = analyze("return M")
    eq(nodes[1].carrier, "effect", "return: effect")
    eq(nodes[1].kind, "return", "return: kind")
end

--------------------------------------------------------------------------------
-- local dependency graph
--------------------------------------------------------------------------------

do
    local nodes = analyze(lines(
        "local function b()",
        "    return 1",
        "end",
        "local function a()",
        "    return b()",
        "end"))
    local a = by_name(nodes, "a")
    eq(#a.deps, 1, "deps: a has one dependency")
    eq(a.deps[1], "b", "deps: a depends on b")
end

do
    local nodes = analyze(lines(
        "local function a()",
        "    return b()",
        "end",
        "local function b()",
        "    return 1",
        "end"))
    eq(#by_name(nodes, "a").deps, 0, "deps: forward reference is not an edge")
end

do
    local nodes = analyze(lines(
        "local function fact(n)",
        "    if n <= 1 then return 1 end",
        "    return n * fact(n - 1)",
        "end"))
    check(by_name(nodes, "fact").recursive == true, "deps: self recursion flagged")
end

--------------------------------------------------------------------------------
-- real generated file (skipped when the runtime mod is absent)
--------------------------------------------------------------------------------

do
    local f = io.open("mod/DiMS/DiMS_Stage1_Boss.lua", "rb")
    if f ~= nil then
        local content = f:read("*a")
        f:close()
        local nodes = analyze(content)
        local counts, unknown = {}, 0
        for _, node in ipairs(nodes) do
            counts[node.carrier] = (counts[node.carrier] or 0) + 1
            if node.kind == "unknown" then unknown = unknown + 1 end
        end
        check(#nodes > 100, "real file: produces many top-level statements")
        eq(unknown, 0, "real file: no unparsed statements")
        check((counts["local"] or 0) > 0, "real file: has top-level locals")
        check((counts.field or 0) > 0, "real file: has field writes")
        check((counts.container or 0) > 0, "real file: has container inserts")
    end
end

--------------------------------------------------------------------------------

function M.run()
    print(string.format("[SpellHotReload top-level IR] %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do
        print("  FAIL: " .. label)
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
