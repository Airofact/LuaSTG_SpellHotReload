local M = {}

function M.run()
    local passed = 0
    local function eq(a, b, label)
        assert(a == b, label .. ": " .. tostring(a) .. " ~= " .. tostring(b))
        passed = passed + 1
    end
    local Lexer = require("SpellHotReload.Source.Lexer")
    local Capture = require("SpellHotReload.Load.LoadCapture")
    eq(#Lexer.Tokenize(""), 0, "empty")
    eq(#Lexer.Tokenize(" \t\r\n\f\v"), 0, "whitespace")
    eq(#Lexer.Tokenize("-- local function fake() end"), 0, "line comment")
    eq(#Lexer.Tokenize("--[=[ function fake() end ]=]"), 0, "long comment")
    local source = "local function f() return 'end' end"
    local tokens = Lexer.Tokenize(source)
    local expected = {
        {"word", "local", 1, 0}, {"word", "function", 7, 0},
        {"word", "f", 16, 1}, {"symbol", "(", 17, 1}, {"symbol", ")", 18, 1},
        {"word", "return", 20, 1}, {"string", "'end'", 27, 1}, {"word", "end", 33, 1},
    }
    eq(#tokens, #expected, "token count")
    for i, e in ipairs(expected) do
        local t = tokens[i]
        eq(t.kind, e[1], "kind " .. i)
        eq(t.value, e[2], "value " .. i)
        eq(t.pos, e[3], "byte pos " .. i)
        eq(t.depth, e[4], "block depth " .. i)
    end
    local function same(a, b, label)
        eq(#a, #b, label .. " count")
        for i, t in ipairs(a) do
            for _, key in ipairs({"kind", "value", "pos", "depth"}) do
                eq(t[key], b[i][key], label .. " " .. i .. "/" .. key)
            end
        end
    end
    for _, s in ipairs({
        'a = "escaped\\\" end" -- tail\nb = [==[ function end ]==]',
        "repeat do if a then f() end end until done",
        "for i=1,3 do while x do local z={} end end",
        "--[=[unterminated", "[=[unterminated", "'unterminated",
        "x.y:z(a[1], {endkey=false}); x==y and x~=z",
        "\239\187\191local x = 1",
    }) do
        for _, t in ipairs(Lexer.Tokenize(s)) do
            eq(s:sub(t.pos, t.pos + #t.value - 1), t.value, "byte slice")
        end
    end
    eq(Capture.Trailer({}), "return {}", "empty trailer bytes")
    eq(Capture.Trailer({"a"}), 'return {["a"]=a}', "single trailer bytes")
    eq(Capture.Trailer({"a","b"}), 'return {["a"]=a,["b"]=b}', "ordered trailer bytes")
    local compile = loadstring or load
    local values = assert(compile("local a,b,c=nil,false,3\n" .. Capture.Trailer({"a","b","c"})))()
    eq(values.a, nil, "map retains nil semantics")
    eq(values.b, false, "map false")
    eq(values.c, 3, "map value")

    -- A fresh generic load graph must work when requiring the legacy loader
    -- is forbidden, not merely when an old cached module happens to be present.
    local keys = {
        "GeneratedBossLoader", "Source.Lexer", "Source.TopLevelIR", "Load.LoadCapture", "Source.Binding",
        "Load.Anchor", "Source.Compose", "Load.AnchorLoad", "Load.LoadHook", "Pipeline.FileMatch",
    }
    local loaded, preloaded = {}, {}
    for _, key in ipairs(keys) do
        local full = "SpellHotReload." .. key
        loaded[full], preloaded[full] = package.loaded[full], package.preload[full]
        package.loaded[full] = nil
    end
    package.preload["SpellHotReload.GeneratedBossLoader"] = function()
        error("generic path required legacy loader")
    end
    local ok, reason = pcall(function()
        local IR = require("SpellHotReload.Source.TopLevelIR")
        local C = require("SpellHotReload.Source.Compose")
        local A = require("SpellHotReload.Load.AnchorLoad")
        local H = require("SpellHotReload.Load.LoadHook")
        eq(#assert(IR.Analyze("local a,b=nil,false")), 2, "independent generic analysis")
        local made = assert(C.Create("function() return a end", nil, {"a"}, {form="expression"}))
        eq(type(made.fn), "function", "independent composition")
        local entry = assert(A.Capture("local a,b=nil,false"))
        eq(entry.map.b, false, "independent dual capture")
        eq(entry.map.a, nil, "independent dual nil")
        eq(A.ReturnArity(entry), 0, "normal file return arity")
        local ret = assert(A.Capture("return 1,nil,3,nil"))
        eq(A.ReturnArity(ret), 4, "independent module arity")
        eq(ret.reloadable, false, "return file still refuses reload")
        eq(H.BossFile("mod/DiMS/F_Boss.lua"), "F_Boss.lua", "selector unchanged")
        eq(H.BossFile("F_Mid.lua"), nil, "allowlist unchanged")
        eq(package.loaded["SpellHotReload.GeneratedBossLoader"], nil, "legacy never loaded")
    end)
    for _, key in ipairs(keys) do
        local full = "SpellHotReload." .. key
        package.loaded[full], package.preload[full] = loaded[full], preloaded[full]
    end
    assert(ok, reason)
    return {passed=passed, failed=0}
end

return M
