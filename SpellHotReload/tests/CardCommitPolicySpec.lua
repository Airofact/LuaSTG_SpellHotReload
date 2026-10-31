local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Real owner policy and common preflight, with miniature first loads only.
-- No legacy Card commit facade or presence-only sharing fixture.
local M={}
local serial=0
function M.run(opts)
    opts=opts or {}
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Cards=require("SpellHotReload.Adapters.Card.CardVersions")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Target=require("SpellHotReload.Adapters.Card.CardTarget")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local ClassAdapter=require("SpellHotReload.Adapters.Class.Class")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local passed,failed,failures=0,0,{}
    local controllers={}
    local function test(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function copy(v) local out={};for k,x in next,v do out[k]=x end;return out end
    local next_state,root,file_root,propose=Cards.Next,Target.CheckDiscovery,Target.CheckFileDiscovery,Files.Propose
    local keys={"_commit_policy_runs","jit"}
    local environment
    local globals={};for _,key in ipairs(keys) do globals[key]=rawget(_G,key) end
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local traps,mutations=0,0
    local hostile=setmetatable({},{
        __index=function() traps=traps+1;error("hostile index") end,
        __tostring=function() traps=traps+1;error("hostile tostring") end,
        __eq=function() traps=traps+1;error("hostile equality") end})
    local keya,keyb="card:1:K:1","card:1:K:2"
    local source=table.concat({
        "local state=4","_commit_policy_runs=_commit_policy_runs+1",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={}","_tmp_sc=boss.card.New('A',1,2,3,4)",
        "function _tmp_sc:init() return 10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,4)",
        "function _tmp_sc:init() return 100 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    },"\n")
    local content=source:gsub("return 10 end","return 20 end"):gsub("return 100 end","return 200 end")
    local function restore()
        Cards.Next,Target.CheckDiscovery,Target.CheckFileDiscovery,Files.Propose=next_state,root,file_root,propose
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        rawset(_G,"jit",globals.jit)
    end
    local function group(snapshot,owner)
        for _,g in ipairs(snapshot.owners) do if g.owner==owner then return g end end
        error("missing actual owner")
    end
    local function fragment(p,owner)
        for _,r in ipairs(p.entries) do if r.owner==owner then return r.fragment end end
        error("missing genuine prepared owner")
    end
    local function fragments(p)
        local out={};for _,r in ipairs(p.entries) do out[#out+1]=r.fragment end
        return out
    end
    local function prepare(f,l,bytes,ids,mode)
        l.content,l.generation,l.snapshot=bytes,l.generation+1,f.capture.snapshot
        local d=must(Planning.Discover(f,must(Source.Build(bytes)),l.generation))
        local options={mode=mode or "file",refresh=f.refresh}
        if mode~="current" then options.root_ids=ids end
        local p=must(Planning.Prepare(f,d,options))
        eq(#p.dependencies.safe_roots,mode=="current" and 1 or #ids,"all requested roots safe")
        eq(#p.dependencies.blocked_roots,0,"no refusal hidden in an empty preparation")
        return p
    end
    local function fixture(mode,bytes,ids)
        restore()
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        _commit_policy_runs=0
        local defaults={}
        for _,name in ipairs({"before","init","frame","render","beforedel","del","after"}) do
            defaults[name]=function() end
        end
        boss.card={_default_card=defaults,New=function(label)
            local card={name=label,is_combat=true}
            for name,fn in next,defaults do card[name]=fn end
            return card
        end}
        serial=serial+1
        local sid="CardCommitPolicySpec:"..serial
        local entry=must(Load.Capture(source,{name="Policy_Boss.lua"}))
        must(entry.reloadable,entry.reason);entry.file="Policy_Boss.lua"
        local f=must(Planning.Capture(entry,sid,_editor_class,defaults))
        environment:FinishLoad()
        local c=f.capture
        local l={capture=c,snapshot=c.snapshot,entry=entry,session_id=sid,
            classes=_editor_class,content=source,generation=0,fixture=f}
        l.binding={class_key="K",slot=1,card=_editor_class.K.cards[1],name="A",
            names={"A","B"},mode="practice",include_previous=false}
        f.refresh=function() return l end
        local p=prepare(f,l,bytes or content,ids or {keya},mode)
        local card,loc=fragment(p,Card),fragment(p,Local)
        eq(#card.joins+#loc.joins,0,"real fixture has no joins")
        eq(#card.cell_writes+#loc.cell_writes,0,"real fixture has no cell writes")
        eq(#card.raw_writes,bytes==source and 0 or 1,"exact selected raw writes")
        return p,c,l
    end
    local function seal(p) return Guard.Seal(p.operation,fragments(p)) end
    local function refusal(v,e,code,label,phase)
        eq(v,nil,label.." refused");eq(type(e),"table",label.." structured")
        if type(e)=="table" then
            eq(e.phase,phase or "commit",label.." phase");eq(e.code,code,label.." code")
            test(type(e.message)=="string",label.." safe message")
        end
    end
    local function isolated(checks,raw_write)
        local path="SpellHotReload/Apply/FileCommit.lua"
        local text=opts.sources and opts.sources[path]
        local chunk=text and assert(loadstring(text,"@candidate/"..path))
            or assert(loadfile(opts.module_path or "THDiMS/game/plugin/SpellHotReload/"..path))
        local env={require=function(name)
            if name=="SpellHotReload.Apply.CommitCheck" and checks then return checks end
            return require(name)
        end}
        if raw_write then env.rawset=raw_write end
        setfenv(chunk,setmetatable(env,{__index=_G}))
        return chunk()
    end
    local function controller(module,sid)
        local tx=must(module.New(sid));controllers[#controllers+1]=tx;return tx
    end
    local function unchanged(p,c,l,base,fn,label)
        eq(c.snapshot,base,label.." base retained")
        eq(l.classes.K.cards[1].init,fn,label.." selected callback retained")
        eq(l.classes.K.cards[2]:init(),100,label.." sibling callback retained")
        eq(_commit_policy_runs,1,label.." no miniature source replay")
        eq(fragment(p,Card).card_plan.view.by_key[keyb].changed,true,label.." sibling still pending")
    end
    local function forbid()
        debug.setupvalue=function() mutations=mutations+1;error("premature write") end
        debug.upvaluejoin=function() mutations=mutations+1;error("premature join") end
        rawset(_G,"jit",{flush=function() mutations=mutations+1;error("premature flush") end})
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug)))
        local p,c,l=fixture()
        local base,fn=c.snapshot,l.classes.K.cards[1].init
        forbid()
        local sealed=must(seal(p))
        eq(Guard.Check(sealed,c,l),true,"real owner and mechanical policy accepts")
        local proposed=sealed.proposed_snapshot
        eq(proposed.revision,1,"one common proposed revision")
        eq(group(proposed,Local),group(base,Local),"no Local writes retain exact actual group")
        eq(#base.owners,3,"one genuine Local/Class/Card publication")
        eq(group(proposed,ClassAdapter),group(base,ClassAdapter),"no Class writes retain exact actual group")
        eq(#fragment(p,ClassAdapter).raw_writes,0,"readonly Class does not gain callback write authority")
        eq(group(proposed,Card).state.units[keya].definition_version,
            group(base,Card).state.units[keya].definition_version+1,"selected Card version proposed")
        eq(group(proposed,Card).state.units[keyb].definition_version,
            group(base,Card).state.units[keyb].definition_version,"unselected Card version retained")
        unchanged(p,c,l,base,fn,"pure policy");eq(mutations,0,"Seal and Check never mutate or flush")

        p,c,l=fixture("file",source,{})
        base,fn=c.snapshot,l.classes.K.cards[1].init
        forbid();sealed=must(seal(p))
        eq(sealed.proposed_snapshot,base,"genuine no-op exact common base")
        eq(#sealed.journal+#sealed.joins,0,"no-op has no installation actions")
        eq(Guard.Check(sealed,c,l),true,"no-op still checks original owners")
        eq(mutations,0,"no-op policy pure")

        -- Card's existing private version service is still a domain check.
        -- Its group is NOT a file revision or a second publication ledger.
        p,c,l=fixture();base,fn=c.snapshot,l.classes.K.cards[1].init
        sealed=must(seal(p))
        local marker={phase="inject",code="unsupported",message="version policy refused"}
        Cards.Next=function(plan)
            eq(plan,fragment(p,Card).card_plan,"Card version service exact private plan")
            return nil,marker
        end
        local v,e=Guard.Check(sealed,c,l)
        eq(v,nil,"Guard respects real Card version refusal");eq(e,marker,"direct Guard retains owner error identity")
        Cards.Next=function() error(hostile) end
        v,e=Guard.Check(sealed,c,l);refusal(v,e,"stale","Guard contains unsafe owner throw")
        unchanged(p,c,l,base,fn,"owner refusal");eq(traps,0,"unsafe owner object untouched")

        -- Retired selection/functions fields are replaced by their actual public
        -- plan/capture/fragment boundaries; no ignored legacy fields are added.
        local cases={
            {"kernel kind",function(_,_,_,s) s.kind="foreign" end,"stale"},
            {"kernel version",function(_,_,_,s) s.version=2 end,"stale"},
            {"capture kind",function(_,cap) cap.kind="foreign" end,"ownership","seal"},
            {"capture version",function(_,cap) cap.version=2 end,"ownership","seal"},
            {"base identity",function(x) x.operation.base_snapshot={} end,"ownership","seal"},
            {"Local base group",function(x) fragment(x,Local).base_group={} end,"ownership","seal"},
            {"no-write Local metadata",function(x)
                local f=fragment(x,Local);f.proposed_group=copy(f.proposed_group)
            end,"ownership","seal"},
            {"no-write Class metadata",function(x)
                local f=fragment(x,ClassAdapter);f.proposed_group=copy(f.proposed_group)
            end,"ownership","seal"},
            {"live snapshot",function(_,_,live) live.snapshot={} end,"stale","locate"},
            {"live capture",function(_,_,live) live.capture={} end,"stale","locate"},
            {"live session",function(_,_,live) live.session_id="foreign" end,"stale"},
            {"live bytes",function(_,_,live) live.content=live.content.."\n" end,"stale","locate"},
            {"live generation",function(_,_,live) live.generation=99 end,"stale","locate"},
            {"missing source",function(_,_,live) live.entry.missing=true end,"stale","inject"},
            {"retired entry",function(_,_,live) live.entry.reloadable=false end,"stale","inject"},
            {"released",function(_,_,live) live.released=true end,"stale","locate"},
            {"poisoned",function(_,_,live) live.poisoned=true end,"stale","locate"},
            {"operation metatable",function(x)
                setmetatable(x.operation,{__index=function() traps=traps+1;error("plan index") end})
            end,"ownership","seal","commit"},
        }
        for _,case in ipairs(cases) do
            p,c,l=fixture();sealed=must(seal(p))
            base,fn=c.snapshot,l.classes.K.cards[1].init
            case[2](p,c,l,sealed);forbid()
            if case[4]=="seal" then v,e=seal(p) else v,e=Guard.Check(sealed,c,l) end
            refusal(v,e,case[3],case[1],case[4]=="seal" and (case[5] or "versions") or (case[4] or "commit"))
            eq(c.snapshot,base,case[1].." no snapshot publication")
            eq(l.classes.K.cards[1].init,fn,case[1].." no callback publication")
            eq(_commit_policy_runs,1,case[1].." no source replay")
        end
        eq(mutations,0,"input matrix has no mutation/flush")

        p,c,l=fixture();sealed=must(seal(p))
        fragment(p,Card).card_runtime.file_location=nil
        v,e=Guard.Check(sealed,c,l);refusal(v,e,"stale","missing original file correspondence")
        p,c,l=fixture();sealed=must(seal(p))
        p.operation.card.target={}
        v,e=Guard.Check(sealed,c,l);refusal(v,e,"stale","changed original file operation target")

        -- Current genuinely carries BOTH full-file and private current proof.
        p,c,l=fixture("current");sealed=must(seal(p))
        local runtime=fragment(p,Card).card_runtime
        test(runtime.file_location~=nil and runtime.current_location~=nil,"Current has both genuine scopes")
        local location=runtime.current_location
        local located={phase="locate",code="ownership",message="located root changed",
            unit_key=keya,file="Policy_Boss.lua"}
        local located_calls=0
        Target.CheckDiscovery=function(loc,binding,capture,live)
            located_calls=located_calls+1
            eq(loc,location,"exact original Current location");eq(binding,l.binding,"latest Current binding")
            eq(capture,c,"exact common capture");eq(live,l,"fresh live input")
            return nil,located
        end
        v,e=Guard.Check(sealed,c,l)
        refusal(v,e,"ownership","located refusal","locate");eq(e,located,"direct owner error unchanged")
        eq(located_calls,1,"real Current check reached once")
        eq(e.unit_key,keya,"owner key retained");eq(e.file,"Policy_Boss.lua","owner file retained")

        -- Common proposal precedes both complete three-owner/native read passes. FileCommit captures
        -- neutral Guard functions at MODULE LOAD, not the mutable Card policy.
        p,c,l=fixture();base,fn=c.snapshot,l.classes.K.cards[1].init
        local log,inputs,versions={}, {[Local]=0,[ClassAdapter]=0,[Card]=0},0
        for _,owner in ipairs({Local,ClassAdapter,Card}) do
            local raw_fragment=fragment(p,owner)
            local owner_guard=raw_fragment.owner_guard
            raw_fragment.owner_guard=function(f,cap,live)
                inputs[owner]=inputs[owner]+1;log[#log+1]=owner.Id
                test(f~=raw_fragment,"Guard consumes sealed owner fragment")
                test(f.raw_writes~=raw_fragment.raw_writes,"Guard consumes sealed action array")
                if owner==Card then test(f.raw_writes[1]~=raw_fragment.raw_writes[1],"Guard consumes sealed raw action") end
                return owner_guard(f,cap,live)
            end
        end
        local original_fragments=fragments(p)
        Files.Propose=function(operation,all)
            versions=versions+1;log[#log+1]="version"
            eq(operation,p.operation,"common version exact operation")
            eq(all,original_fragments,"common version all original owner fragments")
            return propose(operation,all)
        end
        local checks=copy(Guard)
        checks.Seal=function(...) log[#log+1]="seal";return Guard.Seal(...) end
        checks.Owners=function(...) log[#log+1]="owners";return Guard.Owners(...) end
        checks.Mechanical=function(...) log[#log+1]="mechanical";return Guard.Mechanical(...) end
        local module=isolated(checks)
        checks.Seal=function() error("late replacement of captured Seal") end
        checks.Owners=function() error("late replacement of captured Owners") end
        checks.Mechanical=function() error("late replacement of captured Mechanical") end
        local tx=controller(module,l.session_id)
        rawset(_G,"jit",{flush=function(...) eq(select("#",...),0,"whole-cache flush");log[#log+1]="flush" end})
        local receipt,err
        eq(tx:Run(function(token)
            receipt,err=tx:Commit(token,p.operation,original_fragments,l,function()
                log[#log+1]="fresh";return l
            end)
        end),true,"policy-backed scope")
        test(receipt~=nil,"real policy-backed commit succeeds")
        eq(inputs[Local],2,"Local owner before and after refresh")
        eq(inputs[ClassAdapter],2,"Class owner before and after refresh")
        eq(inputs[Card],2,"Card owner before and after refresh")
        eq(versions,1,"one common version proposal")
        eq(table.concat(log,","),"seal,version,owners,local,class,card,mechanical,flush,fresh,owners,local,class,card,mechanical",
            "all policy before native final checks and Consume")
        eq(c.snapshot,receipt and receipt.snapshot,"kernel installs common proposal")
        eq(c.snapshot.revision,1,"one installed common revision")
        eq(l.classes.K.cards[1]:init(),20,"selected callback installed")
        eq(l.classes.K.cards[2]:init(),100,"unselected callback retained")
        eq(_commit_policy_runs,1,"miniature candidate wiring not executed")
        local remainder=prepare(l.fixture,l,content,{})
        eq(fragment(remainder,Card).card_plan.view.by_key[keya].changed,false,"new discovery selected callback clean")
        eq(fragment(remainder,Card).card_plan.view.by_key[keyb].changed,true,"new discovery sibling still pending")
        must(tx:Release())

        for _,mode in ipairs({"input-first","version-refuse","version-throw","input-final"}) do
            p,c,l=fixture();base,fn=c.snapshot,l.classes.K.cards[1].init
            local reads,version_count,flush_count,raw_count=0,0,0,0
            local card_fragment=fragment(p,Card);local owner_guard=card_fragment.owner_guard
            card_fragment.owner_guard=function(...)
                reads=reads+1
                if mode=="input-first" or (mode=="input-final" and reads==2) then
                    return nil,{phase="commit",code="stale",message="policy refusal"}
                end
                return owner_guard(...)
            end
            Files.Propose=function(operation,all)
                version_count=version_count+1
                if mode=="version-refuse" then return nil,marker end
                if mode=="version-throw" then error(hostile) end
                return propose(operation,all)
            end
            tx=controller(isolated(nil,function(t,k,value)
                raw_count=raw_count+1;return rawset(t,k,value)
            end),l.session_id)
            forbid()
            rawset(_G,"jit",{flush=function() flush_count=flush_count+1 end})
            eq(tx:Run(function(token)
                receipt,err=tx:Commit(token,p.operation,fragments(p),l,l.fixture.refresh)
                eq(tx:Check(token),true,mode.." preflight retains token")
            end),true,mode.." scope")
            refusal(receipt,err,mode=="version-refuse" and "unsupported" or
                (mode=="version-throw" and "ownership" or "stale"),mode)
            test(err~=marker,mode.." kernel returns normalized structural error")
            eq(err.file,"Policy_Boss.lua",mode.." kernel supplies file")
            unchanged(p,c,l,base,fn,mode)
            eq(tx:Poisoned(),false,mode.." preflight does not poison")
            eq(version_count,1,mode.." one common proposal before owner reads")
            eq(reads,mode=="input-first" and 1 or (mode=="input-final" and 2 or 0),mode.." exact Card reads")
            eq(flush_count,mode=="input-final" and 1 or 0,mode.." flush count")
            eq(raw_count,0,mode.." no live raw write")
            eq(mutations,0,mode.." no join or cell write")
            must(tx:Release())
        end
        eq(traps,0,"no hostile metamethod executed")
    end)
    restore()
    for _,tx in ipairs(controllers) do tx:Release() end
    if environment then environment:Restore() end
    for _,key in ipairs(keys) do rawset(_G,key,globals[key]) end
    if not ok then error(problem) end
    for _,label in ipairs(failures) do print("FAIL CardCommitPolicySpec: "..label) end
    return {passed=passed,failed=failed}
end
return M
