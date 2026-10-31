-- Workflow state/receipt/engine protocol with genuine common first-load capture.
-- No-op receipts below are synthetic contract inputs; PluginEntrySpec exercises real receipts.
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
    local globals={"_sc_table","lstg","stage","ext","boss","_editor_class","_tmp_sc"}
    local saved={};for _,k in ipairs(globals) do saved[k]=rawget(_G,k) end
    local environment
    local ok,problem=pcall(function()
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,n in ipairs(callbacks) do defaults[n]=function() end end
    if environment then environment:Restore() end
        environment=ClassFixture.Install()
        _editor_class={K={}}
    boss.card={New=function(n)
        local c={name=n,is_combat=true};for _,cb in ipairs(callbacks) do c[cb]=defaults[cb] end;return c
    end}
    local source=table.concat({"local counter=3","local function helper(n) return counter+n end",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={}","_tmp_sc=boss.card.New('Live')",
        "function _tmp_sc:init(n) return helper(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
    local entry=assert(Load.Capture(source,{name="Request_Boss.lua"}));entry.file="Request_Boss.lua"
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local f=assert(Planning.Capture(entry,"request:1",_editor_class,defaults))
    local capture=f.capture
    environment:FinishLoad()
    local snapshot=capture.snapshot
    local classes=_editor_class;local class=classes.K;local list=class.cards;local card=list[1]
    local live={entry=entry,classes=classes,session_id="request:1",capture=capture,snapshot=snapshot}
    local target=assert(Target.Resolve({class_key="K",card=card,slot=1,name="Live",
        mode="practice",names={"Live"},include_previous=true},capture,live))
    local deltas={};for i,g in ipairs(snapshot.owners) do
        deltas[i]={owner=g.owner,owner_id=g.owner_id,changed=false,unit_refs={}}
    end
    local receipt={kind="SpellHotReload.FileCommit.Receipt",version=1,file=entry.file,
        snapshot=snapshot,changed=false,owner_deltas=deltas}
    local calls=0
    local function frozen()
        local run=R.Freeze(target,capture);assert(R.BindReceipt(run,receipt,capture));return run
    end
        Binding.IsReplay=function() return false end
        R.Handoff=function() calls=calls+1 end
        local run=R.Freeze(target,capture)
        eq(run.state,"prepared","frozen before receipt")
        local yes,err=R.Request(run,live)
        eq(yes,nil,"uncommitted request refused");eq(err.phase,"restart","workflow error phase")
        eq(calls,0,"uncommitted no engine")
        eq(R.BindReceipt(run,{snapshot={}},capture),nil,"foreign snapshot receipt refused")
        eq(run.state,"prepared","failed receipt does not bind")
        local wrong={};for k,v in pairs(receipt) do wrong[k]=v end
        wrong.kind="CardReceipt"
        eq(R.BindReceipt(run,wrong,capture),nil,"old owner-only receipt refused")
        wrong.kind=receipt.kind;wrong.owner_deltas={}
        eq(R.BindReceipt(run,wrong,capture),nil,"filtered owner deltas refused")
        wrong.owner_deltas={deltas[3],deltas[2],deltas[1]}
        eq(R.BindReceipt(run,wrong,capture),nil,"foreign owner order refused")
        wrong.owner_deltas=deltas;wrong.changed=true
        eq(R.BindReceipt(run,wrong,capture),nil,"unchanged snapshot cannot claim changed")
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
        local original_name=run.name;run.name="candidate name"
        eq(R.Request(run,live),nil,"frozen scalar tamper refused even after acceptance")
        run.name=original_name
        for _,flag in ipairs({"released","poisoned","publication_error"}) do
            live[flag]=true;eq(R.Request(run,live),nil,"accepted request checks "..flag);live[flag]=nil
        end
        local fn=card.init;card.init=function() end
        eq(R.Request(run,live),nil,"accepted callback drift refused");card.init=fn
        local extra={};list[2]=extra
        eq(R.Request(run,live),nil,"accepted whole-list ownership drift refused");list[2]=nil
        Binding.IsReplay=function() return true end
        eq(R.Request(run,live),nil,"accepted replay refused")
        Binding.IsReplay=function() return false end
        entry.missing,entry.reloadable=true,false
        eq(R.Request(run,live),true,"Missing retains accepted frozen proof without versions lookup")
        entry.missing,entry.reloadable=nil,true
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
    if environment then environment:Restore() end
    for _,k in ipairs(globals) do rawset(_G,k,saved[k]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected: "..tostring(problem) end
    print(string.format("CurrentRestartSpec: %d passed / %d failed",passed,failed))
    for _,label in ipairs(failures) do print("  FAIL "..label) end
    return {passed=passed,failed=failed}
end
return M
