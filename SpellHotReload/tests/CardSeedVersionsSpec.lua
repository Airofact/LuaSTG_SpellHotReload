-- Card-owned first-load aggregation; genuine miniature files only.
-- Lua5.1 uses presence-only capability for read-only metadata, never sharing proof.
local M = {}
function M.run()
    local Card = require("SpellHotReload.Card")
    local Compat = require("SpellHotReload.LoadVersions")
    local Load = require("SpellHotReload.AnchorLoad")
    local Source = require("SpellHotReload.FunctionPlan")
    local Functions = require("SpellHotReload.FunctionVersions")
    local Cards = require("SpellHotReload.CardVersions")
    local passed,failed,failures=0,0,{}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v,e end
    local function pack(...) return {n=select("#",...),...} end
    local seed,inspect,fseed,match,owners,cseed =
        Card.SeedVersions,Source.Inspect,Functions.Seed,Card.Match,Card.CaptureOwnership,Cards.Seed
    local keys={"boss","_editor_class","_tmp_sc","_seed_versions_runs","_seed_versions_api","jit"}
    local globals={};for _,key in ipairs(keys) do globals[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local traps,mutations=0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("hostile index") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end})
    local names={"before","init","frame","render","beforedel","del","after"}
    local source=table.concat({
        "local state=4","local flag=false","local empty",
        "local function helper(n) return state+n end",
        "local function setter(v) state=v end",
        "local function reader() return state,flag,empty end",
        "local alias=helper",
        "_seed_versions_runs=_seed_versions_runs+1",
        "_seed_versions_api={set=setter,read=reader}",
        "_editor_class['K'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end",
        "function _tmp_sc:frame(n) return alias(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n)+100 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    local function restore()
        Card.SeedVersions,Source.Inspect,Functions.Seed,Card.Match,Card.CaptureOwnership,Cards.Seed =
            seed,inspect,fseed,match,owners,cseed
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        rawset(_G,"jit",globals.jit)
    end
    local function fixture()
        restore()
        if not join then debug.upvaluejoin=function() error("presence-only, never join") end end
        _seed_versions_runs=0;_editor_class={K={}}
        local defaults={}
        for _,name in ipairs(names) do defaults[name]=function() end end
        boss={card={_default_card=defaults,New=function(label)
            local card={name=label,is_combat=true}
            for name,fn in next,defaults do card[name]=fn end
            return card
        end},move={New=function() return {is_combat=false} end}}
        local entry=must(Load.Capture(source,{name="SeedAdapter_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="SeedAdapter_Boss.lua"
        return entry,_editor_class,defaults
    end
    local function equivalent(a,b,entry,classes,label)
        eq(a.kind,b.kind,label.." kind");eq(a.version,b.version,label.." version")
        eq(a.classes,classes,label.." explicit registry")
        local x,y=a.snapshot,b.snapshot
        eq(x.entry,entry,label.." original entry");eq(x.anchor,entry.anchor,label.." original anchor")
        for _,field in ipairs({"revision","session_id","file","loaded_source"}) do eq(x[field],y[field],label.." "..field) end
        eq(table.concat(x.order,","),table.concat(y.order,","),label.." complete owner order")
        eq(#a.ownership,#b.ownership,label.." complete lists")
        for i,owner in ipairs(a.ownership) do
            local other=b.ownership[i]
            eq(owner.class,other.class,label.." class "..i);eq(owner.list,other.list,label.." list "..i)
            eq(#owner.slots,#other.slots,label.." slots "..i)
            for j,card in ipairs(owner.slots) do eq(card,other.slots[j],label.." slot "..i..":"..j) end
        end
        for _,key in ipairs(x.order) do
            local unit,other=x.units[key],y.units[key]
            eq(unit.card,other.card,label.." card "..key);eq(unit.definition_version,other.definition_version,label.." version "..key)
            for _,name in ipairs(names) do
                eq(unit.callbacks[name].fn,other.callbacks[name].fn,label.." callback "..key..":"..name)
                eq(unit.callbacks[name].definition_version,other.callbacks[name].definition_version,label.." callback version "..key..":"..name)
            end
        end
        for _,name in ipairs(x.functions.names) do
            eq(x.functions.units[name].fn,rawget(entry.map,name),label.." original trailer "..name)
            eq(x.functions.units[name].fn,y.functions.units[name].fn,label.." compatibility trailer "..name)
        end
    end
    local function refusal(v,e,code,label)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then
            eq(e.code,code,label.." code");test(type(e.message)=="string",label.." safe message")
        end
    end
    local held_module,held_preload
    local version_key="SpellHotReload.LoadVersions"
    local ok,problem=pcall(function()
        test(type(seed)=="function","adapter seeder exported")
        eq(Compat.Kind,"SpellHotReload.LoadVersions","compatibility kind")
        eq(Compat.Version,1,"compatibility version")
        local entry,classes,defaults=fixture()
        local old_init,old_helper=classes.K.cards[2].init,entry.map.helper
        debug.setupvalue=function() mutations=mutations+1;error("seed writes") end
        debug.upvaluejoin=function() mutations=mutations+1;error("seed joins") end
        rawset(_G,"jit",{flush=function() mutations=mutations+1;error("seed flushes") end})
        local direct=must(Card.SeedVersions(entry,"seed:session",classes,defaults))
        local compat=must(Compat.Capture(entry,"seed:session",classes,defaults))
        equivalent(direct,compat,entry,classes,"real seed")
        eq(direct.snapshot.revision,0,"aggregate first revision")
        eq(direct.snapshot.functions.revision,0,"local first revision")
        eq(#direct.snapshot.order,2,"all combat owners")
        eq(#direct.ownership[1].slots,3,"placeholder included")
        eq(direct.ownership[1].slots[1],classes.K.cards[1],"placeholder identity")
        test(direct~=compat and direct.snapshot~=compat.snapshot,"no module cache")
        local saved_default=direct.snapshot.defaults.after
        defaults.after=function() end
        eq(direct.snapshot.defaults.after,saved_default,"default snapshot retained")
        defaults.after=saved_default
        _seed_versions_api.set(nil)
        local again=must(Card.SeedVersions(entry,"seed:session",classes,defaults))
        eq(again.snapshot.functions.units.helper.fn,old_helper,"nil state does not forge a new function")
        local state,flag,empty=_seed_versions_api.read()
        eq(state,nil,"nil state retained");eq(flag,false,"false state retained");eq(empty,nil,"empty state retained")
        _seed_versions_api.set(false)
        must(Card.SeedVersions(entry,"seed:session",classes,defaults))
        eq(select(1,_seed_versions_api.read()),false,"false setter retained")
        eq(classes.K.cards[2].init,old_init,"no callback publication")
        eq(entry.map.helper,old_helper,"original trailer map unchanged")
        eq(_seed_versions_runs,1,"no source replay")
        eq(mutations,0,"no seed mutators")
        -- Production is independent of the compatibility module, even cold.
        held_module,held_preload=package.loaded[version_key],package.preload[version_key]
        package.loaded[version_key]=nil
        package.preload[version_key]=function() error("legacy metadata facade forbidden") end
        local captured,reason=Card.CaptureVersions(entry,"seed:session")
        test(captured~=nil,"production does not depend on compatibility facade")
        eq(reason,nil,"production facade-independent success")
        if captured then equivalent(captured,direct,entry,classes,"production seed") end
        package.loaded[version_key],package.preload[version_key]=held_module,held_preload
        held_module,held_preload=nil,nil
        entry,classes,defaults=fixture()
        set(entry.anchor,entry.slots.helper,function() return 99 end)
        local v,e=Card.SeedVersions(entry,"seed:session",classes,defaults)
        refusal(v,e,"stale","external function setter not reseeded")
        eq(entry.map.helper~=select(2,get(entry.anchor,entry.slots.helper)),true,"trailer is history not live values")
        entry,classes,defaults=fixture()
        entry.map.helper=function() end
        v,e=Card.SeedVersions(entry,"seed:session",classes,defaults)
        refusal(v,e,"stale","forged trailer identity")
        for _,case in ipairs({
            {function(x) x.reloadable=false end,"unsupported"},
            {function(x) x.missing=true end,"unsupported"},
            {function(_,c) c.K.cards[4]={} end,"ownership"},
            {function(_,c) c.K.cards[3]=c.K.cards[2] end,"ownership"},
        }) do
            entry,classes,defaults=fixture();case[1](entry,classes)
            v,e=Card.SeedVersions(entry,"seed:session",classes,defaults)
            refusal(v,e,case[2],"invalid first-load entry")
        end
        entry,classes,defaults=fixture()
        for _,inputs in ipairs({
            {hostile,"seed:session",classes,defaults},
            {entry,"seed:session",hostile,defaults},
            {entry,"seed:session",classes,hostile},
        }) do
            v,e=Card.SeedVersions(unpack(inputs))
            refusal(v,e,"unsupported","hostile capture input")
        end
        -- Compatibility is a forwarding entry, not a second metadata algorithm.
        local marker,tail={},{}
        Card.SeedVersions=function(a,b,c,d)
            eq(a,entry,"compat entry exact input");eq(b,"compat:session","compat explicit session")
            eq(c,classes,"compat explicit classes");eq(d,defaults,"compat explicit defaults")
            return marker,nil,tail,nil
        end
        local results=pack(Compat.Capture(entry,"compat:session",classes,defaults))
        eq(results.n,4,"compat return arity retained");eq(results[1],marker,"compat result identity")
        eq(results[3],tail,"compat tail identity")
        -- Each pure dependency is consumed in order, and every refusal is exact.
        for stop=0,5 do
            restore()
            local log={}
            local fake={file="Fake_Boss.lua",loaded_source="loaded bytes",reloadable=true,map={helper=old_helper}}
            local defs={helper={}}
            local analysis,initial_functions,matched,initial_owners,ownership,aggregate
            analysis,initial_functions,matched,initial_owners,ownership,aggregate={},{},{},{},{},{}
            local function step(i)
                log[#log+1]=i
                if stop==i then return nil,marker end
                return true
            end
            Source.Inspect=function(bytes)
                eq(bytes,fake.loaded_source,"inspect loaded bytes")
                if not step(1) then return nil,marker end
                return {definitions=defs,analysis=analysis}
            end
            Functions.Seed=function(e,s,initial)
                eq(e,fake,"function seed original entry");eq(s,"explicit:session","function seed explicit session")
                eq(initial.helper,old_helper,"function seed original map value")
                if not step(2) then return nil,marker end
                return initial_functions
            end
            Card.Match=function(a,common)
                eq(a,analysis,"Match shares complete analysis");eq(common.content,fake.loaded_source,"Match complete loaded bytes")
                if not step(3) then return nil,marker end
                return matched
            end
            Card.CaptureOwnership=function(m,c,e)
                eq(m,matched,"ownership complete Match");eq(c,classes,"ownership explicit classes")
                eq(e,fake,"ownership original entry")
                if not step(4) then return nil,marker end
                return initial_owners,ownership
            end
            Cards.Seed=function(f,o,d)
                eq(f,initial_functions,"aggregate original functions");eq(o,initial_owners,"aggregate complete owners")
                eq(d,defaults,"aggregate explicit defaults")
                if not step(5) then return nil,marker end
                return aggregate
            end
            v,e=Card.SeedVersions(fake,"explicit:session",classes,defaults)
            local last=stop==0 and 5 or stop
            eq(#log,last,"refusal short-circuits "..stop)
            for i=1,last do eq(log[i],i,"seed dependency order "..stop..":"..i) end
            if stop==0 then
                eq(v.snapshot,aggregate,"aggregate output exact identity")
                eq(v.ownership,ownership,"ownership output exact identity")
                eq(v.classes,classes,"classes output exact identity")
                eq(v.kind,Compat.Kind,"output compatibility marker");eq(v.version,Compat.Version,"output compatibility version")
            else
                eq(v,nil,"dependency refusal "..stop);eq(e,marker,"dependency error identity "..stop)
            end
        end
        eq(traps,0,"no hostile metamethod")
    end)
    if held_module or held_preload then package.loaded[version_key],package.preload[version_key]=held_module,held_preload end
    restore()
    for _,key in ipairs(keys) do rawset(_G,key,globals[key]) end
    if not ok then error(problem) end
    for _,label in ipairs(failures) do print("FAIL CardSeedVersionsSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
