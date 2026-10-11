-- Full-file discovery/selection via the existing Driver; no engine required.
local Driver = require("SpellHotReload.Driver")
local Registry = require("SpellHotReload.NodeRegistry")
local Index = require("SpellHotReload.UnitIndex")
local IR = require("SpellHotReload.Source.TopLevelIR")
local Card = require("SpellHotReload.Adapters.Card.Card")
local Callbacks = require("SpellHotReload.Adapters.Card.CardCallbacks")
local Lexer = require("SpellHotReload.Source.Lexer")
local M = {}
function M.run(options)
    local DriverAPI = options and options.driver or Driver
    local passed, failed, failures = 0, 0, {}
    local function eq(actual, expected, label)
        if actual == expected then passed = passed + 1
        else failed = failed + 1; failures[#failures+1] = label end
    end
    local function reject(value, err, phase, label)
        eq(value, nil, label .. " refuses")
        eq(type(err), "table", label .. " structured")
        eq(err and err.phase, phase, label .. " phase")
    end
    local calls, analysis_calls, shared, shared_common = {}, 0
    local function adapter(id, specs, claim_key)
        return {
            ContractVersion=2, Id=id,
            Match=function(analysis, common)
                calls[#calls+1] = id
                if shared then
                    eq(analysis, shared, "one shared analysis " .. id)
                    eq(common, shared_common, "one shared common " .. id)
                else shared, shared_common = analysis, common end
                local units, claims = {}, {}
                for _, s in ipairs(specs) do
                    units[#units+1] = {key=s[1], carrier=id,
                        source_ranges={{first=s[2], last=s[3]}}, context={tag=s[1]}}
                    claims[#claims+1] = {kind="definition", key=claim_key or s[1], unit_key=s[1]}
                end
                return {units=units, claims=claims, context={all=true, id=id}}
            end,
            Locate=function() error("Locate forbidden") end,
            Inject=function() error("Inject forbidden") end,
            Commit=function() error("Commit forbidden") end,
            Restart=function() error("Restart forbidden") end,
        }
    end
    local driver = DriverAPI.New()
    local z = adapter("z", {{"later",5,7}})
    local a = adapter("a", {{"early",1,3}})
    eq(driver:RegisterDiscovery(z), true, "register z")
    eq(driver:RegisterDiscovery(a), true, "register a")
    eq(driver:RegisterDiscovery(a), false, "duplicate Id refused")
    eq(#driver.adapters:Carriers(), 0, "discovery does not register legacy carrier")
    local live_ref, supplied = {}, {session_id="S", candidate_generation=3, base_revision=7}
    supplied.registry_entry = live_ref
    local old_analyze = IR.Analyze
    IR.Analyze = function(...) analysis_calls=analysis_calls+1; return old_analyze(...) end
    local ok, discovery = pcall(driver.Discover, driver, "F.lua", "G=1 H=2", supplied)
    IR.Analyze = old_analyze
    assert(ok, discovery)
    assert(discovery)
    eq(analysis_calls, 1, "one analysis across registered adapters")
    eq(table.concat(calls, ","), "a,z", "all adapters enumerated")
    eq(discovery.kind, "SpellHotReload.Driver.Discovery", "discovery kind")
    eq(discovery.owner, driver, "discovery owner")
    eq(discovery.file, "F.lua", "requested file")
    eq(discovery.content, "G=1 H=2", "full bytes retained")
    eq(discovery.snapshot.common.session_id, "S", "session retained")
    eq(discovery.snapshot.common.candidate_generation, 3, "generation retained")
    eq(discovery.snapshot.common.base_revision, 7, "revision retained")
    eq(discovery.snapshot.common.registry_entry, live_ref, "live reference retained only")
    eq(supplied.file, nil, "caller common not mutated")
    eq(supplied.content, nil, "caller bytes not mutated")
    eq(discovery.index.snapshot, discovery.snapshot, "index bound to snapshot")
    eq(discovery.index.unit_count, 2, "complete index")
    eq(assert(Index.Get(discovery.index, "early")).entry.adapter, a, "adapter ownership retained")
    local selected = assert(driver:SelectDiscovery(discovery, {"later", "early"}))
    eq(selected.kind, "SpellHotReload.Driver.DiscoverySelection", "selection kind")
    eq(selected.discovery, discovery, "selection retains complete discovery")
    eq(#selected.entries, 2, "both explicit units")
    eq(selected.entries[1].unit.key, "early", "source order, not request order")
    eq(selected.entries[2].unit.key, "later", "source order second")
    eq(selected.entries[1], discovery.snapshot.by_key.early, "original entry identity")
    eq(selected.entries[1].context.common, discovery.snapshot.common, "shared context retained")
    eq(selected.entries[1].context.adapter.file, discovery.snapshot.adapter_contexts.a, "file context retained")
    eq(selected.entries[1].context.adapter.unit, selected.entries[1].unit.context, "unit context retained")
    selected.entries[1] = nil
    eq(#discovery.snapshot.entries, 2, "selection array does not modify discovery")
    eq(#assert(driver:SelectDiscovery(discovery, {"early"})).entries, 1, "one selected")
    eq(#discovery.index.list, 2, "unselected unit remains indexed")
    eq(#assert(driver:SelectDiscovery(discovery, {})).entries, 0, "empty explicit selection")
    eq(#calls, 2, "selection does not rerun Match or execution hooks")
    for _, keys in ipairs({{"early","early"},{"absent"},{"early","absent"},{false},
        {[2]="early"}, {named="early"}, {[1]="early",[3]="later"}, {[math.huge]="early"}}) do
        local value, err = driver:SelectDiscovery(discovery, keys)
        reject(value, err, "locate", "invalid selection")
    end
    local nv, ne = driver:SelectDiscovery(discovery, nil)
    reject(nv,ne,"locate","nil selection")
    local v, e = DriverAPI.New():SelectDiscovery(discovery, {"early"})
    reject(v,e,"locate","foreign driver")
    v,e = driver:SelectDiscovery({}, {})
    reject(v,e,"locate","fabricated artifact")
    local touched = 0
    local hostile = setmetatable({}, {__index=function() touched=touched+1 end,
        __tostring=function() touched=touched+1 end})
    v,e = driver:SelectDiscovery(hostile, {})
    reject(v,e,"locate","artifact metatable")
    v,e = driver:SelectDiscovery(discovery, hostile)
    reject(v,e,"locate","keys metatable")
    v,e = driver:Discover("F.lua", "G=1", hostile)
    reject(v,e,"analyze","common metatable")
    eq(touched,0,"metatables not invoked")
    v,e = driver:Discover("F.lua","G=1",{file="other.lua"})
    reject(v,e,"analyze","common file mismatch")
    v,e = driver:Discover("", "G=1")
    reject(v,e,"analyze","empty file")
    v,e = driver:Discover("F.lua", false)
    reject(v,e,"analyze","non-string content")
    local empty_driver = DriverAPI.New()
    eq(#assert(empty_driver:Discover("empty.lua","")).index.list,0,"empty file/registry")
    local legacy = {Locate=function() error("legacy Locate forbidden") end,
        Inject=function() error("legacy Inject forbidden") end,
        Commit=function() error("legacy Commit forbidden") end}
    assert(empty_driver:Register("global",legacy))
    eq(#assert(empty_driver:Discover("legacy.lua","G=1")).index.list,0,"legacy adapters excluded")
    eq(empty_driver:RegisterDiscovery(legacy),false,"legacy cannot enter discovery")
    shared,shared_common = nil,nil
    local conflict = DriverAPI.New()
    assert(conflict:RegisterDiscovery(adapter("a",{{"a",1,3}},"same")))
    assert(conflict:RegisterDiscovery(adapter("b",{{"b",1,3}},"same")))
    v,e = conflict:Discover("F.lua","G=1")
    reject(v,e,"match","semantic conflict")
    eq(e.code,"ownership","conflict not silently resolved")
    shared,shared_common = nil,nil
    local thrown = DriverAPI.New()
    local bad = adapter("bad",{})
    bad.Match=function() error(hostile) end
    assert(thrown:RegisterDiscovery(bad))
    v,e = thrown:Discover("F.lua","G=1")
    reject(v,e,"match","Match exception")
    eq(touched,0,"thrown object not stringified")
    -- Real Card discovery: full file and both classes, independent of practice.
    local source = [[
_editor_class["A"] = Class(boss)
_editor_class["A"].cards = {}
_tmp_sc = boss.card.New("same",1,2,3,4)
function _tmp_sc:init() end
table.insert(_editor_class["A"].cards,_tmp_sc)
_editor_class["B"] = Class(boss)
_editor_class["B"].cards = {}
_tmp_sc = boss.card.New("same",1,2,3,4)
function _tmp_sc:init() end
table.insert(_editor_class["B"].cards,_tmp_sc)
DRIVER_DISCOVERY_EFFECT()
]]
    local old_effect, effects = _G.DRIVER_DISCOVERY_EFFECT, 0
    _G.DRIVER_DISCOVERY_EFFECT = function() effects=effects+1 end
    local card_driver = DriverAPI.New()
    assert(card_driver:RegisterDiscovery(Card))
    local old_lex, lex_calls = Lexer.Tokenize, 0
    Lexer.Tokenize = function(...) lex_calls=lex_calls+1; return old_lex(...) end
    local found, real = pcall(card_driver.Discover,card_driver,"Boss.lua",source)
    Lexer.Tokenize = old_lex
    _G.DRIVER_DISCOVERY_EFFECT = old_effect
    assert(found, real); assert(real)
    eq(lex_calls,1,"one full-file lex for both real Card classes")
    eq(effects,0,"candidate initialization never executed")
    eq(real.index.unit_count,2,"all real card classes discovered")
    local current = assert(card_driver:SelectDiscovery(real,{"card:B"}))
    eq(current.entries[1].adapter,Card,"real card adapter retained")
    eq(current.entries[1].unit.context.class_key,"B","explicit current class selected")
    eq(real.snapshot.by_key["card:A"].unit.context.class_key,"A","other class remains accessible")
    eq(next(Card)~=nil,true,"adapter retained without hook execution")
    lex_calls = 0
    Lexer.Tokenize = function(...) lex_calls=lex_calls+1; return old_lex(...) end
    local bom_ok, bom = pcall(card_driver.Discover,card_driver,"Boss.lua","\239\187\191"..source)
    Lexer.Tokenize = old_lex
    assert(bom_ok,bom); assert(bom)
    eq(lex_calls,1,"one BOM full-file lex across classes")
    eq(bom.content,"\239\187\191"..source,"BOM byte identity retained")
    eq(bom.index.unit_count,2,"BOM real discovery")
    for _,d in ipairs({real,bom}) do
        for _,class in ipairs({"A","B"}) do
            local parsed = assert(Callbacks.Read(d.content,class,d.snapshot.analysis))
            local legacy_read = assert(Callbacks.Read(d.content,class))
            eq(#parsed,#legacy_read,"shared/legacy layout length")
            eq(parsed[1].constructor,legacy_read[1].constructor,"shared/legacy constructor")
            eq(parsed[1].callbacks.init,legacy_read[1].callbacks.init,"shared/legacy callback bytes")
            eq(parsed[1].callback_points.init.first,legacy_read[1].callback_points.init.first,
                "shared/legacy raw definition first byte")
            eq(parsed[1].callback_points.init.last,legacy_read[1].callback_points.init.last,
                "shared/legacy raw definition last byte")
        end
    end
    local parsed, perr = Callbacks.Read(source.."-- changed","A",real.snapshot.analysis)
    eq(parsed,nil,"shared analysis cannot come from different bytes")
    eq(type(perr),"string","shared source mismatch diagnostic")
    parsed = Callbacks.Read(source,"A",bom.snapshot.analysis)
    eq(parsed,nil,"shared offset must match actual BOM")
    parsed = Callbacks.Read(source,"A",hostile)
    eq(parsed,nil,"shared analysis metatable rejected")
    eq(touched,0,"shared analysis validation does not invoke metatable")
    local removed = assert(card_driver:Discover("Boss.lua",""))
    local comparison = assert(Index.Compare(real.index,removed.index))
    eq(comparison.counts.removed_units,2,"unmatched old units enter deletion comparison")
    eq(comparison.counts.added_units,0,"no invented replacement units")
    print(string.format("[SpellHotReload driver discovery] %d passed, %d failed",passed,failed))
    for _,f in ipairs(failures) do print("  FAIL: "..f) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
