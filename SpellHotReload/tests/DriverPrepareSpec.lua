-- Contract-5 preparation: pure discovery selection is tested separately.
-- Synthetic owners below prove dispatch only; the final case uses REAL Local/Card.
local M={}
local serial=0
function M.run()
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Fixture=require("SpellHotReload.tests.PlanningFixture")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Syntax=require("SpellHotReload.Source.SyntaxTree")
    local passed,failed,failures=0,0,{}
    local function eq(a,b,label) assert(rawequal(a,b),label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function copy(t) local r={};for k,v in next,t do r[k]=v end;return r end
    local traps,mutations=0,0
    local hostile=setmetatable({},{__index=function() traps=traps+1;error("hostile index") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end})
    local controllers={}
    local saved={boss=rawget(_G,"boss"),classes=rawget(_G,"_editor_class"),tmp=rawget(_G,"_tmp_sc"),prepare=Driver.PrepareDiscovery}
    local ids={"local","host","value"} -- Domain fixtures, NOT wrappers around production adapters.
    local function fixture()
        serial=serial+1
        local entry=must(Load.Capture("local state=1",{name="Prepare_Boss.lua"}));entry.file="Prepare_Boss.lua"
        local f={entry=entry,session="DriverPrepare:"..serial,driver=Driver.New(),adapters={},calls={},roots={}}
        local pieces={}
        for i,id in ipairs(ids) do
            local owner={Id=id,ContractVersion=5}
            local ref={owner=owner,id=1};local def={definition_version=1,unit_ref=ref}
            local key=id..":unit"
            local record={key=key,kind="fixture",definition=def,definition_version=1}
            pieces[i]={owner=owner,owner_id=id,state={},units={{unit_ref=ref,private_ref=def}},
                records={record},functions={},edges={},initial={},identity_objects={},
                authority={cells={},raws={},forbidden={}}}
            owner.Match=function(source,common)
                eq(source,common.source,"synthetic Match receives common facts")
                return {units={{key=key,carrier=id,source_ranges={{first=i,last=i}},context={tag=key}}},
                    claims={{kind="definition",key=key,unit_key=key}},context={tag=id}}
            end
            owner.Reconcile=function(previous,candidate,context)
                local e=candidate.by_key[key];local private={tag=key,previous=previous.records[1]}
                local unit={unit_ref=ref,private_ref=private,status="corresponding",candidate_entry=e,previous_records=previous.records}
                return {rows={{status="corresponding",previous=previous.records[1],candidate={entry=e},
                    reason="fixture correspondence",evidence={"original reference"},dependencies={},conditions={}}},
                    view={source=candidate.common.source},units={unit},exports={{unit_ref=ref,conditions={}}}}
            end
            owner.Locate=function(unit,c)
                f.calls[#f.calls+1]="locate:"..id
                eq(c.phase,"locate","unit Locate phase");eq(c.scope,"unit","unit Locate scope")
                eq(c.adapter.unit,unit.private_ref,"Locate private unit identity")
                return {unit=unit,context=c}
            end
            owner.Inject=function(handle,unit,c)
                eq(c.common,f.discovery.snapshot.common,"every phase shares complete common")
                eq(c.operation.source,f.discovery.source,"every phase shares full facts")
                eq(c.adapter.file,f.discovery.snapshot.adapter_contexts[id],"original owner file context")
                if c.scope=="unit" then
                    f.calls[#f.calls+1]="resolve:"..id
                    eq(c.phase,"resolve","unit Inject resolves finite needs")
                    eq(handle.unit,unit,"original located unit")
                    eq(handle.context.operation,c.operation,"new phase retains exact operation")
                    eq(handle.context.view,c.view,"new phase retains exact private view")
                    eq(c.adapter.unit,unit.private_ref,"unit context is private correspondence")
                    eq(c.request.unit_ref,ref,"public request has original unit ref")
                    return {selection_ref={},needs={},affected={}}
                end
                eq(unit,nil,"owner aggregation has no fake public unit")
                eq(handle.kind,"SpellHotReload.Driver.OwnerHandle","owner envelope")
                eq(handle.operation,c.operation,"owner handle exact operation")
                eq(handle.owner,owner,"owner envelope identity")
                if c.phase=="resolve" then
                    f.calls[#f.calls+1]="constrain:"..id
                    return {operation=c.operation,owner=owner,blocked_roots={},evidence={}}
                end
                f.calls[#f.calls+1]="prepare:"..id
                eq(c.phase,"prepare","owner preparation phase")
                eq(c.selection.owner,owner,"final owner selection")
                return {operation=c.operation,owner=owner,base_group=c.base_group,proposed_group=c.base_group,
                    joins={},cell_writes={},raw_writes={},read_set={},capture_reads={},owner_guard=function() return true end}
            end
            owner.Commit=function() mutations=mutations+1;error("implicit Commit forbidden") end
            owner.Restart=function() mutations=mutations+1;error("implicit Restart forbidden") end
            f.adapters[id]=owner;must(f.driver:RegisterDiscovery(owner))
        end
        f.capture=must(Files.Capture(entry,f.session,pieces))
        f.discovery=must(f.driver:DiscoverPublished(entry.file,entry.source,must(Files.Publication(f.capture)),
            {capture=f.capture,generation=4}))
        for _,group in ipairs(f.discovery.reconciliation.groups) do
            f.roots[group.owner_id]={root_id=group.owner_id,unit_ref=group.units[1].unit_ref,selector={tag=group.owner_id}}
        end
        for _,owner in pairs(f.adapters) do
            owner.Match=function() mutations=mutations+1;error("Match replay forbidden") end
            owner.Reconcile=function() mutations=mutations+1;error("Reconcile replay forbidden") end
        end
        function f.operation(requested)
            local roots={};for _,id in ipairs(requested or ids) do roots[#roots+1]=f.roots[id] end
            return {file=entry.file,entry=entry,anchor=entry.anchor,loaded_source=entry.loaded_source,
                source=entry.source,capture=f.capture,base_snapshot=f.capture.snapshot,session_id=f.session,
                generation=4,mode="file",roots=roots}
        end
        return f
    end
    local function refuse(change,where,label)
        local f=fixture();local d,op=f.discovery,f.operation()
        local driver=f.driver
        local nd,no,nr=change(f,d,op);d=nd or d;driver=nr or driver
        if no==false then op=nil elseif no~=nil then op=no end
        local called,p,e,phase=pcall(driver.PrepareDiscovery,driver,d,op)
        eq(called,true,label.." safely refuses");eq(p,nil,label.." no partial preparation")
        eq(type(e),"table",label.." structured diagnostic")
        eq(e.phase,where,label.." diagnostic phase");eq(phase,where,label.." dispatch phase")
        eq(#f.calls,0,label.." all input validation precedes hooks")
    end
    local ok,problem=pcall(function()
        local f=fixture();local op=f.operation({"value","host","local"})
        local p=must(f.driver:PrepareDiscovery(f.discovery,op))
        eq(p.kind,"SpellHotReload.Driver.PreparedDiscovery","preparation artifact")
        eq(p.version,2,"owner aggregate format");eq(p.owner,f.driver,"original driver")
        eq(p.discovery,f.discovery,"complete discovery retained");eq(p.operation,op,"explicit original operation")
        eq(#p.entries,3,"every original owner prepares")
        eq(table.concat(f.calls,","),"locate:value,resolve:value,locate:host,resolve:host,locate:local,resolve:local,constrain:local,constrain:host,constrain:value,prepare:local,prepare:host,prepare:value",
            "explicit root resolution then original owner constraints/preparation")
        for i,id in ipairs(ids) do
            local r=p.entries[i]
            eq(r.owner,f.adapters[id],"owner ordering independent of root ordering")
            eq(r.base_group,f.capture.snapshot.owners[i],"original owner group")
            eq(r.context.operation,op,"original preparation context")
            eq(r.fragment.operation,op,"original prepared fragment")
            eq(r.fragment.owner,r.owner,"fragment owner identity")
            eq(r.handle.by_ref[f.roots[id].unit_ref].unit,r.output.units[1],"located correspondence identity")
        end
        eq(#f.discovery.index.list,3,"complete discovery remains indexed")
        f.calls={};local one=must(f.driver:PrepareDiscovery(f.discovery,f.operation({"host"})))
        eq(#one.entries,3,"one root retains all read-only owners")
        eq(#one.entries[1].handle.located,0,"unrequested owner has no fake Locate")
        eq(#one.entries[2].handle.located,1,"requested unit located once")
        eq(one~=p and one.entries~=p.entries,true,"no cached preparation")
        f.calls={};local empty=must(f.driver:PrepareDiscovery(f.discovery,f.operation({})))
        eq(#empty.entries,3,"empty roots still prepare every owner")
        eq(table.concat(f.calls,","),"constrain:local,constrain:host,constrain:value,prepare:local,prepare:host,prepare:value","empty roots only aggregate owner reads")
        eq(f.driver.Commit,nil,"no implicit publication facade")
        refuse(function(_,d) return hostile end,"locate","hostile discovery")
        refuse(function(_,d) return nil,hostile end,"locate","hostile operation")
        refuse(function() return nil,false end,"locate","nil operation")
        refuse(function() return nil,nil,Driver.New() end,"locate","foreign driver")
        for _,field in ipairs({"capture","base_snapshot","source","entry"}) do
            refuse(function(_,_,o) o[field]={} end,"locate","foreign "..field)
        end
        refuse(function(_,_,o) o.generation=5 end,"locate","generation mismatch")
        refuse(function(_,_,o) o.roots=nil end,"resolve","missing roots")
        refuse(function(_,_,o) o.roots={o.roots[1],o.roots[1]} end,"resolve","duplicate roots")
        refuse(function(_,_,o) o.roots={[2]=o.roots[1]} end,"resolve","sparse roots")
        refuse(function(_,_,o) o.roots={{root_id="foreign",unit_ref={},selector={}}} end,"resolve","foreign root ref")
        refuse(function(_,_,o) o.roots[2].selector=hostile end,"resolve","foreign private selector")
        refuse(function(f) f.adapters.value.Inject=false end,"locate","later invalid owner contract")
        refuse(function(f) f.adapters.value.Id="replacement" end,"locate","later owner identity changed")
        for _,item in ipairs({{"locate","locate",2},{"unit","resolve",3},{"constraint","resolve",7},{"prepare","inject",10}}) do
            for _,thrown in ipairs({false,true}) do
                f=fixture();local owner=f.adapters.host
                local hook=item[1]=="locate" and "Locate" or "Inject";local original=owner[hook]
                local reason={phase=item[2],code="stale",message="specific refusal",stage="owner detail"}
                owner[hook]=function(h,u,c)
                    local selected=item[1]=="locate" or item[1]=="unit" and c.scope=="unit"
                        or item[1]=="constraint" and c.scope=="owner" and c.phase=="resolve"
                        or item[1]=="prepare" and c.scope=="owner" and c.phase=="prepare"
                    if selected then if thrown then error(hostile,0) else return nil,reason end end
                    return original(h,u,c)
                end
                local value,e,where=f.driver:PrepareDiscovery(f.discovery,f.operation())
                eq(value,nil,"no partial artifact from "..item[1])
                eq(where,item[2],"precise failure phase "..item[1])
                if thrown then eq(e.cause,hostile,"opaque thrown cause retained")
                else eq(e,reason,"explicit diagnostic identity retained") end
                eq(#f.calls,item[3],"later hooks short-circuit "..item[1])
            end
        end
        eq(mutations,0,"generic preparation never replays discovery or publishes")
        eq(traps,0,"opaque refusals never invoke hostile metamethods")
        -- Real production owners: a shared helper and one Card root, no wrapper API.
        local names={"before","init","frame","render","beforedel","del","after"};local defaults={}
        for _,name in ipairs(names) do defaults[name]=function() end end
        _G.boss={card={New=function(name)
            local card={name=name,is_combat=true};for _,cb in ipairs(names) do card[cb]=defaults[cb] end;return card
        end}}
        _G._editor_class={K={}}
        local source=table.concat({"local counter=3","local function helper(n) return counter+n end",
            "local function independent() return 500 end","_editor_class['K'].cards={}",
            "_tmp_sc=boss.card.New('A',1,2,3,100)","function _tmp_sc:init(n) return helper(n) end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)","_tmp_sc=boss.card.New('B',1,2,3,100)",
            "function _tmp_sc:init(n) return helper(n)+100 end","table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
        local entry=must(Load.Capture(source,{name="RealPrepare_Boss.lua"}));entry.file="RealPrepare_Boss.lua"
        local real=must(Fixture.Capture(entry,"RealPrepareSpec:"..serial,_editor_class,defaults))
        local classes=_editor_class;local a,b=classes.K.cards[1],classes.K.cards[2]
        local before=real.capture.snapshot;local old_helper=Anchor.Get(entry,"helper");local old_init=a.init
        local candidate=source:gsub("counter%+n","counter+n+10"):gsub("return helper%(n%) end","return helper(n)+1 end"):gsub("return 500","return 501")
        local facts=must(Source.Build(candidate));local discovery=must(Fixture.Discover(real,facts,1))
        local function live()
            return {capture=real.capture,snapshot=real.capture.snapshot,entry=entry,session_id=real.session,
                content=candidate,generation=1,classes=classes,binding={class_key="K",slot=1,card=a,
                    name="A",names={"A","B"},mode="practice",include_previous=false}}
        end
        local calls=0;local original_prepare=Driver.PrepareDiscovery
        Driver.PrepareDiscovery=function(self,d,o)
            calls=calls+1;eq(self,real.driver,"real original driver");eq(d,discovery,"real full discovery")
            return original_prepare(self,d,o)
        end
        local old_build,old_analyze,old_lex=Source.Build,IR.Analyze,Syntax.Parse
        local function forbidden() error("preparation rebuilt supplied full-file facts") end
        Source.Build,IR.Analyze,Syntax.Parse=forbidden,forbidden,forbidden
        local ran,prepared,report,operation=pcall(Fixture.Prepare,real,discovery,{mode="current",refresh=live})
        Source.Build,IR.Analyze,Syntax.Parse=old_build,old_analyze,old_lex
        Driver.PrepareDiscovery=original_prepare
        if not ran then error(prepared,0) end
        must(prepared,report);eq(calls,1,"real owners enter common preparation once")
        eq(prepared.operation,operation,"real operation identity")
        eq(report.prepared,prepared,"file policy consumes same prepared owners")
        eq(#operation.roots,1,"Current starts with only frozen Card root")
        eq(#prepared.entries,2,"both real owners contribute")
        eq(#prepared.entries[1].fragment.cell_writes,1,"only required changed helper prepares")
        eq(#prepared.entries[2].fragment.raw_writes,1,"only selected changed callback prepares")
        eq(Anchor.Get(entry,"helper"),old_helper,"preparation has no cell write")
        eq(a.init,old_init,"preparation has no raw publication")
        eq(real.capture.snapshot,before,"preparation has no snapshot publication")
        eq(Anchor.Get(entry,"independent")(),500,"unrequested Local edit remains actual")
        local tx=must(Tx.New(real.session));controllers[#controllers+1]=tx
        local receipt=must(Fixture.Publish(real,prepared,tx))
        eq(receipt.changed,true,"only explicit common publish produces changed receipt")
        eq(receipt.snapshot.revision,1,"both owners advance file once")
        eq(a:init(2),16,"selected real callback uses changed helper")
        eq(b:init(2),115,"retained sibling sees actual helper without candidate wrapper")
        local card_group=must(Files.GetAdapterRecords(real.capture,Card));local local_group=must(Files.GetAdapterRecords(real.capture,Local))
        eq(card_group.state.units["card:1:K:1"].definition_version,2,"selected Card definition version")
        eq(card_group.state.units["card:1:K:2"].definition_version,1,"sibling definition retained")
        eq(local_group.state.by_name.helper.definition_version,2,"required Local version installed")
        local model,witness=Fixture.Remaining(real,facts,1,live);must(model,witness)
        eq(model.complete,false,"fresh actual accounting retains independent pending edit")
        local independent_pending=false
        for _,row in ipairs(model.pending) do
            if row.key=="local:independent" then independent_pending=true end
        end
        eq(independent_pending,true,"fresh remainder identifies the unselected Local edit")
        eq(witness,nil,"partial actual adoption has no completion witness")
    end)
    Driver.PrepareDiscovery=saved.prepare
    for _,controller in ipairs(controllers) do controller:Release() end
    _G.boss,_G._editor_class,_G._tmp_sc=saved.boss,saved.classes,saved.tmp
    if not ok then failed=failed+1;failures[#failures+1]=type(problem)=="string" and problem or "opaque spec error" end
    return {passed=passed,failed=failed,failures=failures}
end
return M
