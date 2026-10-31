-- Real common Plugin/Driver/FileCommit completion receipts; LuaJIT target.
-- Only miniature first loads execute. No engine/readiness/performance claim.
local M={}
function M.run()
    local passed,failed,failures=0,0,{}
    local function check(v,label)
        if v then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(a==b,label..": "..tostring(a).." ~= "..tostring(b)) end
    local function has(s,p,label) check(type(s)=="string" and s:find(p,1,true),label..": "..tostring(s)) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local Store=require("SpellHotReload.Runtime.SnapshotStore")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Card=require("SpellHotReload.Adapters.Card.Card")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local FILE="Complete_Boss.lua"
    local function stable(store,bytes,update)
        local c=store:BeginCandidate(FILE,update or store._next_generation,"spec")
        must(store:RecordFirstRead(FILE,c.generation,bytes,1))
        return must(store:VerifyStable(FILE,c.generation,bytes,2,1))
    end
    local function store_tests()
        local store=Store.New({hash=function() return "collision" end})
        store:SetAccepted(FILE,"base")
        local entry={};local snapshot={file=FILE,session_id="test",entry=entry,revision=1}
        local capture={snapshot=snapshot}
        local scope={entry=entry,snapshot=snapshot,capture=capture,session_id="test",revision=1}
        local c=stable(store,"edit")
        must(store:RecordPartialPublication(FILE,c.generation,"edit",1))
        eq(store:RecordCompletion(FILE,c.generation+1,"edit",scope),nil,"old generation cannot complete")
        eq(store:RecordCompletion(FILE,c.generation,"wrong",scope),nil,"hash collision cannot complete other bytes")
        eq(store:RecordCompletion(FILE,c.generation,"edit",{}),nil,"scope mandatory")
        check(store:GetCandidate(FILE)~=nil,"bad completion leaves candidate")
        must(store:RecordCompletion(FILE,c.generation,"edit",scope))
        eq(store:GetCandidate(FILE),nil,"exact generation removed")
        eq(store:GetAccepted(FILE).content,"base","completion not accepted bytes")
        eq(store:GetPartialPublication(FILE).revision,1,"sticky partial retained")
        eq(store:IsDismissed(FILE,"edit"),false,"completion not Dismiss")
        check(store:IsCompleted(FILE,"edit",scope),"exact completion")
        scope.revision=999
        eq(store:IsCompleted(FILE,"edit",scope),false,"scope copied, caller mutation not permission")
        scope.revision=1
        eq(store:IsCompleted(FILE,"edit",scope),false,"invalid scope retires record")
        c=stable(store,"edit");must(store:RecordCompletion(FILE,c.generation,"edit",scope))
        eq(store:IsCompleted(FILE,"new",scope),false,"new bytes invalidate")
        eq(store:IsCompleted(FILE,"edit",scope),false,"old completion cannot swallow a return to old bytes")
        c=stable(store,"edit");must(store:RecordCompletion(FILE,c.generation,"edit",scope))
        local newer=store:BeginCandidate(FILE,10,"same-byte export")
        must(store:RecordFirstRead(FILE,newer.generation,"edit",11))
        check(store:IsCompleted(FILE,"edit",scope),"same observed bytes retain completion")
        must(store:RecordFirstRead(FILE,newer.generation,"new bytes",12))
        eq(store:IsCompleted(FILE,"edit",scope),false,"new first-read bytes invalidate even before stable")
        c=stable(store,"edit");must(store:RecordCompletion(FILE,c.generation,"edit",scope))
        store:Clear()
        eq(store:IsCompleted(FILE,"edit",scope),false,"session Clear releases completion")
        eq(store:HasPartialPublication(FILE),false,"Clear releases sticky partial separately")
    end
    local globals={"lstg","boss","_editor_class","_tmp_sc","_sc_table","ext","IsValid","jit","Include"}
    local saved={};for _,name in ipairs(globals) do saved[name]=rawget(_G,name) end
    local modules={"lstg.FileSystemWatcher","lstg.FileSystemWatcher.FileAction","SpellHotReload.Runtime.Watcher","SpellHotReload.Runtime.Plugin"}
    local loaded={};for _,name in ipairs(modules) do loaded[name]=package.loaded[name] end
    local action={added=1,modified=2,removed=3,renamed_old_name=4,renamed_new_name=5}
    package.loaded[modules[1]]={create=function() error("native watcher forbidden") end}
    package.loaded[modules[2]]=action
    package.loaded[modules[3]],package.loaded[modules[4]]=nil,nil
    local Plugin=require("SpellHotReload.Runtime.Plugin")
    local Watcher=require("SpellHotReload.Runtime.Watcher")
    local Load=require("SpellHotReload.Adapters.Class.ClassLoad")
    local ClassFixture=require("SpellHotReload.tests.ClassFixture")
    local environment
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Binding=require("SpellHotReload.Adapters.Card.PracticeBinding")
    local Restart=require("SpellHotReload.Runtime.CurrentRestart")
    local Compose=require("SpellHotReload.Source.Compose")
    local FileApply=require("SpellHotReload.Apply.FileApply")
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local real_join,real_set=debug.upvaluejoin,debug.setupvalue
    local old_restart,old_create,old_account,old_remaining=Restart.Handoff,Compose.Create,FileApply.InspectFileRemainder,FileApply.Remaining
    local old_build,old_witness=Source.Build,FileApply.CheckWitness
    local plugins={}
    local callbacks={"before","init","frame","render","beforedel","del","after"}
    local defaults={};for _,name in ipairs(callbacks) do defaults[name]=function() end end
    local SOURCE=table.concat({"-- Generated by LuaSTG Editor Sharp","local state=4",
        "local function helper(n) return state+n end",
        "_editor_class['K']=Class(boss)",
        "_editor_class['K'].cards={}","_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return helper(n) end","table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)","function _tmp_sc:init(n) return helper(n)+100 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)"},"\n")
    local EDIT=SOURCE:gsub("state%+n end","state+n+10 end"):gsub("helper%(n%)%+100","helper(n)+200")
    local function candidate(f,bytes) f.disk=bytes;return stable(f.p:GetStore(),bytes) end
    local function card_group(f) return must(Files.Owner(f.capture,Card)) end
    local function local_group(f) return must(Files.Owner(f.capture,Local)) end
    local function versions(f,helper_version,a_version,b_version,label)
        local local_state=local_group(f).state
        local card_state=card_group(f).state
        eq(local_state.by_name.helper.definition_version,helper_version,label.." actual helper version")
        eq(local_state.by_name.state.binding_kind,"state",label.." scalar owned by Local")
        eq(local_state.by_name.state.definition_version,1,label.." scalar definition not advanced")
        eq(card_state.units["card:1:K:1"].definition_version,a_version,label.." actual A version")
        eq(card_state.units["card:1:K:1"].callbacks.init.definition_version,a_version,label.." A init version")
        eq(card_state.units["card:1:K:2"].definition_version,b_version,label.." actual B version")
        eq(card_state.units["card:1:K:2"].callbacks.init.definition_version,b_version,label.." B init version")
    end
    local function fixture(first_source)
        first_source=first_source or SOURCE
        debug.upvaluejoin,debug.setupvalue=real_join,real_set
        _G.jit=saved.jit;FileApply.Remaining=old_remaining;FileApply.InspectFileRemainder=old_account
        Source.Build,FileApply.CheckWitness=old_build,old_witness
        if environment then environment:Restore() end
        environment=ClassFixture.Install()
        _editor_class={K={}};_sc_table={}
        local f={disk=first_source,reads=0,creates=0,discoveries=0,restarts=0,constructs=0,includes=0,
            kernels=0,builds=0,witness_checks=0,receipts={},discovered={},events={}}
        _G.Include=function() f.includes=f.includes+1 end
        _G.IsValid=function() return true end
        lstg={var={},Log=function() end,FileManager={EnumFiles=function() return {{FILE,false}} end}}
        ext={replay={IsReplay=function() return false end}}
        boss.card={_default_card=defaults,New=function(name)
            f.constructs=f.constructs+1;local c={name=name,is_combat=true}
            for _,cb in ipairs(callbacks) do c[cb]=defaults[cb] end
            return c
        end}
        f.p=Plugin.New();plugins[#plugins+1]=f.p
        f.entry=must(Load.Capture(first_source,{name=FILE}));must(f.p:AdoptLoad(FILE,f.entry))
        environment:FinishLoad()
        f.capture=must(f.p:GetVersions(FILE));f.classes=_editor_class
        must(Files.Validate(f.capture));eq(#f.capture.snapshot.owners,3,"genuine complete owner capture")
        f.p._activated,f.p._supported,f.p._sandbox_ok=true,true,true
        f.p._activation_attempted=true
        f.p:GetStore():SetAccepted(FILE,first_source,"baseline")
        f.p._watcher=Watcher.New({root="mod/Test",store=f.p:GetStore(),known_files={FILE},
            quiet_frames=1,read_gap=1,drift_interval=100000,max_read_failures=1,
            is_completed=function(file,bytes) return f.p:_IsCompleted(file,bytes) end,
            on_missing=function(file,why) f.p:Missing(file,why) end})
        f.p._watcher.ReadFile=function()
            f.reads=f.reads+1;if f.on_read then f.on_read() end
            if f.disk==nil then return nil,"missing",2 end
            return f.disk
        end
        f.p._watcher._fs={close=function() end,read=function(_,info)
            local event=table.remove(f.events,1);if not event then return false end
            info.file_name,info.action=FILE,event;return true
        end}
        Source.Build=function(...) f.builds=f.builds+1;return old_build(...) end
        FileApply.CheckWitness=function(...) f.witness_checks=f.witness_checks+1;return old_witness(...) end
        local discover=f.p._driver.Discover
        f.p._driver.Discover=function(self,...)
            f.discoveries=f.discoveries+1;return discover(self,...)
        end
        local discover_versioned=f.p._DiscoverVersioned
        f.p._DiscoverVersioned=function(self,file,candidate,capture,source)
            local base=capture.snapshot
            local d,e=discover_versioned(self,file,candidate,capture,source)
            if d then f.discovered[#f.discovered+1]={discovery=d,source=source,snapshot=base} end
            return d,e
        end
        local kernel=f.p._commit.Commit
        f.p._commit.Commit=function(self,token,operation,fragments,...)
            f.kernels=f.kernels+1
            local base=operation.capture.snapshot
            local receipt,e=kernel(self,token,operation,fragments,...)
            if receipt then
                f.receipts[#f.receipts+1]={receipt=receipt,base=base,source=operation.source,fragments=fragments}
            end
            return receipt,e
        end
        Compose.Create=function(...)
            f.creates=f.creates+1;if f.on_create then f.on_create() end
            return old_create(...)
        end
        Restart.Handoff=function()
            f.restarts=f.restarts+1;if f.restart_fault then error("restart fault") end
        end
        _sc_table[1]={"K","A",f.classes.K.cards[1],1,false};lstg.var.sc_index=1
        return f
    end
    local function scan(f,path)
        if path=="event" then f.events[#f.events+1]=action.modified
        elseif path=="drift" then f.p._watcher:_drift_scan()
        else f.p:Rescan() end
        for _=1,6 do f.p:Tick() end
    end
    -- Read-only evidence is required even for an actual no-op receipt. This
    -- observer does not manufacture receipts, witnesses or permission to remove.
    local function complete_evidence(f,label)
        local r=must(f.receipts[#f.receipts],"real receipt required")
        local receipt=r.receipt
        eq(receipt.kind,"SpellHotReload.FileCommit.Receipt",label.." common receipt kind")
        eq(receipt.version,1,label.." common receipt version")
        eq(receipt.snapshot,f.capture.snapshot,label.." actual receipt snapshot")
        eq(receipt.changed,receipt.snapshot~=r.base,label.." actual changed flag")
        eq(#receipt.owner_deltas,3,label.." both owner deltas")
        local last=must(f.discovered[#f.discovered],"post-publication discovery required")
        eq(last.snapshot,receipt.snapshot,label.." new discovery against installed snapshot")
        eq(last.source,r.source,label.." same complete analysis reused")
        check(#f.discovered>=2,label.." pre-commit and new post-commit discovery")
        local record=must(f.p._completion_checks[FILE],"completion witness required")
        local witness=record.witness
        eq(witness.kind,"SpellHotReload.FileApply.Witness",label.." actual witness")
        eq(witness.snapshot,receipt.snapshot,label.." witness actual snapshot")
        eq(witness.report.operation.source,r.source,label.." witness same complete source")
        eq(witness.report.prepared.discovery,last.discovery,label.." witness new discovery")
        eq(#witness.report.operation.roots,0,label.." accounting has empty publication roots")
        eq(#witness.report.prepared.entries,3,label.." all original owners checked")
        eq(#witness.report.owner_evidence,3,label.." complete owner coverage")
        eq(witness.plan.proposed_snapshot,witness.plan.base_snapshot,label.." no invented snapshot")
        eq(#witness.plan.joins+#witness.plan.journal,0,label.." no mechanical publication actions")
        for _,row in ipairs(witness.report.prepared.entries) do
            local fragment=row.fragment
            eq(#fragment.joins+#fragment.cell_writes+#fragment.raw_writes,0,label.." no owner writes")
            eq(fragment.proposed_group,fragment.base_group,label.." owner actual group retained")
        end
        eq(f.p:GetStore():GetCandidate(FILE),nil,label.." stable candidate removed")
    end
    local function quiet(f,label)
        complete_evidence(f,label)
        local creates,discoveries,builds,rev=f.creates,f.discoveries,f.builds,f.capture.snapshot.revision
        for _,path in ipairs({"event","drift","rescan"}) do
            local checked=f.witness_checks
            scan(f,path);eq(f.p:GetStore():GetCandidate(FILE),nil,label.." "..path.." no resurrection")
            check(f.witness_checks>checked,label.." "..path.." rechecks actual witness")
        end
        eq(f.creates,creates,label.." watcher no compilation")
        eq(f.discoveries,discoveries,label.." watcher no discovery")
        eq(f.builds,builds,label.." watcher no full analysis")
        eq(f.capture.snapshot.revision,rev,label.." watcher no publication")
    end
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug)))
        store_tests()
        local f=fixture();candidate(f,EDIT)
        has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","actual file Apply completes")
        eq(f.capture.snapshot.revision,1,"one commit revision")
        versions(f,2,1,2,"first common publication");eq(f.kernels,1,"one common kernel")
        eq(f.classes.K.cards[2]:init(1),215,"new wrapper and shared helper active")
        eq(f.restarts,0,"file action no restart")
        eq(f.constructs,2,"no registration replay")
        eq(f.p:GetStore():GetAccepted(FILE).content,SOURCE,"completion no whole file ACK")
        eq(f.p:GetStore():GetPartialPublication(FILE).revision,1,"completion retains partial ledger")
        eq(f.p:GetStore():IsDismissed(FILE,EDIT),false,"completion never Dismiss")
        quiet(f,"first complete")
        candidate(f,EDIT:gsub("state%+n%+10","state+n+20"))
        has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","second file Apply completes")
        eq(f.capture.snapshot.revision,2,"second actual publication")
        versions(f,3,1,2,"second helper publication")
        quiet(f,"second complete")
        candidate(f,SOURCE)
        has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","original bytes undo actual definitions")
        eq(f.capture.snapshot.revision,3,"source revert really publishes")
        versions(f,4,1,3,"actual source revert")
        eq(f.classes.K.cards[2]:init(1),105,"source revert active")
        quiet(f,"source revert")
        -- No-op receipt can confirm pure formatting; zero actions alone cannot.
        f=fixture();candidate(f,SOURCE.."\n-- only formatting")
        has(f.p:ApplyFileFromUI(FILE),"no definition changes","semantic no-op")
        eq(f.capture.snapshot.revision,0,"no-op does not invent revision")
        eq(f.p:GetStore():HasPartialPublication(FILE),false,"no-op has no partial publication")
        eq(f.p:GetStore():GetCandidate(FILE),nil,"checked semantic no-op complete")
        quiet(f,"no-op")
        -- Include edits are outside Card reload, not executed publications.
        -- Addition/removal/path changes, both call forms, long strings and
        -- middle-of-file calls share the same safety/completion rule.
        local include_edits={
            {before="",after="\nInclude 'new.lua'"},
            {before="\nInclude 'old.lua'",after=""},
            {before="\nInclude 'old.lua'",after="\nInclude('new.lua');"},
            {before="\nInclude [[old.lua]]",after="\nInclude [=[new.lua]=]"},
            {before="Include 'old.lua'\n",after="Include('new.lua')\n",middle=true},
        }
        local function with_include(bytes,change,side)
            if change.middle then
                return (bytes:gsub("local function helper",change[side].."local function helper",1))
            end
            return bytes..change[side]
        end
        for i,change in ipairs(include_edits) do
            local first=with_include(SOURCE,change,"before")
            local expected=change.before=="" and 0 or 1
            f=fixture(first);candidate(f,with_include(SOURCE,change,"after"))
            has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","Include-only "..i)
            eq(f.capture.snapshot.revision,0,"Include-only no publication version "..i)
            eq(f.p:GetStore():HasPartialPublication(FILE),false,"Include-only no receipt of publication "..i)
            eq(f.includes,expected,"Include-only never replayed "..i)
            eq(f.constructs,2,"Include-only no card registration "..i)
            eq(f.p:GetStore():GetAccepted(FILE).content,first,"Include-only no whole-file ACK "..i)
            quiet(f,"Include-only "..i)
            f=fixture(first);candidate(f,with_include(EDIT,change,"after"))
            has(f.p:ApplyFromUI(),"candidate retained","Include does not swallow sibling "..i)
            eq(f.classes.K.cards[2]:init(1),115,"sibling wrapper still old "..i)
            eq(f.includes,expected,"Current does not execute Include "..i)
            has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","file finishes alongside Include "..i)
            eq(f.classes.K.cards[2]:init(1),215,"file callback and helper effective "..i)
            eq(f.includes,expected,"file does not execute Include "..i)
            eq(f.constructs,2,"neither action replays registration "..i)
            quiet(f,"Include partial then complete "..i)
        end
        -- Similar spelling is not permission to discard arbitrary effects.
        for _,suffix in ipairs({"\nInclude(helper(1))","\nInclude('x.lua',helper(1))",
            "\nInclude('x.lua')()","\nif true then Include 'x.lua' end",
            "\nInclude 'x.lua'; UNREPLAYED_UNKNOWN()","\nloader.Include('x.lua')"}) do
            f=fixture();local base=f.capture.snapshot;candidate(f,EDIT..suffix)
            has(f.p:ApplyFileFromUI(FILE),"unbounded top-level change","nonliteral/nonstandalone Include refused")
            eq(f.capture.snapshot,base,"refused effect no publication")
            eq(f.classes.K.cards[1]:init(1),5,"refused effect helper unchanged")
            eq(f.includes,0,"refused effect not executed")
            eq(f.kernels,0,"unknown Include effect refused before kernel")
            eq(#f.receipts,0,"unknown effect no receipt")
            eq(f.p:GetStore():HasPartialPublication(FILE),false,"unknown effect no partial history")
        end
        local shadow="local function Include(path) return path end\n"
        local function with_shadow(bytes)
            return (bytes:gsub("local state=4",shadow.."local state=4",1))
        end
        f=fixture(with_shadow(SOURCE).."\nInclude 'old.lua'")
        local base=f.capture.snapshot;candidate(f,with_shadow(EDIT).."\nInclude 'new.lua'")
        has(f.p:ApplyFileFromUI(FILE),"unbounded top-level change","local Include is not global loader")
        eq(f.capture.snapshot,base,"shadowed call no publication")
        eq(f.kernels,0,"shadowed Include refused before kernel")
        eq(#f.receipts,0,"shadowed Include no receipt")
        -- Ignoring a new Include does not manufacture a class binding.
        f=fixture();candidate(f,(EDIT:gsub("return helper%(n%) end",
            "return _editor_class['N'] end",1)).."\nInclude 'new_classes.lua'")
        has(f.p:ApplyFileFromUI(FILE),"candidate retained","unavailable binding still pending")
        eq(f.classes.K.cards[1]:init(1),15,"unsafe callback kept with shared helper update")
        eq(card_group(f).state.units["card:1:K:1"].definition_version,1,"unsafe callback version retained")
        eq(f.classes.K.cards[2]:init(1),215,"independent callback remains publishable")
        eq(f.includes,0,"new Include not executed to obtain missing binding")
        check(f.classes.N==nil,"no class registration inferred")
        -- Current must not turn unsupported Include syntax into completion.
        f=fixture();candidate(f,SOURCE.."\nInclude(helper(1))")
        local result=f.p:ApplyFromUI()
        has(result,"candidate retained","Current dynamic Include remains pending")
        has(result,"top-level change not published or not confirmed","dynamic call stays explicitly pending")
        check(f.p:GetStore():GetCandidate(FILE)~=nil,"dynamic call candidate not swallowed")
        eq(f.includes,0,"Current dynamic Include not executed")
        -- Current consumes the SAME full remainder: sibling edits are not ACKed.
        f=fixture();candidate(f,EDIT)
        has(f.p:ApplyFromUI(),"candidate retained","current leaves sibling definition")
        eq(f.restarts,1,"current restarts")
        versions(f,2,1,1,"Current partial publication")
        local model=must(f.p:GetCandidateRemainder(FILE))
        eq(model.complete,false,"current partial model")
        eq(f.p._completion_checks[FILE],nil,"Current partial has no completion witness")
        check(f.p:GetStore():GetCandidate(FILE)~=nil,"Current partial candidate retained")
        local pending=false
        for _,row in ipairs(model.pending) do
            if row.kind=="callback" and row.key=="card:1:K:2:init" then pending=true end
        end
        check(pending,"specific sibling pending")
        eq(f.classes.K.cards[2]:init(1),115,"shared propagation not sibling wrapper publish")
        has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","file finishes current remainder")
        eq(f.capture.snapshot.revision,2,"two actual commits not a blanket ACK")
        versions(f,2,1,2,"File finishes sibling wrapper")
        quiet(f,"partial then complete")
        for _,path in ipairs({"file","current"}) do
            f=fixture();candidate(f,SOURCE:gsub("state%+n end","state+n+10 end"))
            local result=path=="file" and f.p:ApplyFileFromUI(FILE) or f.p:ApplyFromUI()
            has(result,"candidate complete; removed",path.." helper-only complete")
            eq(f.classes.K.cards[2]:init(1),115,path.." unchanged sibling shares helper")
            eq(card_group(f).state.units["card:1:K:2"].definition_version,1,path.." sibling wrapper not advanced")
            quiet(f,path.." helper-only")
        end
        -- Definition completion is independent of failed restart. Retry has no
        -- disk/Match/compile/commit work, even after another disk edit.
        f=fixture();candidate(f,SOURCE:gsub("return helper%(n%) end","return helper(n)+1 end",1))
        f.restart_fault=true
        local result=f.p:ApplyFromUI()
        has(result,"restart failed","restart fault reported")
        has(result,"candidate complete; removed","definitions complete before restart failure")
        eq(f.p:GetStore():GetCandidate(FILE),nil,"failed restart does not resurrect definitions")
        eq(f.p:HasRestartPending(),true,"restart still retryable without candidate")
        complete_evidence(f,"completed definitions before failed restart")
        local reads,creates,discoveries,revision=f.reads,f.creates,f.discoveries,f.capture.snapshot.revision
        f.disk=EDIT;f.restart_fault=false
        eq(f.p:RetryRestartFromUI(),"restart requested","retry frozen restart")
        eq(f.reads,reads,"Retry no read");eq(f.creates,creates,"Retry no compile")
        eq(f.discoveries,discoveries,"Retry no Match");eq(f.capture.snapshot.revision,revision,"Retry no commit")
        -- No safe actions does not mean all bytes were published.
        for _,bytes in ipairs({SOURCE:gsub("state=4","state=999"),
            (SOURCE:gsub("'B',1,2,3,100","'B',1,2,3,200"))}) do
            f=fixture();candidate(f,bytes)
            has(f.p:ApplyFileFromUI(FILE),"candidate retained","no-op unsupported bytes stay")
            eq(f.capture.snapshot.revision,0,"unsupported-only no version advance")
            model=must(f.p:GetCandidateRemainder(FILE));eq(model.complete,false,"unsupported bytes not complete")
            check(#model.pending>0,"explicit remainder, not empty action count")
            eq(f.p._completion_checks[FILE],nil,"unsupported bytes no completion proof")
            eq(f.kernels,1,"unsupported-only real no-op transaction")
            eq(f.receipts[1].receipt.changed,false,"unsupported-only real no-op receipt")
        end
        -- New observed bytes invalidate old completion permanently, including
        -- a later revert; same-byte events themselves do not invalidate it.
        for _,path in ipairs({"event","drift","rescan"}) do
            f=fixture();candidate(f,EDIT);f.p:ApplyFileFromUI(FILE)
            quiet(f,path.." complete")
            local next_bytes=EDIT.."\n-- new edit"
            f.disk=next_bytes;scan(f,path)
            eq(f.p:GetStore():GetCandidate(FILE).first_content,next_bytes,path.." new bytes surface")
            eq(f.p._completion_checks[FILE],nil,path.." new bytes release proof")
            f.p:GetStore():CancelCandidate(FILE);f.disk=EDIT;scan(f,path)
            check(f.p:GetStore():GetCandidate(FILE)~=nil,path.." revert not swallowed by old completion")
        end
        -- Saved scope and read witness both matter; reference graph alone is
        -- not enough. Ordinary state values are intentionally NOT frozen.
        for _,fault in ipairs({"callback","function","classes","list","snapshot","revision","session","capture"}) do
            f=fixture();candidate(f,EDIT)
            has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed",fault.." baseline completes")
            complete_evidence(f,fault.." baseline")
            if fault=="callback" then f.classes.K.cards[2].init=function() end
            elseif fault=="function" then must(Anchor.Set(f.entry,"helper",function() end))
            elseif fault=="classes" then _editor_class={K=f.classes.K}
            elseif fault=="list" then f.classes.K.cards={f.classes.K.cards[1],f.classes.K.cards[2]}
            elseif fault=="snapshot" then
                local copy={};for k,v in pairs(f.capture.snapshot) do copy[k]=v end
                f.capture.snapshot=copy
            elseif fault=="revision" then f.capture.snapshot.revision=f.capture.snapshot.revision+1
            elseif fault=="session" then f.p._session_id="other"
            else f.p._versions[FILE].capture={} end
            eq(f.p:_IsCompleted(FILE,EDIT),false,fault.." invalidates completion")
            eq(f.p._completion_checks[FILE],nil,fault.." releases witness")
        end
        f=fixture();candidate(f,EDIT)
        has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","scalar baseline completes")
        complete_evidence(f,"scalar baseline")
        must(Anchor.Set(f.entry,"state",42))
        check(f.p:_IsCompleted(FILE,EDIT),"ordinary state evolution retains completion")
        eq(f.classes.K.cards[2]:init(1),253,"updated code uses evolving original state")
        f.p:Missing(FILE,"spec");eq(f.p._completion_checks[FILE],nil,"Missing clears proof")
        eq(f.p:GetStore():IsCompleted(FILE,EDIT,{}),false,"Missing clears bytes")
        f=fixture();candidate(f,EDIT)
        has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed","Release baseline completes")
        complete_evidence(f,"Release baseline");f.p:Release()
        eq(next(f.p._completion_checks),nil,"Release releases witness")
        eq(next(f.p:GetStore()._completed),nil,"Release releases completion bytes")
        -- Preparation/commit failure cannot create completion history. Assert
        -- the intended seam, so an earlier refusal cannot masquerade as rollback.
        for _,fault in ipairs({"syntax","disk","flush","setter"}) do
            f=fixture();candidate(f,EDIT);local base=f.capture.snapshot
            local helper=local_group(f).state.by_name.helper.fn
            local a,b=f.classes.K.cards[1].init,f.classes.K.cards[2].init
            local flushes,throws=0,0
            if fault=="syntax" then candidate(f,EDIT.."\nfunction bad(")
            elseif fault=="disk" then f.disk=EDIT.."\n-- drift"
            elseif fault=="flush" then _G.jit={flush=function()
                flushes=flushes+1;f.disk=EDIT.."\n-- flush drift"
            end}
            else
                debug.setupvalue=function(fn,i,v)
                    local name=real_set(fn,i,v)
                    if fn==f.entry.anchor and v~=helper then
                        throws=throws+1;error("after-write setter fault")
                    end
                    return name
                end
            end
            result=f.p:ApplyFileFromUI(FILE)
            check(result:sub(1,7)~="applied",fault.." no success")
            eq(f.kernels,(fault=="flush" or fault=="setter") and 1 or 0,fault.." exact kernel boundary")
            eq(flushes,fault=="flush" and 1 or 0,fault.." flush seam reached")
            eq(throws,fault=="setter" and 1 or 0,fault.." real helper write then throw")
            eq(#f.receipts,0,fault.." no common receipt")
            eq(f.capture.snapshot,base,fault.." actual versions not published")
            eq(Anchor.Get(f.entry,"helper"),helper,fault.." original helper restored")
            eq(f.classes.K.cards[1].init,a,fault.." A callback retained")
            eq(f.classes.K.cards[2].init,b,fault.." B callback retained")
            eq(f.p._commit:Poisoned(),false,fault.." no poisoned session")
            eq(f.p._completion_checks[FILE],nil,fault.." no witness")
            eq(next(f.p:GetStore()._completed),nil,fault.." no completion bytes")
            check(f.p:GetStore():GetCandidate(FILE)~=nil,fault.." candidate retained")
            eq(f.p:GetStore():HasPartialPublication(FILE),false,fault.." no partial revision")
            debug.setupvalue=real_set;_G.jit=saved.jit
        end
        -- Faults AFTER receipt: definitions really committed, but no completion
        -- may be published from stale bytes/versions/live bindings or a failed
        -- diagnostic. Both entry points use this same accounting boundary.
        for _,path in ipairs({"file","current"}) do
            for _,fault in ipairs({"throw","report","disk","generation","callback","function","snapshot","bookkeeping"}) do
                f=fixture();candidate(f,EDIT:gsub("helper%(n%)%+200","helper(n)+100"))
                local bytes=f.disk;local hits=0;local mutated=false
                if fault=="bookkeeping" then
                    f.p:GetStore().RecordCompletion=function() hits=hits+1;return nil,"completion fault" end
                end
                FileApply.InspectFileRemainder=function(driver,discovery,operation,refresh)
                    f.account_calls=(f.account_calls or 0)+1
                    local actual=must(f.receipts[1],"accounting must follow real receipt")
                    eq(actual.receipt.changed,true,path.." "..fault.." real changed receipt before accounting")
                    eq(operation.base_snapshot,actual.receipt.snapshot,path.." "..fault.." installed snapshot")
                    eq(operation.source,actual.source,path.." "..fault.." shared complete analysis")
                    check(discovery~=f.discovered[1].discovery,path.." "..fault.." new actual discovery")
                    eq(operation.mode,"file",path.." "..fault.." common file accounting")
                    eq(#operation.roots,0,path.." "..fault.." no publication roots")
                    eq(operation.file_proof,nil,path.." "..fault.." accounting operation not prepared for publication")
                    if fault=="throw" then hits=hits+1;error("diagnostic fault") end
                    if fault=="report" then hits=hits+1;return nil,"diagnostic refusal" end
                    if fault~="bookkeeping" then
                        FileApply.Remaining=function(...)
                            local m,e=old_remaining(...)
                            must(m,e)
                            if not mutated then
                                mutated=true;hits=hits+1
                                if fault=="disk" then f.disk=bytes.."\n-- during remainder"
                                elseif fault=="generation" then candidate(f,bytes)
                                elseif fault=="callback" then f.classes.K.cards[2].init=function() end
                                elseif fault=="function" then must(Anchor.Set(f.entry,"helper",function() end))
                                elseif fault=="snapshot" then
                                    local copy={};for k,v in pairs(f.capture.snapshot) do copy[k]=v end
                                    f.capture.snapshot=copy
                                end
                            end
                            return m,e
                        end
                    end
                    return old_account(driver,discovery,operation,refresh)
                end
                result=path=="file" and f.p:ApplyFileFromUI(FILE) or f.p:ApplyFromUI()
                has(result,"completion unavailable",path.." "..fault.." accounting failure visible")
                eq(f.account_calls,1,path.." "..fault.." actual accounting reached")
                eq(hits,1,path.." "..fault.." intended fault reached once")
                eq(f.kernels,1,path.." "..fault.." one real kernel")
                eq(#f.receipts,1,path.." "..fault.." one real receipt")
                eq(f.receipts[1].receipt.changed,true,path.." "..fault.." definitions really changed")
                eq(f.capture.snapshot.revision,1,path.." "..fault.." actual committed revision kept")
                check(f.p:GetStore():GetCandidate(FILE)~=nil,path.." "..fault.." no candidate removal")
                eq(f.p._completion_checks[FILE],nil,path.." "..fault.." no witness")
                eq(next(f.p:GetStore()._completed),nil,path.." "..fault.." no completion record")
                eq(f.p:GetStore():GetPartialPublication(FILE).revision,1,path.." "..fault.." sticky publication intact")
                FileApply.InspectFileRemainder=old_account;FileApply.Remaining=old_remaining
                if fault=="throw" or fault=="report" or fault=="bookkeeping" then
                    f.p:GetStore().RecordCompletion=nil
                    has(f.p:ApplyFileFromUI(FILE),"candidate complete; removed",path.." "..fault.." no-op recovery")
                    eq(f.capture.snapshot.revision,1,path.." "..fault.." recovery does not re-publish")
                    eq(f.kernels,2,path.." "..fault.." recovery common no-op transaction")
                    eq(f.receipts[2].receipt.changed,false,path.." "..fault.." recovery real no-op receipt")
                    complete_evidence(f,path.." "..fault.." recovered completion")
                end
            end
        end
        f=fixture();candidate(f,EDIT)
        local commit=f.p._driver.CommitDiscovery
        f.p._driver.CommitDiscovery=function(self,...)
            local receipt,e=commit(self,...);if receipt then receipt.kind="not a receipt" end
            return receipt,e
        end
        has(f.p:ApplyFileFromUI(FILE),"receipt bookkeeping failed","wrong receipt rejected")
        eq(f.capture.snapshot.revision,1,"receipt fault does not undo real definitions")
        eq(f.kernels,1,"receipt corruption follows actual kernel")
        eq(#f.receipts,1,"receipt corruption follows real common receipt")
        check(f.p._publication_error~=nil,"receipt corruption makes bookkeeping sticky")
        check(f.p:GetStore():GetCandidate(FILE)~=nil,"receipt fault keeps candidate")
        eq(f.p._completion_checks[FILE],nil,"receipt fault no completion")
    end)
    debug.upvaluejoin,debug.setupvalue=real_join,real_set
    Restart.Handoff,Compose.Create,FileApply.InspectFileRemainder,FileApply.Remaining=old_restart,old_create,old_account,old_remaining
    Source.Build,FileApply.CheckWitness=old_build,old_witness
    for _,p in ipairs(plugins) do p:Release() end
    for _,name in ipairs(modules) do package.loaded[name]=loaded[name] end
    if environment then environment:Restore() end
    for _,name in ipairs(globals) do rawset(_G,name,saved[name]) end
    if not ok then failed=failed+1;failures[#failures+1]="unexpected error: "..tostring(problem) end
    print(string.format("CandidateCompletionSpec: %d passed / %d failed",passed,failed))
    for _,why in ipairs(failures) do print("  FAIL "..why) end
    return {passed=passed,failed=failed}
end
return M
