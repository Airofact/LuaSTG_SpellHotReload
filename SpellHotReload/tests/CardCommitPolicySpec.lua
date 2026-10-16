local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Card-owned commit input/version policy. Synthetic first loads only.
-- Lua5.1 presence-only join is sufficient for zero-join raw publications here;
-- it is never a proof of physical sharing or target engine behavior.
local M = {}
local serial = 0
function M.run(opts)
    opts = opts or {}
    local Card = require("SpellHotReload.Adapters.Card.Card")
    local Cards = require("SpellHotReload.Adapters.Card.CardVersions")
    local Target = require("SpellHotReload.Adapters.Card.CardTarget")
    local Guard = require("SpellHotReload.Apply.CommitCheck")
    local Load = require("SpellHotReload.Load.AnchorLoad")
    local Capture = require("SpellHotReload.Adapters.Card.Card")
    local passed, failed, failures = 0, 0, {}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v,e end
    local input,propose,next_state,root = Card.CheckCommitInput,Card.ProposeVersion,Cards.Next,Target.CheckDiscovery
    local keys={"boss","_editor_class","_tmp_sc","_commit_policy_runs","jit"}
    local globals={};for _,key in ipairs(keys) do globals[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local traps,mutations=0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("hostile index") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end,
        __eq=function() traps=traps+1;error("hostile equality") end})
    local source=table.concat({
        "local state=4","_commit_policy_runs=_commit_policy_runs+1",
        "_editor_class['K'].cards={}","_tmp_sc=boss.card.New('A',1,2,3,4)",
        "function _tmp_sc:init() return 10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,4)",
        "function _tmp_sc:init() return 100 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    local content=source:gsub("return 10 end","return 20 end"):gsub("return 100 end","return 200 end")
    local function restore()
        Card.CheckCommitInput,Card.ProposeVersion,Cards.Next,Target.CheckDiscovery=input,propose,next_state,root
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        rawset(_G,"jit",globals.jit)
    end
    local function fixture()
        restore()
        if not join then debug.upvaluejoin=function() error("presence only: no joins allowed") end end
        _commit_policy_runs=0;_editor_class={K={}}
        local defaults={}
        for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
            defaults[name]=function() end
        end
        boss={card={New=function(label)
            local card={name=label,is_combat=true}
            for name,fn in next,defaults do card[name]=fn end
            return card
        end}}
        serial=serial+1
        local sid="CardCommitPolicySpec:"..serial
        local entry=must(Load.Capture(source,{name="Policy_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        entry.file="Policy_Boss.lua"
        local capture=must(Capture.SeedVersions(entry,sid,_editor_class,defaults))
        local selection=must(Cards.Select(must(Planning.Report(capture,content)),{"card:1:K:1"}))
        local live={capture=capture,snapshot=capture.snapshot,entry=entry,session_id=sid,
            classes=_editor_class,content=content}
        assert(#selection.joins==0 and #selection.writes==0 and #selection.publications==1)
        return selection,capture,live
    end
    local function refusal(v,e,code,label)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then
            eq(e.phase,"commit",label.." phase");eq(e.code,code,label.." code")
            test(type(e.message)=="string",label.." safe message")
        end
    end
    local function isolated()
        local path="SpellHotReload/Apply/CardCommit.lua"
        local text=opts.sources and opts.sources[path]
        return (text and assert(loadstring(text,"@candidate/"..path))
            or assert(loadfile("THDiMS/game/plugin/SpellHotReload/"..path)))()
    end
    local function unchanged(s,c,l,base,fn,label)
        eq(c.snapshot,base,label.." base retained");eq(l.classes.K.cards[1].init,fn,label.." callback retained")
        eq(_commit_policy_runs,1,label.." no source/body replay")
        eq(#s.pending,1,label.." sibling still pending")
    end
    local ok,problem=pcall(function()
        test(type(input)=="function","input rule exported");test(type(propose)=="function","version proposal exported")
        local s,c,l=fixture()
        local base,fn=c.snapshot,l.classes.K.cards[1].init
        debug.setupvalue=function() mutations=mutations+1;error("premature write") end
        debug.upvaluejoin=function() mutations=mutations+1;error("premature join") end
        rawset(_G,"jit",{flush=function() mutations=mutations+1;error("premature flush") end})
        eq(Card.CheckCommitInput(s,c,l),true,"valid fixed-layout input")
        local proposed=must(Card.ProposeVersion(s))
        eq(proposed.revision,1,"aggregate proposed revision")
        eq(proposed.functions,base.functions,"no function writes keep local revision")
        eq(proposed.units["card:1:K:1"].definition_version,base.units["card:1:K:1"].definition_version+1,"selected definition proposed")
        eq(proposed.units["card:1:K:2"].definition_version,base.units["card:1:K:2"].definition_version,"unselected definition unchanged")
        unchanged(s,c,l,base,fn,"pure policy")
        eq(mutations,0,"policy never mutates")
        local empty=must(Cards.Select(must(Planning.Report(c,source)),{}))
        eq(Card.ProposeVersion(empty),base,"empty proposal exact base")
        local marker={phase="inject",code="unsupported",message="version policy refused"}
        Cards.Next=function(selection) eq(selection,s,"version service exact input");return nil,marker end
        local v,e=Card.ProposeVersion(s);eq(v,nil,"version refusal retained");eq(e,marker,"version error exact identity")
        Cards.Next=next_state
        local cases={
            {function(x) x.kind="foreign" end,"unsupported"},
            {function(x) x.version=2 end,"unsupported"},
            {function(_,y) y.kind="foreign" end,"unsupported"},
            {function(_,y) y.version=2 end,"unsupported"},
            {function(x) x.base_revision=9 end,"stale"},
            {function(x) x.functions.base_revision=9 end,"stale"},
            {function(x) x.functions.base={} end,"stale"},
            {function(_,_,z) z.snapshot={} end,"stale"},
            {function(_,_,z) z.capture={} end,"stale"},
            {function(_,_,z) z.session_id="foreign" end,"stale"},
            {function(_,_,z) z.content=z.content.."\n" end,"stale"},
            {function(_,_,z) z.entry.missing=true end,"stale"},
            {function(_,_,z) z.entry.reloadable=false end,"stale"},
            {function(_,_,z) z.released=true end,"stale"},
            {function(_,_,z) z.poisoned=true end,"stale"},
            {function(x) setmetatable(x,{__index=function() traps=traps+1;error("plan index") end}) end,"unsupported"},
        }
        for i,case in ipairs(cases) do
            s,c,l=fixture();case[1](s,c,l)
            v,e=Card.CheckCommitInput(s,c,l);refusal(v,e,case[2],"input case "..i)
        end
        s,c,l=fixture();s.file_location=nil
        v,e=Card.CheckCommitInput(s,c,l);refusal(v,e,"unsupported","missing correspondence scope")
        s,c,l=fixture();s.location={}
        v,e=Card.CheckCommitInput(s,c,l);refusal(v,e,"unsupported","conflicting correspondence scopes")
        s,c,l=fixture();local location,binding={key="root-key"},{mode="practice"}
        s.location,l.binding,s.file_location=location,binding,nil
        Target.CheckDiscovery=function(loc,current,capture,live)
            eq(loc,location,"located root exact location");eq(current,binding,"located root latest binding")
            eq(capture,c,"located root exact capture");eq(live,l,"located root fresh live")
            return nil,{code="ownership",message="located root changed"}
        end
        v,e=Card.CheckCommitInput(s,c,l);refusal(v,e,"ownership","located refusal")
        eq(e.unit_key,"root-key","located key retained");eq(e.file,"Policy_Boss.lua","located file retained")
        s,c,l=fixture()
        Card.CheckCommitInput=function(a,b,d)
            eq(a,s,"Guard exact selection");eq(b,c,"Guard exact capture");eq(d,l,"Guard exact live")
            return nil,marker
        end
        v,e=Guard.Check(s,c,l);eq(v,nil,"Guard respects adapter refusal");eq(e,marker,"Guard preserves policy error")
        Card.CheckCommitInput=function() error(hostile) end
        v,e=Guard.Check(s,c,l);refusal(v,e,"stale","Guard contains unsafe thrown object")
        eq(traps,0,"unsafe object not inspected")
        -- The kernel captures the Card proposal callback when instantiated.
        -- Input policy remains the two fresh Guard reads before Consume.
        s,c,l=fixture();base,fn=c.snapshot,l.classes.K.cards[1].init
        local log,inputs,versions={},0,0
        Card.CheckCommitInput=function(...)
            inputs=inputs+1;log[#log+1]="input";return input(...)
        end
        Card.ProposeVersion=function(plan)
            versions=versions+1;log[#log+1]="version"
            test(plan~=s,"proposal consumes sealed selection")
            test(plan.publications~=s.publications,"proposal consumes sealed array")
            test(plan.publications[1]~=s.publications[1],"proposal consumes sealed action")
            return propose(plan)
        end
        local Tx=isolated();local controller=must(Tx.New(l.session_id))
        Card.ProposeVersion=function() error("late replacement must not replace pinned policy") end
        rawset(_G,"jit",{flush=function() log[#log+1]="flush" end})
        local receipt,err
        must(controller:Run(function(token)
            receipt,err=controller:Commit(token,s,c,l,function()
                log[#log+1]="fresh";return l
            end)
        end))
        test(receipt~=nil,"policy-backed commit succeeds")
        eq(inputs,2,"input policy before and after flush")
        eq(versions,1,"one sealed version proposal")
        eq(table.concat(log,","),"input,version,flush,fresh,input","pre-consume policy order")
        eq(c.snapshot,receipt and receipt.snapshot,"kernel installs proposal last")
        eq(c.snapshot.revision,1,"one installed revision")
        eq(l.classes.K.cards[1]:init(),20,"selected callback installed")
        eq(l.classes.K.cards[2]:init(),100,"unselected callback not installed")
        eq(#s.pending,1,"unselected source still pending")
        eq(_commit_policy_runs,1,"candidate wiring not executed")
        must(controller:Release())
        for _,mode in ipairs({"input-first","version-refuse","version-throw","input-final"}) do
            s,c,l=fixture();base,fn=c.snapshot,l.classes.K.cards[1].init
            local read_count,version_count,flush_count=0,0,0
            Card.CheckCommitInput=function(...)
                read_count=read_count+1
                if mode=="input-first" or (mode=="input-final" and read_count==2) then
                    return nil,{phase="commit",code="stale",message="policy refusal"}
                end
                return input(...)
            end
            Card.ProposeVersion=function(plan)
                version_count=version_count+1
                if mode=="version-refuse" then return nil,marker end
                if mode=="version-throw" then error(hostile) end
                return propose(plan)
            end
            controller=must(isolated().New(l.session_id))
            rawset(_G,"jit",{flush=function() flush_count=flush_count+1 end})
            must(controller:Run(function(token) receipt,err=controller:Commit(token,s,c,l) end))
            refusal(receipt,err,mode=="version-refuse" and "unsupported" or
                (mode=="version-throw" and "unsupported" or "stale"),mode)
            unchanged(s,c,l,base,fn,mode)
            eq(controller:Poisoned(),false,mode.." preflight does not poison")
            eq(version_count,mode=="input-first" and 0 or 1,mode.." proposal count")
            eq(flush_count,mode=="input-final" and 1 or 0,mode.." flush count")
            must(controller:Release())
        end
        eq(traps,0,"no hostile metamethod executed")
    end)
    restore()
    for _,key in ipairs(keys) do rawset(_G,key,globals[key]) end
    if not ok then error(problem) end
    for _,label in ipairs(failures) do print("FAIL CardCommitPolicySpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
