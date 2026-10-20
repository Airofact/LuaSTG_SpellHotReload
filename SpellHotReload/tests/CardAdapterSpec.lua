-- REAL Card+Local five hooks through Driver and the common FileCommit kernel.
-- Synthetic genuine first loads only. No Plugin/CurrentRestart/FileApply claim.
local M={}
local serial=0
function M.run()
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Compose=require("SpellHotReload.Source.Compose")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Binding=require("SpellHotReload.Source.Binding")
    local names={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(names) do defaults[name]=function() end end
    local saved={boss=rawget(_G,"boss"),classes=rawget(_G,"_editor_class"),tmp=rawget(_G,"_tmp_sc")}
    local controllers={};local passed,failed,failures=0,0,{}
    local function eq(a,b,label) assert(rawequal(a,b),label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function case(label,body)
        local ok,err=pcall(body)
        if not ok then failed=failed+1;failures[#failures+1]=label..": "..(type(err)=="string" and err or "opaque error") end
    end
    local source=table.concat({
        "local counter=3",
        "local function helper(n) return counter+n end",
        "local function independent() return 500 end",
        "_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end",
        "_tmp_sc.frame=function(self) return counter end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n)+100 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    local function fixture(content,no_cards)
        content=content or source;serial=serial+1
        if no_cards then _G.boss=nil;_G._editor_class=nil
        else
            _G.boss={card={New=function(name)
                local card={name=name,is_combat=true}
                for _,cb in ipairs(names) do card[cb]=defaults[cb] end
                return card
            end}}
            _G._editor_class={K={},Q={}}
        end
        local entry=must(Load.Capture(content,{name="CardAdapter_Boss.lua"}));entry.file="CardAdapter_Boss.lua"
        local session="CardAdapterSpec:"..serial
        local lp=must(Local.Capture(entry,session))
        local captured_defaults
        if not no_cards then captured_defaults=defaults end
        local cp=must(Card.Capture(entry,session,lp,_editor_class,captured_defaults))
        local capture=must(Files.Capture(entry,session,{lp,cp}))
        local driver=Driver.New();must(driver:RegisterDiscovery(Local));must(driver:RegisterDiscovery(Card))
        local f={entry=entry,session=session,capture=capture,driver=driver,loaded=content,content=content,
            classes=_editor_class,generation=0,transactions=0,keya="card:1:K:1",keyb="card:1:K:2"}
        if not no_cards then f.current={slot=1,card=f.classes.K.cards[1],mode="practice",include_previous=false} end
        f.tx=must(Tx.New(session));controllers[#controllers+1]=f.tx
        return f
    end
    local function live(f)
        local classes=rawget(_G,"_editor_class");local binding
        if f.current then
            local ctx=f.current;local class=classes and classes.K;local list=class and class.cards
            local labels={};for i,card in ipairs(list or {}) do labels[i]=rawget(card,"name") or "" end
            binding={class_key="K",slot=ctx.slot,card=ctx.card,name=rawget(ctx.card,"name"),names=labels,
                mode=ctx.mode,include_previous=ctx.include_previous}
        end
        return {capture=f.capture,snapshot=f.capture.snapshot,entry=f.entry,session_id=f.session,
            content=f.content,generation=f.generation,classes=classes,binding=binding}
    end
    local function discover(f,content)
        f.content=content;f.generation=f.generation+1
        local facts=must(Source.Build(content))
        return must(f.driver:DiscoverPublished(f.entry.file,facts,must(Files.Publication(f.capture)),
            {capture=f.capture,generation=f.generation})),facts
    end
    local function operation(f,d,requested,mode)
        local roots,available={},{};local cv
        for _,group in ipairs(d.reconciliation.groups) do
            local list=group.owner==Local and Local.Roots(group.view) or Card.Roots(group.view)
            if group.owner==Card then cv=group.view end
            for _,root in ipairs(list) do available[root.root_id]=root;roots[#roots+1]=root end
        end
        local input={refresh=function() return live(f) end}
        if mode=="current" or mode=="inspect" then
            local l=live(f);local root,target=Card.CurrentRoot(cv,Card.FreezeBinding(l.binding),f.capture,l)
            roots={must(root,target)};input.target=target
        elseif requested then roots={};for _,key in ipairs(requested) do roots[#roots+1]=assert(available[key]) end end
        return {capture=f.capture,base_snapshot=f.capture.snapshot,source=d.source,file=f.entry.file,
            entry=f.entry,anchor=f.entry.anchor,loaded_source=f.loaded,session_id=f.session,generation=f.generation,
            mode=mode or "file",roots=roots,card=input}
    end
    local function prepare(f,content,requested,mode)
        local d=discover(f,content);local op=operation(f,d,requested,mode)
        return must(f.driver:PrepareDiscovery(d,op)),d,op
    end
    local function publish(f,p,refresh)
        local ran,receipt,err=f.tx:Run(function(token)
            return f.driver:CommitDiscovery(p,function(op,fragments)
                f.transactions=f.transactions+1
                return f.tx:Commit(token,op,fragments,live(f),refresh or function() return live(f) end)
            end)
        end)
        eq(ran,true,"common transaction scope returned normally")
        return receipt,err
    end
    local function no_scan(body)
        local create,analyze,bind=Compose.Create,IR.Analyze,Binding.Analyze
        local count=0
        Compose.Create=function(...) count=count+1;return create(...) end
        IR.Analyze=function() error("Card five hooks repeated full-file IR") end
        Binding.Analyze=function() error("Card five hooks repeated full-file binding") end
        local ok,err=pcall(body,function() return count end)
        Compose.Create,IR.Analyze,Binding.Analyze=create,analyze,bind
        if not ok then error(err,0) end
    end
    case("complete no-change real two-owner path",function()
        local f=fixture();local d=discover(f,source);local op=operation(f,d);local base=f.capture.snapshot
        no_scan(function(count)
            local p=must(f.driver:PrepareDiscovery(d,op))
            eq(#p.entries,2,"both original owners prepare")
            eq(count(),0,"no-change complete selection creates zero closures")
            local receipt=must(publish(f,p));eq(receipt.changed,false,"real unchanged receipt")
            eq(f.capture.snapshot,base,"unchanged receipt retains exact common snapshot")
            eq(f.transactions,1,"both registration hooks enter one transaction")
        end)
    end)
    case("Current A requests only actual provider chain",function()
        local f=fixture();local candidate=source:gsub("counter%+n","counter+n+10")
            :gsub("helper%(n%)%+100","helper(n)+200"):gsub("return 500","return 501")
        local d=discover(f,candidate);local op=operation(f,d,nil,"current");local old_card=must(Files.Owner(f.capture,Card))
        local old_a=f.classes.K.cards[1].init;local old_b=f.classes.K.cards[2].init
        eq(#op.roots,1,"Current caller provides exactly its private Card root")
        eq(op.roots[1].root_id,f.keya,"Current caller excludes unrelated Local roots")
        no_scan(function(count)
            local p=must(f.driver:PrepareDiscovery(d,op))
            eq(#p.dependencies.safe_roots,1,"Current preparation retains only its requested root")
            eq(p.dependencies.safe_roots[1].root_id,f.keya,"Current dependencies preserve target provenance")
            eq(count(),1,"Current A only constructs its changed Local helper")
            eq(#p.entries[2].fragment.raw_writes,0,"retained Card callbacks are not rebuilt")
            eq(d.reconciliation.groups[1].view.version_view.by_name.independent.probe,nil,"unrequested Local edit is not probed")
            local receipt=must(publish(f,p));eq(receipt.changed,true,"Current helper publication returns real changed receipt")
            eq(f.transactions,1,"Current uses exactly one common transaction")
        end)
        local cg=must(Files.Owner(f.capture,Card))
        eq(cg,old_card,"helper-only retains exact Card group")
        eq(f.classes.K.cards[1].init,old_a,"current callback identity retained")
        eq(f.classes.K.cards[2].init,old_b,"unselected callback identity retained")
        eq(f.classes.K.cards[1]:init(2),15,"selected current sees updated helper")
        eq(f.classes.K.cards[2]:init(2),115,"other actual callback sees helper without candidate +200")
        eq(Anchor.Get(f.entry,"independent")(),500,"independent pending edit stays actual old function")
        eq(cg.state.units[f.keya].definition_version,1,"Current helper-only does not advance Card source")
        eq(Cards.Observations(f.capture.snapshot,cg,f.keya)[1].version,2,"display follows actual helper v2")
        local fresh=must(f.driver:DiscoverPublished(f.entry.file,d.source,must(Files.Publication(f.capture)),
            {capture=f.capture,generation=f.generation}))
        eq(fresh.source,d.source,"post-publication fresh discovery consumes same analysis")
        eq(fresh.reconciliation.groups[1].view.version_view.by_name.helper.changed,false,"fresh Local comparison uses newly installed version")
        local next_op=operation(f,fresh,nil,"current")
        local p=must(f.driver:PrepareDiscovery(fresh,next_op));local final=must(publish(f,p))
        eq(final.changed,false,"fresh Current actual check returns real unchanged receipt")
        eq(f.capture.snapshot.revision,1,"fresh unchanged check does not advance revision")
    end)
    case("selected callback and helper publish atomically",function()
        local f=fixture();local candidate=source:gsub("counter%+n","counter+n+10")
            :gsub("return helper%(n%) end","return helper(n)+1 end")
        local p=prepare(f,candidate,{f.keya})
        eq(#p.entries[1].fragment.cell_writes,1,"one selected Local cell")
        eq(#p.entries[2].fragment.raw_writes,1,"one selected Card callback")
        local receipt=must(publish(f,p));eq(receipt.changed,true,"joint publication changed receipt")
        eq(f.capture.snapshot.revision,1,"two owners advance file exactly once")
        eq(f.transactions,1,"two writers use one transaction")
        local group=must(Files.Owner(f.capture,Card))
        eq(group.state.units[f.keya].definition_version,2,"selected Card definition advances")
        eq(group.state.units[f.keyb].definition_version,1,"unselected Card definition does not advance")
        eq(f.classes.K.cards[1]:init(2),16,"actual callback and helper use joint new definitions")
    end)
    case("real Card constrains selected Local AST by root",function()
        for _,body in ipairs({"_editor_class['K']","_tmp_sc","_sc_table"}) do
            local f=fixture();local candidate=source:gsub("return counter%+n","return "..body)
                :gsub("'A',1,2","'A',2,2"):gsub("return 500","return 501")
            local old=f.entry.map.helper;local p=prepare(f,candidate,{"local:helper","local:independent"})
            eq(#p.dependencies.blocked_roots,1,"Card business constraint blocks only helper root")
            eq(p.dependencies.blocked_roots[1].root_id,"local:helper","real Local root provenance retained")
            eq(p.dependencies.safe_roots[1].root_id,"local:independent","independent Local root survives")
            eq(#p.entries[2].fragment.card_plan.registry_reads,0,"blocked facts leave no Card registry read")
            must(publish(f,p));eq(Anchor.Get(f.entry,"helper"),old,"blocked helper not installed")
            eq(Anchor.Get(f.entry,"independent")(),501,"safe independent root installed")
        end
    end)
    case("final registry and Current lifecycle drift refuse",function()
        local f=fixture();local p=prepare(f,source:gsub("return counter%+n","return _editor_class['Q']"),{"local:helper"})
        local before=f.capture.snapshot;local old=f.entry.map.helper
        local receipt,err=publish(f,p,function() f.classes.Q={};return live(f) end)
        eq(receipt,nil,"post-flush registry drift has no receipt");eq(err.code,"stale","registry guard diagnostic")
        eq(f.capture.snapshot,before,"registry drift leaves common snapshot")
        eq(Anchor.Get(f.entry,"helper"),old,"registry drift leaves actual helper")
        for _,field in ipairs({"mode","include_previous","names"}) do
            f=fixture();p=prepare(f,source:gsub("counter%+n","counter+n+10"),nil,"current")
            before=f.capture.snapshot
            receipt,err=publish(f,p,function()
                if field=="mode" then f.current.mode="debug"
                elseif field=="include_previous" then f.current.include_previous=true
                else f.classes.K.cards[2].name="renamed external sibling" end
                return live(f)
            end)
            eq(receipt,nil,"Current lifecycle drift has no receipt")
            eq(f.capture.snapshot,before,"Current lifecycle drift installs no snapshot")
        end
    end)
    case("all source claimants remain ambiguous",function()
        local initial=source:gsub("'B',1,2","'A',1,2")
        local f=fixture(initial)
        local candidate=initial:gsub("_tmp_sc=boss.card.New%('A',1,2,3,100%)\nfunction _tmp_sc:init%(n%) return helper%(n%)%+100 end\n","")
        -- Rebuild from the held descriptor twice: a second insert alone would
        -- be an unknown placeholder after the first insertion clears pending.
        candidate=candidate.."\n_editor_class['K'].cards={_tmp_sc,_tmp_sc}"
        local d=discover(f,candidate);local location=must(Target.LocateFileDiscovery(d.snapshot,f.capture,live(f)))
        eq(location.by_key[f.keya].status,"ambiguous","first claimant cannot win by traversal order")
        eq(location.by_key[f.keyb].status,"ambiguous","second claimant is also ambiguous")
        eq(#location.located,0,"no ambiguous claimant is live-located")
        eq(#location.unowned,2,"both reused candidate occurrences remain unowned")
    end)
    case("Card-free capture uses no registry or defaults",function()
        local content="local function helper() return 1 end"
        local f=fixture(content,true);local cg=must(Files.Owner(f.capture,Card))
        eq(#cg.units,0,"genuine empty Card contribution has no fake unit")
        eq(#f.capture.initial_owners[2].authority.raws,0,"empty Card has no raw write authority")
        local p=prepare(f,"local function helper() return 2 end",{"local:helper"})
        eq(#p.entries,2,"empty original Card owner still prepares")
        local receipt=must(publish(f,p));eq(receipt.changed,true,"Card-free Local publication has real receipt")
        eq(Files.Owner(f.capture,Card),cg,"empty Card group remains exact original")
        eq(Anchor.Get(f.entry,"helper")(),2,"Card-free real Local function updated")
    end)
    case("Card-free class reads refuse only their own root",function()
        for _,late_registry in ipairs({false,true}) do
            local content="local function helper() return 1 end\nlocal function independent() return 500 end"
            local f=fixture(content,true);local old=Anchor.Get(f.entry,"helper")
            -- No first-load registry proof exists. A later live Q cannot
            -- retroactively authorize a selected definition to capture it.
            if late_registry then _G._editor_class={Q={}} end
            local candidate=content:gsub("return 1","return _editor_class['Q']"):gsub("return 500","return 501")
            local p=prepare(f,candidate,{"local:helper","local:independent"})
            eq(#p.dependencies.blocked_roots,1,"missing initial registry proof blocks only one root")
            eq(p.dependencies.blocked_roots[1].root_id,"local:helper","class read refusal retains helper provenance")
            eq(#p.dependencies.safe_roots,1,"independent Local root survives empty Card constraints")
            eq(p.dependencies.safe_roots[1].root_id,"local:independent","independent provenance survives")
            eq(#p.entries[2].fragment.card_plan.registry_reads,0,"empty Card retains no unsupported registry proof")
            local receipt=must(publish(f,p));eq(receipt.changed,true,"independent root still has changed receipt")
            eq(Anchor.Get(f.entry,"helper"),old,"class-reading helper remains actual old version")
            eq(Anchor.Get(f.entry,"independent")(),501,"independent update publishes despite rejected class read")
        end
    end)
    for _,tx in ipairs(controllers) do tx:Release() end
    _G.boss=saved.boss;_G._editor_class=saved.classes;_G._tmp_sc=saved.tmp
    return {passed=passed,failed=failed,failures=failures}
end
return M
