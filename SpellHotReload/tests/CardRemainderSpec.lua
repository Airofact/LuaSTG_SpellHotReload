-- Complete remainder diagnostics, NOT candidate removal or game acceptance.
-- Only miniature FIRST-load fixtures execute. Candidates never initialize or
-- register. LuaJIT uses the real CardCommit kernel for publication evidence;
-- Lua5.1 uses a throwing presence stub for pure analysis, never fake commits.
local M = {}
function M.run()
    local Cards = require("SpellHotReload.CardVersions")
    local Target = require("SpellHotReload.CardTarget")
    local Card = require("SpellHotReload.Card")
    local Driver = require("SpellHotReload.Driver")
    local Load = require("SpellHotReload.AnchorLoad")
    local Commit = require("SpellHotReload.CardCommit")
    local Anchor = require("SpellHotReload.Anchor")
    local passed, failed, failures = 0, 0, {}
    local function check(v, label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(a==b,label .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function has(model,kind,key)
        for _,row in ipairs(model.pending) do
            if row.kind==kind and (not key or row.key==key) then return row end
        end
    end
    local globals={"boss","_editor_class","_tmp_sc","_sc_table","REMAINDER_EFFECT","jit"}
    local saved={};for _,name in ipairs(globals) do saved[name]=rawget(_G,name) end
    local real_join,real_set=debug.upvaluejoin,debug.setupvalue
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(callbacks) do defaults[name]=function() end end
    local serial,controllers=0,{}
    local SIDE=table.concat({"_editor_class['L'].cards={}",
        "_tmp_sc=boss.card.New('Side',1,2,3,100)",
        "function _tmp_sc:init(n) return idle(n) end",
        "table.insert(_editor_class['L'].cards,_tmp_sc)"},"\n")
    local SOURCE=table.concat({"local state=4","local flag=false","local empty",
        "local function helper(n) return state+n end",
        "local function idle(n) return n+100 end",
        "local alias=helper","REMAINDER_EFFECT()",
        "_editor_class['K'].cards={boss.move.New(0,0,1)}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end",
        "_tmp_sc.frame=function(self) return flag,empty end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n)+10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",SIDE},"\n")
    local KA,KB="card:1:K:2","card:1:K:3"
    local function fixture(source)
        source=source or SOURCE
        serial=serial+1
        debug.setupvalue=real_set
        debug.upvaluejoin=real_join or function() error("presence-only analysis") end
        jit=saved.jit
        local f={effects=0,constructs=0,bytes=source}
        REMAINDER_EFFECT=function() f.effects=f.effects+1 end
        _editor_class={K={},L={}};_sc_table={}
        boss={card={_default_card=defaults,New=function(label)
            f.constructs=f.constructs+1
            local c={name=label,is_combat=true}
            for _,name in ipairs(callbacks) do c[name]=defaults[name] end
            return c
        end},move={New=function() return {is_combat=false} end}}
        f.entry=must(Load.Capture(source,{name="Remainder_Boss.lua",
            capability={getupvalue=true,setupvalue=true,upvaluejoin=true}}))
        f.entry.file="Remainder_Boss.lua"
        f.capture=must(Card.CaptureVersions(f.entry,"remainder:" .. serial))
        f.driver=Driver.New();assert(f.driver:RegisterDiscovery(Card))
        f.live={capture=f.capture,entry=f.entry,classes=_editor_class,
            session_id=f.capture.snapshot.session_id}
        f.controller=must(Commit.New(f.live.session_id));controllers[#controllers+1]=f.controller
        function f.report(bytes,scope)
            local base=f.capture.snapshot
            f.bytes=bytes;f.live.snapshot=base;f.live.content=bytes
            local discovery=must(f.driver:Discover(f.entry.file,bytes,{session_id=base.session_id,
                registry_entry=f.entry,loaded_source=base.loaded_source,published_units=base,
                base_revision=base.revision,candidate_generation=7})).snapshot
            if scope=="current" then
                local list=f.live.classes.K.cards
                local names={};for i,c in ipairs(list) do names[i]=c.name or "" end
                local binding={class_key="K",slot=2,card=list[2],name=list[2].name,
                    names=names,mode="practice",include_previous=false}
                f.live.binding=binding
                local target=must(Target.Resolve(binding,f.capture,f.live))
                local location=must(Target.LocateDiscovery(target,discovery,binding,f.capture,f.live))
                return must(Cards.CompareLocated(base,location,binding,f.capture,f.live))
            end
            local location=must(Target.LocateFileDiscovery(discovery,f.capture,f.live))
            return must(Cards.CompareFileLocated(base,location,f.capture,f.live))
        end
        function f.remaining(bytes,scope) return must(Cards.Remaining(f.report(bytes,scope))) end
        function f.commit(bytes,scope)
            local report=f.report(bytes,scope)
            local selection=must(scope=="current" and Cards.Select(report,{KA}) or Cards.SelectFile(report))
            local ran,receipt,err=f.controller:Run(function(token)
                return f.controller:Commit(token,selection,f.capture,f.live,function() return f.live end)
            end)
            eq(ran,true,"trusted offline scope ran")
            return must(receipt,err),selection
        end
        return f
    end
    local ok,problem=pcall(function()
        local f=fixture()
        local base=f.capture.snapshot
        local model=f.remaining(SOURCE)
        eq(model.complete,true,"unchanged complete source")
        eq(#model.pending,0,"all tokens covered")
        eq(model.file,f.entry.file,"file scope")
        eq(model.session_id,base.session_id,"session scope")
        eq(model.revision,0,"actual revision, not proposal")
        eq(model.generation,7,"candidate generation")
        eq(model.content,SOURCE,"exact bytes kept distinct from signatures")
        local bom=fixture("\239\187\191" .. SOURCE)
        eq(bom.remaining("\239\187\191" .. SOURCE).complete,true,"BOM first-load offsets")
        local bom_edit="\239\187\191" .. SOURCE:gsub("state=4","state=999")
        local bom_pending=bom.remaining(bom_edit)
        local state_point=has(bom_pending,"initializer","local:state")
        check(state_point and state_point.first==4,"BOM initializer byte range refers to full bytes")
        f=fixture();base=f.capture.snapshot
        local formatted="\239\187\191" .. SOURCE:gsub("state=4","state = 4 -- retained state\r\n")
            :gsub("return helper%(n%) end","return -- comment\n helper ( n ) end",1)
        eq(f.remaining(formatted).complete,true,"BOM and formatting are not semantic changes")
        local edited=SOURCE:gsub("state%+n end","state+n+1 end")
            :gsub("helper%(n%)%+10","helper(n)+20")
        local joins,writes,flushes=0,0,0
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        jit={flush=function() flushes=flushes+1;error("premature flush") end}
        model=f.remaining(edited)
        eq(model.complete,false,"planned definitions are not published")
        check(has(model,"function","local:helper"),"helper pending")
        check(has(model,"callback",KB .. ":init"),"sibling callback pending")
        eq(f.capture.snapshot,base,"analysis leaves snapshot")
        eq(Anchor.Get(f.entry,"helper"),base.functions.units.helper.fn,"analysis leaves cell")
        eq(joins,0,"no joins");eq(writes,0,"no writes");eq(flushes,0,"no flush")
        eq(f.effects,1,"no candidate initialization");eq(f.constructs,3,"no registration replay")
        debug.upvaluejoin=real_join or function() error("presence-only analysis") end
        debug.setupvalue=real_set;jit=saved.jit
        local initialized=SOURCE:gsub("state=4","state=999")
        model=f.remaining(initialized)
        check(has(model,"initializer","local:state"),"initializer not disguised as coverage")
        eq(model.complete,false,"state initialization retained")
        for _,bytes in ipairs({SOURCE:gsub("flag=false","flag=nil"),
            (SOURCE:gsub("local alias=helper","local alias=idle"))}) do
            model=f.remaining(bytes)
            eq(model.complete,false,"nil/false/alias initialization retained")
            check(has(model,"initializer"),"specific initializer reason")
        end
        for _,bytes in ipairs({SOURCE:gsub("'B',1,2,3,100","'Renamed',1,2,3,100"),
            SOURCE:gsub("'B',1,2,3,100","'B',1,2,3,200"),
            SOURCE:gsub("boss.move.New%(0,0,1%)","boss.move.New(1,0,1)"),
            SOURCE:gsub("_editor_class%['L'%].cards={}","_tmp_sc.perform=true\n_editor_class['L'].cards={}"),
            SOURCE .. "\ntable.insert(_sc_table,{'K','A',_tmp_sc,#_editor_class['K'].cards,false})"}) do
            model=f.remaining(bytes)
            eq(model.complete,false,"metadata/list/registration not ACKed by safe mappings")
            local row=has(model,"structure")
            check(row,"specific retained structure reason")
            check(row and (row.first or row.previous_first),"structure byte position")
        end
        -- Current's permissive path still cannot declare unknown top-level edits
        -- complete. File Apply's stronger preflight may refuse them even earlier.
        for _,suffix in ipairs({"\nREMAINDER_EFFECT()","\nGLOBAL_REMAINDER=1",
            "\n_editor_class['N']=Class(boss)"}) do
            model=f.remaining(SOURCE .. suffix,"current")
            eq(model.complete,false,"unknown top-level change retained")
            check(has(model,"unknown"),"unknown byte remainder visible")
            eq(f.effects,1,"unknown call never executed")
        end
        local extra=table.concat({"_tmp_sc=boss.card.New('Extra',1,2,3,100)",
            "function _tmp_sc:init(n) return helper(n)+500 end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
        local expanded=SOURCE:gsub("_editor_class%['L'%].cards={}",extra .. "\n_editor_class['L'].cards={}")
        model=f.remaining(expanded)
        eq(model.complete,false,"new card has no publication history")
        check(has(model,"identity","card:K:4"),"new card explicit source identity reason")
        check(has(model,"structure"),"new wiring not swallowed")
        local start=assert(SOURCE:find("_editor_class['K'].cards",1,true))
        model=f.remaining(SOURCE:sub(1,start-1) .. SIDE)
        eq(model.complete,false,"absent owners retained")
        check(has(model,"identity",KA),"absent owner reason")
        -- An orphan source callback is NOT a loaded live definition. Removing
        -- or changing it cannot vanish behind a blanket _tmp_sc/function mask.
        local orphan=SOURCE .. "\n_tmp_sc=boss.card.New('Orphan',1,2,3,100)\nfunction _tmp_sc:init() return 77 end"
        local g=fixture(orphan)
        model=g.remaining(orphan:gsub("return 77 end","return 88 end"),"current")
        eq(model.complete,false,"unowned callback remains unknown remainder")
        check(has(model,"unknown"),"orphan literal not claimed")
        eq(g.constructs,4,"orphan candidate never constructed")
        local value,err=Cards.Compare(base,(SOURCE:gsub("local empty","local empty=0")))
        eq(value,nil,"declaration-kind change refused before coverage")
        eq(err.code,"unsupported","fixed declaration-kind refusal")
        value,err=Cards.Remaining({})
        eq(value,nil,"non-report refused");eq(err.code,"unsupported","invalid input code")
        value,err=Cards.Remaining(must(Cards.SelectFile(f.report(SOURCE))))
        eq(value,nil,"selection never a receipt or remainder baseline")
        local partition=f.report(SOURCE)
        partition.discovery.analysis.statements[1].tok.first=2
        value,err=Cards.Remaining(partition)
        eq(value,nil,"token partition gap never counts as complete")
        if real_join then
            f=fixture();base=f.capture.snapshot
            local receipt,selection=f.commit(edited,"current")
            eq(receipt.changed,true,"real current transaction")
            model=f.remaining(edited)
            eq(model.complete,false,"partial current leaves sibling")
            eq(has(model,"function","local:helper"),nil,"actual helper publication covered")
            check(has(model,"callback",KB .. ":init"),"unpublished sibling not ACKed")
            local first=f.capture.snapshot
            receipt=f.commit(edited)
            eq(receipt.changed,true,"file publishes remaining sibling")
            model=f.remaining(edited)
            eq(model.complete,true,"all actual definitions published")
            eq(#model.pending,0,"no residual token change")
            eq(model.revision,2,"uses actual aggregate revision")
            eq(f.remaining(edited,"current").complete,true,"current consumes same actual remainder model")
            eq(f.capture.snapshot.loaded_source,SOURCE,"no rewriting loaded structure")
            eq(base.revision,0,"no changing first ledger")
            eq(first.units[KB].definition_version,1,"old pending wrapper history retained")
            receipt=f.commit(edited)
            eq(receipt.changed,false,"no-op receipt not a fake new revision")
            eq(f.remaining(edited).complete,true,"no-op coverage stays complete")
            f.commit(SOURCE)
            eq(f.remaining(SOURCE).complete,true,"revert definitions can complete at original bytes")
            eq(f.remaining(edited).complete,false,"old completed bytes differ from later publications")
            f.commit(edited)
            eq(f.remaining(edited).complete,true,"second forward publication uses current ledger")
            -- Deleted/added OPTIONAL callbacks are supported definition changes,
            -- not structural changes. Compare against actual saved defaults.
            local deleted=edited:gsub("_tmp_sc.frame=function%(self%) return flag,empty end\n","")
            eq(f.remaining(deleted).complete,false,"optional deletion pending before commit")
            f.commit(deleted)
            eq(f.remaining(deleted).complete,true,"optional deletion covered after commit")
            local added=deleted:gsub("table.insert","function _tmp_sc:render() return flag,empty end\ntable.insert",1)
            f.commit(added)
            eq(f.remaining(added).complete,true,"new optional callback covered")
            eq(Anchor.Get(f.entry,"state"),4,"state still original value")
            f.commit(added:gsub("state=4","state=900"))
            model=f.remaining(added:gsub("state=4","state=900"))
            eq(model.complete,false,"successful definitions do not ACK state initializer")
            check(has(model,"initializer","local:state"),"postcommit initializer reason retained")
            local renamed=added:gsub("'B',1,2,3,100","'Renamed',1,2,3,100")
                :gsub("state%+n%+1 end","state+n+2 end")
            f.commit(renamed)
            model=f.remaining(renamed)
            eq(model.complete,false,"safe helper publication never ACKs a rename")
            check(has(model,"structure"),"rename still has precise retained bytes")
            eq(f.live.classes.K.cards[3].name,"B","live name not changed")
            f=fixture()
            local unknown=edited .. "\nREMAINDER_EFFECT()"
            f.commit(unknown,"current")
            model=f.remaining(unknown,"current")
            eq(model.complete,false,"successful current still keeps unknown residual")
            check(has(model,"unknown"),"postcommit unknown reason retained")
            eq(f.effects,1,"postcommit extra initializer not executed")
            f=fixture();f.commit(expanded)
            eq(f.remaining(expanded).complete,false,"published safe roots do not ACK new card")
            eq(f.constructs,3,"live list unchanged")
            -- A proposed Next baseline cannot pass a fresh live comparison.
            f=fixture();selection=must(Cards.SelectFile(f.report(edited)))
            local proposed=must(Cards.Next(selection))
            value,err=Cards.Compare(proposed,edited)
            eq(value,nil,"uninstalled Next never genuine publications")
            eq(err.code,"stale","uninstalled Next refusal")
            -- Real rollback preserves the old ledger and pending remainder.
            local expected=f.capture.snapshot
            debug.setupvalue=function(fn,index,v)
                local name=real_set(fn,index,v)
                if fn==f.entry.anchor and v~=expected.functions.units.helper.fn then error("throw after write") end
                return name
            end
            local ran,failed_receipt=f.controller:Run(function(token)
                return f.controller:Commit(token,selection,f.capture,f.live)
            end)
            eq(ran,true,"fault scope ran");eq(failed_receipt,nil,"failed commit has no receipt")
            debug.setupvalue=real_set
            eq(f.capture.snapshot,expected,"rollback keeps actual ledger")
            eq(f.remaining(edited).complete,false,"failed transaction never completes definitions")
            eq(f.effects,1,"failed candidate never initialized")
            local before=f.capture.snapshot
            value,err=Cards.Compare(before,edited .. "\nlocal extra=0")
            eq(value,nil,"preparation declaration failure produces no coverage")
            eq(f.capture.snapshot,before,"preparation failure keeps actual baseline")
        else
            print("CardRemainderSpec: real shared commits unrun (Lua5.1 missing join)")
        end
    end)
    debug.upvaluejoin,debug.setupvalue=real_join,real_set
    for _,controller in ipairs(controllers) do controller:Release() end
    for _,name in ipairs(globals) do rawset(_G,name,saved[name]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected error: " .. tostring(problem) end
    print(string.format("CardRemainderSpec: %d passed / %d failed",passed,failed))
    for _,why in ipairs(failures) do print("  FAIL " .. why) end
    return {passed=passed,failed=failed}
end
return M
