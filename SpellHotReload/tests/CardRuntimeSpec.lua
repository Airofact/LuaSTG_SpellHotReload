-- Adapter-owned runtime rules; all objects here are synthetic. Existing
-- VersionedApply/Monitor suites cover genuine first-load production transactions.
-- No Plugin receiver/cache, candidate execution, join, cell write or publication.
local M={}
function M.run()
    local Card=require("SpellHotReload.Card")
    local Target=require("SpellHotReload.CardTarget")
    local Cards=require("SpellHotReload.CardVersions")
    local Binding=require("SpellHotReload.PracticeBinding")
    local passed,failed,failures=0,0,{}
    local function check(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
    local function has(value,part,label)
        check(type(value)=="string" and value:find(part,1,true)~=nil,label)
    end
    local function reject(fn,part,label)
        local v,e=fn();eq(v,nil,label.." refused");has(e,part,label.." reason")
    end
    local function copy(v) local r={};for k,x in next,v do r[k]=x end;return r end
    local services={Resolve=Target.Resolve,Check=Target.Check,LocateDiscovery=Target.LocateDiscovery,
        CheckDiscovery=Target.CheckDiscovery,CompareLocated=Cards.CompareLocated,
        Select=Cards.Select,Describe=Cards.Describe,Restart=Binding.Restart,IsReplay=Binding.IsReplay}
    local old_setup,old_join=debug.setupvalue,debug.upvaluejoin
    local old_jit=rawget(_G,"jit")
    local trace={}
    local function mark(v) trace[#trace+1]=v end
    local key="card:1:K:2"
    local anchor=function() end
    local card={name="Live",init=function() return 11 end}
    local placeholder={is_combat=false}
    local list={placeholder,card}
    local class={cards=list}
    local classes={K=class}
    local entry={anchor=anchor,reloadable=true}
    local snapshot={units={[key]={callbacks={init={fn=card.init}}}}}
    local capture={snapshot=snapshot,ownership={{class_key="K",class=class,list=list,slots={placeholder,card}}}}
    local initial={class_key="K",slot=2,card=card,name="Live",mode="practice",
        include_previous=true,names={"","Live"}}
    local target={file="Runtime_Boss.lua",session_id="runtime:1",entry=entry,classes=classes,
        class_key="K",class=class,list=list,card=card,slot=2,name="Live",include_previous=true,key=key}
    local proof={}
    local live={binding=initial,classes=classes,entry=entry,snapshot=snapshot,session_id=target.session_id}
    local common={file="Runtime_Boss.lua",content="synthetic candidate"}
    local Driver=require("SpellHotReload.Driver")
    local driver=Driver.New();assert(driver:RegisterDiscovery(Card))
    local discovery=assert(driver:Discover(common.file,
        "_editor_class['K'].cards={}\n_tmp_sc=boss.card.New('Live',1,2,3,4)\nfunction _tmp_sc:init() end\ntable.insert(_editor_class['K'].cards,_tmp_sc)"))
    common=discovery.snapshot.common
    local discovered=discovery.snapshot.by_key["card:K"]
    local unit=discovered.unit
    local location,report,selection={match="identity",target=target,
        discovery=discovery.snapshot,entry=discovered},{},{}
    local model={selected={key}}
    local function refresh() mark("refresh");return live end
    local function refusal(value,err,part,label)
        eq(value,nil,label.." refused");has(err,part,label.." reason")
    end
    local ok,problem=pcall(function()
        local frozen=Card.FreezeBinding(initial)
        eq(frozen.card,card,"binding keeps live identity")
        eq(frozen.include_previous,true,"binding keeps restart flag")
        eq(frozen.names==initial.names,false,"binding copies names")
        initial.names[2]="Changed"
        eq(frozen.names[2],"Live","binding does not alias caller names")
        initial.names[2]="Live"
        local minimal=Card.FreezeBinding({card=card,include_previous=false})
        eq(minimal.names,nil,"binding missing names stays nil")
        eq(minimal.name,nil,"binding missing name stays nil")
        eq(minimal.include_previous,false,"binding false stays false")
        Target.Resolve=function(i,c,p)
            mark("resolve");eq(i,initial,"initial binding explicit");eq(c,capture,"capture explicit")
            eq(p,proof,"resolve proof explicit");return target
        end
        Target.Check=function(t,b,c,l)
            mark("check");eq(t,target,"resolved target reused");eq(b,initial,"fresh binding consumed")
            eq(c,capture,"check capture");eq(l,live,"fresh context consumed");return true
        end
        Target.LocateDiscovery=function(t,s,b,c,l)
            mark("locate");eq(s,discovery.snapshot,"complete discovery consumed");return location
        end
        Cards.CompareLocated=function(s,p,b,c,l)
            mark("compare");eq(s,snapshot,"actual published snapshot");eq(p,location,"proved correspondence")
            return report
        end
        Cards.Select=function(r,keys)
            mark("select");eq(r,report,"full report consumed");eq(#keys,1,"only one root chosen")
            eq(keys[1],key,"published key chosen");return selection
        end
        Cards.Describe=function(s) mark("describe");eq(s,selection,"prepared selection described");return model end
        Target.CheckDiscovery=function(p,b,c,l)
            mark("recheck");eq(p,location,"same location rechecked");eq(l,live,"final fresh context");return true
        end
        debug.setupvalue=function() error("premature cell write") end
        debug.upvaluejoin=function() error("premature join") end
        _G.jit={flush=function() error("premature cache flush") end}
        local prepared=assert(Card.PrepareVersioned(capture,discovery,initial,proof,refresh))
        eq(table.concat(trace,","),"resolve,refresh,check,locate,compare,select","preparation order retained")
        eq(prepared.target,target,"prepared target");eq(prepared.live,live,"prepared fresh view")
        eq(prepared.location,location,"prepared correspondence");eq(prepared.selection,selection,"prepared selection")
        trace={}
        local display,fresh=Card.InspectPrepared(prepared,capture,refresh)
        eq(display,model,"caller receives presentation");eq(fresh,live,"caller receives final live view")
        eq(table.concat(trace,","),"describe,refresh,recheck","inspection revalidates after describe")
        for _,fault in ipairs({"resolve","refresh","check","locate","compare","select"}) do
            trace={}
            local old
            local err=setmetatable({}, {__tostring=function() error("unsafe error formatting") end})
            if fault=="refresh" then
                reject(function() return Card.PrepareVersioned(capture,discovery,initial,proof,function() return nil,err end) end,
                    "versioned preflight: operation refused","refresh error")
            else
                local object,method=Target,({resolve="Resolve",check="Check",locate="LocateDiscovery"})[fault]
                if not method then object,method=Cards,({compare="CompareLocated",select="Select"})[fault] end
                old=object[method];object[method]=function() mark("failure");return nil,err end
                local value,why=Card.PrepareVersioned(capture,discovery,initial,proof,refresh)
                object[method]=old
                refusal(value,why,(fault=="check" or fault=="resolve") and "locate:" or fault..":",fault.." error")
                eq(trace[#trace],"failure",fault.." stops pipeline")
            end
        end
        local old_describe=Cards.Describe
        Cards.Describe=function() return nil,{message="describe refused"} end
        reject(function() return Card.InspectPrepared(prepared,capture,refresh) end,"describe:","describe failure")
        Cards.Describe=old_describe
        local v,e=Card.InspectPrepared(prepared,capture,function() return nil,{message="fresh refused"} end)
        refusal(v,e,"inspection: fresh refused","inspection refresh failure")
        local old_check=Target.CheckDiscovery
        Target.CheckDiscovery=function() return nil,{message="target changed"} end
        v,e=Card.InspectPrepared(prepared,capture,refresh)
        Target.CheckDiscovery=old_check
        refusal(v,e,"inspection: target changed","inspection final target failure")

        local run=Card.FreezeRestart(target,capture)
        eq(run.kind,"versioned-card-restart","run tagged for controller retry")
        for _,field in ipairs({"file","session_id","entry","classes","class_key","class","list","card","slot","name","include_previous","key"}) do
            eq(run[field],target[field],"run frozen "..field)
        end
        eq(run.anchor,anchor,"anchor fixed");eq(run.raw_name,"Live","raw live name fixed")
        eq(run.capture,capture,"capture fixed")
        eq(run.snapshot,nil,"uncommitted run has no installed receipt")
        run.snapshot=snapshot -- synthetic committed/no-op receipt; no live writes
        local restart_live={session_id=target.session_id,entry=entry,classes=classes}
        local restarts=0
        Binding.IsReplay=function() return false end
        Binding.Restart=function(k,n,c,s,previous)
            restarts=restarts+1
            eq(k,"K","restart frozen class");eq(n,"Live","restart frozen name")
            eq(c,card,"restart frozen card");eq(s,2,"restart frozen slot")
            eq(previous,true,"restart frozen previous flag")
        end
        trace={}
        eq(Card.RestartVersioned(run,restart_live),true,"adapter performs committed restart")
        eq(table.concat(trace,","),"","restart has no source service/refresh path")
        eq(restarts,1,"one handoff")
        for _,fault in ipairs({"released","poisoned","publication_error","session","entry","classes"}) do
            local view=copy(restart_live)
            if fault=="session" then view.session_id="other"
            elseif fault=="entry" then view.entry={}
            elseif fault=="classes" then view.classes={}
            else view[fault]=true end
            v,e=Card.RestartVersioned(run,view)
            refusal(v,e,"frozen restart target",fault)
        end
        local mutations={
            {"anchor",function() entry.anchor=function() end end,function() entry.anchor=anchor end,"target"},
            {"disabled",function() entry.reloadable=false end,function() entry.reloadable=true end,"target"},
            {"snapshot",function() capture.snapshot={} end,function() capture.snapshot=snapshot end,"target"},
            {"name",function() card.name="Renamed" end,function() card.name="Live" end,"target"},
            {"class",function() classes.K={} end,function() classes.K=class end,"target"},
            {"list",function() class.cards={} end,function() class.cards=list end,"target"},
            {"selected",function() list[2]={} end,function() list[2]=card end,"target"},
            {"sibling",function() list[1]={} end,function() list[1]=placeholder end,"slot ownership"},
            {"extra",function() list.foreign={} end,function() list.foreign=nil end,"slot ownership"},
            {"length",function() list[3]={} end,function() list[3]=nil end,"class/list ownership"},
            {"metatable",function() setmetatable(list,{}) end,function() setmetatable(list,nil) end,"class/list ownership"},
            {"callback",function() card.init=function() end end,
                function() card.init=snapshot.units[key].callbacks.init.fn end,"committed callback"},
        }
        for _,mutation in ipairs(mutations) do
            mutation[2]();v,e=Card.RestartVersioned(run,restart_live);mutation[3]()
            refusal(v,e,mutation[4],mutation[1])
        end
        eq(restarts,1,"all stale handoffs refused before game call")
        Binding.IsReplay=function() return true end
        reject(function() return Card.RestartVersioned(run,restart_live) end,"replay","replay")
        Binding.IsReplay=function() return false end
        entry.missing=true;entry.reloadable=false
        eq(Card.RestartVersioned(run,restart_live),true,"Missing preserves committed retry")
        entry.missing=nil;entry.reloadable=true
        Binding.Restart=function() error(setmetatable({}, {__tostring=function() error("unsafe") end})) end
        reject(function() return Card.RestartVersioned(run,restart_live) end,"operation refused","hostile restart error")

        local record={binding=Card.FreezeBinding(initial),classes=classes,class=class,list=list}
        eq(Card.InspectionBindingMatches(record,initial,classes),true,"past binding valid")
        eq(Card.InspectionBindingMatches(record,nil,classes),false,"missing current")
        eq(Card.InspectionBindingMatches(record,initial,{}),false,"changed classes")
        for _,field in ipairs({"class_key","card","slot","name","mode","include_previous","names"}) do
            local b=copy(initial);b[field]=field=="names" and {"","Other"} or {}
            eq(Card.InspectionBindingMatches(record,b,classes),false,"inspection drift "..field)
        end
        local b=copy(initial);b.names=nil
        eq(Card.InspectionBindingMatches(record,b,classes),false,"inspection missing names")
        b.names={"Live"}
        eq(Card.InspectionBindingMatches(record,b,classes),false,"inspection list length")
        class.cards={}
        eq(Card.InspectionBindingMatches(record,initial,classes),false,"inspection list identity")
        class.cards=list;list[2]={}
        eq(Card.InspectionBindingMatches(record,initial,classes),false,"inspection card identity")
        list[2]=card
    end)
    Target.Resolve,Target.Check,Target.LocateDiscovery,Target.CheckDiscovery=
        services.Resolve,services.Check,services.LocateDiscovery,services.CheckDiscovery
    Cards.CompareLocated,Cards.Select,Cards.Describe=services.CompareLocated,services.Select,services.Describe
    Binding.Restart,Binding.IsReplay=services.Restart,services.IsReplay
    debug.setupvalue,debug.upvaluejoin=old_setup,old_join
    rawset(_G,"jit",old_jit)
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..tostring(problem) end
    -- Controller dispatch checks use explicit fake receipts/context, not shared
    -- semantics. Real transaction/Monitor behavior remains in the existing suites.
    local names={"lstg.FileSystemWatcher","lstg.FileSystemWatcher.FileAction","SpellHotReload.Watcher","SpellHotReload.Plugin"}
    local saved_modules={}
    for _,n in ipairs(names) do saved_modules[n]=package.loaded[n] end
    package.loaded[names[1]],package.loaded[names[2]]={},{}
    package.loaded[names[3]],package.loaded[names[4]]=nil,nil
    local saved_classes=rawget(_G,"_editor_class")
    rawset(_G,"_editor_class",classes)
    local methods={"FreezeBinding","PrepareVersioned","FreezeRestart","Commit","Restart","RestartVersioned","InspectPrepared","InspectionBindingMatches"}
    local originals,counts={},{}
    for _,n in ipairs(methods) do originals[n],counts[n]=Card[n],0 end
    local replay,capture_current=Binding.IsReplay,Binding.CaptureCurrent
    local wired,werr=pcall(function()
        local Plugin=require("SpellHotReload.Plugin")
        local candidate={stable=true,generation=7,first_content="synthetic candidate"}
        local context={common=common,adapter={file=discovered.context.adapter.file,
            unit=unit.context}}
        local handle={refresh=function() return live end}
        local prepared={target=target,live=live,location=location,selection=selection,
            handle=handle,context=context,
            driver_prepared={kind="SpellHotReload.Driver.PreparedDiscovery",version=1,
                owner=driver,discovery=discovery,file=discovery.file,content=discovery.content,
                entries={{entry=discovered,adapter=Card,unit=unit,context=context,
                    handle=handle,plan=selection}}}}
        driver.Discover=function() return discovery end
        local p=setmetatable({_loads={[target.file]=entry},_session_id=target.session_id,
            _candidate_inspections={},_activated=true,_supported=true,_sandbox_ok=true,
            _store={GetCandidate=function() return candidate end},
            _driver=driver},Plugin)
        p._commit={Check=function() return true end,Poisoned=function() return false end,
            Commit=function() return {snapshot=snapshot,changed=false} end}
        p.GetVersions=function() return capture end
        local fresh_count=0
        p._FreshVersioned=function() fresh_count=fresh_count+1;return live end
        for _,n in ipairs(methods) do
            local method=n
            Card[method]=function(...)
                counts[method]=counts[method]+1
                if method=="PrepareVersioned" then
                    local c,d,b,proof,refresh=...
                    eq(c,capture,"controller capture explicit");eq(d,discovery,"controller discovery explicit")
                    eq(proof.session_id,target.session_id,"controller proof session")
                    eq(proof.entry,entry,"controller proof entry")
                    eq(refresh(),live,"controller physical refresh remains caller-owned")
                    return prepared
                elseif method=="Commit" then
                    local h,plan,ctx=...
                    eq(h,handle,"controller passes located handle");eq(plan,selection,"controller passes injected output")
                    eq(ctx,context,"controller extends same per-call context")
                    local receipt,err=ctx.adapter.transaction(h,plan,ctx)
                    return receipt~=nil,err,receipt
                elseif method=="InspectPrepared" then
                    local value,c,refresh=...
                    eq(value,prepared,"controller prepared selection");eq(c,capture,"controller inspect capture")
                    eq(refresh(),live,"controller inspection final refresh");return model,live
                elseif method=="RestartVersioned" then
                    local run,view=...
                    eq(run.card,card,"controller frozen card");eq(view.entry,entry,"controller restart entry")
                    eq(view.session_id,target.session_id,"controller restart session")
                    eq(p._restart_active,true,"controller busy gate spans adapter handoff")
                    return true
                end
                return originals[method](...)
            end
        end
        Binding.IsReplay=function() return false end
        Binding.CaptureCurrent=function() return initial end
        eq(p:_PrepareVersioned(target.file,candidate,capture,discovery,initial),prepared,"controller delegates preparation")
        local result=p:_ApplyVersioned({},target.file,candidate,capture,discovery,initial)
        has(result,"applied","controller delegates versioned Apply")
        eq(p._pending_restart_run,nil,"successful handoff drops pending run")
        eq(p._restart_active,false,"controller clears busy gate after success")
        local display=assert(p:InspectCandidate(target.file))
        eq(display==model,false,"controller still detaches cached presentation")
        eq(display.selected[1],key,"controller preserves presented selection")
        display=assert(p:GetCandidateInspection(target.file,initial))
        eq(display.selected[1],key,"cheap inspection delegates binding validity")
        check(fresh_count>=3,"controller invokes supplied fresh views")
        for _,method in ipairs(methods) do check(counts[method]>0,"actual controller invokes "..method) end
        Card.RestartVersioned=function() error("adapter validation fixture") end
        local run=originals.FreezeRestart(target,capture);run.snapshot=snapshot
        local called,err=pcall(p._RestartVersioned,p,run)
        eq(called,false,"unexpected adapter throw propagated")
        has(err,"adapter validation fixture","unexpected adapter error preserved")
        eq(p._restart_active,false,"controller clears busy gate on throw")
        Card.RestartVersioned=function()
            local v,e=p:_RestartVersioned(run)
            eq(v,nil,"reentrant adapter retry refused");has(e,"already active","reentrant retry reason")
            return nil,"retry fixture"
        end
        local v,e=p:_RestartVersioned(run)
        eq(v,nil,"failed adapter handoff surfaced");eq(e,"retry fixture","failed adapter reason kept")
        eq(p._restart_active,false,"controller clears busy gate on refusal")
    end)
    for _,n in ipairs(methods) do Card[n]=originals[n] end
    Binding.IsReplay,Binding.CaptureCurrent=replay,capture_current
    rawset(_G,"_editor_class",saved_classes)
    for _,n in ipairs(names) do package.loaded[n]=saved_modules[n] end
    if not wired then failed=failed+1;failures[#failures+1]="dispatch: "..tostring(werr) end
    print(string.format("CardRuntimeSpec: %d passed / %d failed",passed,failed))
    for _,label in ipairs(failures) do print("  FAIL "..label) end
    return {passed=passed,failed=failed}
end
return M
