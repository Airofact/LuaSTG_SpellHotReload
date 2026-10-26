local Binding = require("SpellHotReload.Source.Binding")
local IR = require("SpellHotReload.Source.TopLevelIR")
local Tree = require("SpellHotReload.Source.SyntaxTree")
local M = {}

function M.run()
    local passed = 0
    local function eq(actual, expected, label)
        assert(actual == expected, label)
        passed = passed + 1
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
    eq(model.statements[3].visible.b, model.by_name.b, "b visible later")
    eq(model.statements[4].visible.c, model.by_name.c, "c visible later")

    -- `local x = x` reads the earlier binding, not the name being declared
    model = bind("local x = 1\nlocal x = x + 1\nG = x")
    eq(#model.duplicates, 1, "duplicate name detected")
    eq(model.duplicates[1].name, "x", "duplicate name")
    eq(model.duplicates[1].count, 2, "duplicate count")
    eq(model.duplicates[1].declarations[2], model.declarations[2], "both declarations kept")
    eq(model.by_name.x, nil, "ambiguous name is not resolvable")
    eq(table.concat(model.names, ","), "x", "unique name list")
    eq(model.statements[2].visible.x, model.declarations[1], "second declaration sees the first")
    eq(model.statements[3].visible.x, model.declarations[2], "later statements bind the newest local")

    -- self-recursion: the local function name is in scope inside its own body
    model = bind("local function f(n)\n  if n <= 1 then return 1 end\n  return n * f(n - 1)\nend")
    eq(model.declarations[1].self_visible, true, "local function self visibility")
    eq(model.statements[1].visible.f, nil, "not visible before the statement")

    -- a forward reference is a global read, never a local edge
    model = bind("G = b\nlocal b = 2")
    eq(model.statements[1].visible.b, nil, "forward name not visible")
    eq(model.statements[2].visible.b, nil, "still not visible before its own declaration")

    -- Nested declarations do not change top-level definition-point visibility.
    local source = "local x = 1\nlocal function g()\n  local x = 2\n  return x\nend\nG = x"
    model, analysis = bind(source)
    local g
    for _, node in ipairs(analysis.nodes) do
        if node.name == "g" then g = node end
    end
    eq(g.deps[1], "x", "identifier hint remains conservative under shadowing")
    eq(#model.declarations, 2, "body local is not a top-level declaration")
    eq(model.statements[2].visible.x, model.by_name.x, "outer x is visible at g definition")
    eq(model.statements[3].visible.x, model.by_name.x, "body shadowing does not leak")

    -- Comments and strings never become declarations.
    model = bind("local a = 1\n-- local b = 2\nG = 'a'\nS = [[local c = 3]]")
    eq(table.concat(model.names, ","), "a", "comments and strings do not declare")
    eq(#model.declarations, 1, "one real declaration")
    eq(model.statements[2].visible.a, model.by_name.a, "a is in scope")
    eq(model.statements[3].visible.a, model.by_name.a, "still in scope")

    -- Loop and repeat locals stay inside their own bodies.
    model = bind("local i = 1\nfor i = 1, 10 do local hidden = i end\nG = i")
    eq(#model.declarations, 1, "loop locals are not top-level declarations")
    eq(model.statements[2].visible.i, model.by_name.i, "outer i visible at loop entry")
    eq(model.statements[3].visible.i, model.by_name.i, "outer i remains after loop")
    eq(model.by_name.hidden, nil, "loop body declaration does not escape")
    model = bind("local t = {}\nfor k, v in pairs(t) do end\nlocal after = t")
    eq(table.concat(model.names, ","), "t,after", "generic loop names do not escape")
    eq(model.statements[3].visible.t, model.by_name.t, "scope survives generic loop")
    model = bind("local x = 1\nrepeat local y = x until x > y\nG = x")
    eq(#model.declarations, 1, "repeat local is not a top-level declaration")
    eq(model.by_name.y, nil, "repeat declaration does not escape")
    eq(model.statements[3].visible.x, model.by_name.x, "outer x remains after repeat")

    -- Function initializer and local-function self visibility stay distinct.
    model = bind("local f = function() return f end\nlocal function g() return g end")
    eq(model.by_name.f.self_visible, false, "initializer does not declare its own prefix")
    eq(model.statements[1].visible.f, nil, "initializer cannot see the new f")
    eq(model.statements[2].visible.f, model.by_name.f, "f visible to the next definition")
    eq(model.statements[2].declares.g, model.by_name.g, "recursive declaration identity")
    eq(model.statements[2].self_visible, true, "local function retains self visibility")
    model = bind("function T.m() return T end")
    eq(#model.declarations, 0, "field function is not a local declaration")

    -- Once shared IR exists, Binding must not inspect descendant references.
    local _, problem, shared_ir = IR.Analyze("local outer = 1\nlocal function recur(n) "
        .. "local outer = n; repeat local held = outer; "
        .. "local inner = function() return held end until outer > 0; "
        .. "return recur(n - 1) end\ndo local hidden = outer end\nlocal later = recur")
    assert(shared_ir, problem)
    local walk, names = Tree.Walk, Tree.Names
    local function forbidden() error("Binding scanned descendant diagnostics", 0) end
    Tree.Walk, Tree.Names = forbidden, forbidden
    local ok, trimmed, why = pcall(Binding.Analyze, shared_ir)
    Tree.Walk, Tree.Names = walk, names
    eq(ok, true, "declaration/visibility analysis does not walk descendants")
    assert(trimmed, why)
    eq(table.concat(trimmed.names, ","), "outer,recur,later", "only top-level declarations retained")
    eq(trimmed.statements[2].visible.outer, trimmed.by_name.outer, "outer declaration identity retained")
    eq(trimmed.statements[2].declares.recur, trimmed.by_name.recur, "self declaration retained")
    eq(trimmed.statements[2].self_visible, true, "self visibility retained without reference scan")
    eq(trimmed.statements[4].visible.recur, trimmed.by_name.recur, "later statement sees recursive function")
    eq(trimmed.by_name.hidden, nil, "block-local declaration stays private")
    eq(trimmed.by_name.held, nil, "nested declaration stays private")
    trimmed.statements[3].visible.outer = nil
    eq(trimmed.statements[4].visible.outer, trimmed.by_name.outer, "statement visibility snapshots stay separate")
    for _, record in ipairs(trimmed.statements) do
        eq(record.certain, nil, "retired reference diagnostics are absent")
        eq(record.uncertain, nil, "no empty reference result masquerades as analysis")
        eq(record.nested, nil, "retired nested diagnostic is absent")
    end

    -- Malformed source has no partial declaration/visibility snapshot.
    for _,source in ipairs({"local ??? = 1\nlocal ok = 2","local"}) do
        local nodes,reason,invalid=IR.Analyze(source)
        eq(nodes,nil,"invalid source has no partial nodes")
        eq(invalid,nil,"invalid source has no partial bindings")
        eq(type(reason),"string","invalid source carries analysis reason")
    end
    -- Keep Binding's own conservative disagreement handling independently.
    local _,_,tampered=IR.Analyze("local a=1")
    tampered.nodes[1].carrier="effect";tampered.nodes[1].kind="unknown"
    model=assert(Binding.Analyze(tampered))
    eq(model.opaque,true,"classification disagreement is opaque")
    eq(model.statements[1].unparsed,true,"disagreement not promoted to proof")
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
    eq(shared.statements[1].declares, nil, "no declaration model written into analysis")
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
