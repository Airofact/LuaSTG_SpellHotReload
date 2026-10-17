-- One prepared aggregate, exact-input scoped writer; no general group transaction.
local M={}
function M.run()
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local passed,failed,failures=0,0,{}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function copy(t) local r={};for k,v in next,t do r[k]=v end;return r end
    local hooks,writes,traps=0,0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("hostile index") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end})
    local function fixture(keys)
        local driver=Driver.New()
        local adapter={Id="value",ContractVersion=4,Reconcile=function() error("unexpected reconciliation") end}
        adapter.Match=function()
            local units,claims={},{}
            for i,key in ipairs({"value:a","value:b"}) do
                units[i]={key=key,carrier="value",source_ranges={{first=i,last=i}},context={}}
                claims[i]={kind="definition",key=key,unit_key=key}
            end
            return {units=units,claims=claims,context={}}
        end
        adapter.Locate=function(u,c) return {unit=u,context=c} end
        adapter.Inject=function(h,u,c) return {handle=h,unit=u,context=c} end
        adapter.Commit=function(h,p,c)
            hooks=hooks+1
            local receipt,err=c.adapter.transaction(h,p,c)
            return receipt~=nil,err,receipt
        end
        adapter.Restartable=true
        adapter.Restart=function() error("restart forbidden") end
        assert(driver:RegisterDiscovery(adapter))
        local discovery=assert(driver:Discover("F.lua","G=12",{}))
        local prepared=assert(driver:PrepareDiscovery(discovery,keys or {"value:a"}))
        adapter.Match=function() error("Match replay forbidden") end
        adapter.Locate=function() error("Locate replay forbidden") end
        adapter.Inject=function() error("Inject replay forbidden") end
        driver.Commit=function() error("legacy commit forbidden") end
        driver.Restart=function() error("legacy restart forbidden") end
        return driver,prepared,adapter
    end
    local receipt={snapshot={},changed=true}
    local function writer(h,p,c)
        writes=writes+1
        eq(p.handle,h,"writer same injected handle")
        eq(p.context,c,"writer same per-call context")
        return receipt
    end
    local function rejected(driver,p,transaction,label)
        local before_h,before_w=hooks,writes
        local called,ok,err=pcall(driver.CommitDiscovery,driver,p,transaction)
        eq(called,true,label.." safe");eq(ok,false,label.." refused")
        eq(type(err),"table",label.." structured")
        if type(err)=="table" then eq(err.phase,"commit",label.." phase") end
        eq(hooks,before_h,label.." before hook");eq(writes,before_w,label.." before writer")
    end
    local prepare,commit=Card.PrepareVersioned,Driver.CommitDiscovery
    local bridge,locate,inject=Card.RuntimeContext,Card.Locate,Card.Inject
    local ok,problem=pcall(function()
        local driver,p,adapter=fixture()
        local record=p.entries[1]
        local saved_writer
        adapter.Commit=function(h,plan,c)
            hooks=hooks+1
            eq(h,record.handle,"dispatch original handle");eq(plan,record.plan,"dispatch original plan")
            eq(c,record.context,"dispatch original context")
            eq(c.common.transaction,nil,"common has no writer")
            saved_writer=c.adapter.transaction
            for _,tuple in ipairs({{{},plan,c},{h,{},c},{h,plan,{}}}) do
                local before=writes
                local v,e=saved_writer(unpack(tuple))
                eq(v,nil,"foreign tuple refused");eq(e.code,"ownership","foreign tuple diagnosis")
                eq(writes,before,"foreign tuple cannot consume writer")
            end
            local result,err=saved_writer(h,plan,c)
            local v,e=saved_writer(h,plan,c)
            eq(v,nil,"second write refused");eq(e.code,"stale","single use diagnosis")
            return result~=nil,err,result
        end
        local published,err,result=driver:CommitDiscovery(p,writer)
        eq(published,true,"success boolean");eq(err,nil,"success error");eq(result,receipt,"receipt identity")
        eq(writes,1,"one atomic writer call")
        eq(record.context.adapter.transaction,nil,"writer revoked after success")
        eq(record.entry.context.adapter.transaction,nil,"discovery context clean")
        local v,e=saved_writer(record.handle,record.plan,record.context)
        eq(v,nil,"retained writer expired");eq(e.code,"stale","retained writer diagnosis")
        eq(writes,1,"retained writer cannot republish")
        -- No Driver receipt installs/restart/cached permissions: kernel owns replay.
        driver,p,adapter=fixture()
        local original=p.entries[1]
        local reason={phase="commit",code="stale",message="kernel declined"}
        v,e=driver:CommitDiscovery(p,function() return nil,reason end)
        eq(v,false,"writer refusal boolean");eq(e,reason,"writer refusal identity")
        eq(original.context.adapter.transaction,nil,"writer revoked after kernel refusal")
        adapter.Commit=function(h,plan,c) saved_writer=c.adapter.transaction;return false,hostile end
        v,e=driver:CommitDiscovery(p,writer)
        eq(v,false,"adapter refusal boolean");eq(e,hostile,"opaque refusal unchanged")
        eq(original.context.adapter.transaction,nil,"writer revoked after adapter refusal")
        local unused,value=pcall(saved_writer,original.handle,original.plan,original.context)
        eq(unused,true,"unused expired writer refuses safely");eq(value,nil,"unused writer expires")
        for _,from in ipairs({"adapter","writer"}) do
            driver,p,adapter=fixture()
            record=p.entries[1]
            adapter.Commit=function(h,plan,c)
                saved_writer=c.adapter.transaction
                if from=="adapter" then error(hostile) end
                local r,why=saved_writer(h,plan,c);return r~=nil,why,r
            end
            local called,thrown=pcall(driver.CommitDiscovery,driver,p,function() error(hostile) end)
            eq(called,false,from.." throw propagated");eq(thrown,hostile,from.." throw identity")
            eq(record.context.adapter.transaction,nil,from.." writer revoked after throw")
            local safe,value=pcall(saved_writer,record.handle,record.plan,record.context)
            eq(safe,true,from.." expired writer refuses safely");eq(value,nil,from.." saved writer expired")
        end
        -- Invalid aggregate/ownership/contract cannot enter either callback.
        driver,p,adapter=fixture()
        rejected(Driver.New(),p,writer,"foreign driver")
        rejected(driver,nil,writer,"nil artifact")
        rejected(driver,hostile,writer,"hostile artifact")
        for _,change in ipairs({
            function(q) q.kind="legacy" end,function(q) q.version=2 end,
            function(q) q.owner={} end,function(q) q.file="Other.lua" end,
            function(q) q.content="different" end,function(q) q.entries=hostile end,
            function(q) q.entries={} end,
            function(q) q.entries={[2]=q.entries[1]} end,
            function(q) q.entries={q.entries[1],q.entries[1]} end,
            function(q) q.entries={q.entries[1],extra=true} end,
            function(q) q.entries={hostile} end,
            function(q) q.discovery={} end}) do
            local q=copy(p);change(q);rejected(driver,q,writer,"bad aggregate")
        end
        for _,field in ipairs({"entry","adapter","unit","context","handle","plan"}) do
            local q=copy(p);q.entries={copy(p.entries[1])};q.entries[1][field]=false
            rejected(driver,q,writer,"bad record "..field)
        end
        for _,context in ipairs({hostile,{}, {common={},adapter={}},
            {common=p.discovery.snapshot.common,adapter=hostile},
            {common=p.discovery.snapshot.common,adapter={file={},unit=p.entries[1].unit.context}},
            {common=p.discovery.snapshot.common,adapter={file=p.entries[1].context.adapter.file,unit={}}}}) do
            local q=copy(p);q.entries={copy(p.entries[1])};q.entries[1].context=context
            rejected(driver,q,writer,"bad context")
        end
        rejected(driver,p,false,"nonfunction writer")
        local scope=p.entries[1].context.adapter
        scope.transaction=writer
        rejected(driver,p,writer,"existing writer")
        eq(scope.transaction,writer,"existing writer untouched");scope.transaction=nil
        local hook=adapter.Commit;adapter.Commit=false
        rejected(driver,p,writer,"invalid adapter contract");adapter.Commit=hook
        local id=adapter.Id;adapter.Id="other"
        rejected(driver,p,writer,"changed adapter Id");adapter.Id=id
        local multi=assert(driver:PrepareDiscovery(p.discovery,{})) -- no hooks for empty
        rejected(driver,multi,writer,"empty prepared result")
        driver,p,adapter=fixture({"value:a","value:b"})
        rejected(driver,p,writer,"multiple prepared aggregates")
        -- Reentrant same-context dispatch is rejected while writer is installed.
        driver,p,adapter=fixture()
        adapter.Commit=function(h,plan,c)
            local before=hooks
            local inner,why=driver:CommitDiscovery(p,writer)
            eq(inner,false,"nested dispatch refused");eq(why.code,"ownership","nested diagnosis")
            eq(hooks,before,"nested no hook")
            local r,err=c.adapter.transaction(h,plan,c);return r~=nil,err,r
        end
        eq(select(1,driver:CommitDiscovery(p,writer)),true,"outer dispatch survives nested refusal")
        -- Card.PrepareVersioned must preserve the SAME whole generic artifact.
        local cd=Driver.New();assert(cd:RegisterDiscovery(Card))
        local bytes="_editor_class['K'].cards={}\n_tmp_sc=boss.card.New('A',1,2,3,4)\nfunction _tmp_sc:init() end\ntable.insert(_editor_class['K'].cards,_tmp_sc)"
        local found=assert(cd:Discover("K_Boss.lua",bytes))
        local entry=found.snapshot.by_key["card:K"]
        local ctx={common=entry.context.common,adapter={file=entry.context.adapter.file,unit=entry.unit.context}}
        local handle={target={},live={},location={}};local plan={}
        Card.RuntimeContext=function() return entry.unit,ctx end
        Card.Locate=function() return handle end
        Card.Inject=function() return plan end
        local wrapper=assert(Card.PrepareVersioned({},found,{},{},function() end))
        eq(wrapper.driver_prepared.owner,cd,"Card retains generic owner")
        eq(wrapper.driver_prepared.discovery,found,"Card retains complete discovery")
        eq(wrapper.driver_prepared.entries[1].handle,wrapper.handle,"Card retained located handle")
        eq(wrapper.driver_prepared.entries[1].plan,wrapper.selection,"Card retained selection")
        eq(wrapper.driver_prepared.entries[1].context,wrapper.context,"Card retained context")
        Card.RuntimeContext,Card.Locate,Card.Inject=bridge,locate,inject
        -- Existing production fixture runs real Plugin/UI/kernel, not a mocked
        -- dispatch. Spy only observes; all original handoff assertions still run.
        local production_calls,production_contexts=0,{}
        Driver.CommitDiscovery=function(self,artifact,atomic)
            production_calls=production_calls+1
            eq(artifact.owner,self,"production explicit generic owner")
            eq(#artifact.entries,1,"production one aggregate")
            eq(type(atomic),"function","production explicit atomic writer")
            local context=artifact.entries[1].context
            production_contexts[#production_contexts+1]=context
            return commit(self,artifact,atomic)
        end
        local handoff=require("SpellHotReload.tests.CardHandoffSpec").run()
        eq(handoff.failed,0,"production original handoff regression")
        if type(debug.upvaluejoin)=="function" then
            eq(production_calls,2,"production Apply dispatches; Retry never redispatches")
            for _,context in ipairs(production_contexts) do
                eq(context.adapter.transaction,nil,"production writer revoked")
            end
        else
            eq(production_calls,0,"Lua5.1 genuine sharing gate not bypassed")
        end
        eq(traps,0,"no opaque error/artifact metamethods")
    end)
    Card.PrepareVersioned,Driver.CommitDiscovery=prepare,commit
    Card.RuntimeContext,Card.Locate,Card.Inject=bridge,locate,inject
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..(type(problem)=="string" and problem or "opaque error") end
    for _,label in ipairs(failures) do print("FAIL DriverCommitSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
