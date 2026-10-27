local Planning=require("SpellHotReload.tests.PlanningFixture")
-- Complete all-owner remainder against actual publication, not removal authority.
-- Genuine miniature first loads only; candidates never execute. Intended for LuaJIT.
local M = {}
function M.run()
    local Cards = require("SpellHotReload.Adapters.Card.CardVersions")
    local FileApply = require("SpellHotReload.Apply.FileApply")
    local Card = require("SpellHotReload.Adapters.Card.Card")
    local Local = require("SpellHotReload.Adapters.Local.Local")
    local Definitions = require("SpellHotReload.Adapters.Local.LocalDefinitions")
    local Files = require("SpellHotReload.Pipeline.FileVersions")
    local Source = require("SpellHotReload.Source.FileAnalysis")
    local Guard = require("SpellHotReload.Apply.CommitCheck")
    local Compose = require("SpellHotReload.Source.Compose")
    local Load = require("SpellHotReload.Load.AnchorLoad")
    local Commit = require("SpellHotReload.Apply.FileCommit")
    local Anchor = require("SpellHotReload.Load.Anchor")
    local passed, failed, failures = 0, 0, {}
    local function check(v, label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(rawequal(a,b),label) end
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
    local function piece(prepared,owner)
        for _,record in ipairs(prepared.entries) do if record.owner==owner then return record.fragment end end
        error("missing real owner fragment")
    end
    local function fixture(source)
        source=source or SOURCE
        serial=serial+1
        debug.setupvalue,debug.upvaluejoin=real_set,real_join;jit=saved.jit
        local f={effects=0,constructs=0,bytes=source,transactions=0}
        REMAINDER_EFFECT=function() f.effects=f.effects+1 end
        _editor_class={K={},L={}};_sc_table={}
        f.classes=_editor_class
        boss={card={_default_card=defaults,New=function(label)
            f.constructs=f.constructs+1
            local c={name=label,is_combat=true}
            for _,name in ipairs(callbacks) do c[name]=defaults[name] end
            return c
        end},move={New=function() return {is_combat=false} end}}
        f.entry=must(Load.Capture(source,{name="Remainder_Boss.lua"}))
        must(f.entry.reloadable,f.entry.reason);f.entry.file="Remainder_Boss.lua"
        f.planning=must(Planning.Capture(f.entry,"remainder:"..serial,f.classes,defaults))
        f.capture=f.planning.capture;f.driver=f.planning.driver
        f.controller=must(Commit.New(f.capture.snapshot.session_id));controllers[#controllers+1]=f.controller
        f.live={capture=f.capture,entry=f.entry,classes=f.classes,session_id=f.capture.snapshot.session_id,generation=7}
        function f.refresh() return f.live end
        f.planning.refresh=f.refresh
        function f.facts(bytes)
            f.bytes=bytes;f.live.snapshot=f.capture.snapshot;f.live.content=bytes
            local list=f.classes.K.cards;local names={}
            for i,c in ipairs(list) do names[i]=c.name or "" end
            f.live.binding={class_key="K",slot=2,card=list[2],name=list[2].name,names=names,
                mode="practice",include_previous=false}
            return must(Source.Build(bytes))
        end
        function f.discovery(bytes)
            return must(Planning.Discover(f.planning,f.facts(bytes),7))
        end
        -- Diagnostic report: every actual owner, empty roots, no file preflight.
        -- Unknown residuals must be observable rather than rejected as File Apply.
        function f.report(bytes)
            local discovery=f.discovery(bytes)
            local op=must(Planning.Operation(f.planning,discovery,{mode="file",root_ids={},refresh=f.refresh}))
            local prepared=must(f.driver:PrepareDiscovery(discovery,op))
            return must(FileApply.Collect(prepared))
        end
        function f.remaining(bytes)
            return must(Planning.Remaining(f.planning,f.facts(bytes),7,f.refresh))
        end
        function f.prepare(bytes,mode)
            local discovery=f.discovery(bytes)
            return Planning.Prepare(f.planning,discovery,{mode=mode or "file",refresh=f.refresh})
        end
        function f.publish(prepared)
            return Planning.Publish(f.planning,prepared,f.controller)
        end
        local kernel=f.controller.Commit
        f.controller.Commit=function(self,...)
            f.transactions=f.transactions+1;return kernel(self,...)
        end
        function f.commit(bytes,mode)
            local prepared=must(f.prepare(bytes,mode))
            check(#prepared.dependencies.safe_roots>0,"publication has genuine safe roots")
            local receipt=must(f.publish(prepared))
            eq(receipt.kind,"SpellHotReload.FileCommit.Receipt","real common receipt")
            eq(receipt.snapshot,f.capture.snapshot,"common receipt actual snapshot")
            return receipt,prepared
        end
        return f
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug)))
        -- Optional statement separators do not change the statement content signature.
        -- Verify both directions through real first-load/file evidence.
        for _,edit in ipairs({{"REMAINDER_EFFECT%(%)","REMAINDER_EFFECT();"},
            {"local state=4","local state=4;"}}) do
            local formatted,count=SOURCE:gsub(edit[1],edit[2])
            eq(count,1,"one formatting edit")
            for _,pair in ipairs({{SOURCE,formatted},{formatted,SOURCE}}) do
                local probe=fixture(pair[1])
                local snapshot=probe.capture.snapshot
                local effects,constructs=probe.effects,probe.constructs
                for attempt=1,2 do
                    local remaining=probe.remaining(pair[2])
                    eq(remaining.complete,true,"separator-only candidate complete")
                    eq(#remaining.pending,0,"separator-only candidate has no pending")
                    eq(probe.capture.snapshot,snapshot,"formatting does not advance publications")
                    eq(probe.effects,effects,"formatting does not replay top-level call")
                    eq(probe.constructs,constructs,"formatting does not reconstruct cards")
                end
            end
        end
        local f=fixture()
        local base=f.capture.snapshot
        eq(Cards.Remaining,nil,"Card versions no longer own full-file accounting")
        eq(Card.InspectFileRemainder,nil,"Card adapter no longer owns completion workflow")
        local unknown=SOURCE.."\nGLOBAL_REMAINDER=1"
        local own_report=f.report(unknown)
        local own_prepared=own_report.prepared
        check(piece(own_prepared,Card).card_runtime.version_view.by_key[KA]~=nil,
            "Card analysis supplies own evidence despite unrelated edit")
        local accepted,reason=FileApply.CheckTopLevel(own_report)
        eq(accepted,nil,"file layer independently rejects unbounded edit")
        check(reason and reason.message:find("unbounded top-level change",1,true),"file layer owns refusal")
        local own_model=must(FileApply.Remaining(own_report))
        check(has(own_model,"unknown"),"file layer owns unknown remainder")
        eq(own_model.complete,false,"unknown edit never counts as complete")
        local card_fragment=piece(own_prepared,Card)
        local evidence=must(Cards.Coverage(card_fragment.card_runtime.version_view,card_fragment.card_plan))
        eq(evidence.complete,nil,"adapter evidence never declares file complete")
        check(evidence.before and evidence.after,"adapter exports proven statement coverage")
        local inserted=must(FileApply.Remaining(f.report(SOURCE:gsub("REMAINDER_EFFECT%(%)", "NEW_UNKNOWN()\nREMAINDER_EFFECT()",1))))
        local new_unknown=0
        for _,row in ipairs(inserted.pending) do
            if row.kind=="unknown" then new_unknown=new_unknown+1 end
        end
        eq(new_unknown,1,"one inserted unknown statement has no positional cascade")
        eq(inserted.complete,false,"source insertion never swallowed")
        local model=f.remaining(SOURCE)
        eq(model.complete,true,"unchanged complete source")
        eq(#model.pending,0,"all statement content accounted")
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
        eq(f.remaining(formatted).complete,false,"changed initializer/body span remains pending despite equivalent runtime meaning")
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
        eq(Anchor.Get(f.entry,"helper"),base.owners[1].state.by_name.helper.fn,"analysis leaves cell")
        eq(joins,0,"no joins");eq(writes,0,"no writes");eq(flushes,0,"no flush")
        eq(f.effects,1,"no candidate initialization");eq(f.constructs,3,"no registration replay")
        debug.upvaluejoin=real_join
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
        -- Whole-file accounting after Current still retains unknown edits.
        -- File Apply's stronger publication preflight rejects them earlier.
        for _,suffix in ipairs({"\nREMAINDER_EFFECT()","\nGLOBAL_REMAINDER=1",
            "\n_editor_class['N']=Class(boss)"}) do
            model=f.remaining(SOURCE .. suffix)
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
        model=g.remaining(orphan:gsub("return 77 end","return 88 end"))
        eq(model.complete,false,"unowned callback remains unknown remainder")
        check(has(model,"unknown"),"orphan literal not claimed")
        eq(g.constructs,4,"orphan candidate never constructed")
        -- Local owns support refusal. Public accounting can still describe a
        -- blocked source; it must not pretend that such a plan publishes edits.
        f=fixture();base=f.capture.snapshot
        local kind_change=SOURCE:gsub("local empty","local empty=0")
        local value,err=Definitions.Pair(must(Definitions.Match(f.entry.source)),
            must(Definitions.Match(must(Source.Build(kind_change)))))
        eq(value,nil,"declaration-kind change refused by Local")
        eq(err.phase,"inject","declaration-kind owner phase")
        eq(err.code,"unsupported","fixed declaration-kind refusal")
        check(err.message:find("declaration kind changed",1,true),"precise declaration-kind reason")
        local kd=f.discovery(kind_change)
        local blocked=must(Planning.Prepare(f.planning,kd,
            {mode="file",root_ids={"local:helper"},refresh=f.refresh}))
        eq(#blocked.dependencies.safe_roots,0,"unsupported Local root cannot publish")
        eq(#blocked.dependencies.blocked_roots,1,"exact requested root blocked")
        eq(blocked.dependencies.blocked_roots[1].root_id,"local:helper","blocked original root")
        eq(blocked.dependencies.blocked_roots[1].reason.code,"unsupported","root carries support refusal")
        for _,record in ipairs(blocked.entries) do
            local fragment=record.fragment
            eq(#fragment.joins+#fragment.cell_writes+#fragment.raw_writes,0,"blocked plan has no actions")
            eq(fragment.proposed_group,fragment.base_group,"blocked plan retains actual owner")
        end
        eq(f.remaining(kind_change).complete,false,"kind change remains visible in accounting")
        eq(f.capture.snapshot,base,"support refusal keeps actual snapshot")
        eq(f.transactions,0,"support refusal never published")
        value,err=FileApply.Remaining({})
        eq(value,nil,"non-report refused");eq(err.phase,"analyze","invalid input phase")
        eq(err.code,"stale","invalid actual report code")
        local selection_report=f.report(SOURCE)
        value,err=FileApply.Remaining(selection_report.prepared.entries[2].context.selection)
        eq(value,nil,"selection never a receipt or remainder baseline")
        eq(err.code,"stale","selection cannot be accounting evidence")
        local partition=f.report(SOURCE)
        partition.coverage.after.scan.analysis.statements={}
        value,err=FileApply.Remaining(partition)
        eq(value,nil,"replaced source sequence cannot count as complete")
        eq(err.code,"stale","source provenance diagnostic")
        f=fixture();base=f.capture.snapshot
        local receipt,prepared=f.commit(edited,"current")
        eq(#prepared.dependencies.safe_roots,1,"Current exact root safe")
        eq(#prepared.dependencies.blocked_roots,0,"Current not silently blocked")
        eq(#piece(prepared,Local).cell_writes,1,"Current truly prepares helper cell")
        eq(#piece(prepared,Card).raw_writes,0,"Current retains unchanged A wrapper")
        eq(f.classes.K.cards[2]:init(1),6,"A reads published helper")
        eq(f.classes.K.cards[3]:init(1),16,"B reads shared helper with old body")
        eq(receipt.changed,true,"real current transaction")
        model=f.remaining(edited)
        eq(model.complete,false,"partial current leaves sibling")
        eq(has(model,"function","local:helper"),nil,"actual helper publication covered")
        check(has(model,"callback",KB .. ":init"),"unpublished sibling not ACKed")
        local first=f.capture.snapshot
        receipt,prepared=f.commit(edited)
        eq(#piece(prepared,Local).cell_writes,0,"file keeps already published helper")
        eq(#piece(prepared,Card).raw_writes,1,"file really prepares remaining B callback")
        eq(f.classes.K.cards[3]:init(1),26,"B reads its new callback and shared helper")
        eq(receipt.changed,true,"file publishes remaining sibling")
        model=f.remaining(edited)
        eq(model.complete,true,"all actual definitions published")
        eq(#model.pending,0,"no residual token change")
        eq(model.revision,2,"uses actual aggregate revision")
        eq(f.remaining(edited).complete,true,"post-Current accounting consumes actual remainder model")
        eq(f.capture.snapshot.loaded_source,SOURCE,"no rewriting loaded structure")
        eq(base.revision,0,"no changing first ledger")
        eq(first.owners[2].state.units[KB].definition_version,1,"old pending wrapper history retained")
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
        local retained=added:gsub("state=4","state=900"):gsub("state%+n%+1 end","state+n+2 end")
        receipt,prepared=f.commit(retained)
        eq(receipt.changed,true,"real helper publication with retained initializer")
        eq(#piece(prepared,Local).cell_writes,1,"retained initializer case writes helper only")
        eq(Anchor.Get(f.entry,"helper")(1),7,"new helper actually installed with retained state")
        model=f.remaining(retained)
        eq(model.complete,false,"successful definitions do not ACK state initializer")
        check(has(model,"initializer","local:state"),"postcommit initializer reason retained")
        local renamed=retained:gsub("'B',1,2,3,100","'Renamed',1,2,3,100")
            :gsub("state%+n%+2 end","state+n+3 end")
        receipt,prepared=f.commit(renamed)
        eq(receipt.changed,true,"rename case also publishes a genuine helper change")
        eq(#piece(prepared,Local).cell_writes,1,"rename does not suppress independent helper update")
        eq(Anchor.Get(f.entry,"helper")(1),8,"rename helper actually installed")
        model=f.remaining(renamed)
        eq(model.complete,false,"safe helper publication never ACKs a rename")
        check(has(model,"structure"),"rename still has precise retained bytes")
        eq(f.live.classes.K.cards[3].name,"B","live name not changed")
        f=fixture()
        local unknown=edited .. "\nREMAINDER_EFFECT()"
        f.commit(unknown,"current")
        model=f.remaining(unknown)
        eq(model.complete,false,"successful current still keeps unknown residual")
        check(has(model,"unknown"),"postcommit unknown reason retained")
        eq(f.effects,1,"postcommit extra initializer not executed")
        f=fixture()
        local expanded_update=expanded:gsub("state%+n end","state+n+1 end")
        receipt,prepared=f.commit(expanded_update)
        eq(receipt.changed,true,"new-card remainder accompanies real helper publication")
        eq(#piece(prepared,Local).cell_writes,1,"new-card case prepares actual helper write")
        eq(Anchor.Get(f.entry,"helper")(1),6,"new-card case helper installed")
        eq(f.remaining(expanded_update).complete,false,"published safe roots do not ACK new card")
        eq(f.constructs,3,"live list unchanged")
        -- A proposed snapshot never becomes an actual accounting baseline.
        f=fixture();base=f.capture.snapshot
        prepared=must(f.prepare(edited))
        local all={};for _,record in ipairs(prepared.entries) do all[#all+1]=record.fragment end
        local sealed=must(Guard.Seal(prepared.operation,all))
        local proposed=sealed.proposed_snapshot
        check(proposed~=base,"genuine proposed snapshot differs from actual")
        eq(f.capture.snapshot,base,"Seal does not install proposed snapshot")
        local actual_report=f.report(edited)
        local impostor={};for key,item in next,actual_report do impostor[key]=item end
        impostor.base=proposed
        value,err=FileApply.Remaining(impostor)
        eq(value,nil,"uninstalled snapshot is not actual remainder baseline")
        eq(err.phase,"analyze","uninstalled baseline accounting phase")
        eq(err.code,"stale","uninstalled baseline refusal")
        local op={};for key,item in next,prepared.operation do op[key]=item end
        op.base_snapshot=proposed;op.file_proof=nil
        value,err=f.driver:PrepareDiscovery(prepared.discovery,op)
        eq(value,nil,"uninstalled snapshot cannot prepare as actual publication")
        eq(err.phase,"locate","uninstalled operation phase")
        eq(err.code,"ownership","uninstalled operation diagnostic")
        eq(f.remaining(edited).complete,false,"actual pending definitions survive Seal")
        -- Real rollback restores the helper after a setter mutates then throws.
        prepared=must(f.prepare(edited));local expected=f.capture.snapshot
        local old_helper=expected.owners[1].state.by_name.helper.fn
        local old_a,old_b=f.classes.K.cards[2].init,f.classes.K.cards[3].init
        eq(#piece(prepared,Local).cell_writes,1,"failure case has real helper write")
        eq(#piece(prepared,Card).raw_writes,1,"failure case has real B publication")
        local throws=0
        debug.setupvalue=function(fn,index,v)
            local name=real_set(fn,index,v)
            if fn==f.entry.anchor and v~=old_helper then throws=throws+1;error("throw after write") end
            return name
        end
        local before_calls=f.transactions
        local failed_receipt,failed_error=f.publish(prepared)
        debug.setupvalue=real_set
        eq(f.transactions,before_calls+1,"fault reached one actual kernel")
        eq(throws,1,"failure really occurred after helper write")
        eq(failed_receipt,nil,"failed commit has no receipt")
        eq(failed_error.phase,"commit","rollback failure phase")
        eq(failed_error.code,"publish","live writes restored diagnostic")
        eq(f.controller:Poisoned(),false,"successful rollback not poison")
        eq(f.capture.snapshot,expected,"rollback keeps actual snapshot")
        eq(Anchor.Get(f.entry,"helper"),old_helper,"rollback restores helper cell")
        eq(f.classes.K.cards[2].init,old_a,"rollback keeps A raw callback")
        eq(f.classes.K.cards[3].init,old_b,"rollback keeps B raw callback")
        model=f.remaining(edited)
        eq(model.complete,false,"failed transaction never completes definitions")
        check(has(model,"function","local:helper"),"failed helper still pending")
        check(has(model,"callback",KB..":init"),"failed B still pending")
        eq(f.effects,1,"failed candidate never initialized")
        local before=f.capture.snapshot
        local extra_local=edited.."\nlocal extra=0"
        value,err=Definitions.Pair(must(Definitions.Match(f.entry.source)),
            must(Definitions.Match(must(Source.Build(extra_local)))))
        eq(value,nil,"declaration-set change refused by Local")
        eq(err.code,"unsupported","declaration-set refusal diagnostic")
        check(err.message:find("top-level declaration order/set changed",1,true),"declaration-set reason")
        eq(f.remaining(extra_local).complete,false,"unsupported declaration set remains pending")
        -- A real File preflight failure returns no prepared evidence for publish.
        before_calls=f.transactions
        value,err=f.prepare(edited.."\nUNREPLAYED_UNKNOWN()")
        eq(value,nil,"unbounded File preparation produces no publishable plan")
        eq(err.phase,"analyze","file preparation failure phase")
        eq(err.code,"unsupported","file preparation failure code")
        eq(f.transactions,before_calls,"failed preparation never enters kernel")
        eq(f.capture.snapshot,before,"preparation failure keeps actual baseline")
        eq(f.effects,1,"no failed candidate source execution")
    end)
    debug.upvaluejoin,debug.setupvalue=real_join,real_set
    for _,controller in ipairs(controllers) do controller:Release() end
    for _,name in ipairs(globals) do rawset(_G,name,saved[name]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected error: " .. (type(problem)=="string" and problem or "opaque error") end
    print(string.format("CardRemainderSpec: %d passed / %d failed",passed,failed))
    for _,why in ipairs(failures) do print("  FAIL " .. why) end
    return {passed=passed,failed=failed}
end
return M
