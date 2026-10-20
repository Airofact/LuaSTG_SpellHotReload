-- Exact registration is not publication. All owners register before ONE writer.
local M={}
local serial=0
function M.run()
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Versions=require("SpellHotReload.Pipeline.FileVersions")
    local passed,failed,failures=0,0,{}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function fixture()
        serial=serial+1
        local driver=Driver.New()
        local owners={}
        for _,id in ipairs({"alpha","beta"}) do
            local owner={Id=id,ContractVersion=5}
            owner.Match=function() return {units={},claims={},context={}} end
            owner.Reconcile=function() return {rows={},view={},units={},exports={}} end
            owner.Locate=function() error("unexpected Locate replay") end
            owner.Inject=function() error("unexpected Inject replay") end
            owner.Commit=function(h,f,c) return c.adapter.register(h,f,c) end
            assert(driver:RegisterDiscovery(owner));owners[#owners+1]=owner
        end
        local entry=assert(Load.Capture("local state=1",{name="Register_Boss.lua"}))
        entry.file="Register_Boss.lua"
        local contributions={}
        for i,owner in ipairs(owners) do
            contributions[i]={owner=owner,owner_id=owner.Id,state={},units={},records={},functions={},edges={},
                initial={},identity_objects={},authority={cells={},raws={},forbidden={}}}
        end
        local capture=assert(Versions.Capture(entry,"RegisterSpec:"..serial,contributions))
        local discovery=assert(driver:Discover(entry.file,entry.source,{session_id=capture.snapshot.session_id}))
        local operation={file=entry.file,entry=entry,anchor=entry.anchor,loaded_source=entry.loaded_source,
            capture=capture,base_snapshot=capture.snapshot,source=entry.source,generation=1,
            session_id=capture.snapshot.session_id,mode="file"}
        local prepared={kind="SpellHotReload.Driver.PreparedDiscovery",version=2,owner=driver,
            operation=operation,discovery=discovery,entries={}}
        for i,group in ipairs(capture.snapshot.owners) do
            local context={common=discovery.snapshot.common,operation=operation,
                adapter={file=discovery.snapshot.adapter_contexts[group.owner_id]}}
            local fragment={operation=operation,owner=group.owner,base_group=group,proposed_group=group}
            prepared.entries[i]={owner=group.owner,base_group=group,context=context,handle={},fragment=fragment}
        end
        return driver,prepared,owners
    end
    local ok,problem=pcall(function()
        local calls,hooks=0,0
        local receipt={kind="SpellHotReload.FileCommit.Receipt"}
        local function transaction(op,fragments)
            calls=calls+1
            eq(#fragments,2,"transaction receives both owners")
            eq(fragments[1].operation,op,"one operation for first owner")
            eq(fragments[2].operation,op,"one operation for second owner")
            return receipt
        end
        local driver,p,owners=fixture()
        for _,owner in ipairs(owners) do
            owner.Commit=function(h,f,c) hooks=hooks+1;eq(calls,0,"no publication during registration");return c.adapter.register(h,f,c) end
        end
        eq(driver:CommitDiscovery(p,transaction),receipt,"returns unique receipt directly")
        eq(calls,1,"one transaction after both registrations");eq(hooks,2,"both hooks run")
        for _,record in ipairs(p.entries) do eq(record.context.adapter.register,nil,"registration writer revoked") end
        for _,kind in ipairs({"refuse","throw","zero","double","foreign","receipt","scope","postcheck"}) do
            driver,p,owners=fixture();calls=0
            local retained,old_scope
            owners[1].Commit=function(h,f,c) return c.adapter.register(h,f,c) end
            owners[2].Commit=function(h,f,c)
                retained=c.adapter.register;old_scope=c.adapter
                if kind=="refuse" then return false end
                if kind=="throw" then error({}) end
                if kind=="zero" then return true end
                if kind=="foreign" then retained({},f,c);return true end
                local accepted=retained(h,f,c)
                if kind=="double" then retained(h,f,c) end
                if kind=="receipt" then return accepted,receipt end
                if kind=="scope" then c.adapter={} end
                if kind=="postcheck" then p.discovery.snapshot=nil end
                return accepted
            end
            local safe,value,err=pcall(driver.CommitDiscovery,driver,p,transaction)
            eq(safe,true,kind.." safely rejected")
            eq(value,nil,kind.." has no receipt");eq(type(err),"table",kind.." structured failure")
            eq(calls,0,kind.." zero transactions after earlier registration")
            eq(old_scope.register,nil,kind.." scope always revoked")
            if retained then
                local active,v,why=pcall(retained,p.entries[2].handle,p.entries[2].fragment,p.entries[2].context)
                eq(active,true,kind.." expired writer safe");eq(v,nil,kind.." retained writer expired")
                eq(why.code,"stale",kind.." expiry diagnosis")
            end
        end
        -- Expired registration closures must not retain operation or context.
        driver,p,owners=fixture()
        local retained,weak
        owners[1].Commit=function(h,f,c)
            retained=c.adapter.register
            weak=setmetatable({c,c.operation},{__mode="v"})
            return retained(h,f,c)
        end
        assert(driver:CommitDiscovery(p,transaction))
        driver,p,owners=nil,nil,nil
        collectgarbage("collect");collectgarbage("collect")
        eq(weak[1],nil,"expired writer releases context")
        eq(weak[2],nil,"expired writer releases operation")
        local active,v=pcall(retained)
        eq(active,true,"detached writer safely rejects");eq(v,nil,"detached writer expired")
        -- Validate the COMPLETE owner list before invoking even the first hook.
        local function reject(change,label)
            driver,p,owners=fixture();calls=0;hooks=0
            owners[1].Commit=function() hooks=hooks+1;return true end
            change(p,owners,driver)
            local safe,value=pcall(driver.CommitDiscovery,driver,p,transaction)
            eq(safe,true,label.." safe");eq(value,nil,label.." refused")
            eq(hooks,0,label.." no early hook");eq(calls,0,label.." no transaction")
        end
        reject(function(q) q.owner={} end,"foreign driver")
        reject(function(q) q.entries={} end,"missing owners")
        reject(function(q) q.entries[3]=q.entries[1] end,"duplicate owner")
        reject(function(q) q.entries[1]=nil end,"sparse owners")
        reject(function(q) q.entries[2].fragment={} end,"foreign fragment")
        reject(function(q) q.entries[2].context.common={} end,"foreign common")
        reject(function(q) q.entries[2].context.adapter.file={} end,"foreign owner context")
        reject(function(q) q.entries[2].context.adapter.register=function() end end,"existing writer")
        reject(function(q,o) o[2].Id="replacement" end,"changed owner Id")
        reject(function(q,o) o[2].ContractVersion=4 end,"old contract")
        reject(function(q,o) o[2].Commit=false end,"missing hook")
        driver,p,owners=fixture();calls=0
        local nested
        owners[1].Commit=function(h,f,c)
            nested=driver:CommitDiscovery(p,transaction)
            return c.adapter.register(h,f,c)
        end
        eq(driver:CommitDiscovery(p,transaction),receipt,"outer registration survives rejected reentry")
        eq(nested,nil,"nested registration refused")
        eq(calls,1,"reentry cannot create a second transaction")
    end)
    if not ok then failed=failed+1;failures[#failures+1]="spec threw: "..(type(problem)=="string" and problem or "opaque error") end
    return {passed=passed,failed=failed,failures=failures}
end
return M
