-- Versioned preparation consumes complete discovery, not legacy node routing.
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
    local calls,mutations,traps={},0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("hostile index") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end})
    local function fixture()
        calls={}
        local driver=Driver.New()
        local adapters={}
        for i,id in ipairs({"local","host","value"}) do
            local key=id..":unit"
            local adapter={Id=id,ContractVersion=4,Reconcile=function() error("unexpected reconciliation") end}
            adapter.Match=function(analysis,common)
                return {units={{key=key,carrier=id,source_ranges={{first=i,last=i}},
                    context={tag=key}}},claims={{kind="definition",key=key,unit_key=key}},
                    context={tag=id}}
            end
            adapter.Locate=function(unit,context)
                calls[#calls+1]="locate:"..id
                return {unit=unit,context=context}
            end
            adapter.Inject=function(handle,unit,context)
                calls[#calls+1]="inject:"..id
                eq(handle.unit,unit,"Inject same complete unit "..id)
                eq(handle.context,context,"Inject same exact context "..id)
                return {handle=handle}
            end
            adapter.Commit=function() mutations=mutations+1;error("commit forbidden") end
            adapter.Restart=function() mutations=mutations+1;error("restart forbidden") end
            adapters[id]=adapter;assert(driver:RegisterDiscovery(adapter))
        end
        local discovery=assert(driver:Discover("F.lua","G=123",{session_id="prepare:session",
            candidate_generation=4,base_revision=7,published_units={}}))
        for _,adapter in pairs(adapters) do
            adapter.Match=function() mutations=mutations+1;error("Match replay forbidden") end
        end
        return driver,discovery,adapters
    end
    local function refused(driver,d,keys,contexts,label)
        local before=#calls
        local ok,v,e=pcall(driver.PrepareDiscovery,driver,d,keys,contexts)
        eq(ok,true,label.." safe refusal");eq(v,nil,label.." refused")
        eq(type(e),"table",label.." structured")
        if type(e)=="table" then eq(e.phase,"locate",label.." phase") end
        eq(#calls,before,label.." all input validation before any hook")
    end
    local bridge,locate,inject,prepare=Card.RuntimeContext,Card.Locate,Card.Inject,Driver.PrepareDiscovery
    local ok,problem=pcall(function()
        local driver,d,adapters=fixture()
        local marker={}
        local base=d.snapshot.by_key["host:unit"].context
        local extended={common=base.common,adapter={file=base.adapter.file,
            unit=base.adapter.unit,runtime=marker}}
        local p=assert(driver:PrepareDiscovery(d,{"value:unit","host:unit","local:unit"},
            {["host:unit"]=extended}))
        eq(p.kind,"SpellHotReload.Driver.PreparedDiscovery","explicit preparation artifact")
        eq(p.version,1,"artifact format version");eq(p.owner,driver,"owned driver")
        eq(p.discovery,d,"whole discovery retained");eq(p.file,d.file,"file retained")
        eq(p.content,d.content,"complete bytes retained");eq(#p.entries,3,"all explicit keys")
        eq(table.concat(calls,","),"locate:local,inject:local,locate:host,inject:host,locate:value,inject:value",
            "source order independent of Id/request order")
        for i,id in ipairs({"local","host","value"}) do
            local r=p.entries[i];local original=d.snapshot.by_key[id..":unit"]
            eq(r.entry,original,"original entry "..id);eq(r.adapter,adapters[id],"registered adapter "..id)
            eq(r.unit,original.unit,"original unit "..id)
            eq(r.context,id=="host" and extended or original.context,"explicit/default context "..id)
            eq(r.plan.handle,r.handle,"plan identity "..id)
            eq(r.context.common,d.snapshot.common,"complete shared common "..id)
        end
        eq(base.adapter.runtime,nil,"no extension stored in discovery")
        eq(#d.index.list,3,"unselected/full index retained")
        local single=assert(driver:PrepareDiscovery(d,{"host:unit"}))
        eq(#single.entries,1,"explicit single selection")
        test(single~=p and single.entries~=p.entries,"no cached preparation")
        local empty=assert(driver:PrepareDiscovery(d,{}))
        eq(#empty.entries,0,"empty explicit selection")
        -- Prepared records lack legacy 'planned' statuses: no implicit commit.
        eq(driver.Commit,nil,"preparation has no implicit publication API")
        for _,keys in ipairs({{"host:unit","host:unit"},{"absent"},{false},{[2]="host:unit"}}) do
            refused(driver,d,keys,nil,"invalid keys")
        end
        refused(driver,d,nil,nil,"nil keys")
        refused(Driver.New(),d,{"host:unit"},nil,"foreign driver")
        refused(driver,hostile,{"host:unit"},nil,"hostile discovery")
        refused(driver,d,{"host:unit"},hostile,"hostile context map")
        refused(driver,d,{"host:unit"},{["value:unit"]=extended},"unselected extension")
        for _,ctx in ipairs({false,hostile,{}, {common={},adapter=extended.adapter},
            {common=base.common,adapter={file={},unit=base.adapter.unit}},
            {common=base.common,adapter={file=base.adapter.file,unit={}}}}) do
            refused(driver,d,{"host:unit"},{["host:unit"]=ctx},"foreign extension")
        end
        -- A bad later adapter must prevent even the earlier valid hooks.
        local saved=adapters.value.Inject;adapters.value.Inject=false
        refused(driver,d,{"local:unit","value:unit"},nil,"later invalid contract")
        adapters.value.Inject=saved
        local saved_id=adapters.value.Id;adapters.value.Id="other"
        refused(driver,d,{"local:unit","value:unit"},nil,"adapter Id changed")
        adapters.value.Id=saved_id
        -- Refusals and thrown errors retain identity; no partial run is returned.
        for _,phase in ipairs({"locate","inject"}) do
            driver,d,adapters=fixture()
            local err={phase=phase,code="stale",message="specific",stage="adapter detail"}
            adapters.host[phase=="locate" and "Locate" or "Inject"]=function() return nil,err end
            local v,e,where=driver:PrepareDiscovery(d,{"local:unit","host:unit","value:unit"})
            eq(v,nil,"no partial prepared result "..phase);eq(e,err,"refusal identity "..phase)
            eq(where,phase,"hook phase "..phase)
            eq(#calls,2+(phase=="inject" and 1 or 0),"later hooks short-circuited "..phase)
            adapters.host[phase=="locate" and "Locate" or "Inject"]=function() error(hostile) end
            local called,thrown=pcall(driver.PrepareDiscovery,driver,d,{"host:unit"})
            eq(called,false,"throw remains throw "..phase);eq(thrown,hostile,"throw identity "..phase)
        end
        -- Production Card wrapper must consume the generic owner method and result.
        local card_driver=Driver.New();assert(card_driver:RegisterDiscovery(Card))
        local bytes="_editor_class['K'].cards={}\n_tmp_sc=boss.card.New('A',1,2,3,4)\nfunction _tmp_sc:init() end\ntable.insert(_editor_class['K'].cards,_tmp_sc)"
        local found=assert(card_driver:Discover("K_Boss.lua",bytes))
        local entry=found.snapshot.by_key["card:K"]
        local context={common=entry.context.common,adapter={file=entry.context.adapter.file,
            unit=entry.context.adapter.unit,runtime={}}}
        local handle={target={},live={},location={}};local selection={}
        Card.RuntimeContext=function() return entry.unit,context end
        local generic_calls=0
        Driver.PrepareDiscovery=function(self,discovery,keys,contexts)
            generic_calls=generic_calls+1
            eq(self,card_driver,"production original owner");eq(discovery,found,"production whole discovery")
            eq(keys[1],"card:K","production explicit current class");eq(#keys,1,"only current class")
            eq(contexts["card:K"],context,"production exact runtime extension")
            return prepare(self,discovery,keys,contexts)
        end
        Card.Locate=function(u,c)
            eq(u,entry.unit,"production Locate discovered unit");eq(c,context,"production Locate context")
            return handle
        end
        Card.Inject=function(h,u,c)
            eq(h,handle,"production Inject original handle");eq(u,entry.unit,"production Inject unit")
            eq(c,context,"production Inject context");return selection
        end
        local result=assert(Card.PrepareVersioned({},found,{},{},function() end))
        eq(generic_calls,1,"production enters generic preparation")
        eq(result.handle,handle,"production original handle result")
        eq(result.selection,selection,"production original Inject result")
        eq(result.context,context,"production result context")
        for _,phase in ipairs({"locate","inject"}) do
            Driver.PrepareDiscovery=function() return nil,hostile,phase end
            local v,e=Card.PrepareVersioned({},found,{},{},function() end)
            eq(v,nil,"production forwards generic refusal "..phase)
            eq(e,phase..": operation refused","production safe diagnostic "..phase)
        end
        Driver.PrepareDiscovery=function() return nil,{message="detail",stage="compare"},"inject" end
        local v,e=Card.PrepareVersioned({},found,{},{},function() end)
        eq(v,nil,"production structured refusal");eq(e,"compare: detail","production original stage detail")
        eq(mutations,0,"no generic preparation mutations");eq(traps,0,"no hostile metamethods")
    end)
    Card.RuntimeContext,Card.Locate,Card.Inject,Driver.PrepareDiscovery=bridge,locate,inject,prepare
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..tostring(problem) end
    for _,label in ipairs(failures) do print("FAIL DriverPrepareSpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
