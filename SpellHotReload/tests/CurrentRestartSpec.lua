-- Workflow request/receipt/engine protocol; synthetic objects only.
local M={}
function M.run()
    local R=require("SpellHotReload.Runtime.CurrentRestart")
    local Binding=require("SpellHotReload.Adapters.Card.PracticeBinding")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local passed,failed,failures=0,0,{}
    local function check(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
    local handoff,replay=R.Handoff,Binding.IsReplay
    local globals={"_sc_table","lstg","stage","ext"}
    local saved={};for _,k in ipairs(globals) do saved[k]=rawget(_G,k) end
    local card={name="Live",init=function() end}
    local list={card};local class={cards=list};local classes={K=class}
    local anchor=function() end;local entry={anchor=anchor,reloadable=true}
    local snapshot={units={one={callbacks={init={fn=card.init}}}}}
    local capture={snapshot=snapshot,ownership={{class_key="K",class=class,list=list,slots={card}}}}
    local target={file="Request_Boss.lua",session_id="request:1",entry=entry,classes=classes,
        class_key="K",class=class,list=list,card=card,slot=1,name="Live",include_previous=true,key="one"}
    local live={entry=entry,classes=classes,session_id=target.session_id}
    local receipt={snapshot=snapshot,changed=false}
    local calls=0
    local function frozen()
        local run=R.Freeze(target,capture);assert(R.BindReceipt(run,receipt,capture));return run
    end
    local ok,problem=pcall(function()
        Binding.IsReplay=function() return false end
        R.Handoff=function() calls=calls+1 end
        local run=R.Freeze(target,capture)
        eq(run.state,"prepared","frozen before receipt")
        local yes,err=R.Request(run,live)
        eq(yes,nil,"uncommitted request refused");eq(err.phase,"restart","workflow error phase")
        eq(calls,0,"uncommitted no engine")
        eq(R.BindReceipt(run,{snapshot={}},capture),nil,"foreign snapshot receipt refused")
        eq(run.state,"prepared","failed receipt does not bind")
        eq(R.BindReceipt(run,receipt,capture),true,"no-op receipt accepted")
        eq(run.snapshot,snapshot,"installed snapshot identity")
        eq(R.BindReceipt(run,receipt,capture),nil,"cannot rebind a request")
        local issue=R.Handoff
        R.Handoff=function(...)
            local value,why=R.Request(run,live)
            eq(value,nil,"nested request refused");check(why.message:find("already active",1,true),"nested reason")
            return issue(...)
        end
        eq(R.Request(run,live),true,"synchronous request accepted")
        eq(run.state,"accepted","accepted state distinct from ready")
        eq(run.ready,"unobserved","request never claims Boss readiness")
        eq(run.attempts,1,"single attempt")
        eq(R.Request(run,live),true,"duplicate successful request idempotent")
        eq(calls,1,"duplicate never issues")
        eq(run.attempts,1,"duplicate no new attempt")
        run=frozen()
        R.Handoff=function() calls=calls+1;error("request fault") end
        yes,err=R.Request(run,live)
        eq(yes,nil,"engine fault refused");check(err.message:find("request fault",1,true),"fault kept")
        eq(run.state,"failed","failure retained for explicit retry")
        eq(run.attempts,1,"failed attempt recorded")
        R.Handoff=function() calls=calls+1 end
        eq(R.Request(run,live),true,"same committed request retried")
        eq(run.attempts,2,"retry attempt recorded")
        eq(capture.snapshot,snapshot,"retry no version advance")
        eq(run.selection,nil,"no prepared selection in run")
        eq(run.discovery,nil,"no candidate discovery in run")
        eq(Card.FreezeRestart,nil,"adapter no freeze API")
        eq(Card.RestartVersioned,nil,"adapter no versioned restart API")
        eq(Card.Restart,nil,"adapter has no restart hook")
        eq(Card.Restartable,nil,"adapter has no restart contract field")
        eq(Binding.Restart,nil,"binding has no restart facade")
        eq(Binding.FlyOut,nil,"binding has no pause facade")
        -- Exercise actual EXT_POS/PracticeStart/FlyOut protocol, not only a spy.
        R.Handoff=handoff
        _sc_table={};lstg={var={}};local starts,fly=0,0
        stage={group={PracticeStart=function(name)
            eq(name,"Spell Practice@Spell Practice","ordinary practice target");starts=starts+1
        end}}
        ext={pause_menu={IsKilled=function() return false end,FlyOut=function() fly=fly+1 end}}
        run=frozen();eq(R.Request(run,live),true,"actual workflow protocol requested")
        eq(starts,1,"one PracticeStart");eq(fly,1,"pause menu closed")
        for i,v in ipairs({"K","Live",card,1,true}) do eq(_sc_table.EXT_POS[i],v,"frozen EXT_POS "..i) end
        eq(lstg.var.sc_index,"EXT_POS","selected practice index")
    end)
    R.Handoff,Binding.IsReplay=handoff,replay
    for _,k in ipairs(globals) do rawset(_G,k,saved[k]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..tostring(problem) end
    print(string.format("CurrentRestartSpec: %d passed / %d failed",passed,failed))
    for _,label in ipairs(failures) do print("  FAIL "..label) end
    return {passed=passed,failed=failed}
end
return M
