-- Real Local/Class/Card FileApply policy/accounting/deletion integration.
-- No Plugin/CurrentRestart/engine claim; only genuine synthetic first loads execute.
local M={}
local serial=0
function M.run()
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local ClassAdapter=require("SpellHotReload.Adapters.Class.Class")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local FileApply=require("SpellHotReload.Apply.FileApply")
    local Compose=require("SpellHotReload.Source.Compose")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local names={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(names) do defaults[name]=function() end end
    local environment
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
        "_editor_class['K']=Class(boss)",
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
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        if no_cards then _G.boss=nil;_G._editor_class=nil
        else
            boss.card={_default_card=defaults,New=function(name)
                local card={name=name,is_combat=true}
                for _,cb in ipairs(names) do card[cb]=defaults[cb] end
                return card
            end}
            -- Genuine external Class; this source does not own Q's constructor.
            _editor_class.Q=Class(boss)
        end
        local entry=must(Load.Capture(content,{name="FilePolicy_Boss.lua"}));entry.file="FilePolicy_Boss.lua"
        local session="FilePolicySpec:"..serial
        local captured_defaults
        if not no_cards then captured_defaults=defaults end
        local f=must(Planning.Capture(entry,session,_editor_class,captured_defaults))
        environment:FinishLoad()
        f.content=content;f.classes=_editor_class;f.generation=0;f.transactions=0
        f.keya,f.keyb="card:1:K:1","card:1:K:2"
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
        return must(Planning.Discover(f,facts,f.generation)),facts
    end
    local function operation(f,d,requested,mode)
        return must(Planning.Operation(f,d,{mode=mode or "file",root_ids=requested,
            refresh=function() return live(f) end}))
    end
    local function piece(prepared,owner)
        for _,record in ipairs(prepared.entries) do if record.owner==owner then return record.fragment end end
        error("missing real owner fragment")
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
        local create,analyze=Compose.Create,IR.Analyze
        local count=0
        Compose.Create=function(...) count=count+1;return create(...) end
        IR.Analyze=function() error("Card five hooks repeated full-file IR") end
        local ok,err=pcall(body,function() return count end)
        Compose.Create,IR.Analyze=create,analyze
        if not ok then error(err,0) end
    end

    local function account(f,source)
        local d=must(Planning.Discover(f,source,f.generation))
        local op=operation(f,d);op.roots={}
        return FileApply.InspectFileRemainder(f.driver,d,op,function() return live(f) end)
    end
    local function pending(model,key)
        for _,row in ipairs(model.pending) do if row.key==key then return true end end
        return false
    end
    case("reference facts keep literals opaque without weakening selected traversal",function()
        local facts=must(Source.Build([=[local Box={_editor_class="label only",[key]=outer,
            reader=function(arg) local inner=arg;return _editor_class['K'],inner,'\x41' end}
            Box:reader(outer)]=]))
        local Tree=facts.analysis.syntax
        local refs=Tree.Names(Tree.root);local names={}
        for i,ref in ipairs(refs) do
            names[i]=Tree.Identifier(ref)
            eq(type(ref),"cdata","reference query returns existing native nodes")
            eq(Tree.Is(ref,"binding"),false,"reference query excludes binding declarations")
            eq(Source.ContainsFact(facts,ref),true,"reference remains owned by its source")
        end
        eq(table.concat(names,","),"key,outer,arg,_editor_class,inner,Box,outer",
            "references cross function bodies but exclude field labels and strings")
        local again=Tree.Names(Tree.root)
        for i,ref in ipairs(refs) do eq(Tree.SameNode(ref,again[i]),true,"reference identity is canonical") end
        local ok,err=pcall(Tree.Walk,Tree.root,function() end)
        eq(ok,false,"ordinary full traversal still validates the unsupported body literal")
        eq(type(err)=="string" and err:find("unsupported string escape",1,true)~=nil,true,
            "opaque reference query does not approve unsupported literal values")
        eq(#Tree.Names(Tree.root),#refs,"failed value traversal does not poison reference facts")
        local foreign=must(Source.Build("local value=1"))
        eq(pcall(foreign.analysis.syntax.Names,Tree.root),false,"reference query rejects foreign source nodes")
        local bad,why=Source.Build([=[local value='\x41']=])
        eq(bad,nil,"direct unsupported literal keeps its existing analysis refusal")
        eq(why.code,"unsupported","direct literal support boundary remains")
    end)
    case("container and delayed Class aliases still block pending construction",function()
        for _,value in ipairs({"{class=_editor_class['K']}","function() return _editor_class['K'] end"}) do
            local initial=source:gsub("local function helper%(n%) return counter%+n end\n","")
                :gsub("_editor_class%['K'%]=Class%(boss%)",
                    "_editor_class['K']=Class(boss)\nlocal Alias="..value.."\nlocal function helper(n) return counter+n end")
            local f=fixture(initial);local snapshot=f.capture.snapshot;local class=f.classes.K
            local candidate=initial:gsub("Class%(boss%)","Class(_object)")
                :gsub("return counter%+n","return (Alias and counter or 0)+n+10")
            local p,d=prepare(f,candidate,{"local:helper"})
            eq(#p.dependencies.safe_roots,0,"pending construction blocks the requested alias consumer")
            eq(#p.dependencies.blocked_roots,1,"one original root is blocked")
            eq(p.dependencies.blocked_roots[1].root_id,"local:helper","Class alias refusal stays on helper root")
            eq(p.dependencies.blocked_roots[1].reason.code,"unsupported","Class alias refusal is explicit")
            local receipt=must(publish(f,p))
            eq(receipt.changed,false,"alias-dependent helper has no publication")
            eq(f.capture.snapshot,snapshot,"alias refusal retains actual file version")
            eq(f.classes.K,class,"candidate Class construction is not replayed")
            eq(Anchor.Get(f.entry,"helper")(1),4,"original helper remains installed")
            local model,witness=account(f,d.source);must(model,witness)
            eq(model.complete,false,"pending construction cannot be acknowledged through alias")
            eq(witness,nil,"alias-blocked source receives no completion witness")
        end
    end)
    case("field labels and string contents do not invent Class aliases",function()
        local initial=source:gsub("local function helper%(n%) return counter%+n end\n","")
            :gsub("_editor_class%['K'%]=Class%(boss%)",
                "_editor_class['K']=Class(boss)\nlocal Alias={_editor_class='_editor_class'}\nlocal function helper(n) return counter+n end")
        local f=fixture(initial);local class=f.classes.K
        local candidate=initial:gsub("Class%(boss%)","Class(_object)")
            :gsub("return counter%+n","return (Alias and counter or 0)+n+10")
        local p,d=prepare(f,candidate,{"local:helper"})
        eq(#p.dependencies.blocked_roots,0,"a field label or string cannot create a registry dependency")
        local receipt=must(publish(f,p))
        eq(receipt.changed,true,"independent helper can publish beside pending construction")
        eq(Anchor.Get(f.entry,"helper")(1),14,"independent helper uses retained live state")
        eq(f.classes.K,class,"unpublished Class identity stays original")
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"safe helper publication does not adopt the new Class definition")
        eq(witness,nil,"pending Class structure still has no completion witness")
    end)
    case("complete actual no-op uses every owner's read witness without rescanning",function()
        local f=fixture();local d=discover(f,source);local op=operation(f,d)
        no_scan(function(count)
            local p=must(FileApply.Prepare(f.driver,d,op))
            eq(#p.entries,3,"all original Local/Class/Card owners prepare")
            local class=piece(p,ClassAdapter)
            eq(#class.raw_writes,0,"readonly Class contributes no raw writes")
            eq(class.proposed_group,class.base_group,"unchanged Class retains actual group")
            local receipt=must(publish(f,p))
            eq(receipt.changed,false,"genuine unchanged receipt")
            local model,witness,fresh=account(f,d.source);must(model,witness);must(witness)
            eq(model.complete,true,"actual three-owner source is complete")
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
    case("unconsumed unsupported initializer stays pending while helper commits",function()
        local f=fixture();local before=Anchor.Get(f.entry,"counter")
        local candidate=source:gsub("local counter=3",
            [=[local counter={nested=function() return '\x41' end}]=])
            :gsub("return counter%+n","return counter+n+1")
        local p,d=prepare(f,candidate);local receipt=must(publish(f,p))
        eq(receipt.changed,true,"supported helper produces a real changed receipt")
        eq(Anchor.Get(f.entry,"counter"),before,"initializer never replaces shared state")
        eq(f.classes.K.cards[1]:init(2),6,"retained callback uses new helper and old scalar")
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"unexecuted initializer prevents full completion")
        eq(witness,nil,"pending initializer has no completion witness")
        eq(pending(model,"local:counter"),true,"initializer remainder survives publication")
        eq(pending(model,"local:helper"),false,"published helper uses actual version")
    end)
    case("unsupported selected helper cannot publish or clear its candidate",function()
        local f=fixture();local before=Anchor.Get(f.entry,"helper");local snapshot=f.capture.snapshot
        local candidate=source:gsub("return counter%+n",
            [=[error('candidate body executed'); return '\x41']=])
        local d=discover(f,candidate)
        local Tree=d.source.analysis.syntax
        eq(#Tree.Names(Tree.root)>0,true,"reference query runs on the same selected source first")
        local p=must(FileApply.Prepare(f.driver,d,operation(f,d)))
        eq(#p.dependencies.blocked_roots>0,true,"selected unsupported body blocks dependent roots")
        local receipt=must(publish(f,p));eq(receipt.changed,false,"refusal produces no installation")
        eq(f.capture.snapshot,snapshot,"refusal retains actual file snapshot")
        eq(Anchor.Get(f.entry,"helper"),before,"refusal retains actual helper")
        eq(Anchor.Get(f.entry,"counter"),3,"refusal retains scalar state")
        eq(f.classes.K.cards[1]:init(2),5,"retained callback behavior stays old")
        local model,witness=account(f,d.source);must(model,witness)
        eq(model.complete,false,"unsupported helper remains pending")
        eq(witness,nil,"unsupported helper cannot be ACKed")
        eq(pending(model,"local:helper"),true,"helper remainder is retained")
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
        eq(piece(p,Card).card_plan.requires_file_check,true,"selected optional deletion requests file proof")
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
    case("unsupported setter inside the contiguous card block is rejected at discovery",function()
        local f=fixture();local snapshot=f.capture.snapshot;local before=f.classes.K.cards[1].frame
        local candidate=source.."\n_tmp_sc.custom=1"
        local d,err=Planning.Discover(f,must(Source.Build(candidate)),1)
        eq(d,nil,"contiguous unsupported setter produces no discovery")
        eq(err.phase,"match","unsupported setter refused before preparation")
        eq(err.code,"unsupported","unsupported assignment diagnostic")
        eq(err.message,"unsupported card assignment: custom","precise contiguous card boundary")
        eq(f.capture.snapshot,snapshot,"discovery refusal retains actual publication")
        eq(f.classes.K.cards[1].frame,before,"discovery refusal leaves callback untouched")
        eq(f.transactions,0,"discovery refusal never enters transaction")
    end)
    case("unchanged orphan setter cannot authorize deletion",function()
        -- The local statement ends the single-card block, so this remains the
        -- separate reconciliation hazard rather than the Match refusal above.
        local initial=source.."\nlocal separator=0\n_tmp_sc.custom=1";local f=fixture(initial)
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
        for _,owner in ipairs({Local,ClassAdapter,Card}) do
            local fragment=piece(p,owner);local evidence=fragment.file_evidence
            fragment.file_evidence=nil
            local report,err=FileApply.Collect(p);eq(report,nil,"missing original owner coverage refuses: "..owner.Id)
            eq(err.code,"ownership","missing coverage diagnostic")
            fragment.file_evidence=evidence
        end
        local card=piece(p,Card).file_evidence
        local index=next(card.before.claims);assert(index)
        piece(p,Local).file_evidence.before.claims[index]="local:fake"
        local report,err=FileApply.Collect(p);eq(report,nil,"cross-owner whole-statement claim collision refuses")
        eq(err.code,"ownership","coverage collision diagnostic")
        eq(f.transactions,0,"coverage refusals never enter transaction")
    end)
    for _,tx in ipairs(controllers) do tx:Release() end
    if environment then environment:Restore() end
    return {passed=passed,failed=failed,failures=failures}
end
return M
