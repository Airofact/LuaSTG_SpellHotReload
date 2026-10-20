-- Shared complete facts -> real Local/Card discovery -> Current -> ONE transaction.
-- Candidate chunks never execute. Every later Prepare owns a NEW discovery;
-- source facts alone may be reused across operations, never live authorization.
local M={}
local serial=0
function M.run()
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Binding=require("SpellHotReload.Source.Binding")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Dependencies=require("SpellHotReload.Pipeline.Dependencies")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local passed,failed,failures=0,0,{}
    local controllers={}
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
    local function view(d,owner)
        for _,group in ipairs(d.reconciliation.groups) do if group.owner==owner then return group.view end end
        error("missing real owner view")
    end
    local function fragment(p,owner)
        for _,record in ipairs(p.entries) do if record.owner==owner then return record.fragment end end
        error("missing real owner fragment")
    end
    local function state(snapshot,owner)
        for _,group in ipairs(snapshot.owners) do if group.owner==owner then return group.state end end
        error("missing actual owner state")
    end
    local function seal(p)
        local fragments={};for _,record in ipairs(p.entries) do fragments[#fragments+1]=record.fragment end
        return must(Guard.Seal(p.operation,fragments))
    end
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,n in ipairs(callbacks) do defaults[n]=function() end end
    local globals={"boss","_editor_class","_tmp_sc","VERSION_DISCOVERY_EFFECT"}
    local saved={};for _,n in ipairs(globals) do saved[n]=rawget(_G,n) end
    local old_join,old_set,old_jit=debug.upvaluejoin,debug.setupvalue,rawget(_G,"jit")
    local old_build,old_analyze,old_binding=Source.Build,IR.Analyze,Binding.Analyze
    local old_local_match,old_card_match=Local.Match,Card.Match
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
    local builds,analyzes,bindings,local_matches,card_matches=0,0,0,0,0
    local joins,writes,flushes,discovery_count=0,0,0,0
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug))) -- Real LuaJIT capability required.
        _G.VERSION_DISCOVERY_EFFECT=function() effects=effects+1 end
        local classes={K={},L={}};_G._editor_class=classes
        _G.boss={card={New=function(name)
            local card={name=name,is_combat=true}
            for _,n in ipairs(callbacks) do card[n]=defaults[n] end
            return card
        end}}
        local entry=must(Load.Capture(source,{name="Discovery_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Discovery_Boss.lua"
        serial=serial+1
        local f=must(Planning.Capture(entry,"VersionDiscoverySpec:"..serial,classes,defaults))
        local capture=f.capture;local initial=capture.snapshot
        local initial_local,initial_card=state(initial,Local),state(initial,Card)
        local keya,keyb,keyc="card:1:K:1","card:1:K:2","card:1:L:1"
        local a,b,c=initial_card.units[keya].card,initial_card.units[keyb].card,initial_card.units[keyc].card
        local candidate=source:gsub("state%+n","state+n+1")
            :gsub("helper%(n%) end","helper(n)+20 end",1)
            :gsub("helper%(n%)%+10","helper(n)+30")
            :gsub("n%+100","n+200")
        local bom="\239\187\191"..candidate
        local facts,bom_facts=must(Source.Build(candidate)),must(Source.Build(bom))
        Source.Build=function() builds=builds+1;error("hidden full Build") end
        IR.Analyze=function() analyzes=analyzes+1;error("hidden full parse") end
        Binding.Analyze=function() bindings=bindings+1;error("hidden binding reconstruction") end
        Local.Match=function(...) local_matches=local_matches+1;return old_local_match(...) end
        Card.Match=function(...) card_matches=card_matches+1;return old_card_match(...) end
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        _G.jit={flush=function() flushes=flushes+1;error("premature flush") end}
        local function discover(input,generation)
            local before_local,before_card=local_matches,card_matches
            local d=must(Planning.Discover(f,input,generation))
            discovery_count=discovery_count+1
            eq(local_matches,before_local+1,"one Local Match per NEW discovery")
            eq(card_matches,before_card+1,"one Card Match per NEW discovery")
            eq(d.source,input,"discovery retains complete facts")
            eq(d.snapshot.common.source,input,"common snapshot retains facts")
            eq(view(d,Local).source,input,"Local private view retains facts")
            eq(view(d,Card).source,input,"Card private view retains facts")
            eq(d.snapshot.analysis,nil,"no duplicate snapshot AST")
            eq(d.snapshot.bindings,nil,"no duplicate snapshot bindings")
            eq(#d.snapshot.entries,5,"three Local bindings and two Card classes")
            local carriers={local_count=0,card_count=0}
            for _,item in ipairs(d.snapshot.entries) do
                if item.adapter==Local then carriers.local_count=carriers.local_count+1 end
                if item.adapter==Card then carriers.card_count=carriers.card_count+1 end
            end
            eq(carriers.local_count,3,"state/helper/other all discovered")
            eq(carriers.card_count,2,"both classes discovered")
            return d
        end
        -- Each operation captures its own bytes/generation; preparing BOM input
        -- or another slot must not contaminate the first operation's final read.
        local function refresh(d,slot)
            local input,generation=d.source,d.snapshot.common.generation
            return function()
                local card=classes.K.cards[slot]
                return {capture=capture,snapshot=capture.snapshot,entry=entry,session_id=f.session,
                    classes=classes,content=input.content,generation=generation,
                    binding={class_key="K",card=card,slot=slot,name="same",names={"same","same"},
                        mode="practice",include_previous=false}}
            end
        end
        local function prepare(d,slot)
            local lm,cm=local_matches,card_matches
            local p=must(Planning.Prepare(f,d,{mode="current",refresh=refresh(d,slot)}))
            eq(local_matches,lm,"Prepare never re-Matches Local")
            eq(card_matches,cm,"Prepare never re-Matches Card")
            eq(p.discovery,d,"preparation retains complete discovery")
            eq(#p.dependencies.safe_roots,1,"one safe Current root")
            eq(#p.dependencies.blocked_roots,0,"no blocked roots")
            return p
        end
        local d=discover(facts,3)
        local snapshot=d.snapshot
        list(view(d,Local).version_view.changed,"helper,other","complete Local changed definitions")
        eq(view(d,Card).runtime,nil,"discovery alone grants no Card runtime view")
        local p=prepare(d,1)
        local lf,cf=fragment(p,Local),fragment(p,Card)
        local compared=cf.card_runtime.version_view
        eq(compared.by_key[keya].changed,true,"A changed after genuine location")
        eq(compared.by_key[keyb].changed,true,"B changed though unselected")
        eq(compared.by_key[keyc].changed,false,"C callback definition unchanged")
        eq(compared.source.analysis,facts.analysis,"Card uses original full AST")
        eq(compared.source.bindings,facts.bindings,"Card uses original lexical bindings")
        eq(lf.local_view.projection.source,facts,"Local projection uses same facts")
        eq(#lf.cell_writes,1,"only necessary Local helper written")
        eq(lf.cell_writes[1].name,"helper","exact selected Local helper")
        eq(#cf.raw_writes,1,"one explicit Card write")
        eq(#cf.card_plan.publications,1,"one explicit callback publication")
        eq(cf.card_plan.publications[1].unit_key,keya,"private card key selects A")
        eq(snapshot.by_key["card:K"].unit.context.layout[2].callbacks.init~=nil,true,"unselected B source retained")
        eq(snapshot.by_key["card:L"]~=nil,true,"unrelated class retained")
        local sealed=seal(p)
        eq(local_matches,1,"Seal never re-Matches Local")
        eq(card_matches,1,"Seal never re-Matches Card")
        eq(capture.snapshot,initial,"Seal never installs snapshot")
        eq(sealed.proposed_snapshot.revision,1,"one proposed common revision")
        local next_local,next_card=state(sealed.proposed_snapshot,Local),state(sealed.proposed_snapshot,Card)
        eq(next_local.by_name.other.fn,initial_local.by_name.other.fn,"unselected other closure retained")
        eq(next_local.by_name.other.definition_version,1,"unselected other version retained")
        for _,key in ipairs({keyb,keyc}) do
            eq(next_card.units[key].card,initial_card.units[key].card,"unselected card identity retained")
            eq(next_card.units[key].callbacks.init.fn,initial_card.units[key].callbacks.init.fn,"unselected callback retained")
            eq(next_card.units[key].callbacks.init.signature,initial_card.units[key].callbacks.init.signature,"unselected signature retained")
            eq(next_card.units[key].callbacks.init.definition_version,1,"unselected callback version retained")
        end
        local impact=must(Dependencies.PublicationImpact(sealed.proposed_snapshot,sealed.owner_deltas))
        local description=must(Card.Describe(cf,{operation=p.operation,snapshot=p.operation.base_snapshot,
            impact=impact,dependencies=p.dependencies}))
        local rows={};for _,row in ipairs(description.cards) do rows[row.key]=row end
        eq(rows[keya].selected,true,"A selected");eq(rows[keya].affected,true,"A publication affected")
        eq(rows[keyb].selected,false,"B unselected");eq(rows[keyb].pending,true,"B remains pending")
        eq(rows[keyb].affected,true,"B affected through shared helper")
        eq(rows[keyc].selected,false,"C unselected");eq(rows[keyc].affected,false,"other branch unaffected")
        eq(a.init,initial_card.units[keya].callbacks.init.fn,"preparation does not publish callback")
        eq(Anchor.Get(entry,"helper"),initial_local.by_name.helper.fn,"preparation does not publish cell")
        local bom_d=discover(bom_facts,4)
        local bom_p=prepare(bom_d,1)
        local bom_cf=fragment(bom_p,Card)
        eq(bom_d.source.content,bom,"complete BOM bytes retained")
        eq(bom_d.source.analysis.source_offset,3,"BOM offset retained")
        eq(bom_d.source.analysis.source,candidate,"AST source excludes BOM")
        list(view(bom_d,Local).version_view.changed,"helper,other","BOM Local changes")
        eq(#fragment(bom_p,Local).cell_writes,1,"BOM same selected helper count")
        eq(#bom_cf.raw_writes,1,"BOM same selected callback count")
        for _,key in ipairs({keya,keyb,keyc}) do
            local normal,with_bom=compared.by_key[key],bom_cf.card_runtime.version_view.by_key[key]
            eq(with_bom.changed,normal.changed,"BOM same callback change decision")
            eq(with_bom.descriptor.callbacks.init,normal.descriptor.callbacks.init,"BOM same callback signature")
        end
        local live=refresh(d,1)
        for _,field in ipairs({"file","session_id","registry_entry","loaded_source","base_revision","capture","generation"}) do
            local bad=copy(snapshot);bad.common=copy(snapshot.common);bad.common[field]=false
            local v,e=Target.LocateFileDiscovery(bad,capture,live())
            refuses(v,e,"stale","scope "..field)
        end
        local bad_source=copy(facts);bad_source.content=candidate.." "
        local v,e=Source.Validate(bad_source);refuses(v,e,"stale","wrong complete bytes")
        local bad=copy(snapshot);bad.common=copy(snapshot.common);bad.common.source=bad_source
        v,e=Target.LocateFileDiscovery(bad,capture,live());refuses(v,e,"stale","wrong live bytes")
        bad_source=copy(facts);bad_source.analysis=copy(facts.analysis);bad_source.analysis.source_offset=3
        bad_source.bindings=copy(facts.bindings);bad_source.bindings.analysis=bad_source.analysis
        bad_source.sites=copy(facts.sites);bad_source.sites.analysis=bad_source.analysis
        v,e=Source.Validate(bad_source);refuses(v,e,"stale","wrong BOM offset")
        bad=copy(snapshot);bad.common=copy(snapshot.common);bad.common.source=bad_source
        v,e=Target.LocateFileDiscovery(bad,capture,live());refuses(v,e,"unsupported","invalid shared source")
        bad=copy(snapshot);bad.adapter_contexts={}
        v,e=Target.LocateFileDiscovery(bad,capture,live());refuses(v,e,"unsupported","missing registered Card")
        bad=copy(snapshot);bad.entries={snapshot.entries[1]}
        v,e=Target.LocateFileDiscovery(bad,capture,live());refuses(v,e,"ownership","filtered discovery index disagrees")
        bad=copy(snapshot);bad.by_key={}
        v,e=Target.LocateFileDiscovery(bad,capture,live());refuses(v,e,"ownership","wrong entry index")
        local touched=0
        local hostile=setmetatable({},{__index=function() touched=touched+1;error("hostile __index") end,
            __tostring=function() touched=touched+1;error("hostile __tostring") end})
        v,e=Source.Validate(hostile);refuses(v,e,"unsupported","source metatable")
        v,e=Target.LocateFileDiscovery(hostile,capture,live());refuses(v,e,"stale","snapshot metatable")
        v,e=f.driver:PrepareDiscovery(hostile,p.operation);refuses(v,e,"ownership","discovery metatable")
        eq(touched,0,"metatables never invoked")
        local invalid=discover(facts,5)
        v,e=Planning.Operation(f,invalid,{mode="file",root_ids={"card:K"},refresh=refresh(invalid,1)})
        refuses(v,e,"ownership","class discovery key is not a publication root")
        local external=discover(facts,6)
        local former=a.init;a.init=function() end
        local called,external_p,external_e=pcall(Planning.Prepare,f,external,{mode="current",refresh=refresh(external,1)})
        a.init=former
        eq(called,true,"external replacement returns diagnostic")
        refuses(external_p,external_e,"stale","external callback replacement at owner Prepare")
        eq(joins,0,"zero premature joins");eq(writes,0,"zero premature setters");eq(flushes,0,"zero premature flushes")
        eq(effects,1,"candidate top-level effect never replayed during preparation")
        debug.upvaluejoin,debug.setupvalue,_G.jit=old_join,old_set,old_jit
        local tx=must(Tx.New(f.session));controllers[#controllers+1]=tx
        local receipt=must(Planning.Publish(f,p,tx))
        eq(receipt.changed,true,"genuine changed receipt")
        eq(receipt.snapshot,capture.snapshot,"receipt is actual common publication")
        eq(capture.snapshot.revision,1,"first real revision")
        local deltas={};for _,delta in ipairs(receipt.owner_deltas) do deltas[delta.owner]=delta end
        eq(deltas[Local].changed,true,"Local delta committed")
        eq(deltas[Card].changed,true,"Card delta committed in same transaction")
        local s1,c1=state(capture.snapshot,Local),state(capture.snapshot,Card)
        eq(s1.by_name.helper.definition_version,2,"actual helper version advances once")
        eq(s1.by_name.other.definition_version,1,"other still pending")
        eq(c1.units[keya].callbacks.init.definition_version,2,"A actual callback version")
        eq(c1.units[keyb].callbacks.init.definition_version,1,"B not published")
        eq(c1.units[keyc].callbacks.init.definition_version,1,"C not published")
        eq(entry.map.helper,initial_local.by_name.helper.fn,"first-load map remains historical")
        eq(capture.snapshot.anchor,initial.anchor,"same genuine anchor")
        eq(capture.snapshot.loaded_source,source,"structural baseline never replaced wholesale")
        eq(Anchor.Get(entry,"helper")(1),6,"published helper behavior")
        eq(a:init(1),26,"A uses new wrapper and helper")
        eq(b:init(1),16,"old B wrapper reads new shared helper")
        eq(c:init(1),101,"unpublished other branch unchanged")
        local again=discover(facts,7)
        eq(again.snapshot.common.base_revision,1,"fresh discovery uses actual revision")
        list(view(again,Local).version_view.changed,"other","only other Local definition remains changed")
        local second=prepare(again,2)
        local second_cf=fragment(second,Card);local compared2=second_cf.card_runtime.version_view
        eq(compared2.by_key[keya].changed,false,"A compared against committed definition")
        eq(compared2.by_key[keyb].changed,true,"B wrapper remains pending")
        eq(compared2.by_key[keyc].changed,false,"C still unchanged")
        eq(#fragment(second,Local).cell_writes,0,"published helper never rewritten")
        eq(#second_cf.raw_writes,1,"second selection writes B alone")
        eq(second_cf.card_plan.publications[1].unit_key,keyb,"second publication uses exact B key")
        v,e=f.driver:PrepareDiscovery(d,p.operation);refuses(v,e,"ownership","old discovery cannot prepare after publication")
        v,e=Target.LocateFileDiscovery(snapshot,capture,live());refuses(v,e,"stale","old baseline snapshot refused")
        local receipt2=must(Planning.Publish(f,second,tx))
        eq(receipt2.changed,true,"second real changed receipt")
        eq(receipt2.snapshot.revision,2,"second common revision")
        eq(state(capture.snapshot,Local).by_name.helper.definition_version,2,"helper version unchanged by B Apply")
        eq(state(capture.snapshot,Local).by_name.other.definition_version,1,"unselected other still pending after two Applies")
        eq(state(capture.snapshot,Card).units[keyb].callbacks.init.definition_version,2,"B actual callback version advances")
        eq(a:init(1),26,"A preserved after B Apply");eq(b:init(1),36,"B new wrapper and same helper")
        eq(c:init(1),101,"C remains on actual old other")
        eq(discovery_count,5,"five independent discoveries exercised")
        eq(local_matches,discovery_count,"no Local Match outside explicit discovery")
        eq(card_matches,discovery_count,"no Card Match outside explicit discovery")
        eq(builds,0,"no hidden full Build")
        eq(analyzes,0,"no hidden whole-file parse")
        eq(bindings,0,"no hidden binding reconstruction")
        eq(effects,1,"only explicit miniature first load executed")
    end)
    Source.Build,IR.Analyze,Binding.Analyze=old_build,old_analyze,old_binding
    Local.Match,Card.Match=old_local_match,old_card_match
    debug.upvaluejoin,debug.setupvalue,_G.jit=old_join,old_set,old_jit
    for _,n in ipairs(globals) do rawset(_G,n,saved[n]) end
    for _,controller in ipairs(controllers) do
        local released=controller:Release();eq(released,true,"common controller released")
    end
    eq(ok,true,"version discovery suite: "..(type(problem)=="string" and problem or "opaque error"))
    print(string.format("VersionDiscoverySpec: %d passed / %d failed",passed,failed))
    for _,failure in ipairs(failures) do print("  FAIL: "..failure) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
