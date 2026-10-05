-- Trusted UI scope/lifecycle fixtures, no engine or generated source execution.
local M={}
function M.run()
    local keys={"lstg.FileSystemWatcher","lstg.FileSystemWatcher.FileAction",
        "SpellHotReload.Watcher","SpellHotReload.Plugin"}
    local saved={}
    for _,k in ipairs(keys) do saved[k]=package.loaded[k] end
    package.loaded[keys[1]]={};package.loaded[keys[2]]={}
    package.loaded[keys[3]]=nil;package.loaded[keys[4]]=nil
    local Plugin=require("SpellHotReload.Plugin")
    local passed,failed,failures=0,0,{}
    local function eq(a,b,label)
        if a==b then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function has(s,p,label) eq(type(s)=="string" and s:find(p,1,true)~=nil,true,label) end
    local calls,token=0,nil
    local p=Plugin.New()
    local controller=p._commit
    local ok,problem=pcall(function()
        eq(type(controller),"table","owned controller")
        eq(p:Apply(),"not activated","legacy direct API unchanged")
        p.Apply=function(self,t)
            calls=calls+1;token=t
            local value,err=controller:Commit(t,{},nil,{session_id=self._session_id})
            eq(value,nil,"invalid plan refused")
            eq(err.code,"unsupported","real token passes phase into plan validation")
            return "applied fixture"
        end
        eq(p:ApplyFromUI(),"applied fixture","UI preserves result string")
        eq(calls,1,"one dispatch")
        eq(type(token),"table","real dynamic token passed")
        local v,e=controller:Commit(token,{},nil,{session_id=p._session_id})
        eq(v,nil,"expired token");eq(e.code,"stale","token ends with button action")
        p:Tick()
        eq(calls,1,"Tick does not dispatch Apply")
        p:StopWatching()
        eq(p._commit,controller,"Stop Watching retains controller")
        eq(p:ApplyFromUI(),"applied fixture","second fresh UI scope")
        local retry_calls=0
        p.RetryRestart=function() retry_calls=retry_calls+1;return "restarted" end
        eq(p:RetryRestartFromUI(),"restarted","retry uses UI entry")
        eq(retry_calls,1,"retry exactly once")
        eq(p:_RunUIAction("unknown"),"unknown UI action","whitelist unknown action")
        eq(retry_calls,1,"unknown does not retry")

        p.Apply=function()
            calls=calls+1
            has(p:ApplyFromUI(),"nested commit scope refused","nested Apply refused")
            has(p:RetryRestartFromUI(),"nested commit scope refused","nested retry refused")
            return "applied outer"
        end
        local before=calls
        eq(p:ApplyFromUI(),"applied outer","outer result retained")
        eq(calls,before+1,"no nested Apply dispatch")
        local thread=coroutine.create(function()
            has(p:ApplyFromUI(),"requires the main thread","coroutine refused")
        end)
        eq(coroutine.resume(thread),true,"coroutine fixture ran")
        eq(calls,before+1,"coroutine no dispatch")
        local touched=0
        local hostile=setmetatable({}, {__tostring=function() touched=touched+1;error("unsafe") end,
            __index=function() touched=touched+1;error("unsafe") end})
        p.Apply=function() error(hostile) end
        has(p:ApplyFromUI(),"callback failed","unknown thrown object contained")
        eq(touched,0,"no unknown-object metamethod")
        p.Apply=function() return "applied recovered" end
        eq(p:ApplyFromUI(),"applied recovered","scope expires after error")
        local q=Plugin.New()
        q.Apply=function(self,t)
            local value,err=controller:Commit(t,{},nil,{session_id=p._session_id})
            eq(value,nil,"foreign controller token refused")
            eq(err.code,"stale","foreign token not accepted")
            return "applied other"
        end
        eq(q:ApplyFromUI(),"applied other","independent Plugin controller")
        eq(q:Release(),true,"other release")
        local release=controller.Release
        controller.Release=function() return nil,{code="phase"} end
        local store,session=p._store,p._session_id
        v,e=p:Release()
        eq(v,nil,"refused release surfaced");eq(e.code,"phase","refused release code")
        eq(p:IsReleased(),false,"refused release not marked")
        eq(p._store,store,"refused release retains store")
        eq(p._session_id,session,"refused release retains session")
        eq(p._commit,controller,"refused release retains controller")
        controller.Release=release
        eq(p:Release(),true,"session release succeeds")
        eq(p:Release(),true,"release idempotent")
        eq(p._commit,nil,"controller strong reference cleared")
        eq(p._commit_error,nil,"controller error cleared")
        eq(p:ApplyFromUI(),"session ended","released Apply blocked")
        eq(p:RetryRestartFromUI(),"session ended","released retry blocked")
        local ran,err=controller:Run(function() error("must not run") end)
        eq(ran,nil,"retained controller inactive");eq(err.code,"stale","retained controller released")
        q=Plugin.New()
        local saved=q._commit;q._commit=nil
        q.Apply=function() error("must not fall back") end
        eq(q:ApplyFromUI(),"UI commit scope unavailable","missing scope no fallback")
        q._commit=saved;eq(q:Release(),true,"missing scope fixture release")

        local file=debug.getinfo(1,"S").source:sub(2)
        -- Read-only consumer wiring check; this does not prove actual engine timing.
        local path=file:match("^(.*[/\\])").."../Tab/MonitorTab.lua"
        local stream=assert(io.open(path,"rb"));local bytes=stream:read("*a");stream:close()
        has(bytes,"plugin:ApplyFromUI()","Monitor Apply routed")
        has(bytes,"plugin:RetryRestartFromUI()","Monitor retry routed")
        eq(bytes:find("plugin:Apply()",1,true),nil,"Monitor not old direct Apply")
    end)
    if not p:IsReleased() then p:Release() end
    for _,k in ipairs(keys) do package.loaded[k]=saved[k] end
    if not ok then failed=failed+1;failures[#failures+1]=tostring(problem) end
    print(string.format("UICommitScopeSpec: %d passed / %d failed",passed,failed))
    for _,why in ipairs(failures) do print("  FAIL "..why) end
    return {passed=passed,failed=failed}
end
return M
