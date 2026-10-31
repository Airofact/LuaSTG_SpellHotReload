-- Real Local five-hook/Driver/FileCommit integration. The optional empty owner
-- below is a domain fixture; it does not prove production Card business rules.
local M={}
local serial=0
function M.run()
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local Compose=require("SpellHotReload.Source.Compose")
    local IR=require("SpellHotReload.Source.TopLevelIR")
    local Tree=require("SpellHotReload.Source.SyntaxTree")
    local passed,failed,failures=0,0,{}
    local controllers={}
    local function eq(a,b,label) assert(rawequal(a,b),label);passed=passed+1 end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function copy(t) local out={};for k,v in next,t do out[k]=v end;return out end
    local function case(label,body)
        local ok,err=pcall(body)
        if not ok then failed=failed+1;failures[#failures+1]=label..": "..(type(err)=="string" and err or "opaque error") end
    end
    local source=table.concat({
        "local counter=3",
        "local flag=false",
        "local empty=nil",
        "local shared={}",
        "local function helper() counter=counter+1;return counter,flag,empty,shared end",
        "local alias=helper",
        "local function consumer() return helper() end",
        "local function independent() return 500 end",
        "local function unused() return 900 end",
    },"\n")
    local function fixture(options)
        serial=serial+1;options=options or {}
        local entry=must(Load.Capture(source,{name="LocalAdapter_Boss.lua"}))
        entry.file="LocalAdapter_Boss.lua"
        local session="LocalAdapterSpec:"..serial
        local driver=Driver.New();must(driver:RegisterDiscovery(Local))
        local initial=must(driver:Discover(entry.file,entry.source,{session_id=session,registry_entry=entry,loaded_source=entry.loaded_source}))
        local contribution=must(Local.Capture(entry,session,initial.snapshot))
        local pieces={contribution}
        local f={entry=entry,driver=driver,session=session,generation=0,options=options,
            registrations=0,transactions=0,observer_calls={},prepared_facts={}}
        if options.observer then
            local observer={Id="observer",ContractVersion=7}
            observer.Match=function() return nil end
            observer.BuildContext=function(source,units) return {source=source,units=units,tag="empty-owner"} end
            observer.Reconcile=function(previous,candidate)
                return {rows={},view={base=previous,source=candidate.common.source},units={},exports={}}
            end
            observer.Locate=function() error("empty owner must have no synthetic unit") end
            observer.Inject=function(handle,unit,c)
                eq(unit,nil,"observer receives owner envelope without fake unit")
                eq(c.scope,"owner","observer aggregate scope")
                eq(handle.owner,observer,"observer exact ownership")
                f.observer_calls[#f.observer_calls+1]=c.phase
                if options.throw_phase==c.phase then error(options.throw_value,0) end
                if c.phase=="resolve" then
                    local blocks,seen={},{}
                    for _,fact in ipairs(c.dependencies.source_facts) do
                        eq(fact.source,c.common.source,"observer consumes same source")
                        eq(Source.Site(fact.source,fact.node)~=nil,true,"observer consumes owned AST node")
                        local body=fact.source.analysis.syntax.FunctionSource(fact.node,false)
                        if options.block_body and body:find(options.block_body,1,true) and not seen[fact.root_id] then
                            seen[fact.root_id]=true
                            blocks[#blocks+1]={root_id=fact.root_id,reason={code="unsupported",message="fixture selected-AST business block"}}
                        end
                    end
                    return {operation=c.operation,owner=observer,blocked_roots=blocks,evidence={}}
                end
                f.prepared_facts=c.dependencies.source_facts
                if options.prepare_failure then return nil,options.prepare_failure end
                return {operation=c.operation,owner=observer,base_group=c.base_group,proposed_group=c.base_group,
                    joins={},cell_writes={},raw_writes={},read_set={},capture_reads={},
                    owner_guard=function()
                        if options.guard_failure then return nil,options.guard_failure end
                        return true
                    end}
            end
            observer.Commit=function(h,p,c)
                f.registrations=f.registrations+1
                eq(f.transactions,0,"registration has not published")
                return c.adapter.register(h,p,c)
            end
            pieces[2]={owner=observer,owner_id=observer.Id,state={},units={},records={},functions={},edges={},
                initial={},identity_objects={},authority={cells={},raws={},forbidden={}}}
            must(driver:RegisterDiscovery(observer));f.observer=observer
        end
        f.capture=must(Files.Capture(entry,session,pieces))
        f.tx=must(Tx.New(session));controllers[#controllers+1]=f.tx
        return f
    end
    local function discover(f,content)
        f.generation=f.generation+1
        local facts=must(Source.Build(content))
        local common={capture=f.capture,generation=f.generation}
        return must(f.driver:DiscoverPublished(f.entry.file,facts,must(Files.Publication(f.capture)),common)),facts
    end
    local function operation(f,d,names)
        local roots,available={},{}
        for _,r in ipairs(Local.Roots(d.reconciliation.groups[1].view)) do available[r.root_id]=r end
        if names==nil then roots=Local.Roots(d.reconciliation.groups[1].view)
        else for _,name in ipairs(names) do roots[#roots+1]=assert(available["local:"..name]) end end
        return {capture=f.capture,base_snapshot=f.capture.snapshot,source=d.source,
            file=f.entry.file,entry=f.entry,anchor=f.entry.anchor,session_id=f.session,
            loaded_source=source,generation=f.generation,mode="file",roots=roots}
    end
    local function prepare(f,content,names)
        local d=discover(f,content);local op=operation(f,d,names)
        return must(f.driver:PrepareDiscovery(d,op)),d,op
    end
    local function publish(f,p)
        local live={capture=f.capture,snapshot=f.capture.snapshot,entry=f.entry,session_id=f.session,
            content=p.operation.source.content,generation=p.operation.generation}
        local ran,receipt,err=f.tx:Run(function(token)
            return f.driver:CommitDiscovery(p,function(op,fragments)
                f.transactions=f.transactions+1
                return f.tx:Commit(token,op,fragments,live)
            end)
        end)
        eq(ran,true,"transaction dispatch returned normally")
        return receipt,err
    end
    local function no_rescan(body)
        local create,analyze=Compose.Create,IR.Analyze
        local count=0
        Compose.Create=function(...) count=count+1;return create(...) end
        IR.Analyze=function() error("preparation repeated whole-file IR analysis") end
        local ok,err=pcall(body,function() return count end)
        Compose.Create,IR.Analyze=create,analyze
        if not ok then error(err,0) end
    end
    case("Local-only no-change",function()
        local f=fixture();local base=f.capture.snapshot
        local d=discover(f,source);local op=operation(f,d)
        no_rescan(function(count)
            local p=must(f.driver:PrepareDiscovery(d,op))
            eq(#p.entries,1,"Local-only file prepares one original owner")
            eq(count(),0,"unchanged full selection constructs zero closures")
            eq(#p.entries[1].fragment.cell_writes,0,"unchanged full selection has no writes")
            local receipt=must(publish(f,p))
            eq(receipt.changed,false,"no-change receipt is real and unchanged")
            eq(f.capture.snapshot,base,"no-change retains exact snapshot")
            eq(base.revision,0,"no-change does not advance revision")
        end)
    end)
    case("two selected Apply preserve actual state",function()
        local f=fixture();local alias=f.entry.map.helper;local shared=f.entry.map.shared
        must(Anchor.Set(f.entry,"counter",41))
        local first=source:gsub("counter%+1","counter+2"):gsub("return 900","return 901")
        local d=discover(f,first);local op=operation(f,d,{"consumer"})
        local prepared
        no_rescan(function(count)
            prepared=must(f.driver:PrepareDiscovery(d,op))
            eq(count(),1,"retained consumer demands only changed helper")
            local view=d.reconciliation.groups[1].view.version_view
            eq(view.by_name.unused.probe,nil,"unrequested changed function is not probed")
            eq(#prepared.entries[1].fragment.cell_writes,1,"only selected helper publishes")
        end)
        local receipt=must(publish(f,prepared))
        eq(receipt.changed,true,"real changed receipt for first Apply")
        eq(f.capture.snapshot.revision,1,"first Apply installs one revision")
        local n,flag,empty,t=(must(Anchor.Get(f.entry,"consumer")))()
        eq(n,43,"retained consumer observes new helper over live counter")
        eq(flag,false,"false state preserved");eq(empty,nil,"nil state preserved")
        eq(t,shared,"table identity preserved")
        eq(Anchor.Get(f.entry,"alias"),alias,"independent alias keeps old function")
        eq((must(Anchor.Get(f.entry,"alias")))(),44,"old alias still executes old increment")
        local second=first:gsub("counter%+2","counter+3")
        local p,d2=prepare(f,second,{"consumer"})
        receipt=must(publish(f,p))
        eq(receipt.changed,true,"real changed receipt for second Apply")
        eq(f.capture.snapshot.revision,2,"second Apply advances once")
        eq((must(Anchor.Get(f.entry,"consumer")))(),47,"second Apply retains evolving scalar cell")
        eq(Anchor.Get(f.entry,"shared"),shared,"second Apply retains shared table")
        local group=must(Files.Owner(f.capture,Local))
        eq(group.state.by_name.helper.definition_version,3,"helper has its own actual version")
        eq(group.state.by_name.consumer.definition_version,1,"affected consumer source version stays actual")
        eq(group.state.by_name.unused.definition_version,1,"pending function source version stays actual")
        local fresh=must(f.driver:DiscoverPublished(f.entry.file,d2.source,must(Files.Publication(f.capture)),
            {capture=f.capture,generation=f.generation}))
        eq(fresh.source,d2.source,"post-publication discovery consumes same complete source")
        eq(fresh.reconciliation.groups[1].view.version_view.by_name.helper.changed,false,"fresh comparison uses installed helper")
        eq(fresh.reconciliation.groups[1].view.version_view.by_name.unused.changed,true,"fresh comparison retains genuine remainder")
        local next_op=operation(f,fresh,{"consumer"})
        no_rescan(function(count)
            local verified=must(f.driver:PrepareDiscovery(fresh,next_op))
            eq(count(),0,"fresh Locate/actual checks do not rebuild unchanged definitions")
            local final=must(publish(f,verified))
            eq(final.changed,false,"fresh checked unchanged selection yields real no-op receipt")
            eq(f.capture.snapshot.revision,2,"fresh no-op does not advance actual versions")
        end)
    end)
    case("empty observer prunes selected AST root",function()
        local f=fixture({observer=true,block_body="counter+2"})
        local content=source:gsub("counter%+1","counter+2"):gsub("return 500","return 501")
        local before=f.entry.map.helper
        local p=prepare(f,content,{"consumer","independent"})
        eq(#p.entries,2,"empty original owner remains in prepared set")
        eq(table.concat(f.observer_calls,","),"resolve,prepare","empty owner performs both aggregate phases")
        eq(#p.dependencies.safe_roots,1,"independent root survives observer block")
        eq(p.dependencies.safe_roots[1].root_id,"local:independent","surviving root identity")
        eq(p.dependencies.blocked_roots[1].root_id,"local:consumer","business block keeps original root provenance")
        eq(#f.prepared_facts,1,"dropped root facts are absent at preparation")
        eq(f.prepared_facts[1].root_id,"local:independent","only surviving root syntax prepared")
        must(publish(f,p))
        eq(f.registrations,1,"empty owner registers once")
        eq(f.transactions,1,"both owners enter one transaction")
        eq(Anchor.Get(f.entry,"helper"),before,"blocked helper not installed")
        eq((must(Anchor.Get(f.entry,"independent")))(),501,"independent function installed")
        local group=must(Files.Owner(f.capture,Local))
        eq(group.state.by_name.helper.definition_version,1,"blocked helper version retained")
        eq(group.state.by_name.independent.definition_version,2,"safe definition version advanced")
    end)
    case("prepare and final guard failure",function()
        local specific={phase="inject",code="stale",message="fixture preparation refused"}
        local f=fixture({observer=true,prepare_failure=specific})
        local d=discover(f,source:gsub("counter%+1","counter+2"));local op=operation(f,d,{"consumer"})
        local before=f.capture.snapshot
        local p,err=f.driver:PrepareDiscovery(d,op)
        eq(p,nil,"later owner failure returns no partial prepared result")
        eq(err,specific,"specific preparation refusal preserved")
        eq(f.registrations,0,"prepare failure registers nothing")
        eq(f.transactions,0,"prepare failure publishes nothing")
        eq(f.capture.snapshot,before,"prepare failure leaves snapshot")
        f=fixture({observer=true,guard_failure={code="stale",message="fixture final guard refused"}})
        p=prepare(f,source:gsub("counter%+1","counter+2"),{"consumer"})
        before=f.capture.snapshot;local fn=f.entry.map.helper
        local receipt,why=publish(f,p)
        eq(receipt,nil,"final guard failure has no receipt");eq(why.code,"stale","guard diagnostic")
        eq(f.capture.snapshot,before,"final guard failure leaves snapshot")
        eq(Anchor.Get(f.entry,"helper"),fn,"final guard failure leaves function")
    end)
    case("aggregate hook exception has safe diagnostic",function()
        local traps=0
        local thrown=setmetatable({},{__index=function() traps=traps+1;error("hostile index") end,
            __tostring=function() traps=traps+1;error("hostile tostring") end})
        for _,phase in ipairs({"resolve","prepare"}) do
            local f=fixture({observer=true,throw_phase=phase,throw_value=thrown})
            local d=discover(f,source);local op=operation(f,d,{"consumer"})
            local called,value,why,where=pcall(f.driver.PrepareDiscovery,f.driver,d,op)
            eq(called,true,"aggregate "..phase.." throw safely normalized")
            eq(value,nil,"aggregate "..phase.." throw returns no partial preparation")
            eq(why.cause,thrown,"aggregate "..phase.." preserves thrown cause identity")
            eq(where,phase=="prepare" and "inject" or "resolve","aggregate failure phase")
            eq(f.transactions,0,"aggregate throw never publishes")
            eq(f.registrations,0,"aggregate throw never registers")
        end
        for _,hook in ipairs({"Locate","Inject"}) do
            local f=fixture();local d=discover(f,source);local op=operation(f,d,{"consumer"})
            local original=Local[hook]
            Local[hook]=function() error(thrown,0) end
            local called,value,why,where=pcall(f.driver.PrepareDiscovery,f.driver,d,op)
            Local[hook]=original
            eq(called,true,"unit "..hook.." throw safely normalized")
            eq(value,nil,"unit "..hook.." throw returns no partial preparation")
            eq(why.cause,thrown,"unit "..hook.." preserves thrown cause identity")
            eq(where,hook=="Locate" and "locate" or "resolve","unit failure phase")
            eq(f.transactions,0,"unit throw never publishes")
        end
        eq(traps,0,"exception boundary does not invoke hostile metamethods")
    end)
    case("empty selection retains all original reads",function()
        local f=fixture();local p=prepare(f,source,{})
        local replacement=function() end
        must(Anchor.Set(f.entry,"unused",replacement))
        local before=f.capture.snapshot;local receipt,why=publish(f,p)
        eq(receipt,nil,"external replacement of unselected function rejects no-op")
        eq(why.code,"stale","unselected read failure diagnostic")
        eq(f.capture.snapshot,before,"external replacement does not advance snapshot")
        eq(Anchor.Get(f.entry,"unused"),replacement,"external value is not overwritten")
    end)
    case("unsupported structure retains original owner reads",function()
        local f=fixture()
        local content=source:gsub("local function unused%(%) return 900 end","")
        local p,d=prepare(f,content)
        eq(d.reconciliation.groups[1].view.version_view,nil,"declaration removal has no supported version view")
        eq(#p.dependencies.safe_roots,0,"unsupported structure is not a safe update")
        eq(#p.dependencies.blocked_roots>0,true,"original roots retain explicit block diagnostics")
        eq(p.entries[1].fragment.proposed_group,f.capture.snapshot.owners[1],"unsupported structure retains exact actual group")
        local receipt=must(publish(f,p))
        eq(receipt.changed,false,"retained checked group gives unchanged receipt")
        eq(f.capture.snapshot.revision,0,"no definition removal is acknowledged by publication")
        eq(Anchor.Get(f.entry,"unused"),f.entry.map.unused,"removed candidate function stays live")
        local replacement=function() end
        p=prepare(f,content)
        must(Anchor.Set(f.entry,"unused",replacement))
        local value,why=publish(f,p)
        eq(value,nil,"blocked original function is still guarded")
        eq(why.code,"stale","blocked original read diagnostic")
    end)
    case("Local exact selection/location boundary",function()
        local f=fixture();local p,d,op=prepare(f,source:gsub("counter%+1","counter+2"),{"consumer"})
        local r=p.entries[1];local selected=r.context.selection
        local binding=Source.Declaration(d.source,"helper")
        local provider=must(Local.Provider(r.context.view,binding))
        eq(provider.unit_ref,r.context.view.by_name.helper.unit.unit_ref,"canonical Binding maps to original provider unit")
        eq(Local.Provider(r.context.view,copy(binding)),nil,"same-name copied binding cannot claim provider")
        eq(Local.Provider(r.context.view,{name="helper"}),nil,"name alone cannot claim provider")
        local first=r.context.base_group.state.entry.source
        local original=must(Source.Declaration(first,"helper"))
        local equivalent=must(Source.Build(d.source.content))
        eq(Local.Provider(r.context.view,Source.Declaration(equivalent,"helper")),nil,"same bytes do not share candidate declaration identity")
        eq(Local.Provider(r.context.view,original),nil,"first-load declaration cannot impersonate candidate")
        eq(Local.CapturedProvider(r.context.base_group,original),provider.unit_ref,"original declaration maps to stable captured unit")
        eq(Local.CapturedProvider(r.context.base_group,copy(original)),nil,"copied original declaration refused")
        eq(Local.CapturedProvider(r.context.base_group,binding),nil,"candidate declaration cannot impersonate first load")
        eq(Source.Declarations(d.source)[binding.ordinal],binding,"provider input is canonical IR declaration")
        local function reject(handle,selection,label)
            local c=copy(r.context);c.selection=selection
            local value,why=Local.Inject(handle,nil,c)
            eq(value,nil,label.." refused");eq(why.code,"ownership",label.." diagnostic")
        end
        local foreign=copy(r.handle);foreign.owner={}
        reject(foreign,selected,"foreign owner envelope")
        local absent=copy(r.handle);absent.by_ref={}
        reject(absent,selected,"missing real location")
        local incomplete=copy(selected);incomplete.units={}
        local consumer=d.reconciliation.groups[1].view.by_name.consumer.unit.unit_ref
        for _,unit in ipairs(selected.units) do
            if unit.unit_ref==consumer then incomplete.units[#incomplete.units+1]=unit end
        end
        reject(r.handle,incomplete,"same-root dependency omitted")
        local bad=copy(selected);bad.units={}
        for i,unit in ipairs(selected.units) do
            local u=copy(unit);u.roots={}
            for n,root in ipairs(unit.roots) do u.roots[n]=copy(root);u.roots[n].selection_ref={} end
            bad.units[i]=u
        end
        reject(r.handle,bad,"foreign private choice")
        local q=d.reconciliation.groups[1].view.by_name.helper
        local c=copy(r.context);c.scope="unit";c.phase="resolve"
        c.request={operation=op,view=c.view,root_id="foreign",unit_ref=q.unit.unit_ref,conditions={{}}}
        local value,why=Local.Inject(r.handle.by_ref[q.unit.unit_ref].handle,q.unit,c)
        eq(value,nil,"foreign Local condition rejected");eq(why.code,"ownership","condition diagnostic")
        c.request.conditions={};c.request.selector={}
        value,why=Local.Inject(r.handle.by_ref[q.unit.unit_ref].handle,q.unit,c)
        eq(value,nil,"foreign Local root selector rejected")
        eq(why.code,"ownership","selector diagnostic")
    end)
    for _,controller in ipairs(controllers) do controller:Release() end
    return {passed=passed,failed=failed,failures=failures}
end
return M
