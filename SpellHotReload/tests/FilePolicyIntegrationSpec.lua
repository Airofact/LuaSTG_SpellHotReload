-- Real two-owner FileApply policy/accounting/deletion integration.
-- No Plugin/CurrentRestart/engine claim; only genuine synthetic first loads execute.
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
    local FileApply=require("SpellHotReload.Apply.FileApply")
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
        local entry=must(Load.Capture(content,{name="FilePolicy_Boss.lua"}));entry.file="FilePolicy_Boss.lua"
        local session="FilePolicySpec:"..serial
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
        return must(FileApply.Prepare(f.driver,d,op)),d,op
    end
    local function publish(f,p,refresh)
        local ready,problem=FileApply.CheckProof(p.operation,live(f))
        if not ready then return nil,problem end
        local ran,receipt,err=f.tx:Run(function(token)
            return f.driver:CommitDiscovery(p,function(op,fragments)
                f.transactions=f.transactions+1
                return f.tx:Commit(token,op,fragments,live(f),FileApply.Refresh(op,refresh or function() return live(f) end))
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

    local function account(f,source)
        local d=must(f.driver:DiscoverPublished(f.entry.file,source,must(Files.Publication(f.capture)),
            {capture=f.capture,generation=f.generation}))
        local op=operation(f,d);op.roots={}
        return FileApply.InspectFileRemainder(f.driver,d,op,function() return live(f) end)
    end
    local function pending(model,key)
        for _,row in ipairs(model.pending) do if row.key==key then return true end end
        return false
    end
    case("complete actual no-op uses every owner's read witness without rescanning",function()
        local f=fixture();local d=discover(f,source);local op=operation(f,d)
        no_scan(function(count)
            local p=must(FileApply.Prepare(f.driver,d,op));local receipt=must(publish(f,p))
            eq(receipt.changed,false,"genuine unchanged receipt")
            local model,witness,fresh=account(f,d.source);must(model,witness);must(witness)
            eq(model.complete,true,"actual two-owner source is complete")
            eq(#model.pending,0,"no fabricated remainder")
            eq(count(),0,"no-op preparation/accounting constructs no closures")
            eq(FileApply.CheckWitness(witness,f.capture,fresh),true,"all-owner no-op witness validates")
            debug.setupvalue(f.entry.anchor,assert(Anchor.Slot(f.entry,"counter")),9)
            eq(Anchor.Get(f.entry,"counter"),9,"ordinary scalar changes in its existing shared cell")
            eq(FileApply.CheckWitness(witness,f.capture,live(f)),true,"completion witness does not freeze scalar values")
            local old=f.classes.K.cards[2].init;f.classes.K.cards[2].init=function() end
            eq(FileApply.CheckWitness(witness,f.capture,live(f)),nil,"witness checks unselected callback")
            f.classes.K.cards[2].init=old
            f.generation=f.generation+1
            eq(FileApply.CheckWitness(witness,f.capture,live(f)),nil,"witness binds exact generation")
        end)
    end)
    case("partial Current keeps sibling, independent definition and initializer pending",function()
        local f=fixture();local candidate=source:gsub("counter=3","counter=999")
            :gsub("counter%+n","counter+n+10"):gsub("helper%(n%)%+100","helper(n)+200")
            :gsub("return 500","return 501")
        local p,d=prepare(f,candidate,nil,"current");must(publish(f,p))
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"partial Current cannot clear whole candidate")
        eq(witness,nil,"incomplete source receives no completion witness")
        eq(pending(model,"local:independent"),true,"unselected Local edit remains pending")
        eq(pending(model,f.keyb..":init"),true,"sibling callback source remains pending")
        eq(pending(model,"local:counter"),true,"state initializer remains pending")
        eq(pending(model,"local:helper"),false,"published helper compares actual new version")
        eq(Anchor.Get(f.entry,"counter"),3,"ordinary state value was not replayed")
        eq(f.classes.K.cards[2]:init(2),115,"retained sibling observes shared helper only")
        local snapshot=f.capture.snapshot
        local observed,complete=account(f,d.source);must(observed,complete)
        eq(f.capture.snapshot,snapshot,"repeated accounting never installs Next")
    end)
    case("initializer alias and false-nil changes remain pending",function()
        local initial="local flag=false\nlocal function helper() return 1 end\nlocal function idle() return 5 end\nlocal alias=helper"
        local f=fixture(initial,true)
        local candidate=initial:gsub("flag=false","flag=nil"):gsub("return 1","return 2"):gsub("alias=helper","alias=idle")
        local p,d=prepare(f,candidate);must(publish(f,p))
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"retained initializer changes prevent completion")
        eq(pending(model,"local:flag"),true,"false-to-nil initializer remains")
        eq(pending(model,"local:alias"),true,"independent function alias remains")
        eq(Anchor.Get(f.entry,"flag"),false,"actual false cell retained")
        eq(Anchor.Get(f.entry,"alias")(),1,"alias retains original copied function")
        eq(Anchor.Get(f.entry,"helper")(),2,"selected function changed independently")
    end)
    case("no Card file can really publish and complete",function()
        local f=fixture("local function helper() return 1 end",true)
        local p,d=prepare(f,"local function helper() return 2 end")
        local receipt=must(publish(f,p));eq(receipt.changed,true,"Local-only changed receipt")
        no_scan(function(count)
            local model,witness,fresh=account(f,d.source);must(model,witness);must(witness)
            eq(model.complete,true,"empty original Card owner does not prevent completion")
            eq(count(),0,"accounting does not reconstruct pending functions")
            eq(FileApply.CheckWitness(witness,f.capture,fresh),true,"real empty-owner witness")
        end)
    end)
    case("unbounded effects block File and selected deletion, not ordinary Current",function()
        for _,mode in ipairs({"file","current"}) do
            local f=fixture();local candidate=source:gsub("counter%+n","counter+n+10").."\nUNREPLAYED_UNKNOWN()"
            local d=discover(f,candidate);local op=operation(f,d,nil,mode)
            local p,err=FileApply.Prepare(f.driver,d,op)
            if mode=="file" then
                eq(p,nil,"file policy rejects new unknown top-level effect")
                eq(err.code,"unsupported","unknown effect diagnostic")
                eq(f.capture.snapshot.revision,0,"refused file policy has no publication")
            else
                must(p,err);must(publish(f,p))
                local model,witness=account(f,d.source);must(model,witness)
                eq(model.complete,false,"ordinary Current retains unknown candidate effect")
            end
        end
        local f=fixture();local candidate=source:gsub("_tmp_sc.frame=function%(self%) return counter end\n","").."\nUNREPLAYED_UNKNOWN()"
        local d=discover(f,candidate);local p,err=FileApply.Prepare(f.driver,d,operation(f,d,nil,"current"))
        eq(p,nil,"selected deletion requires complete top-level effect policy")
        eq(err.code,"unsupported","deletion unknown effect refusal")
        eq(f.capture.snapshot.revision,0,"refused deletion never publishes")
    end)
    case("safe deletion need not clear unrelated pending; reverse uses actual versions",function()
        local f=fixture();local old=f.classes.K.cards[1].frame
        local without=source:gsub("_tmp_sc.frame=function%(self%) return counter end\n","")
        local candidate=without:gsub("counter=3","counter=999"):gsub("return 500","return 501")
            :gsub("helper%(n%)%+100","helper(n)+200")
        local p,d=prepare(f,candidate,nil,"current")
        eq(p.entries[2].fragment.card_plan.requires_file_check,true,"selected optional deletion requests file proof")
        local receipt=must(publish(f,p));eq(receipt.changed,true,"real default restoration receipt")
        eq(f.classes.K.cards[1].frame,defaults.frame,"deletion installs exact saved default")
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"independent pending does not disappear after safe deletion")
        eq(pending(model,f.keya..":frame"),false,"actual deleted callback is no longer pending")
        eq(pending(model,f.keyb..":init"),true,"sibling pending does not block safe deletion")
        local d2=discover(f,without);local complete,w=account(f,d2.source);must(complete,w);must(w)
        eq(complete.complete,true,"restoring unrelated candidate changes permits completion")
        local p3,d3=prepare(f,source);local added=must(publish(f,p3))
        eq(added.changed,true,"reverse edit publishes optional callback against actual default")
        eq(f.classes.K.cards[1].frame==defaults.frame,false,"restored function is a new callback")
        eq(f.classes.K.cards[1].frame==old,false,"reverse uses prepared closure, not old receipt")
        local final,final_witness=account(f,d3.source);must(final,final_witness);must(final_witness)
        eq(final.complete,true,"reverse completion uses actual latest callback version")
        eq(FileApply.CheckWitness(w,f.capture,live(f)),nil,"older completion witness invalidates on publication")
    end)
    case("safe registration wiring remains pending after selected deletion",function()
        local f=fixture()
        local candidate=source:gsub("_tmp_sc.frame=function%(self%) return counter end\n","")
            .."\ntable.insert(_sc_table,{'K','A',_tmp_sc,#_editor_class['K'].cards,false})"
        local p,d=prepare(f,candidate,nil,"current")
        local receipt=must(publish(f,p));eq(receipt.changed,true,"safe deletion with retained registration publishes")
        eq(f.classes.K.cards[1].frame,defaults.frame,"selected callback restores saved default")
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"safe registration exclusion is not adoption")
        eq(witness,nil,"retained registration cannot produce completion witness")
        local structure=false
        for _,row in ipairs(model.pending) do if row.kind=="structure" then structure=true end end
        eq(structure,true,"unexecuted registration keeps exact structure remainder")
    end)
    case("unchanged orphan setter cannot authorize deletion",function()
        local initial=source.."\n_tmp_sc.custom=1";local f=fixture(initial)
        local candidate=initial:gsub("_tmp_sc.frame=function%(self%) return counter end\n","")
        local p,d=prepare(f,candidate,nil,"current");local before=f.classes.K.cards[1].frame
        eq(#p.dependencies.blocked_roots,1,"unmodeled setter blocks selected Card root")
        local receipt=must(publish(f,p));eq(receipt.changed,false,"blocked absence is a real no-op")
        eq(f.classes.K.cards[1].frame,before,"unknown setter never restores default")
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"blocked callback absence remains pending")
    end)
    case("deletion proof refuses post-invalidation unrelated class drift",function()
        local initial=source.."\n_editor_class['Q'].name='Q'";local f=fixture(initial)
        local candidate=initial:gsub("_tmp_sc.frame=function%(self%) return counter end\n","")
        local p=prepare(f,candidate,nil,"current");local base=f.capture.snapshot;local before=f.classes.K.cards[1].frame
        local receipt,err=publish(f,p,function() f.classes.Q={};return live(f) end)
        eq(receipt,nil,"unrelated deletion class drift rejects whole transaction")
        eq(err.code,"stale","class drift final diagnostic")
        eq(f.capture.snapshot,base,"class drift never installs file snapshot")
        eq(f.classes.K.cards[1].frame,before,"class drift does not restore callback")
    end)
    case("structure, source absence and new owner cannot be ACKed",function()
        for _,candidate in ipairs({source:gsub("'A',1,2","'A',2,2"),
            source:gsub("local function helper%(n%) return counter%+n end\n",""),
            source.."\n_tmp_sc=boss.card.New('C',1,2,3,100)\nfunction _tmp_sc:init() end\ntable.insert(_editor_class['K'].cards,_tmp_sc)"}) do
            local f=fixture();local d=discover(f,candidate);local model,witness=account(f,d.source);must(model,witness)
            eq(model.complete,false,"retained structure or missing/new owner remains pending")
            eq(witness,nil,"unadopted source has no completion witness")
            eq(f.capture.snapshot.revision,0,"accounting never publishes")
        end
    end)
    case("all-owner coverage is mandatory and overlapping claims refuse",function()
        local f=fixture();local d=discover(f,source);local p=must(f.driver:PrepareDiscovery(d,operation(f,d)))
        local card=p.entries[2].fragment.file_evidence;p.entries[2].fragment.file_evidence=nil
        local report,err=FileApply.Collect(p);eq(report,nil,"missing original owner coverage refuses")
        eq(err.code,"ownership","missing coverage diagnostic")
        p.entries[2].fragment.file_evidence=card
        local index=next(card.before.claims);assert(index)
        p.entries[1].fragment.file_evidence.before.claims[index]="local:fake"
        report,err=FileApply.Collect(p);eq(report,nil,"cross-owner whole-statement claim collision refuses")
        eq(err.code,"ownership","coverage collision diagnostic")
        eq(f.transactions,0,"coverage refusals never enter transaction")
    end)
    for _,tx in ipairs(controllers) do tx:Release() end
    _G.boss=saved.boss;_G._editor_class=saved.classes;_G._tmp_sc=saved.tmp
    return {passed=passed,failed=failed,failures=failures}
end
return M
