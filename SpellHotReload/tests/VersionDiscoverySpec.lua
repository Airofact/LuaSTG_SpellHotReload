-- Version services consume the SAME complete discovery, never re-Match it.
-- Only miniature synthetic first-load files execute; never game-generated code.
local M = {}
function M.run()
    local Driver = require("SpellHotReload.Driver")
    local Card = require("SpellHotReload.Card")
    local Cards = require("SpellHotReload.CardVersions")
    local Source = require("SpellHotReload.FunctionPlan")
    local Load = require("SpellHotReload.AnchorLoad")
    local Capture = require("SpellHotReload.LoadVersions")
    local Anchor = require("SpellHotReload.Anchor")
    local Compose = require("SpellHotReload.Compose")
    local IR = require("SpellHotReload.TopLevelIR")
    local Binding = require("SpellHotReload.Binding")
    local passed, failed, failures = 0, 0, {}
    local function eq(a,b,label)
        if a==b then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function list(a,b,label) eq(table.concat(a,","),b,label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function refuses(v,e,code,label)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        eq(e and e.code,code,label.." code")
    end
    local function copy(v) local r={};for k,x in next,v do r[k]=x end;return r end
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,n in ipairs(callbacks) do defaults[n]=function() end end
    local globals={"boss","_editor_class","_tmp_sc","VERSION_DISCOVERY_EFFECT"}
    local saved={};for _,n in ipairs(globals) do saved[n]=rawget(_G,n) end
    local old_join,old_set,old_jit=debug.upvaluejoin,debug.setupvalue,rawget(_G,"jit")
    local old_analyze,old_binding,old_match=IR.Analyze,Binding.Analyze,Card.Match
    local source=[[
local state=4
local function helper(n) return state+n end
local function other(n) return n+100 end
_editor_class["K"].cards={}
_tmp_sc=boss.card.New("same",1,2,3,4)
function _tmp_sc:init(n) return helper(n) end
table.insert(_editor_class["K"].cards,_tmp_sc)
_tmp_sc=boss.card.New("same",1,2,3,4)
function _tmp_sc:init(n) return helper(n)+10 end
table.insert(_editor_class["K"].cards,_tmp_sc)
_editor_class["L"].cards={}
_tmp_sc=boss.card.New("same",1,2,3,4)
function _tmp_sc:init(n) return other(n) end
table.insert(_editor_class["L"].cards,_tmp_sc)
VERSION_DISCOVERY_EFFECT()
]]
    local effects=0
    _G.VERSION_DISCOVERY_EFFECT=function() effects=effects+1 end
    _G._editor_class={K={},L={}}
    _G.boss={card={New=function(name)
        local card={name=name,is_combat=true}
        for _,n in ipairs(callbacks) do card[n]=defaults[n] end
        return card
    end}}
    local ok,problem=pcall(function()
        local entry=must(Load.Capture(source,{name="Discovery_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Discovery_Boss.lua"
        if not old_join then debug.upvaluejoin=function() error("presence-only fixture") end end
        local capture=must(Capture.Capture(entry,"session",_editor_class,defaults))
        local state=capture.snapshot
        local keya,keyb,keyc="card:1:K:1","card:1:K:2","card:1:L:1"
        local a,b,c=state.units[keya].card,state.units[keyb].card,state.units[keyc].card
        local candidate=source:gsub("state%+n","state+n+1")
            :gsub("helper%(n%) end","helper(n)+20 end",1)
            :gsub("helper%(n%)%+10","helper(n)+30")
            :gsub("n%+100","n+200")
        local driver=Driver.New()
        assert(driver:RegisterDiscovery(Card))
        local function discover(bytes,base)
            return must(driver:Discover(base.file,bytes,{session_id=base.session_id,
                registry_entry=base.entry,loaded_source=base.loaded_source,
                base_revision=base.revision,published_units=base,candidate_generation=3})).snapshot
        end
        local snapshot=discover(candidate,state)
        local legacy=must(Cards.Compare(state,candidate))
        local analyzes,matches,binding_calls,joins,writes,flushes=0,0,0,0,0,0
        IR.Analyze=function(content,...)
            if content==candidate then analyzes=analyzes+1 end
            return old_analyze(content,...)
        end
        Binding.Analyze=function(...) binding_calls=binding_calls+1;return old_binding(...) end
        Card.Match=function(...) matches=matches+1;return old_match(...) end
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        _G.jit={flush=function() flushes=flushes+1;error("premature flush") end}
        local scan=must(Source.InspectDiscovery(snapshot))
        eq(scan.analysis,snapshot.analysis,"shared analysis identity")
        eq(scan.bindings,snapshot.bindings,"shared binding identity")
        eq(analyzes,0,"Inspect does not re-analyze candidate")
        eq(binding_calls,0,"Inspect does not rebuild bindings")
        local diff=must(Cards.CompareDiscovery(state,snapshot))
        eq(analyzes,0,"all version stages reuse candidate analysis")
        eq(matches,0,"version discovery never re-Matches")
        eq(binding_calls,1,"only immutable loaded baseline is re-analyzed")
        eq(diff.discovery,snapshot,"full discovery retained by card report")
        eq(diff.functions.discovery,snapshot,"function report shares discovery")
        eq(diff.functions.prepared.content,candidate,"complete candidate bytes")
        list(diff.changed,table.concat(legacy.changed,","),"legacy changed equivalence")
        list(diff.affected,table.concat(legacy.affected,","),"legacy affected equivalence")
        list(diff.functions.changed,"helper,other","complete function diff")
        eq(diff.by_key[keya].callbacks.init.signature,legacy.by_key[keya].callbacks.init.signature,
            "same current callback signature")
        eq(diff.by_key[keyb].callbacks.init.signature,legacy.by_key[keyb].callbacks.init.signature,
            "same unselected callback signature")
        eq(diff.by_key[keyc].action,legacy.by_key[keyc].action,"same unrelated impact")
        local selected=must(Cards.Select(diff,{keya}))
        eq(selected.discovery,snapshot,"selection retains full discovery")
        eq(selected.functions.discovery,snapshot,"nested selection retains discovery")
        list(selected.selected,keya,"published card keys not class keys")
        list(selected.pending,keyb,"other wrapper remains pending")
        list(selected.functions.selected,"helper","only necessary helper")
        list(selected.functions.pending,"other","other branch remains pending")
        eq(snapshot.by_key["card:K"].unit.context.layout[2].callbacks.init~=nil,true,
            "unselected discovery preserved")
        eq(#snapshot.entries,2,"all classes retained")
        eq(#selected.publications,1,"one explicit callback publication")
        local proposed=must(Cards.Next(selected))
        local renamed_legacy,legacy_error=Cards.Compare(state,candidate:gsub('New%("same"','New("renamed"',1))
        refuses(renamed_legacy,legacy_error,"ambiguous","legacy gsub multiple returns")
        eq(state.revision,0,"no version installed during preparation")
        eq(proposed.revision,1,"proposed aggregate revision")
        eq(proposed.units[keyb].callbacks.init.fn,b.init,"unselected old identity")
        eq(a.init,state.units[keya].callbacks.init.fn,"no premature publication")
        eq(Anchor.Get(entry,"helper"),state.functions.units.helper.fn,"no premature cell write")
        eq(joins,0,"zero joins");eq(writes,0,"zero writes");eq(flushes,0,"zero flushes")
        eq(effects,1,"candidate top-level effect not replayed")
        for _,field in ipairs({"file","session_id","registry_entry","loaded_source",
            "base_revision","published_units"}) do
            local bad=copy(snapshot);bad.common=copy(snapshot.common);bad.common[field]=false
            local v,e=Cards.CompareDiscovery(state,bad)
            refuses(v,e,"stale","scope "..field)
        end
        local bad=copy(snapshot);bad.common=copy(snapshot.common);bad.common.content=candidate.." "
        local v,e=Cards.CompareDiscovery(state,bad);refuses(v,e,"unsupported","wrong bytes")
        v,e=Source.InspectDiscovery(bad);refuses(v,e,"unsupported","Inspect bytes")
        bad=copy(snapshot);bad.analysis=copy(snapshot.analysis);bad.analysis.source_offset=3
        bad.common=copy(snapshot.common);bad.common.analysis=bad.analysis
        v,e=Cards.CompareDiscovery(state,bad);refuses(v,e,"unsupported","wrong BOM offset")
        bad=copy(snapshot);bad.adapter_contexts={}
        v,e=Cards.CompareDiscovery(state,bad);refuses(v,e,"unsupported","missing registered Card")
        bad=copy(snapshot);bad.entries={snapshot.entries[1]}
        v,e=Cards.CompareDiscovery(state,bad);refuses(v,e,"unsupported","filtered discovery")
        bad=copy(snapshot);bad.by_key={}
        v,e=Cards.CompareDiscovery(state,bad);refuses(v,e,"ownership","wrong entry index")
        local touched=0
        local hostile=setmetatable({},{__index=function() touched=touched+1 end})
        v,e=Cards.CompareDiscovery(state,hostile);refuses(v,e,"stale","snapshot metatable")
        v,e=Source.InspectDiscovery(hostile);refuses(v,e,"unsupported","source metatable")
        eq(touched,0,"metatables never invoked")
        v,e=Cards.Select(diff,{"card:K"});refuses(v,e,"unsupported","class key not publication key")
        IR.Analyze,Binding.Analyze,Card.Match=old_analyze,old_binding,old_match
        local bom="\239\187\191"..candidate
        local bom_snapshot=discover(bom,state)
        local bom_diff=must(Cards.CompareDiscovery(state,bom_snapshot))
        local bom_legacy=must(Cards.Compare(state,bom))
        list(bom_diff.changed,table.concat(bom_legacy.changed,","),"BOM changed equivalence")
        eq(bom_diff.by_key[keya].callbacks.init.signature,bom_legacy.by_key[keya].callbacks.init.signature,
            "BOM callback equivalence")
        local renamed=candidate:gsub('New%("same"','New("renamed"',1)
        v,e=Cards.CompareDiscovery(state,discover(renamed,state))
        refuses(v,e,"ambiguous","fixed layout rename still refused")
        local former=a.init;a.init=function() end
        v,e=Cards.CompareDiscovery(state,snapshot);refuses(v,e,"stale","external callback replacement")
        a.init=former
        debug.upvaluejoin,debug.setupvalue,_G.jit=old_join,old_set,old_jit
        if old_join then
            -- TEST ONLY manual publication; transaction coverage remains CardCommitSpec.
            for _,join in ipairs(selected.joins) do
                debug.upvaluejoin(join.fn,join.index,join.anchor,join.donor)
            end
            for _,write in ipairs(selected.writes) do must(Anchor.Set(entry,write.name,write.value)) end
            for _,pub in ipairs(selected.publications) do rawset(pub.target,pub.key,pub.value) end
            local next_snapshot=discover(candidate,proposed)
            local again=must(Cards.CompareDiscovery(proposed,next_snapshot))
            list(again.changed,keyb,"partial publication leaves wrapper pending")
            list(again.functions.changed,"other","partial publication leaves helper pending")
            local second=must(Cards.Select(again,{keyb}))
            eq(#second.writes,0,"published helper not re-written")
            eq(#second.publications,1,"next wrapper alone publishes")
            eq(again.discovery,next_snapshot,"next actual baseline discovery retained")
            v,e=Cards.CompareDiscovery(proposed,snapshot)
            refuses(v,e,"stale","old baseline snapshot refused")
        else
            print("VersionDiscoverySpec: real joins/partial publication not run (Lua5.1)")
        end
    end)
    IR.Analyze,Binding.Analyze,Card.Match=old_analyze,old_binding,old_match
    debug.upvaluejoin,debug.setupvalue,_G.jit=old_join,old_set,old_jit
    for _,n in ipairs(globals) do rawset(_G,n,saved[n]) end
    assert(ok,problem)
    print(string.format("VersionDiscoverySpec: %d passed / %d failed",passed,failed))
    for _,f in ipairs(failures) do print("  FAIL: "..f) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
