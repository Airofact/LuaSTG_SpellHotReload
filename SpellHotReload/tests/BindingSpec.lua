local Binding = require("SpellHotReload.Binding")
local IR = require("SpellHotReload.TopLevelIR")
local M = {}

function M.run()
    local passed = 0
    local function eq(actual, expected, label)
        assert(actual == expected, label)
        passed = passed + 1
    end
    local function names(list)
        local out = {}
        for i = 1, #list do out[i] = list[i].name end
        return table.concat(out, ",")
    end
    local function bind(content, options)
        local nodes, err, analysis = IR.Analyze(content, options)
        assert(analysis ~= nil, err)
        local model, reason = Binding.Analyze(analysis)
        assert(model ~= nil, reason)
        return model, analysis, nodes
    end

    -- declaration set: names, kinds, slots, order and byte ranges
    local model, analysis = bind("local a = 1\nlocal function f() end\nlocal b, c\nG = 1")
    eq(#model.declarations, 4, "every top-level local is a declaration")
    eq(table.concat(model.names, ","), "a,f,b,c", "names in first-declaration order")
    eq(model.by_name.a.kind, "value", "value kind")
    eq(model.by_name.f.kind, "function", "function kind")
    eq(model.by_name.b.kind, "declare", "declare kind")
    eq(model.by_name.b.slot, 1, "first slot")
    eq(model.by_name.c.slot, 2, "second slot")
    eq(model.by_name.f.self_visible, true, "local function sees itself")
    eq(model.by_name.a.self_visible, false, "plain local does not")
    eq(model.by_name.a.statement, 1, "declaration statement index")
    eq(model.by_name.c.statement, 3, "multi-name statement index")
    eq(model.by_name.a.source_range, analysis.statements[1].source_range, "byte range matches statement")
    eq(model.by_name.c.source_range, analysis.statements[3].source_range, "multi-name byte range")
    eq(model.by_name.a.token < model.by_name.b.token, true, "declaration tokens in source order")
    eq(#model.duplicates, 0, "no duplicates")
    eq(model.complete, false, "never claims a complete binding proof")
    eq(model.by_name.a, model.declarations[1], "by_name shares declaration identity")

    -- definition-point visibility is strictly backwards
    model = bind("local a = 1\nlocal b = a\nlocal c = b + a\nlocal d = 1")
    eq(model.statements[1].visible.a, nil, "not visible in its own initializer")
    eq(model.statements[1].declares.a, model.by_name.a, "own declaration recorded")
    eq(model.statements[2].visible.a, model.by_name.a, "previous declaration visible")
    eq(model.statements[2].declares.b, model.by_name.b, "second declaration recorded")
    eq(names(model.statements[2].certain), "a", "initializer reads the visible local")
    eq(model.statements[3].visible.b, model.by_name.b, "b visible later")
    eq(names(model.statements[3].certain), "b,a", "both names read in token order")
    eq(#model.statements[3].uncertain, 0, "nothing nested")
    eq(model.statements[4].visible.c, model.by_name.c, "c visible later")
    eq(names(model.statements[1].certain), "", "nothing to read yet")

    -- `local x = x` reads the earlier binding, not the name being declared
    model = bind("local x = 1\nlocal x = x + 1\nG = x")
    eq(#model.duplicates, 1, "duplicate name detected")
    eq(model.duplicates[1].name, "x", "duplicate name")
    eq(model.duplicates[1].count, 2, "duplicate count")
    eq(model.duplicates[1].declarations[2], model.declarations[2], "both declarations kept")
    eq(model.by_name.x, nil, "ambiguous name is not resolvable")
    eq(table.concat(model.names, ","), "x", "unique name list")
    eq(model.statements[2].visible.x, model.declarations[1], "second declaration sees the first")
    eq(names(model.statements[2].certain), "x", "initializer binds the earlier local")
    eq(model.statements[3].visible.x, model.declarations[2], "later statements bind the newest local")

    -- self-recursion: the local function name is in scope inside its own body
    model = bind("local function f(n)\n  if n <= 1 then return 1 end\n  return n * f(n - 1)\nend")
    eq(model.declarations[1].self_visible, true, "local function self visibility")
    eq(model.statements[1].visible.f, nil, "not visible before the statement")
    eq(#model.statements[1].certain, 0, "no proven top-level read inside the body")
    eq(names(model.statements[1].uncertain), "f", "self-reference is nested, not proven")

    -- a forward reference is a global read, never a local edge
    model = bind("G = b\nlocal b = 2")
    eq(model.statements[1].visible.b, nil, "forward name not visible")
    eq(#model.statements[1].certain, 0, "forward name is not a local read")
    eq(model.statements[2].visible.b, nil, "still not visible before its own declaration")

    -- nested shadowing: TopLevelIR token-name deps are heuristic, not safety
    local source = "local x = 1\nlocal function g()\n  local x = 2\n  return x\nend\nG = x"
    model, analysis = bind(source)
    local g
    for _, node in ipairs(analysis.nodes) do
        if node.name == "g" then g = node end
    end
    eq(g.deps[1], "x", "heuristic token-name dep lists the shadowed name")
    eq(#model.statements[2].certain, 0, "no proven read inside the shadowing body")
    eq(names(model.statements[2].uncertain), "x", "shadowed read stays uncertain")
    eq(names(model.statements[3].certain), "x", "top-level read is proven")

    -- comments and strings never become declarations or reads
    model = bind("local a = 1\n-- local b = 2\nG = 'a'\nS = [[local c = 3]]")
    eq(table.concat(model.names, ","), "a", "comments and strings do not declare")
    eq(#model.declarations, 1, "one real declaration")
    eq(model.statements[2].visible.a, model.by_name.a, "a is in scope")
    eq(#model.statements[2].certain, 0, "string contents are not identifiers")
    eq(model.statements[3].visible.a, model.by_name.a, "still in scope")
    eq(#model.statements[3].certain, 0, "long string is not code")

    -- field names, method names and table keys are not variable reads
    model = bind("local a = 1\nlocal t = {}\nT.a = a\nt = { a = a, b }")
    eq(names(model.statements[3].certain), "a", "only the value side is a read")
    eq(names(model.statements[4].certain), "t,a", "receiver and value read, key does not")
    model = bind("local o = {}\nlocal m = 3\no:m(m)")
    eq(names(model.statements[3].certain), "o,m", "method name excluded, argument is a read")

    -- table keys are bracketed values, not keys, when indexed with [ ]
    model = bind("local k = 1\nT = { [k] = 2 }")
    eq(names(model.statements[2].certain), "k", "computed key is a read")

    -- for-loop control variables rebind, they are not reads of an outer local
    model = bind("local i = 1\nfor i = 1, 10 do end\nG = i")
    eq(model.statements[2].visible.i, model.by_name.i, "outer local still visible")
    eq(names(model.statements[2].certain), "", "loop variable is not a read")
    eq(names(model.statements[3].certain), "i", "outer local read after the loop")
    model = bind("local t = {}\nfor k, v in pairs(t) do end")
    eq(names(model.statements[2].certain), "t", "loop expression reads the visible local")

    -- repeat/until scope leak: the until expression may see a body local
    model = bind("local x = 1\nrepeat\n  local y = x\nuntil x > y")
    eq(#model.statements[2].certain, 0, "repeat demotes every hit")
    eq(names(model.statements[2].uncertain), "x,x", "both textual hits stay uncertain")

    -- assignment targets count as reads of the visible local
    model = bind("local a = 1\na = a + 1")
    eq(names(model.statements[2].certain), "a,a", "target and value both read the local")

    -- nested blocks are flagged; function statements nest their name path
    model = bind("local a = 1\nlocal f = function() return 1 end")
    eq(model.statements[1].nested, false, "flat statement")
    eq(model.statements[2].nested, true, "nested block detected")
    model = bind("function T.m() return T end")
    eq(model.statements[1].nested, true, "function statement nests its name path")
    eq(#model.declarations, 0, "field function is not a local declaration")
    eq(#model.statements[1].certain, 0, "no proven read in a function statement")

    -- a statement TopLevelIR cannot parse makes the snapshot opaque
    model = bind("local ??? = 1\nlocal ok = 2")
    eq(model.opaque, true, "unparsed statement is flagged")
    eq(table.concat(model.names, ","), "ok", "only the parsed declaration is claimed")
    eq(model.statements[1].unparsed, true, "statement flagged unparsed")
    model = bind("local")
    eq(model.opaque, true, "degenerate local statement is opaque")
    eq(#model.declarations, 0, "no invented declaration")
    model = bind("local a = 1\nUnknown()\nSIDE_EFFECT()")
    eq(model.opaque, false, "an unadapted call is still lexically analyzable")

    -- duplicate names keep first-declaration order and stay ambiguous
    model = bind("local a = 1\nlocal b = 2\nlocal a = 3")
    eq(table.concat(model.names, ","), "a,b", "names keep first-declaration order")
    eq(#model.duplicates, 1, "one duplicate name")
    eq(model.by_name.a, nil, "duplicate name is ambiguous")
    eq(model.by_name.b, model.declarations[2], "unique name resolves")

    -- empty and comment-only files are valid, not errors
    model = bind("")
    eq(#model.statements, 0, "empty file has no statements")
    eq(#model.declarations, 0, "empty file declares nothing")
    eq(model.complete, false, "empty snapshot still claims nothing")
    model = bind("-- nothing here")
    eq(#model.statements, 0, "comment-only file has no statements")

    -- BOM is accounted for in the public byte range only
    model = bind("\239\187\191local a = 1")
    eq(model.declarations[1].source_range.first, 4, "BOM offset applied to bytes")
    eq(model.declarations[1].source_range.last, 14, "BOM-aware end")
    eq(model.declarations[1].token, 2, "token index stays BOM-normalized")

    -- the model never writes back into the analysis snapshot
    local shared
    model, shared = bind("local a = 1\nG = a")
    eq(shared.statements[1].visible, nil, "analysis snapshot untouched")
    eq(shared.statements[1].certain, nil, "no model records on the analysis")
    eq(shared.binding_complete, false, "analysis keeps its own completeness flag")

    -- Binding never executes the analyzed source
    local touched = false
    local old_effect = _G.SIDE_EFFECT
    _G.SIDE_EFFECT = function() touched = true end
    model = bind("SIDE_EFFECT()")
    _G.SIDE_EFFECT = old_effect
    eq(touched, false, "analysis does not run candidate code")

    -- defensive input handling
    local bad, reason = Binding.Analyze(nil)
    eq(bad, nil, "nil analysis is rejected")
    eq(type(reason), "string", "failure carries a reason")
    bad = Binding.Analyze(setmetatable({}, { __index = function() error("no") end }))
    eq(bad, nil, "analysis with a metatable is rejected")
    bad = Binding.Analyze({ tokens = {}, nodes = {} })
    eq(bad, nil, "missing statements is rejected")
    bad = Binding.Analyze({ tokens = {}, statements = {}, nodes = {} })
    eq(type(bad), "table", "empty analysis is valid")
    eq(#bad.names, 0, "empty analysis has no names")

    print(string.format("[SpellHotReload binding] %d passed, 0 failed", passed))
    return { passed = passed, failed = 0 }
end

return M
