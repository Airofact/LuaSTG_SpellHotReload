-- Current-root correspondence with real common captures and shared analysis.
-- Miniature genuine first loads only; no candidate chunk, publication or engine.
local M={}
function M.run(opts)
    opts=opts or {}
    local Target=opts.target or require("SpellHotReload.Adapters.Card.CardTarget")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Evidence=require("SpellHotReload.Adapters.Card.CardReconcile")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Syntax=require("SpellHotReload.Source.SyntaxTree")
    local Compose=require("SpellHotReload.Source.Compose")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Callbacks=require("SpellHotReload.Adapters.Card.CardCallbacks")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local passed,failed,failures=0,0,{}
    local function eq(a,b,label)
        if rawequal(a,b) then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function copy(v) local r={};for k,x in next,v do r[k]=x end;return r end
    -- Preserve every unrelated owner/entry while corrupting ONE Card proof.
    local function replace_entry(snapshot,key,change)
        local old=assert(snapshot.by_key[key]);local entry=copy(old);change(entry)
        local entries={};for i,item in ipairs(snapshot.entries) do entries[i]=item==old and entry or item end
        snapshot.entries=entries;snapshot.by_key=copy(snapshot.by_key);snapshot.by_key[key]=entry
    end
    local function corrupt_analysis(snapshot,field,value)
        snapshot.common=copy(snapshot.common)
        local facts=copy(snapshot.common.source);local analysis=copy(facts.analysis)
        facts.analysis=analysis
        facts.sites=copy(facts.sites);facts.sites.analysis=analysis
        analysis[field]=value;snapshot.common.source=facts
    end
    local function refusal(v,e,code,label)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        eq(e and e.phase,"locate",label.." phase");eq(e and e.code,code,label.." code")
        eq(e and e.file,"Remapping_Boss.lua",label.." file")
    end
    local saved={}
    for _,n in ipairs({"boss","_editor_class","_tmp_sc","REMAPPING_EFFECT"}) do saved[n]=rawget(_G,n) end
    local saved_apis={read=Callbacks.Read,match=Card.Match,build=Source.Build,analyze=IR.Analyze,
        tokenize=Syntax.Parse,create=Compose.Create}
    local function restore_apis()
        Callbacks.Read,Card.Match= saved_apis.read,saved_apis.match
        Source.Build,IR.Analyze,Syntax.Parse,Compose.Create=
            saved_apis.build,saved_apis.analyze,saved_apis.tokenize,saved_apis.create
    end
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,n in ipairs(callbacks) do defaults[n]=function() end end
    local effects,serial=0,0
    local function source(labels,with_move,bom)
        local lines={"local state=4","REMAPPING_EFFECT()","_editor_class['K'].cards={}"}
        if with_move then lines[#lines+1]="table.insert(_editor_class['K'].cards,boss.move.New(0,0,1))" end
        for i,label in ipairs(labels) do
            lines[#lines+1]=string.format("_tmp_sc=boss.card.New(%q,1,2,3,4)",label)
            lines[#lines+1]=string.format("function _tmp_sc:init() return %d end",i)
            lines[#lines+1]="table.insert(_editor_class['K'].cards,_tmp_sc)"
        end
        lines[#lines+1]="_editor_class['L'].cards={boss.move.New(0,0,1)}"
        return (bom and "\239\187\191" or "")..table.concat(lines,"\n")
    end
    local function fixture(labels,slot,move)
        _editor_class={K={},L={}}
        REMAPPING_EFFECT=function() effects=effects+1 end
        boss={card={New=function(label)
            local card={name=label,is_combat=true}
            for _,n in ipairs(callbacks) do card[n]=defaults[n] end
            return card
        end},move={New=function() return {is_combat=false} end}}
        serial=serial+1
        local bytes=source(labels,move)
        local entry=must(Load.Capture(bytes,{name="Remapping_Boss.lua"}))
        entry.file="Remapping_Boss.lua"
        local f=must(Planning.Capture(entry,"remapping:"..serial,_editor_class,defaults))
        local capture=f.capture
        local list=_editor_class.K.cards
        local names={};for i,card in ipairs(list) do names[i]=card.name or "" end
        local binding={class_key="K",slot=slot,card=list[slot],name=list[slot].name,
            names=names,mode=move and "debug" or "practice",include_previous=false}
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,
            classes=_editor_class,session_id=f.session,generation=7}
        local target=must(Target.Resolve(binding,capture,live))
        local function discovery(candidate)
            live.snapshot,live.content=capture.snapshot,candidate
            return must(Planning.Discover(f,must(Source.Build(candidate)),7)).snapshot
        end
        return binding,capture,live,target,discovery
    end
    local ok,problem=pcall(function()
        local b,c,l,t,discover=fixture({"A","B"},2)
        local snapshot=discover(source({"A","B"}))
        local location=must(Target.LocateDiscovery(t,snapshot,b,c,l))
        eq(location.kind,"SpellHotReload.CardTarget.DiscoveryLocation","kind")
        eq(location.key,"card:1:K:2","publication key retained")
        eq(location.source_key,"card:K","class key distinct")
        eq(location.discovery,snapshot,"full snapshot retained")
        eq(location.entry,snapshot.by_key["card:K"],"original source entry")
        eq(location.descriptor,snapshot.by_key["card:K"].unit.context.layout[2],"descriptor identity")
        eq(location.candidate_slot,2,"same source slot");eq(location.target.slot,2,"live restart slot")
        eq(location.generation,7,"generation retained")
        eq(Target.CheckDiscovery(location,b,c,l),true,"immediate candidate recheck")
        local cases={
            {{"A","B"},2,false,{"A","B"},false,2,"same"},
            {{"A","B"},2,false,{"A","Renamed"},false,2,"rename"},
            {{"B"},2,true,{"Prefix","B","Suffix"},true,3,"debug to full named"},
            {{"Prefix","B","Suffix"},3,true,{"B"},true,2,"full to debug named"},
            {{"A","B"},2,false,{"Prefix","A","B"},false,3,"named prefix append"},
            {{"A","B"},2,false,{"A","B","Suffix"},false,2,"named suffix append"},
            {{"Same","Same"},2,false,{"Same","Same"},false,2,"duplicate unchanged slots"},
            {{"A",""},2,false,{"A","","Suffix"},false,2,"unnamed head"},
            {{""},2,true,{"Prefix",""},true,3,"unnamed tail debug to full"},
            {{"A","B"},2,false,{"A","B"},false,2,"BOM",true},
        }
        for _,case in ipairs(cases) do
            b,c,l,t,discover=fixture(case[1],case[2],case[3])
            snapshot=discover(source(case[4],case[5],case[8]))
            local prior,effect=c.snapshot,effects
            local located,why=Target.LocateDiscovery(t,snapshot,b,c,l)
            assert(located,case[7]..": "..(why and why.message or "no result"))
            location=located
            eq(location.candidate_slot,case[6],case[7].." candidate")
            eq(location.target.slot,case[2],case[7].." original restart index")
            eq(location.target.card,b.card,case[7].." live object unchanged")
            eq(Target.CheckDiscovery(location,b,c,l),true,case[7].." recheck")
            eq(c.snapshot,prior,case[7].." no version install")
            eq(effects,effect,case[7].." no candidate initializer")
            eq(#snapshot.entries,3,case[7].." Local declaration and both Card classes retained")
            eq(snapshot.by_key["local:state"].adapter.Id,"local",case[7].." real Local entry retained")
            eq(snapshot.by_key["card:L"].adapter,Card,case[7].." unrelated class retained")
        end
        local rejected={
            {{"Same","Same"},2,false,{"Same"},false,"duplicate lost slot"},
            {{"A","B"},2,false,{"A","B","B"},false,"candidate duplicate name"},
            {{"A","B"},2,false,{"B","A"},false,"interior reorder"},
            {{"A","B"},2,false,{"Other","Renamed"},false,"sibling changed with rename"},
            {{"A","B"},2,false,{"Other","B"},false,"same-name root with changed sibling"},
            {{"A","B"},2,false,{"A","Other","B"},false,"interior insertion"},
            {{""},2,true,{"","",""},true,"unnamed both-end alignment"},
            {{"A",""},2,false,{"Other","","Suffix"},false,"unnamed neither-end"},
            {{"A",""},2,false,{"A","Named"},false,"unnamed gains identity"},
        }
        for _,case in ipairs(rejected) do
            b,c,l,t,discover=fixture(case[1],case[2],case[3])
            snapshot=discover(source(case[4],case[5]))
            local v,e=Target.LocateDiscovery(t,snapshot,b,c,l)
            refusal(v,e,"ambiguous",case[6])
        end
        b,c,l,t,discover=fixture({"A","B"},2)
        snapshot=discover(source({"A","B"}));location=must(Target.LocateDiscovery(t,snapshot,b,c,l))
        -- The entire Match context must be present even for one selected root.
        for _,field in ipairs({"file","session_id","registry_entry","loaded_source",
            "base_revision","capture","source","generation"}) do
            local bad=copy(snapshot);bad.common=copy(snapshot.common);bad.common[field]=false
            local v,e=Target.LocateDiscovery(t,bad,b,c,l);refusal(v,e,"stale","scope "..field)
        end
        local malformed={
            {"missing Card context",function(s) s.adapter_contexts={} end,"unsupported"},
            {"filtered entries",function(s)
                s.entries={};s.by_key=copy(snapshot.by_key);s.by_key["card:L"]=nil
                for _,e in ipairs(snapshot.entries) do if e.unit.key~="card:L" then s.entries[#s.entries+1]=e end end
            end,"unsupported"},
            {"wrong index",function(s) s.by_key={} end,"ownership"},
            {"wrong Card owner",function(s)
                replace_entry(s,"card:K",function(e) e.adapter={} end)
            end,"ownership"},
            {"unselected context",function(s)
                replace_entry(s,"card:L",function(e) e.context=copy(e.context);e.context.common={} end)
            end,"ownership"},
            {"sparse layout",function(s)
                replace_entry(s,"card:K",function(e)
                    e.unit=copy(e.unit);e.unit.context=copy(e.unit.context)
                    e.unit.context.layout={[2]=e.unit.context.layout[2]}
                end)
            end,"ownership"},
            {"extra index",function(s) s.by_key=copy(snapshot.by_key);s.by_key.extra={} end,"ownership"},
            {"bytes analysis",function(s) corrupt_analysis(s,"source","wrong") end,"unsupported"},
            {"offset",function(s) corrupt_analysis(s,"source_offset",3) end,"unsupported"},
        }
        for _,case in ipairs(malformed) do
            local bad=copy(snapshot);case[2](bad)
            local v,e=Target.LocateDiscovery(t,bad,b,c,l);refusal(v,e,case[3],case[1])
        end
        local missing=discover(source({"A","B"}):gsub("'K'","'Absent'"))
        local v,e=Target.LocateDiscovery(t,missing,b,c,l);refusal(v,e,"ambiguous","class deletion")
        snapshot=discover(source({"A","B"}))
        -- New mapping does not bypass fixed-layout versions or mutate metadata.
        local renamed=discover(source({"A","Renamed"}))
        location=must(Target.LocateDiscovery(t,renamed,b,c,l))
        eq(location.candidate_name,"Renamed","candidate name kept separate")
        eq(t.name,"B","live name not published")
        local group,initial=Files.GetAdapterRecords(c,Card);must(group,initial)
        local rows=must(Evidence.Index(c,renamed))
        local file_location=must(Target.LocateFileDiscovery(renamed,c,l))
        local match
        for _,owner in ipairs(renamed.reconciliation.groups) do
            if owner.owner==Card then match=owner.view.match end
        end
        local report=must(Cards.Compare(group,initial.evidence,renamed.common.source,match,file_location,rows))
        eq(report.locations,file_location,"comparison consumes explicit complete file correspondence")
        eq(report.by_key[t.key].location,file_location.by_key[t.key],"private version comparison keeps original file row")
        eq(report.by_key[t.key].descriptor,location.descriptor,"current and file mapping agree on descriptor")
        eq(report.by_key[t.key].location.candidate_slot,location.candidate_slot,"current and file source slots agree")
        -- No parser, compiler, mutator or old selection path runs during Locate.
        local chunk=assert(loadfile(assert(opts.module_path,"module_path required")))
        local traps=0
        setfenv(chunk,setmetatable({loadstring=function() traps=traps+1;error("compile") end,
            load=function() traps=traps+1;error("compile") end,
            rawset=function() traps=traps+1;error("write") end,
            debug=setmetatable({},{__index=function() traps=traps+1;error("debug") end}),
            jit={flush=function() traps=traps+1;error("flush") end}}, {__index=_G}))
        local pure=chunk()
        Callbacks.Read=function() error("re-read forbidden") end
        Card.Match=function() error("re-match forbidden") end
        Source.Build=function() error("source rebuild forbidden") end
        IR.Analyze=function() error("IR rebuild forbidden") end
        Syntax.Parse=function() error("parsing forbidden") end
        Compose.Create=function() error("callback construction forbidden") end
        local ran,value=pcall(function()
            local found=must(pure.LocateDiscovery(t,renamed,b,c,l))
            return pure.CheckDiscovery(found,b,c,l)
        end)
        restore_apis()
        eq(ran,true,"no hidden re-read/re-match");eq(value,true,"pure gate succeeds");eq(traps,0,"no forbidden primitives")
        -- Every failed recheck leaves the old capture and live callbacks alone.
        for _,field in ipairs({"content","generation","key","source_key","entry","descriptor",
            "candidate_slot","candidate_name","match","target","discovery"}) do
            location=must(Target.LocateDiscovery(t,renamed,b,c,l))
            local bad=copy(location);bad[field]=false
            v,e=Target.CheckDiscovery(bad,b,c,l)
            eq(v,nil,"tampered "..field.." refused");eq(type(e),"table","tampered "..field.." error")
        end
        location=must(Target.LocateDiscovery(t,renamed,b,c,l))
        local content=l.content;l.content=content.." "
        v,e=Target.CheckDiscovery(location,b,c,l);refusal(v,e,"stale","fresh disk bytes")
        l.content=content
        local sid=l.session_id;l.session_id="new"
        v,e=Target.CheckDiscovery(location,b,c,l);refusal(v,e,"stale","session change");l.session_id=sid
        local revision=c.snapshot.revision;c.snapshot.revision=revision+1
        v,e=Target.CheckDiscovery(location,b,c,l);refusal(v,e,"stale","revision change");c.snapshot.revision=revision
        local other=l.classes.L.cards[1];l.classes.L.cards[1]={}
        v,e=Target.CheckDiscovery(location,b,c,l);refusal(v,e,"ownership","unselected placeholder change")
        l.classes.L.cards[1]=other
        local fresh=copy(b);fresh.mode="debug"
        v,e=Target.CheckDiscovery(location,fresh,c,l);refusal(v,e,"stale","current mode change")
        eq(Target.CheckDiscovery(location,b,c,l),true,"restored baseline usable")
        local handlers=0
        local hostile=setmetatable({},{__index=function() handlers=handlers+1;error("index") end,
            __tostring=function() handlers=handlers+1;error("stringify") end})
        v,e=Target.LocateDiscovery(t,hostile,b,c,l);refusal(v,e,"stale","metatable snapshot")
        v,e=Target.CheckDiscovery(hostile,b,c,l);refusal(v,e,"unsupported","metatable location")
        eq(handlers,0,"no hostile handlers")
        eq(b.card.name,"B","metadata untouched");eq(b.card.init(),2,"old callback still live")
    end)
    restore_apis()
    -- Restore nil globals too.
    for _,n in ipairs({"boss","_editor_class","_tmp_sc","REMAPPING_EFFECT"}) do rawset(_G,n,saved[n]) end
    assert(ok,problem)
    print(string.format("CardRemappingSpec: %d passed / %d failed",passed,failed))
    for _,f in ipairs(failures) do print("  FAIL: "..f) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
