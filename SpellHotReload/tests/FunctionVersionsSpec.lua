-- Local's actual versions and selection through the real common pipeline.
-- Only miniature first-load fixtures execute. Publication always uses FileCommit;
-- metadata projection/Seal below never installs a proposed snapshot or cells.
local M={}
local serial=0
function M.run()
    local Source=require("SpellHotReload.Source.FileAnalysis")
    local Definitions=require("SpellHotReload.Adapters.Local.LocalDefinitions")
    local Versions=require("SpellHotReload.Adapters.Local.LocalVersions")
    local Local=require("SpellHotReload.Adapters.Local.Local")
    local Files=require("SpellHotReload.Pipeline.FileVersions")
    local Dependencies=require("SpellHotReload.Pipeline.Dependencies")
    local Planning=require("SpellHotReload.tests.PlanningFixture")
    local Load=require("SpellHotReload.Load.AnchorLoad")
    local Anchor=require("SpellHotReload.Load.Anchor")
    local Compose=require("SpellHotReload.Source.Compose")
    local Guard=require("SpellHotReload.Apply.CommitCheck")
    local Tx=require("SpellHotReload.Apply.FileCommit")
    local passed,failed,failures=0,0,{}
    local controllers={}
    local function check(value,label)
        if value then passed=passed+1 else failed=failed+1;failures[#failures+1]=label end
    end
    local function eq(a,b,label) check(a==b,label..": "..tostring(a).." ~= "..tostring(b)) end
    local function list(a,expected,label) eq(table.concat(a,","),expected,label) end
    local function must(v,e) assert(v,type(e)=="table" and e.message or e);return v end
    local function refuse(fn,code,label)
        local value,err=fn()
        eq(value,nil,label.." rejected");eq(type(err),"table",label.." structured error")
        if type(err)=="table" then
            eq(err.code,code,label.." code")
            check(type(err.message)=="string" and err.message~="",label.." message")
        end
    end
    local function state(snapshot)
        for _,group in ipairs(snapshot.owners) do if group.owner==Local then return group.state end end
        error("original Local owner missing")
    end
    local function live(f)
        return {capture=f.capture,snapshot=f.capture.snapshot,entry=f.entry,session_id=f.session,
            content=f.content,generation=f.generation}
    end
    local function fixture(content)
        serial=serial+1
        local entry=must(Load.Capture(content,{name="Versions_Boss.lua"}))
        must(entry.reloadable,entry.reason)
        entry.file="Versions_Boss.lua"
        local f=must(Planning.Capture(entry,"FunctionVersionsSpec:"..serial))
        f.content,f.generation=content,0
        f.refresh=function() return live(f) end
        return f
    end
    -- Input assembly only: Build once, then NEW discovery against actual records.
    -- No old Select/Next report, compatibility ledger or manual Join/Set commit.
    local function discover(f,content)
        local facts,err=Source.Build(content);if not facts then return nil,err end
        f.content,f.generation=content,f.generation+1
        return Planning.Discover(f,facts,f.generation)
    end
    local function view(d)
        for _,group in ipairs(d.reconciliation.groups) do if group.owner==Local then return group.view end end
        error("Local reconciliation missing")
    end
    local function fragment(p)
        for _,record in ipairs(p.entries) do if record.owner==Local then return record.fragment end end
        error("Local fragment missing")
    end
    local function prepare(f,d,root_ids)
        return Planning.Prepare(f,d,{mode="file",root_ids=root_ids,refresh=f.refresh})
    end
    local function selection(f,content,root_ids)
        return must(prepare(f,must(discover(f,content)),root_ids))
    end
    local function seal(p)
        local fragments={};for _,record in ipairs(p.entries) do fragments[#fragments+1]=record.fragment end
        return must(Guard.Seal(p.operation,fragments))
    end
    local function selected(p,expected,label)
        local names={};for _,write in ipairs(fragment(p).cell_writes) do names[#names+1]=write.name end
        list(names,expected,label)
    end
    local function affected(p,expected,label)
        local plan=seal(p)
        local impact=must(Dependencies.PublicationImpact(plan.proposed_snapshot,plan.owner_deltas))
        local names={};local s=state(plan.proposed_snapshot)
        for _,name in ipairs(s.names) do if impact.affected[s.by_name[name].unit_ref] then names[#names+1]=name end end
        list(names,expected,label)
    end
    local function describe(p)
        local plan=seal(p)
        local impact=must(Dependencies.PublicationImpact(plan.proposed_snapshot,plan.owner_deltas))
        return must(Local.Describe(fragment(p),{operation=p.operation,snapshot=p.operation.base_snapshot,
            dependencies=p.dependencies,impact=impact}))
    end
    local function publish(f,p)
        if not f.tx then f.tx=must(Tx.New(f.session));controllers[#controllers+1]=f.tx end
        return must(Planning.Publish(f,p,f.tx))
    end
    local function blocked(f,content,root_id,label)
        local d=must(discover(f,content))
        local op=must(Planning.Operation(f,d,{mode="file",root_ids={root_id},refresh=f.refresh}))
        -- Examine genuine root refusal before the separate whole-file policy.
        local p=must(f.driver:PrepareDiscovery(d,op))
        eq(#p.dependencies.safe_roots,0,label.." no publishable root")
        eq(#p.dependencies.blocked_roots,1,label.." one blocked root")
        eq(p.dependencies.blocked_roots[1].root_id,root_id,label.." exact root")
        eq(p.dependencies.blocked_roots[1].reason.code,"unsupported",label.." domain refusal")
        eq(#fragment(p).cell_writes,0,label.." no installation")
    end
    local original_join,original_set,original_jit=debug.upvaluejoin,debug.setupvalue,rawget(_G,"jit")
    local original_f=rawget(_G,"f")
    local joins,writes,flushes=0,0,0
    local f,entry,initial,initial_snapshot,base,changed
    local ok,problem=pcall(function()
        must(Anchor.Supported(Compose.Capability(debug))) -- Real LuaJIT capability, no presence shim.
        local source=table.concat({
            "local counter=0","local config={tag='old'}",
            "local function helper(n) return counter+n end",
            "local function pattern(n) return helper(n) end",
            "local alias=helper",
            "local function alias_user(n) return alias(n) end",
            "local function other(n) return n+100 end",
            "local function setter(n) counter=n end",
        },"\n")
        -- Metadata must not join, set or flush, including first-load contribution.
        debug.upvaluejoin=function() joins=joins+1;error("premature join") end
        debug.setupvalue=function() writes=writes+1;error("premature write") end
        _G.jit={flush=function() flushes=flushes+1;error("premature flush") end}
        f=fixture(source);entry=f.entry;initial_snapshot=f.capture.snapshot;base=state(initial_snapshot)
        initial={};for _,name in ipairs({"helper","pattern","alias_user","other","setter"}) do initial[name]=Anchor.Get(entry,name) end
        eq(Versions.Kind,"SpellHotReload.LocalVersions","private version kind");eq(Versions.Version,1,"private version protocol")
        eq(initial_snapshot.revision,0,"initial transaction revision")
        eq(initial_snapshot.session_id,f.session,"session carried")
        eq(base.entry,entry,"loaded entry held");eq(base.anchor,entry.anchor,"unique anchor held")
        eq(base.loaded_source,source,"initial structural source held")
        list(base.names,"counter,config,helper,pattern,alias,alias_user,other,setter","all binding source order")
        local function_names={}
        for _,name in ipairs(base.names) do if base.by_name[name].binding_kind=="function" then function_names[#function_names+1]=name end end
        list(function_names,"helper,pattern,alias_user,other,setter","direct function source order")
        list(base.by_name.helper.dependencies,"counter","actual helper upvalue")
        list(base.by_name.pattern.dependencies,"helper","actual consumer upvalue")
        list(base.by_name.alias_user.dependencies,"alias","alias is its own cell")
        eq(base.by_name.pattern.observed.helper,1,"initial dependency observation")
        eq(base.by_name.alias_user.observed.helper,nil,"alias does not observe helper version")
        eq(base.by_name.helper.fn,initial.helper,"genuine published identity held")
        eq(base.by_name.alias.binding_kind,"state","alias not a function definition")
        eq(base.by_name.counter.binding_kind,"state","scalar not a function definition")
        eq(base.by_name.helper.definition_version,1,"initial per-definition version")
        local local_initial=select(2,Files.Owner(f.capture,Local))
        for _,cell in ipairs(local_initial.authority.cells) do
            check(cell.name~="alias" and cell.name~="counter" and cell.name~="config","no setter authority for state or alias")
        end
        eq(#entry.source.bindings.names,8,"shared inspection declaration count")
        local inspection=must(Definitions.Match(must(Source.Build(source.."\nerror('chunk ran')"))))
        eq(#inspection.definitions.helper,1,"inspection never executes chunk")
        refuse(function() return Source.Build("local function f( end") end,"compile","inspection syntax")
        local same=must(discover(f,source));list(view(same).version_view.changed,"","unchanged source")
        local noop=must(prepare(f,same,{"local:pattern"}))
        selected(noop,"","unchanged root no write");affected(noop,"","unchanged impact")
        eq(seal(noop).proposed_snapshot,initial_snapshot,"no-op keeps actual snapshot")
        eq(describe(noop).functions[2].action,"keep-definition","unchanged action")
        local whitespace="-- leading comment\n"..source:gsub("counter%+n","counter + -- inside literal\n n").."\n-- trailing comment"
        list(view(must(discover(f,whitespace))).version_view.changed,"","comments and whitespace ignored")
        local strings=fixture("local function f() return 'a -- b' end")
        list(view(must(discover(strings,"local function f() return 'a -- c' end"))).version_view.changed,"f","opaque string bytes preserved")
        list(view(must(discover(strings,'local function f() return "a -- b" end'))).version_view.changed,"f","literal spelling conservatively changed")
        local numbers=fixture("local function f() return 1 end")
        list(view(must(discover(numbers,"local function f() return 1.0 end"))).version_view.changed,"f","numeric spelling preserved")
        list(view(must(discover(numbers,"local function f() return -1 end"))).version_view.changed,"f","operator preserved")
        changed=source:gsub("counter%+n","counter+n*10"):gsub("n%+100","n+200")
        local d=must(discover(f,changed));local v=view(d).version_view
        eq(v.base,base,"actual published baseline");eq(v.source.content,changed,"complete candidate retained")
        list(v.changed,"helper,other","all pending definitions discovered")
        eq(next(v.probes),nil,"comparison constructs no analysis closures")
        local p=must(prepare(f,d,{"local:pattern"}));local frag=fragment(p)
        selected(p,"helper","unchanged root selects changed dependency only")
        check(v.by_name.other.changed,"unrelated candidate remains pending")
        eq(frag.proposed_group.state.by_name.other.fn,initial.other,"unrelated function not proposed for publication")
        affected(p,"helper,pattern","post-selection effective impact")
        eq(#frag.cell_writes,1,"only helper cell write")
        eq(frag.cell_writes[1].before,initial.helper,"write old function identity")
        eq(#frag.raw_writes,0,"no callback publication")
        eq(p.restarts,nil,"no implicit restart context")
        eq(p.operation.base_snapshot.revision,0,"expected transaction revision")
        eq(p.operation.session_id,f.session,"selection session")
        eq(#frag.read_set,5,"all actual function identities held for recheck")
        check(#frag.capture_reads>0,"all old capture slots held for recheck")
        eq(v.by_name.other.probe,nil,"unselected changed definition not constructed")
        local presentation=describe(p)
        eq(presentation.functions[1].action,"compile-publish","changed action")
        eq(presentation.functions[2].action,"shared-impact","unchanged consumer action")
        eq(presentation.functions[3].action,"keep-definition","independent alias not propagated")
        local proposed=seal(p).proposed_snapshot;local next_state=state(proposed)
        eq(proposed.revision,1,"next transaction revision proposed")
        eq(initial_snapshot.revision,0,"old snapshot not advanced")
        eq(next_state.by_name.helper.definition_version,2,"only selected definition advances")
        eq(next_state.by_name.helper.fn,frag.cell_writes[1].value,"proposed new function identity")
        eq(next_state.by_name.pattern.definition_version,1,"consumer source version retained")
        eq(next_state.by_name.pattern.fn,initial.pattern,"consumer closure retained")
        eq(next_state.by_name.pattern.observed.helper,2,"consumer observed helper version advances")
        eq(base.by_name.pattern.observed.helper,1,"old observations not mutated")
        eq(next_state.by_name.other.definition_version,1,"pending source version retained")
        eq(next_state.by_name.other.signature,base.by_name.other.signature,"pending signature retained")
        eq(next_state.by_name.alias_user.observed.helper,nil,"alias has no helper observation")
        eq(proposed.loaded_source,source,"partial Apply never rewrites structural source")
        eq(Anchor.Get(entry,"helper"),initial.helper,"proposing is not commit")
        refuse(function() return Versions.Reads({base=next_state}) end,"stale","uninstalled proposed identities")
        local empty=selection(f,changed,{});selected(empty,"","empty roots select nothing")
        eq(seal(empty).proposed_snapshot,initial_snapshot,"empty selection cannot acknowledge file")
        list(view(d).version_view.changed,"helper,other","empty roots preserve pending definitions")
        selected(selection(f,changed,{"local:other"}),"other","independent root")
        selected(selection(f,changed,{"local:pattern","local:other"}),"helper,other","two roots source order")
        selected(selection(f,changed,{"local:other","local:pattern"}),"helper,other","root order irrelevant")
        selected(selection(f,changed,{"local:alias_user"}),"","alias never follows helper")
        local initializer=changed:gsub("local counter=0","local counter=error('initializer ran')")
        local preserve=selection(f,initializer,{"local:pattern"});local diag=describe(preserve).initializers
        eq(#diag,1,"initializer change diagnosed");eq(diag[1].name,"counter","state initializer name")
        eq(diag[1].action,"preserve-state","state preserved");eq(diag[1].requires_restart,true,"initializer requires restart")
        eq(Anchor.Get(entry,"counter"),0,"initializer not executed")
        eq(state(seal(preserve).proposed_snapshot).by_name.counter.signature,base.by_name.counter.signature,"initializer never marked published")
        eq(view(must(discover(f,source:gsub("local alias=helper","local alias=other")))).version_view.by_name.alias.initializer_changed,true,
            "alias initializer is state, not shared definition")
        list(view(must(discover(f,changed.."\nerror('candidate chunk ran')"))).version_view.changed,"helper,other","unknown top-level call never executed")
        list(view(must(discover(f,source:gsub("return counter%+n","error('body ran')")))).version_view.changed,"helper","body never executed")
        list(view(must(discover(f,source:gsub("counter%+n","counter+n*10").."\nfor i=1,0 do end"))).version_view.changed,"helper","unrelated top-level block never executed")
        local added=selection(f,source:gsub("return counter%+n","return counter+n+#config.tag"),{"local:pattern"})
        list(fragment(added).local_view.version_view.by_name.helper.dependencies,"config,counter","new capture of existing local")
        eq(#fragment(added).joins,2,"new capture joins planned")
        local shadow=selection(f,source:gsub("return helper%(n%)","local helper=function() return 9 end return helper(n)"),{"local:pattern"})
        list(fragment(shadow).local_view.version_view.by_name.pattern.dependencies,"","body shadow is not a graph edge")
        local removed=selection(f,source:gsub("return helper%(n%)","return n"),{"local:pattern"})
        list(fragment(removed).local_view.version_view.changed,"pattern","edge removal is definition change")
        list(fragment(removed).local_view.version_view.by_name.pattern.dependencies,"","removed dependency")
        selected(removed,"pattern","changed root with removed edge")
        local pending_edge=source:gsub("return helper%(n%)","return other(n)"):gsub("n%+100","n+200")
        local other_only=selection(f,pending_edge,{"local:other"})
        affected(other_only,"other","pending edge not used for actual propagation")
        eq(state(seal(other_only).proposed_snapshot).by_name.pattern.signature,base.by_name.pattern.signature,"changed edge in pending source retained")
        local forward=selection(f,pending_edge,{"local:pattern"})
        selected(forward,"pattern","later other local stays global")
        list(fragment(forward).local_view.version_view.by_name.pattern.dependencies,"","forward name not fabricated as capture")
        local edge_source="local function a() return 1 end\nlocal function b() return 2 end\nlocal function root() return a() end"
        local edges=fixture(edge_source);local edge_candidate=edge_source:gsub("return 2","return 20"):gsub("return a%(%)","return b()")
        selected(selection(edges,edge_candidate,{"local:root"}),"b,root","changed root follows visible new dependency")
        local b_only=selection(edges,edge_candidate,{"local:b"});affected(b_only,"b","pending root edge not actually published")
        eq(state(seal(b_only).proposed_snapshot).by_name.root.definition_version,1,"pending root source preserved")
        local chain_source="local function a() return 1 end\nlocal function b() return a() end\nlocal function c() return b() end"
        local chain=fixture(chain_source);local chain_p=selection(chain,chain_source:gsub("return 1","return 2"),{"local:c"})
        affected(chain_p,"a,b,c","transitive impact");selected(chain_p,"a","transitive selection avoids recompiling consumers")
        local chain_next=state(seal(chain_p).proposed_snapshot)
        eq(chain_next.by_name.c.observed.a,2,"transitive observed version");eq(chain_next.by_name.c.observed.b,1,"unchanged intermediate version")
        local cycle_source="local a,b\na=function(n) if n==0 then return 0 end return 1+b(n-1) end\nb=function(n) if n==0 then return 0 end return 2+a(n-1) end"
        local cycle=fixture(cycle_source);local cycle_p=selection(cycle,cycle_source:gsub("1%+b","10+b"):gsub("2%+a","20+a"),{"local:a"})
        selected(cycle_p,"a,b","cycle selection terminates")
        eq(state(seal(cycle_p).proposed_snapshot).by_name.a.observed.b,2,"cycle observations terminate")
        local recursive_source="local function f(n) if n==0 then return 0 end return 1+f(n-1) end"
        local recursive=fixture(recursive_source)
        selected(selection(recursive,recursive_source:gsub("1%+f","10+f"),{"local:f"}),"f","self recursion terminates")
        local global_source="local function f() return later end\nlocal later=7"
        local globals=fixture(global_source);list(state(globals.capture.snapshot).by_name.f.dependencies,"","unseen forward local remains global")
        eq(#fragment(selection(globals,global_source:gsub("return later","return later+1"),{"local:f"})).joins,0,"global not fabricated as local")
        local bom=fixture("\239\187\191"..source)
        list(view(must(discover(bom,"\239\187\191"..changed))).version_view.changed,"helper,other","BOM bytes preserved")
        local states=fixture("local a=false\nlocal b\nlocal c={}")
        eq(#Local.Roots(view(must(discover(states,states.entry.loaded_source)))),0,"no direct function roots")
        local state_p=selection(states,"local a=true\nlocal b\nlocal c={}",{})
        eq(#describe(state_p).initializers,1,"state-only initializer diagnostics")
        eq(seal(state_p).proposed_snapshot,states.capture.snapshot,"state-only no-op revision")
        -- Support refusals are now explicit per-root outcomes, not an old whole-report error.
        for _,case in ipairs({
            {changed.."\nlocal extra=1","local:pattern","add declaration"},
            {changed:gsub("local alias=helper\n",""),"local:pattern","remove declaration"},
            {changed:gsub("local counter=0","local count=0"),"local:pattern","rename declaration"},
            {changed.."\nreturn 3","local:pattern","top-level return"},
            {changed.."\nhelper=other","local:pattern","nonliteral overwrite"},
            {changed.."\nhelper=function() end","local:pattern","repeated definition"},
            {changed.."\nif false then helper=other end","local:pattern","conditional overwrite"},
            {changed:gsub("local alias=helper","local alias=function() end"),"local:alias_user","state becoming function requires restart"},
            {changed:gsub("local function other%(n%) return n%+200 end","local other=make()"),"local:other","function becoming unknown RHS"},
        }) do blocked(f,case[1],case[2],case[3]) end
        refuse(function() return discover(f,42) end,"unsupported","nonstring source")
        refuse(function() return discover(f,"local function helper( end") end,"compile","candidate syntax")
        refuse(function() return Local.Capture({},f.session) end,"ownership","bad entry")
        refuse(function() return Planning.Capture(entry,"") end,"ownership","empty session")
        refuse(function() return Planning.Capture(entry,1) end,"ownership","nonstr session")
        local saved=entry.map.helper;entry.map.helper=nil
        local missing,missing_err=Local.Capture(entry,f.session);entry.map.helper=saved
        refuse(function() return missing,missing_err end,"stale","missing first-load function identity")
        local roots_d=must(discover(f,changed))
        for _,roots in ipairs({{"local:pattern","local:pattern"},{"local:alias"},{"local:nope"},{[2]="local:pattern"},"local:pattern"}) do
            refuse(function() return Planning.Operation(f,roots_d,{root_ids=roots,refresh=f.refresh}) end,"ownership","invalid explicit root ids")
        end
        local meta_calls=0
        local meta=setmetatable({},{__index=function() meta_calls=meta_calls+1;error("metamethod ran") end})
        refuse(function() return Local.Capture(meta,f.session) end,"ownership","entry metatable")
        refuse(function() return Files.Publication(meta) end,"ownership","capture metatable")
        refuse(function() return Planning.Operation(f,roots_d,{root_ids=meta,refresh=f.refresh}) end,"ownership","root metatable")
        refuse(function() return Guard.Seal(meta,{}) end,"ownership","operation metatable")
        refuse(function() return Files.Publication({}) end,"ownership","bad capture")
        refuse(function() return Guard.Seal({}, {}) end,"ownership","wrong prepared operation")
        eq(meta_calls,0,"no metamethod calls")
        local original_slot=entry.slots.helper;entry.slots.helper=entry.slots.counter
        local drift,derr=Versions.Reads({base=base});entry.slots.helper=original_slot
        refuse(function() return drift,derr end,"stale","slot drift at live read boundary")
        entry.missing=true;local absent,aerr=Versions.Reads({base=base});entry.missing=nil
        refuse(function() return absent,aerr end,"stale","missing live anchor")
        local original_source=entry.loaded_source;entry.loaded_source=changed
        eq(Files.Validate(f.capture),false,"structural baseline rewrite invalidates capture");entry.loaded_source=original_source
        eq(joins,0,"zero premature join");eq(writes,0,"zero premature write");eq(flushes,0,"zero premature flush")
        debug.upvaluejoin,debug.setupvalue,_G.jit=original_join,original_set,original_jit
        -- Every publication uses a freshly prepared genuine discovery and one common transaction.
        local first=selection(f,changed,{"local:pattern"});local receipt=publish(f,first)
        eq(receipt.changed,true,"real first changed receipt");eq(receipt.snapshot,f.capture.snapshot,"receipt is actual publication")
        eq(f.capture.snapshot.revision,1,"first common transaction revision")
        eq(Anchor.Get(entry,"pattern"),initial.pattern,"old consumer kept");eq(initial.pattern(3),30,"old consumer sees helper-only update")
        eq(Anchor.Get(entry,"alias"),initial.helper,"alias identity kept");eq(Anchor.Get(entry,"alias_user")(3),3,"alias consumer not propagated")
        eq(Anchor.Get(entry,"other"),initial.other,"unapplied function kept")
        list(view(must(discover(f,changed))).version_view.changed,"other","partial Apply retains pending branch")
        local first_again=selection(f,changed,{"local:pattern"});local snapshot1=f.capture.snapshot
        selected(first_again,"","same selected branch not republished")
        eq(publish(f,first_again).changed,false,"same branch no-op receipt");eq(f.capture.snapshot,snapshot1,"same branch no revision advance")
        local second=publish(f,selection(f,changed,{"local:other"}));local s2=state(f.capture.snapshot)
        eq(second.snapshot.revision,2,"second partial transaction")
        eq(s2.by_name.helper.definition_version,2,"helper does not advance twice")
        eq(s2.by_name.pattern.definition_version,1,"wrapper never published")
        eq(s2.by_name.other.definition_version,2,"second branch version advances")
        list(view(must(discover(f,changed))).version_view.changed,"","both branches now published")
        eq(initial.other(3),103,"escaped old unrelated function unchanged");eq(Anchor.Get(entry,"other")(3),203,"second branch new function")
        initial.setter(11);eq(initial.pattern(3),41,"state setter still live")
        local newer=changed:gsub("n%*10","n*20");local third=publish(f,selection(f,newer,{"local:pattern"}))
        local s3=state(f.capture.snapshot)
        eq(third.snapshot.revision,3,"third transaction revision");eq(s3.by_name.helper.definition_version,3,"third helper publication version")
        eq(initial.pattern(3),71,"continuous helper changes");eq(s3.by_name.pattern.observed.helper,3,"observations distinguish helper version")
        eq(third.snapshot.loaded_source,source,"loaded source never accepted wholesale")
        refuse(function() return f.driver:CommitDiscovery(first,function() error("stale transaction entered") end) end,"ownership","old prepared snapshot after writes")
        must(Anchor.Set(entry,"helper",function() return 99 end))
        refuse(function() return Versions.Reads({base=s3}) end,"stale","external function setter not rebaselined")
        local csource="local x=1\nlocal function f() return x end"
        local cf=fixture(csource);local foreign=fixture("local x=2\nlocal function f() return x end")
        original_join(Anchor.Get(cf.entry,"f"),1,foreign.entry.anchor,foreign.entry.slots.x)
        refuse(function() return Versions.Reads({base=state(cf.capture.snapshot)}) end,"stale","external capture join detected")
        local independent=fixture(csource);local forged=must(Load.Capture(csource,{name="Versions_Boss.lua"}))
        must(Anchor.Set(forged,"f",Anchor.Get(independent.entry,"f")))
        forged.map.f=Anchor.Get(independent.entry,"f")
        refuse(function() return Local.Capture(forged,"forged") end,"stale","initial foreign cells not treated as sharing")
        -- Real shared-cell scenarios are mandatory; missing capabilities fail above.
        local function scenario(label,body)
            local success,reason=pcall(body)
            check(success,label..": "..(type(reason)=="string" and reason or "opaque error"))
        end
        scenario("edge removal and partial source baselines",function()
            local text="local function helper() return 1 end\nlocal function pattern() return helper() end\nlocal function root() return pattern() end"
            local e=fixture(text);local old_helper,old_pattern,old_root=Anchor.Get(e.entry,"helper"),Anchor.Get(e.entry,"pattern"),Anchor.Get(e.entry,"root")
            local candidate=text:gsub("return 1","return 2"):gsub("return helper%(%)","return 50")
            local helper_only=selection(e,candidate,{"local:helper"})
            list(fragment(helper_only).local_view.version_view.changed,"helper,pattern","both changed definitions visible")
            affected(helper_only,"helper,pattern,root","old edge propagates before pending removal")
            eq(state(seal(helper_only).proposed_snapshot).by_name.pattern.definition_version,1,"removal stays pending")
            publish(e,helper_only);local s1=state(e.capture.snapshot)
            eq(old_root(),2,"actual pending wrapper still follows helper");eq(s1.by_name.pattern.definition_version,1,"pending removal source version untouched")
            eq(s1.by_name.root.observed.helper,2,"actual old graph observation advances")
            local remove_edge=selection(e,candidate,{"local:pattern"})
            selected(remove_edge,"pattern","second transaction removes edge");affected(remove_edge,"pattern,root","removal impacts old root")
            publish(e,remove_edge);local s=state(e.capture.snapshot)
            eq(old_root(),50,"old root reads new pattern");eq(old_pattern(),2,"escaped old pattern is different definition")
            eq(old_helper(),1,"escaped old helper never rewritten");eq(s.by_name.root.observed.helper,nil,"new runtime graph stops observing helper")
            eq(s.by_name.root.observed.pattern,2,"root observes pattern version");eq(s.by_name.root.definition_version,1,"root source initial version")
            list(view(must(discover(e,candidate))).version_view.changed,"","both branches published")
            local further=candidate:gsub("return 2","return 3");local nochange=selection(e,further,{"local:root"})
            selected(nochange,"","root no longer requests removed helper")
            eq(fragment(nochange).local_view.version_view.by_name.helper.changed,true,"unreachable helper pending")
            local before=e.capture.snapshot;eq(publish(e,nochange).changed,false,"no-op changed receipt false");eq(e.capture.snapshot,before,"no-op no revision")
            publish(e,selection(e,further,{"local:helper"}))
            eq(old_root(),50,"removed edge never resurrected");eq(old_pattern(),3,"escaped old pattern still shares helper cell")
            eq(state(e.capture.snapshot).by_name.root.observed.helper,nil,"escaped closure not falsely current definition")
        end)
        scenario("new captures and changing state after preparation",function()
            local text="local state=nil\nlocal enabled=false\nlocal config={tag='old'}\nlocal function helper() return 1 end\nlocal function root() return helper() end"
            local e=fixture(text);local old_root=Anchor.Get(e.entry,"root")
            local candidate=text:gsub("return 1","return state,enabled,config.tag"):gsub("local state=nil\n","local state=error('initialization replayed')\n")
            local p=selection(e,candidate,{"local:root"})
            eq(#fragment(p).joins,3,"all new captures are existing cells");eq(#fragment(p).cell_writes,1,"new capture only helper write")
            eq(Anchor.Get(e.entry,"state"),nil,"nil state retained before commit")
            must(Anchor.Set(e.entry,"state",{tick=7}));must(Anchor.Set(e.entry,"enabled",true));must(Anchor.Set(e.entry,"config",{tag="live"}))
            publish(e,p);local s=state(e.capture.snapshot);local a,b,c=old_root()
            eq(a.tick,7,"ordinary state not frozen by preparation");eq(b,true,"boolean cell not frozen");eq(c,"live","whole-table replacement read live")
            eq(s.by_name.helper.definition_version,2,"new capture body version");eq(s.by_name.root.definition_version,1,"new capture does not republish root")
            local stable=selection(e,candidate,{"local:root"})
            eq(#describe(stable).initializers,1,"unapplied initializer still pending diagnostic")
            list(fragment(stable).local_view.version_view.changed,"","function source already published")
            must(Anchor.Set(e.entry,"state",false));must(Anchor.Set(e.entry,"enabled",nil));must(Anchor.Set(e.entry,"config",{tag="replaced-again"}))
            a,b,c=old_root();eq(a,false,"false state after commit");eq(b,nil,"nil state after commit");eq(c,"replaced-again","table changes after commit")
            selected(stable,"","state mutation alone not definition change")
            local before=e.capture.snapshot;eq(publish(e,stable).changed,false,"state-only no changed receipt");eq(e.capture.snapshot,before,"state mutation no revision")
            local remainder=must(Planning.Remaining(e,must(Source.Build(candidate)),e.generation,e.refresh))
            check(not remainder.complete,"retained initializer prevents whole-file completion")
        end)
        scenario("mutual recursion selected as one necessary group",function()
            local text=cycle_source;local e=fixture(text);local old_a,old_b=Anchor.Get(e.entry,"a"),Anchor.Get(e.entry,"b")
            local candidate=text:gsub("1%+b","10+b"):gsub("2%+a","20+a")
            local p=selection(e,candidate,{"local:b"});selected(p,"a,b","recursive dependencies selected together")
            eq(#fragment(p).cell_writes,2,"deduplicated cycle writes");eq(#fragment(p).joins,2,"deduplicated cycle joins")
            eq(old_a(2),3,"old recursive state unchanged by selection");publish(e,p)
            eq(Anchor.Get(e.entry,"a")(2),30,"new recursive a");eq(Anchor.Get(e.entry,"b")(2),30,"new recursive b")
            eq(old_a(2),21,"escaped old a calls new b");eq(old_b(2),12,"escaped old b calls new a")
            local s=state(e.capture.snapshot);eq(s.by_name.a.observed.b,2,"a observes b version");eq(s.by_name.b.observed.a,2,"b observes a version")
            eq(e.capture.snapshot.revision,1,"cycle one common transaction")
            local another=candidate:gsub("10%+b","100+b");local p2=selection(e,another,{"local:b"});selected(p2,"a","unchanged recursive consumer not replaced")
            publish(e,p2);s=state(e.capture.snapshot)
            eq(s.by_name.a.definition_version,3,"a advances again");eq(s.by_name.b.definition_version,2,"b source stable")
            eq(s.by_name.b.observed.a,3,"b shared observation advances");eq(Anchor.Get(e.entry,"b")(2),120,"unchanged b reads second a")
        end)
        scenario("unchanged literal initializer self is global",function()
            local saved_f=rawget(_G,"f");local text="local f=function() return f end";local e=fixture(text)
            _G.f=7;eq(Anchor.Get(e.entry,"f")(),7,"literal initializer global self")
            local p=selection(e,text:gsub("return f","return f+1"),{"local:f"})
            eq(#fragment(p).joins,0,"global self never wired to anchor");publish(e,p)
            eq(Anchor.Get(e.entry,"f")(),8,"updated literal keeps global self")
            eq(state(e.capture.snapshot).by_name.f.observed.f,nil,"not recursive local graph");_G.f=saved_f
        end)
        scenario("hot old consumers with partial publication",function()
            local text="local function a() return 1 end\nlocal function b() return a() end\nlocal function c() return b() end\nlocal independent=a"
            local e=fixture(text);local old_c,alias=Anchor.Get(e.entry,"c"),Anchor.Get(e.entry,"independent")
            local acc=0;for _=1,10000 do acc=acc+old_c() end
            eq(acc,10000,"old consumers warmed with ordinary JIT enabled")
            publish(e,selection(e,text:gsub("return 1","return 20"),{"local:c"}))
            acc=0;for _=1,10000 do acc=acc+old_c() end
            eq(acc,200000,"hot old consumers read new a after cell commit");eq(alias(),1,"independent function copy not refreshed")
            local s=state(e.capture.snapshot)
            eq(s.by_name.b.definition_version,1,"hot intermediate not republished");eq(s.by_name.c.definition_version,1,"hot root not republished")
            eq(s.by_name.c.observed.a,2,"transitive observation of hot changed definition");eq(s.by_name.c.fn,old_c,"hot root closure kept")
        end)
        -- Public capture/proposal hardening. Local private state is owner-produced,
        -- not an arbitrary user-supplied old snapshot/identity map accepted by Compare.
        scenario("public snapshot input hardening",function()
            local clean=fixture(source);local actual=clean.capture.snapshot
            local function copy(t) local out={};for k,v in pairs(t) do out[k]=v end;return out end
            local function bad_snapshot(change,label)
                local bad=copy(clean.capture);bad.snapshot=copy(actual);change(bad.snapshot)
                eq(Files.Validate(bad),false,label.." invalid")
                refuse(function() return Files.Publication(bad) end,"ownership",label.." cannot enter discovery")
                eq(clean.capture.snapshot,actual,label.." actual snapshot untouched")
            end
            for _,bad in ipairs({-1,0/0,math.huge,0.5,"1"}) do bad_snapshot(function(s) s.revision=bad end,"bad revision "..tostring(bad)) end
            for _,case in ipairs({
                {"kind","wrong"},{"version",2},{"session_id",""},{"anchor",function() end},
            }) do bad_snapshot(function(s) s[case[1]]=case[2] end,"bad snapshot "..case[1]) end
            bad_snapshot(function(s) s.owners={actual.owners[1],actual.owners[1]} end,"duplicate owner")
            bad_snapshot(function(s) s.owners={[2]=actual.owners[2]} end,"owner array hole")
            local function bad_group(change,label)
                bad_snapshot(function(s)
                    s.owners={copy(actual.owners[1]),actual.owners[2]}
                    local g=s.owners[1];g.records={};for i,r in ipairs(actual.owners[1].records) do g.records[i]=copy(r) end
                    change(g)
                end,label)
            end
            bad_group(function(g) g.records[#g.records+1]=g.records[1] end,"duplicate publication record")
            bad_group(function(g) g.records[1]=nil end,"record array hole")
            bad_group(function(g) g.units={} end,"unowned graph record")
            for _,bad in ipairs({-1,0,0.5,math.huge,0/0,"1"}) do
                bad_group(function(g) g.records[1].definition_version=bad end,"bad definition version "..tostring(bad))
            end
            bad_group(function(g) g.records[1].definition_version=2 end,"record version disagrees with private definition")
            -- Original name/capture-array guarantees now come from genuine full
            -- syntax and owner records; assert their generated invariants directly.
            local s=state(actual);local seen={}
            for i,name in ipairs(s.names) do
                check(type(name)=="string" and not seen[name],"dense unique original name "..i);seen[name]=true
                local unit=s.by_name[name];check(type(unit)=="table" and unit.name==name,"every name has private record")
                local dependencies={}
                for n,dep in ipairs(unit.dependencies) do
                    check(type(dep)=="string" and not dependencies[dep] and s.by_name[dep]~=nil,"dense unique actual capture "..n)
                    dependencies[dep]=true
                end
            end
            for name in pairs(s.by_name) do check(seen[name],"no unlisted private binding record") end
            eq(s.kind,Versions.Kind,"private state kind");eq(s.version,Versions.Version,"private state protocol")
            eq(s.session_id,actual.session_id,"private session same as common scope")
            eq(s.anchor,actual.anchor,"private anchor same as common scope")
            eq(type(clean.capture.initial_owners[1].evidence.projection.initializers),"table","original initializer baseline retained")
        end)
    end)
    debug.upvaluejoin,debug.setupvalue,_G.jit=original_join,original_set,original_jit
    rawset(_G,"f",original_f)
    for _,controller in ipairs(controllers) do
        local released,reason=controller:Release()
        check(released==true,"controller released: "..(type(reason)=="table" and reason.message or ""))
    end
    check(ok,"version suite: "..(type(problem)=="string" and problem or "opaque error"))
    for _,label in ipairs(failures) do print("[FunctionVersions migrated] FAIL "..label) end
    return {passed=passed,failed=failed,failures=failures}
end
return M
