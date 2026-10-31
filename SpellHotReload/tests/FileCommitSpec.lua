-- Two independent owners, genuine synthetic first load, real LuaJIT cells.
-- This is a kernel spec, not engine smoke or a production-owner integration test.
local M={}
local serial=0
function M.run()
    local Driver=require("SpellHotReload.Pipeline.Driver")
    local FileMatch=require("SpellHotReload.Pipeline.FileMatch")
    local LocalOwner=require("SpellHotReload.Adapters.Local.Local")
    local function matched_projection(source)
        local driver=Driver.New();assert(driver:RegisterDiscovery(LocalOwner))
        local discovery,err=driver:Discover("LocalFixture_Boss.lua",source,{})
        if not discovery then return nil,err end
        local context,why=FileMatch.ForOwner(discovery.snapshot,LocalOwner,source)
        if not context then return nil,why end
        return context.projection,discovery.snapshot
    end
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Versions=require("SpellHotReload.Pipeline.FileVersions")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Compose=require("SpellHotReload.Source.Compose")
    local Tree=require("SpellHotReload.Source.SyntaxTree")
    local Plan=require("SpellHotReload.Source.FunctionPlan")
    local Definitions=require("SpellHotReload.Adapters.Local.LocalDefinitions")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local get,set,join,id=debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid
    local real_jit,real_raw,old_target=rawget(_G,"jit"),rawset,rawget(_G,"_file_commit_spec_target")
    local passed,failed,failures=0,0,{}
    local function test(value,label)
        if value then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) test(rawequal(a,b),label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function copy(t) local out={};for k,v in next,t do out[k]=v end;return out end
    local function reset()
        debug.getupvalue,debug.setupvalue,debug.upvaluejoin,debug.upvalueid=get,set,join,id
        real_raw(_G,"jit",real_jit)
    end
    local source=table.concat({
        "local counter=7",
        "local function helper() return counter+1 end",
        "local function unused() return counter end",
        "_file_commit_spec_target={}",
        "function _file_commit_spec_target.callback() return helper() end",
        "function _file_commit_spec_target.spare() return counter end",
    },"\n")
    local function fixture(mode,module)
        reset();serial=serial+1
        local sid="FileCommitSpec:"..serial
        local loaded=mode=="absent" and source:gsub("function _file_commit_spec_target.callback%(%) return helper%(%) end","") or source
        local entry=must(Load.Capture(loaded,{name="Tx_Boss.lua"}));entry.file="Tx_Boss.lua"
        local target=_file_commit_spec_target
        local candidate=mode=="noop" and source or source:gsub("counter%+1","counter+2"):gsub("return helper%(%)","return helper()+3")
        local facts=must(Source.Build(candidate))
        local owners={{Id="alpha"},{Id="beta"}}
        local ref_counter={owner=owners[1],id=1}
        local ref_helper={owner=owners[1],id=2}
        local ref_unused={owner=owners[1],id=3}
        local ref_callback={owner=owners[2],id=1}
        local default
        do local counter=99;default=function() return counter end end
        local h={fn=entry.map.helper,definition_version=1}
        local u={fn=entry.map.unused,definition_version=1}
        local c={fn=target.callback,definition_version=1}
        local spare={fn=target.spare,definition_version=1}
        local counter_record={definition_version=1}
        local a={owner=owners[1],owner_id="alpha",state={helper=h,unused=u,counter=counter_record},
            units={{unit_ref=ref_counter},{unit_ref=ref_helper},{unit_ref=ref_unused}},
            records={{key="counter",kind="state",definition=counter_record,definition_version=1},
                {key="helper",kind="function",definition=h,definition_version=1},
                {key="unused",kind="function",definition=u,definition_version=1}},
            functions={h.fn,u.fn},edges={{consumer=ref_helper,provider=ref_counter},{consumer=ref_unused,provider=ref_counter}},
            initial={},identity_objects={},authority={cells={},raws={},forbidden={}}}
        for _,item in ipairs({{name="helper",ref=ref_helper},{name="unused",ref=ref_unused}}) do
            a.authority.cells[#a.authority.cells+1]={unit_ref=item.ref,anchor=entry.anchor,index=entry.slots[item.name],name=item.name}
        end
        local b={owner=owners[2],owner_id="beta",state={callback=c,spare=spare,target=target},
            units={{unit_ref=ref_callback}},records={
                {key="callback",kind="callback",definition=c,definition_version=1},
                {key="spare",kind="callback",definition=spare,definition_version=1}},
            functions=c.fn and {c.fn,spare.fn} or {spare.fn},edges=c.fn and {{consumer=ref_callback,provider=ref_helper},{consumer=ref_callback,provider=ref_counter}} or {{consumer=ref_callback,provider=ref_counter}},
            initial={},identity_objects={target},authority={cells={},raws={
                {unit_ref=ref_callback,target=target,key="callback"},
                {unit_ref=ref_callback,target=target,key="spare"}},forbidden={default}}}
        local capture=must(Versions.Capture(entry,sid,{a,b}))
        local base=capture.snapshot
        local operation={file=entry.file,session_id=sid,capture=capture,entry=entry,anchor=entry.anchor,
            loaded_source=loaded,source=facts,generation=1,base_snapshot=base,mode="file"}
        local fragments={}
        local guard_calls={0,0}
        for i,group in ipairs(base.owners) do
            fragments[i]={operation=operation,owner=group.owner,base_group=group,proposed_group=group,
                joins={},cell_writes={},raw_writes={},read_set={},capture_reads={},published_delta={}}
            fragments[i].owner_guard=function(f,cap,live)
                guard_calls[i]=guard_calls[i]+1
                return cap==capture and live.snapshot==base
            end
        end
        local function reads(fragment,fn,ref,name,rawkey)
            if rawkey then fragment.read_set[#fragment.read_set+1]={owner=fragment.owner,unit_ref=ref,target=target,key=rawkey,value=fn}
            else fragment.read_set[#fragment.read_set+1]={owner=fragment.owner,unit_ref=ref,
                anchor=entry.anchor,index=entry.slots[name],name=name,value=fn} end
            for _,record in ipairs(must(Compose.Plan(fn,entry)).joins) do
                local r=copy(record);r.owner=fragment.owner;r.unit_ref=ref
                fragment.capture_reads[#fragment.capture_reads+1]=r
            end
        end
        reads(fragments[1],h.fn,ref_helper,"helper")
        reads(fragments[1],u.fn,ref_unused,"unused")
        if c.fn then reads(fragments[2],c.fn,ref_callback,nil,"callback")
        else fragments[2].read_set[1]={owner=owners[2],unit_ref=ref_callback,target=target,key="callback",value=nil} end
        reads(fragments[2],spare.fn,ref_callback,nil,"spare")
        if mode~="noop" then
            local projection=must(matched_projection(facts))
            local descriptor=projection.definitions.helper[1]
            local probe=must(Plan.Probe(facts,descriptor))
            local hp=must(Compose.Plan(probe.created,entry))
            local syntax;local Tree=facts.analysis.syntax
            for _,statement in ipairs(facts.analysis.statements) do
                local definition=Tree.Match(statement.syntax,"definition")
                local target_node=definition and Tree.Match(definition.target,"member")
                if target_node and target_node.name=="callback" then syntax=definition.fn end
            end
            local visible=must(Source.Visible(facts,syntax))
            local created=must(Compose.Create(Tree.FunctionSource(syntax,false),nil,visible,
                {form="expression",tree=facts.analysis.syntax,syntax=syntax,name="FileCommitSpec:callback"}))
            local cp=must(Compose.Plan(created,entry))
            local nh,nc={fn=hp.fn,definition_version=2},{fn=cp.fn,definition_version=2}
            local ga,gb=copy(base.owners[1]),copy(base.owners[2])
            ga.state={helper=nh,unused=u,counter=counter_record};ga.functions={nh.fn,u.fn}
            ga.records={a.records[1],{key="helper",kind="function",definition=nh,definition_version=2},a.records[3]}
            gb.state={callback=nc,spare=spare,target=target};gb.functions={nc.fn,spare.fn}
            gb.records={{key="callback",kind="callback",definition=nc,definition_version=2},b.records[2]}
            gb.edges={{consumer=ref_callback,provider=ref_helper},{consumer=ref_callback,provider=ref_counter}}
            fragments[1].proposed_group,fragments[2].proposed_group=ga,gb
            fragments[1].cell_writes={{owner=owners[1],unit_ref=ref_helper,anchor=entry.anchor,
                index=entry.slots.helper,name="helper",before=h.fn,value=nh.fn}}
            fragments[2].raw_writes={{owner=owners[2],unit_ref=ref_callback,target=target,key="callback",before=c.fn,value=nc.fn}}
            for i,p in ipairs({hp,cp}) do
                for _,record in ipairs(p.joins) do
                    local r=copy(record);r.owner=owners[i];r.unit_ref=i==1 and ref_helper or ref_callback
                    fragments[i].joins[#fragments[i].joins+1]=r
                end
            end
        end
        local live={capture=capture,snapshot=base,entry=entry,session_id=sid,content=candidate,generation=1}
        return {tx=must((module or Tx).New(sid)),module=module or Tx,operation=operation,
            fragments=fragments,capture=capture,base=base,live=live,target=target,
            old_helper=h.fn,old_callback=c.fn,default=default,guard_calls=guard_calls,refs={ref_helper,ref_callback},initial_inputs={a,b}}
    end
    local function scoped(f,refresh)
        local ran,value,err=f.tx:Run(function(token)
            return f.tx:Commit(token,f.operation,f.fragments,f.live,refresh)
        end)
        eq(ran,true,"UI scope returns");return value,err
    end
    local function unchanged(f,label)
        eq(select(2,get(f.capture.entry.anchor,f.capture.entry.slots.helper)),f.old_helper,label.." helper restored")
        eq(f.target.callback,f.old_callback,label.." callback restored")
        eq(f.capture.snapshot,f.base,label.." snapshot retained")
    end
    local function with_raw(writer)
        local key="SpellHotReload.Apply.FileCommit"
        local saved=package.loaded[key]
        real_raw(_G,"rawset",writer);package.loaded[key]=nil
        local ok,module=pcall(require,key)
        real_raw(_G,"rawset",real_raw);package.loaded[key]=saved
        assert(ok,module);return module
    end
    local ok,problem=pcall(function()
        assert(type(join)=="function","FileCommitSpec requires real LuaJIT upvaluejoin")
        local f=fixture()
        local receipt=must(scoped(f))
        eq(receipt.kind,"SpellHotReload.FileCommit.Receipt","neutral receipt")
        eq(receipt.snapshot,f.capture.snapshot,"one installed file snapshot")
        eq(receipt.snapshot.revision,1,"two owners advance file revision once")
        eq(#receipt.owner_deltas,2,"one receipt covers two owners")
        eq(f.target.callback(),12,"both owner installations effective")
        eq(select(2,get(f.capture.entry.anchor,f.capture.entry.slots.counter)),7,"scalar state preserved")
        eq(f.capture.snapshot.owners[1].state.helper.fn,f.capture.snapshot.owners[1].functions[1],"state and projection share sealed function")
        eq(f.capture.snapshot.owners[1].records[2].definition,f.capture.snapshot.owners[1].state.helper,"one record identity after seal")
        eq(f.guard_calls[1],2,"first owner guard before and after refresh")
        eq(f.guard_calls[2],2,"second owner guard before and after refresh")
        f=fixture("noop")
        local flushes,refreshes=0,0
        real_raw(_G,"jit",{flush=function() flushes=flushes+1 end})
        receipt=must(scoped(f,function() refreshes=refreshes+1;return f.live end))
        eq(receipt.changed,false,"no-op receipt")
        eq(receipt.snapshot,f.base,"no-op same snapshot")
        eq(flushes,0,"no-op zero flush")
        eq(refreshes,1,"no-op still refreshes")
        f=fixture("noop");f.target.spare=function() end
        local value=scoped(f);eq(value,nil,"no-op checks unselected published reads")
        for _,kind in ipairs({"unused","spare","default","anchor"}) do
            f=fixture()
            local j=f.fragments[1].joins[1]
            local dest=kind=="unused" and f.capture.entry.map.unused or kind=="spare" and f.target.spare
                or kind=="default" and f.default or f.capture.entry.anchor
            local index
            for n=1,255 do local name=get(dest,n);if not name then break end;if name==j.name then index=n;break end end
            assert(index,"fixture destination capture")
            j.fn,j.index=dest,index
            -- Even placing the published fn in the installation list grants no join permission.
            f.fragments[1].cell_writes[1].value=dest;f.fragments[1].proposed_group.functions[1]=dest
            value=scoped(f);eq(value,nil,"published join destination refused: "..kind);unchanged(f,kind)
        end
        f=fixture();f.fragments[1].cell_writes={};f.fragments[1].joins={}
        value=scoped(f);eq(value,nil,"other owner's write cannot advance no-write ledger");unchanged(f,"no-write owner")
        f=fixture()
        local proposed=f.fragments[1].proposed_group
        -- Original contributor arrays are no longer the capture whitelist.
        f.initial_inputs[2].identity_objects[#f.initial_inputs[2].identity_objects+1]=proposed.state.helper
        f.initial_inputs[2].identity_objects[1]={}
        f.initial_inputs[2].authority.raws[1].key="unowned"
        real_raw(_G,"jit",{flush=function()
            proposed.state.helper.fn=function() return -1 end
            proposed.functions[1]=proposed.state.helper.fn
            proposed.records[2].definition_version=99
            proposed.edges={}
        end})
        receipt=must(scoped(f))
        eq(f.capture.snapshot.owners[1].state.helper.fn,select(2,get(f.capture.entry.anchor,f.capture.entry.slots.helper)),"flush cannot alter sealed ledger")
        eq(f.capture.snapshot.owners[1].records[2].definition_version,2,"sealed definition version retained")
        eq(f.capture.snapshot.owners[2].state.target,f.target,"copied first-load live identity retained")
        -- Candidate facts may not escape into metadata, even as table keys.
        for _,as_key in ipairs({false,true}) do
            f=fixture()
            local source=f.operation.source
            local analysis=source.analysis
            local ffi=require("ffi")
            local copied=ffi.new("TSNode[1]");copied[0]=analysis.syntax.root[0]
            local facts={copied,source,analysis,source.sites,source.syntax_check,analysis.syntax,analysis.syntax.root,
                source.sites[analysis.statements[1].syntax],
                analysis.statements,analysis.statements[1],analysis.statements[1].syntax,
                analysis.nodes,analysis.nodes[1],Source.Declarations(source),
                Source.DeclaredNames(source),Source.Declaration(source,"counter"),
                Source.Declaration(source,"counter").name_syntax,
                analysis.declarations_by_name,analysis.declarations_by_name.counter}
            for _,fact in ipairs(facts) do
                local metadata={}
                if as_key then metadata[fact]=true else metadata.held=fact end
                f.fragments[1].proposed_group.state.extra=metadata
                local sealed,reason=pcall(Guard.Seal,f.operation,f.fragments)
                eq(sealed,false,"candidate fact rejected before writes")
                test(type(reason)=="string" and reason:find("candidate source",1,true),"candidate fact refusal is explicit")
                unchanged(f,"candidate fact")
            end
        end
        f=fixture()
        local shared={tag="metadata"};shared.self=shared
        f.fragments[1].proposed_group.state.extra=shared
        f.fragments[1].proposed_group.state.alias=shared
        receipt=must(scoped(f))
        local published=f.capture.snapshot.owners[1].state
        eq(published.extra,published.alias,"publication preserves shared metadata")
        eq(published.extra.self,published.extra,"publication preserves metadata cycles")
        test(published.extra~=shared,"publication seals metadata independently")
        eq(f.capture.snapshot.owners[2].state.target,f.target,"first-load identity still retained")
        f=fixture()
        local extra=copy(f.fragments[1].cell_writes[1]);extra.value=function() return -1 end
        f.fragments[1].cell_writes[2]=extra
        f.fragments[1].proposed_group.functions[#f.fragments[1].proposed_group.functions+1]=extra.value
        local conflict
        value,conflict=scoped(f)
        eq(value,nil,"same physical cell with different action refused")
        eq(conflict.code,"conflict","both valid candidates reach physical conflict check");unchanged(f,"conflict")
        f=fixture()
        f.initial_inputs[2].authority.raws[#f.initial_inputs[2].authority.raws+1]={
            unit_ref=f.refs[2],target=f.target,key="arbitrary"}
        f.fragments[2].raw_writes[1].key="arbitrary"
        value=scoped(f);eq(value,nil,"unowned raw field refused");unchanged(f,"raw authority")
        f=fixture()
        f.fragments[1].cell_writes[1].name="counter"
        f.fragments[1].cell_writes[1].index=f.capture.entry.slots.counter
        value=scoped(f);eq(value,nil,"state cell has no function-write authority");unchanged(f,"state authority")
        f=fixture()
        real_raw(_G,"jit",{flush=function() debug.setupvalue=function(...) return set(...) end end})
        value=scoped(f);eq(value,nil,"flush API drift refused");unchanged(f,"API drift")
        f=fixture()
        value=scoped(f,function() f.live.content="changed on disk";return f.live end)
        eq(value,nil,"refresh byte drift refused");unchanged(f,"bytes")
        for _,mode in ipairs({"skip","after"}) do
            local target,armed
            local module=with_raw(function(t,k,v)
                if armed and t==target and k=="callback" then
                    armed=false
                    if mode=="after" then real_raw(t,k,v);error("after raw write") end
                    return t
                end
                return real_raw(t,k,v)
            end)
            f=fixture(nil,module);target=f.target;armed=true
            value=scoped(f);eq(value,nil,"raw "..mode.." failure has no receipt");unchanged(f,"raw "..mode)
        end
        for _,stage in ipairs({"cell","raw","snapshot"}) do
            for _,when in ipairs({"before","after","skip"}) do
                local target_capture,target_card,armed
                local module=with_raw(function(t,k,v)
                    local selected=stage=="raw" and t==target_card and k=="callback"
                        or stage=="snapshot" and t==target_capture and k=="snapshot"
                    if armed and selected then
                        armed=false
                        if when=="after" then real_raw(t,k,v) end
                        if when=="skip" then return t end
                        error("injected raw boundary")
                    end
                    return real_raw(t,k,v)
                end)
                f=fixture(nil,module);target_capture=f.capture;target_card=f.target;armed=true
                if stage=="cell" then
                    debug.setupvalue=function(fn,index,value)
                        if armed and fn==f.capture.entry.anchor and index==f.capture.entry.slots.helper then
                            armed=false
                            if when=="after" then set(fn,index,value) end
                            if when=="skip" then return "helper" end
                            error("injected cell boundary")
                        end
                        return set(fn,index,value)
                    end
                end
                value=scoped(f);eq(value,nil,stage.." "..when.." refuses");unchanged(f,stage.." "..when)
            end
        end
        f=fixture()
        local duplicate=copy(f.fragments[1].joins[1])
        f.fragments[1].joins[#f.fragments[1].joins+1]=duplicate
        f.fragments[1].cell_writes[2]=copy(f.fragments[1].cell_writes[1])
        local joins_done=0
        debug.upvaluejoin=function(... ) joins_done=joins_done+1;return join(...) end
        receipt=must(scoped(f))
        eq(joins_done,2,"identical proved actions execute once")
        f=fixture()
        debug.upvaluejoin=function(...) join(...);error("candidate joined then threw") end
        value=scoped(f);eq(value,nil,"joined-then-throw candidate has no receipt");unchanged(f,"join throw")
        f=fixture("noop")
        local consumed
        local ran=f.tx:Run(function(token)
            must(f.tx:Commit(token,f.operation,f.fragments,f.live))
            consumed=f.tx:Check(token)
        end)
        eq(ran,true,"no-op scope runs");eq(consumed,nil,"no-op consumes unique token")
        local absent_target,armed
        local absent_module=with_raw(function(t,k,v)
            if armed and t==absent_target and k=="callback" then
                armed=false;real_raw(t,k,v);error("new raw field then throw")
            end
            return real_raw(t,k,v)
        end)
        f=fixture("absent",absent_module);absent_target=f.target;armed=true
        value=scoped(f);eq(value,nil,"new raw field failure has no receipt")
        unchanged(f,"nil raw preimage");eq(rawget(f.target,"callback"),nil,"rollback deletes originally absent field")
        for _,drift in ipairs({"bytes","api","read"}) do
            f=fixture()
            local guards=0
            f.fragments[2].owner_guard=function()
                guards=guards+1
                if guards==2 then
                    if drift=="bytes" then f.live.content="guard changed candidate"
                    elseif drift=="api" then debug.setupvalue=function(...) return set(...) end
                    else f.target.spare=function() return -1 end end
                end
                return true
            end
            local still_valid
            local ran,receipt=f.tx:Run(function(token)
                local r=f.tx:Commit(token,f.operation,f.fragments,f.live)
                still_valid=f.tx:Check(token)
                return r
            end)
            eq(ran,true,"last-guard "..drift.." safe")
            eq(receipt,nil,"last-guard "..drift.." refused")
            eq(still_valid,true,"last-guard "..drift.." refused before Consume")
            unchanged(f,"last-guard "..drift)
        end
        f=fixture()
        debug.upvaluejoin=function() end
        value=scoped(f);eq(value,nil,"silent no-op join fails postimage/shared identity");unchanged(f,"no-op join")
        local poison_target,forward=true,true
        local module=with_raw(function(t,k,v)
            if t==poison_target and k=="callback" then
                if forward then forward=false;real_raw(t,k,v);error("mutate then throw") end
                error("restore failed")
            end
            return real_raw(t,k,v)
        end)
        f=fixture(nil,module);poison_target=f.target
        local peer=must(module.New(f.operation.session_id))
        local reason
        value,reason=scoped(f)
        eq(value,nil,"failed restoration has no receipt");eq(reason.code,"rollback","rollback diagnosis")
        eq(f.tx:Poisoned(),true,"controller poisoned")
        eq(peer:Poisoned(),true,"peer shares poison")
        eq(select(2,get(f.capture.entry.anchor,f.capture.entry.slots.helper)),f.old_helper,"continues earlier restoration after raw restore failure")
        must(f.tx:Release())
        eq(module.New(f.operation.session_id),nil,"Release does not clear poison")
        must(peer:Release())
        local snapshot_target,snapshot_forward
        local snapshot_module=with_raw(function(t,k,v)
            if t==snapshot_target and k=="snapshot" then
                if snapshot_forward then snapshot_forward=false;real_raw(t,k,v) end
                error("snapshot forward/restore failed")
            end
            return real_raw(t,k,v)
        end)
        f=fixture(nil,snapshot_module);snapshot_target=f.capture;snapshot_forward=true
        value,reason=scoped(f)
        eq(value,nil,"failed snapshot restoration has no receipt");eq(reason.code,"rollback","snapshot rollback diagnosis")
        eq(f.target.callback,f.old_callback,"raw restored despite later snapshot restore failure")
        eq(select(2,get(f.capture.entry.anchor,f.capture.entry.slots.helper)),f.old_helper,"cell restored despite later snapshot restore failure")
        eq(f.tx:Poisoned(),true,"snapshot restoration failure poisons session")
        must(f.tx:Release())
        eq(snapshot_module.New(f.operation.session_id),nil,"snapshot poison survives Release")
        f=fixture()
        debug.upvaluejoin=nil
        value=scoped(f);eq(value,nil,"missing capability injected in LuaJIT refuses");unchanged(f,"missing join")
    end)
    reset();real_raw(_G,"_file_commit_spec_target",old_target)
    if not ok then failed=failed+1;failures[#failures+1]="spec threw: "..(type(problem)=="string" and problem or "opaque error") end
    return {passed=passed,failed=failed,failures=failures}
end
return M
