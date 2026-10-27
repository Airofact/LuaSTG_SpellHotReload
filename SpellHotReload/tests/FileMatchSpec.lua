local FileMatch = require("SpellHotReload.Pipeline.FileMatch")
local Registry = require("SpellHotReload.Pipeline.NodeRegistry")
local Syntax = require("SpellHotReload.Source.SyntaxTree")
local IR = require("SpellHotReload.Source.TopLevelIR")
local Source = require("SpellHotReload.Source.FileAnalysis")
local M = {}

function M.run()
    local passed = 0
    local function eq(actual, expected, label)
        assert(actual == expected, label)
        passed = passed + 1
    end
    local function hook() error("execution hooks must not run") end
    local function adapter(id, match)
        return {
            ContractVersion = 5, Id = id, Match = match, Reconcile = function() error("unexpected reconciliation") end,
            Locate = hook, Inject = hook, Commit = hook, Restart = hook,
        }
    end
    local function registry(...)
        local r = Registry.New()
        for _, a in ipairs({ ... }) do assert(r:RegisterDiscovery(a)) end
        return r
    end
    local function unit(key, first, last)
        return {
            key = key, carrier = "card", context = { marker = key },
            source_ranges = { { first = first or 1, last = last or 1 } },
        }
    end
    local function result(units, claims)
        return { units = units or {}, claims = claims or {}, context = { all = true } }
    end
    local function claim(key, owner, kind)
        return { kind = kind or "callback", key = key, unit_key = owner }
    end
    local function discover(r, content, common, options)
        if content == nil then content = "G = 1" end
        local source,err = Source.Build(content,options)
        if not source then return nil,err end
        return FileMatch.Discover(r, source, common or { file = "F.lua" })
    end
    local function reject(r, code, phase, label, content, common, options)
        local snapshot, err = discover(r, content, common, options)
        eq(snapshot, nil, label .. ": no partial snapshot")
        eq(err.code, code, label .. ": code")
        eq(err.phase, phase or "match", label .. ": phase")
        assert(type(err.message) == "string" and err.message ~= "", label)
        return err
    end

    local source = "-- fake callback\nlocal a, b = 1, 2\nG = 'function end'\nSIDE_EFFECT()"
    local seen, calls = nil, {}
    local first, second = unit("a", 18, 33), unit("b", 18, 33)
    local fc, uc = { layout = "full" }, second.context
    local function match_a(facts, common)
        seen = facts
        local analysis = facts.analysis
        calls[#calls + 1] = "a"
        eq(facts, common.source, "common shares complete source")
        eq(facts.content, source, "Match gets exact complete bytes")
        eq(#analysis.statements, 3, "full-file statements include effect")
        eq(#analysis.nodes, 4, "multi-local keeps two carrier nodes")
        eq(analysis.syntax.Is(analysis.statements[1].syntax,"local"),true,"comment does not become trigger")
        eq(analysis.binding_complete, nil, "no obsolete binding-model field")
        eq(analysis.source_offset, 0, "plain-source offset")
        return { units = { first }, claims = { claim("slot-a", "a") }, context = fc }
    end
    local function match_b(analysis)
        calls[#calls + 1] = "b"
        eq(analysis, seen, "all adapters share one analysis")
        return result({ second }, { claim("slot-b", "b") })
    end
    local supplied = {
        file = "F.lua", session_id = "session", generation = 7,
        loaded_source = "loaded", registry_entry = {}, base_revision = 2,
        capture = {}, trace_context = "caller marker",
    }
    local old_parse, parse_count = Syntax.Parse, 0
    Syntax.Parse = function(content,previous)
        parse_count = parse_count + 1
        return old_parse(content,previous)
    end
    local ok, snapshot = pcall(discover, registry(adapter("b", match_b),
        adapter("a", match_a)), source, supplied)
    Syntax.Parse = old_parse
    assert(ok, snapshot)
    assert(snapshot)
    eq(parse_count, 1, "shared native snapshot parsed once")
    eq(table.concat(calls, ","), "a,b", "all registered adapters run")
    eq(#snapshot.units, 2, "all units retained without target selection")
    eq(snapshot.units[2], second, "original unit preserved")
    eq(snapshot.by_key.b.unit, second, "arbitrary-unit lookup")
    eq(snapshot.by_key.missing, nil, "unknown unit lookup")
    eq(snapshot.by_key.b.context.adapter.unit, uc, "unit context retained")
    eq(snapshot.by_key.a.context.adapter.file, fc, "file context retained")
    eq(snapshot.adapter_contexts.a, fc, "per-adapter full-file context")
    eq(snapshot.by_key.a.context.common, snapshot.common, "one shared common")
    eq(snapshot.common == supplied, false, "caller common is not reused")
    eq(supplied.trace_context, "caller marker", "caller metadata not overwritten")
    eq(supplied.source, nil, "authoritative source not written into caller common")
    eq(snapshot.common.registry_entry, supplied.registry_entry, "registry reference retained")
    eq(snapshot.common.capture, supplied.capture, "capture identity retained")
    eq(snapshot.common.session_id, "session", "session retained")
    eq(snapshot.common.generation, 7, "generation retained")
    eq(snapshot.common.loaded_source, "loaded", "loaded baseline retained")
    eq(snapshot.common.base_revision, 2, "revision retained")
    eq(#snapshot.claims, 2, "claims aggregated")
    eq(snapshot.claim_owners["callback:6:slot-a"], snapshot.by_key.a, "canonical owner index")

    local nodes, err, analysis = IR.Analyze("\239\187\191local a, b = 1, 2\r\nG=2")
    eq(err, nil, "analysis success error still nil")
    eq(nodes, analysis.nodes, "carrier nodes share snapshot")
    eq(analysis.source_offset, 3, "BOM offset")
    eq(analysis.syntax.Range(analysis.statements[1].syntax),1,"snapshot uses BOM-stripped byte coordinates")
    eq(analysis.statements[1].source_range.first, 4, "public range includes BOM offset")
    eq(analysis.statements[1].source_range.last, 20, "public range end")
    eq(analysis.statements[2].line, 2, "CRLF line number")
    eq(analysis.statements[2].text, "G=2", "statement text excludes CRLF")
    eq(analysis.statements[1].syntax,nodes[2].syntax,"multi-local statement shared")
    local bom = "\239\187\191G=2"
    local bom_snapshot = assert(discover(registry(adapter("bom", function(a, c)
        eq(a.content, bom, "source preserves BOM")
        eq(c.source,a,"same complete BOM source")
        local range = a.analysis.statements[1].source_range
        return result({ unit("bom", range.first, range.last) })
    end)), bom))
    eq(bom_snapshot.by_key.bom.unit.source_ranges[1].last, #bom, "raw-byte bounds")

    eq(#assert(discover(registry())).units, 0, "empty registry succeeds")
    eq(#assert(discover(registry(), "")).common.source.analysis.statements, 0, "empty file succeeds")
    local blank_nodes, blank_err, blank = IR.Analyze("")
    eq(#blank_nodes, 0, "empty carrier nodes")
    eq(blank_err, nil, "empty analysis error")
    eq(#blank.syntax.Statements(blank.syntax.root),0,"empty native statement sequence")
    local empty = assert(discover(registry(adapter("empty", function()
        return result()
    end)), " -- comment only"))
    eq(#empty.common.source.analysis.statements,0,"comment-only file has no statements")
    eq(empty.adapter_contexts.empty.all, true, "empty Match retains context")
    eq(#empty.units, 0, "empty Match is not an error")
    local host = assert(discover(registry(), "Call()", nil, { host_calls = { Call = true } }))
    eq(host.common.source.analysis.nodes[1].carrier, "host", "analysis options forwarded")

    reject(nil, "unsupported", "match", "registry required")
    reject({}, "unsupported", "match", "enumeration missing")
    reject({ Discoveries = function() error("enumeration failed") end },
        "unsupported", "match", "enumeration exception")
    reject({ Discoveries = function() return { [2] = adapter("x", hook) } end },
        "unsupported", "match", "sparse enumeration")
    local dup = adapter("dup", hook)
    reject({ Discoveries = function() return { dup, dup } end },
        "ownership", "match", "duplicate enumerated Id")
    local invalid = adapter("invalid", hook)
    invalid.Match = nil
    reject({ Discoveries = function() return { invalid } end },
        "unsupported", "match", "contract rechecked")
    reject(registry(), "unsupported", "analyze", "common file required", "G=1", {})
    local bad_source,bad_error=FileMatch.Discover(registry(),42,{file="F.lua"})
    eq(bad_source,nil,"complete source type required")
    eq(bad_error.phase,"analyze","source type diagnosed at Match input")
    reject(registry(), "unsupported", "analyze", "common metatable", "G=1",
        setmetatable({ file = "F.lua" }, { __index = hook }))

    local function bad(value, label)
        reject(registry(adapter("bad", function() return value end)),
            "unsupported", "match", label)
    end
    bad(false, "non-table result")
    bad(setmetatable({}, { __index = hook }), "result metatable")
    bad({ units = {}, claims = {} }, "missing file context")
    bad(result({ [2] = unit("x") }), "sparse units")
    bad(result({ named = unit("x") }), "extra array key")
    bad(result({ false }), "invalid unit")
    bad(result({ setmetatable(unit("x"), { __index = hook }) }), "unit metatable")
    local meta = unit("x")
    meta.source_ranges = setmetatable(meta.source_ranges, { __index = hook })
    bad(result({ meta }), "ranges metatable")
    meta = unit("x")
    meta.source_ranges[1] = setmetatable(meta.source_ranges[1], { __index = hook })
    bad(result({ meta }), "range metatable")
    bad(result({ unit("x") }, { setmetatable(claim("s", "x"), { __index = hook }) }),
        "claim metatable")
    reject(registry(adapter("duplicate", function()
        return result({ unit("x") }, { claim("s", "x"), claim("s", "x") })
    end)), "ownership", "match", "duplicate claim")
    local u = unit("x"); u.key = ""; bad(result({ u }), "empty unit key")
    u = unit("x"); u.carrier = false; bad(result({ u }), "invalid carrier")
    u = unit("x"); u.context = nil; bad(result({ u }), "missing unit context")
    u = unit("x"); u.source_ranges = {}; bad(result({ u }), "empty ranges")
    u = unit("x"); u.source_ranges[3] = { first = 1, last = 1 }
    bad(result({ u }), "sparse ranges")
    for _, range in ipairs({
        { first = 0, last = 1 }, { first = 2, last = 1 },
        { first = 1, last = 99 }, { first = 1.5, last = 2 },
        { first = 0/0, last = 2 }, { first = 1, last = math.huge },
    }) do
        u = unit("x"); u.source_ranges = { range }; bad(result({ u }), "invalid range bounds")
    end
    bad(result({ unit("x") }, { [2] = claim("s", "x") }), "sparse claims")
    bad(result({ unit("x") }, { claim("s", "unknown") }), "claim of absent unit")
    bad(result({ unit("x") }, { claim("s", "x", "unknown") }), "unknown claim kind")
    bad(result({ unit("x") }, { claim("", "x") }), "empty semantic key")

    reject(registry(adapter("x", function() return result({ unit("same"), unit("same") }) end)),
        "ownership", "match", "duplicate same-adapter unit")
    reject(registry(adapter("x", function() return result({ unit("same") }) end),
        adapter("y", function() return result({ unit("same") }) end)),
        "ownership", "match", "duplicate cross-adapter unit")
    reject(registry(adapter("x", function()
        return result({ unit("x"), unit("y") }, { claim("slot", "x"), claim("slot", "y") })
    end)), "ownership", "match", "same-adapter semantic conflict")
    local conflict = reject(registry(adapter("x", function()
        return result({ unit("x") }, { claim("slot", "x") })
    end), adapter("y", function()
        return result({ unit("y") }, { claim("slot", "y") })
    end)), "ownership", "match", "cross-adapter semantic conflict")
    eq(conflict.file, "F.lua", "ownership error file")
    eq(conflict.unit_key, "y", "ownership error unit")

    reject(registry(adapter("throw", function() error("Match exploded") end)),
        "unsupported", "match", "Match exception")
    reject(registry(adapter("nil", function() return nil, "declined" end)),
        "unsupported", "match", "nil is failure, not empty Match")
    local structured = reject(registry(adapter("error", function()
        return nil, { code = "ambiguous", message = "two layouts", file = "wrong",
            phase = "commit", unit_key = "u" }
    end)), "ambiguous", "match", "adapter structured failure")
    eq(structured.file, "F.lua", "orchestrator supplies error file")
    eq(structured.unit_key, "u", "adapter unit error retained")
    reject(registry(adapter("objecterror", function()
        return nil, setmetatable({}, { __tostring = hook })
    end)), "unsupported", "match", "error conversion avoids metamethod")
    local shared_facts=assert(Source.Build("G=1"))
    local previous_analyze,previous_build=IR.Analyze,Source.Build
    IR.Analyze=function() error("Match must not analyze source") end
    Source.Build=function() error("Match must not build source") end
    local analysis_ok,analysis_result=pcall(FileMatch.Discover,registry(),shared_facts,{file="F.lua"})
    IR.Analyze,Source.Build=previous_analyze,previous_build
    assert(analysis_ok,analysis_result);assert(analysis_result)
    eq(analysis_result.common.source,shared_facts,"Match reuses validated source without hidden analysis")
    local foreign,foreign_error=FileMatch.Discover(registry(),shared_facts,{file="F.lua",source={}})
    eq(foreign,nil,"foreign common source refused")
    eq(foreign_error.code,"ownership","source provenance diagnostic")

    local touched = false
    local old_effect = _G.SIDE_EFFECT
    _G.SIDE_EFFECT = function() touched = true end
    local execution_ok, execution_error = pcall(discover, registry(), "SIDE_EFFECT()")
    _G.SIDE_EFFECT = old_effect
    assert(execution_ok, execution_error)
    eq(touched, false, "candidate top-level call never executed")
    print(string.format("[SpellHotReload file Match] %d passed, 0 failed", passed))
    return { passed = passed, failed = 0 }
end

return M
