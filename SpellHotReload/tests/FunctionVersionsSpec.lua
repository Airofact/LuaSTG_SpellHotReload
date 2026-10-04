local M = {}
function M.run()
    local Versions = require("SpellHotReload.FunctionVersions")
    local Plan = require("SpellHotReload.FunctionPlan")
    local Anchor = require("SpellHotReload.Anchor")
    local Compose = require("SpellHotReload.Compose")
    local passed, failed, failures = 0, 0, {}
    local function check(value, label)
        if value then passed = passed + 1 else
            failed = failed + 1; failures[#failures + 1] = label
        end
    end
    local function eq(a, b, label) check(a == b, label .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
    local function list(a, expected, label) eq(table.concat(a, ","), expected, label) end
    local function refuse(fn, code, label)
        local value, err = fn()
        eq(value, nil, label .. " rejected")
        eq(type(err), "table", label .. " structured error")
        if type(err) == "table" then
            eq(err.code, code, label .. " code")
            check(type(err.message) == "string" and err.message ~= "", label .. " message")
        end
    end
    local caps = { getupvalue = true, setupvalue = true, upvaluejoin = true }
    local function capture(source)
        local entry = assert(Anchor.Capture(source, { name = "Versions_Boss.lua", capability = caps }))
        entry.file = "Versions_Boss.lua"
        return entry
    end
    -- This helper is ONLY first-load synthetic test setup, never a production
    -- recipe for rebasing after an external setter or partial commit.
    local function seed(entry)
        local scan = assert(Plan.Inspect(entry.loaded_source))
        local initial = {}
        for name in pairs(scan.definitions) do initial[name] = assert(Anchor.Get(entry, name)) end
        local state, err = Versions.Seed(entry, "session-1", initial)
        assert(state, err and err.message)
        return state, initial
    end
    local function compare(state, content)
        local value, err = Versions.Compare(state, content)
        assert(value, err and err.message)
        return value
    end
    local function select_report(report, roots)
        local value, err = Versions.Select(report, roots)
        assert(value, err and err.message)
        return value
    end
    local function commit(selection)
        -- Test-only manual commit; no production atomicity/phase/rollback claim.
        for _, item in ipairs(selection.functions) do assert(Compose.Join(item.join_plan)) end
        for _, write in ipairs(selection.writes) do assert(Anchor.Set(selection.entry, write.name, write.value)) end
        return assert(Versions.Next(selection))
    end
    local source = table.concat({
        "local counter=0", "local config={tag='old'}",
        "local function helper(n) return counter+n end",
        "local function pattern(n) return helper(n) end",
        "local alias=helper",
        "local function alias_user(n) return alias(n) end",
        "local function other(n) return n+100 end",
        "local function setter(n) counter=n end",
    }, "\n")
    local entry = capture(source)
    local initial = {}
    for _, name in ipairs({"helper","pattern","alias_user","other","setter"}) do
        initial[name] = Anchor.Get(entry, name)
    end
    if type(debug.upvaluejoin) ~= "function" then
        refuse(function() return Versions.Seed(entry,"session-1",initial) end,
            "capability", "real no-join seed")
    end
    local original_join, original_set, original_jit = debug.upvaluejoin, debug.setupvalue, rawget(_G,"jit")
    local joins, writes, flushes = 0, 0, 0
    debug.upvaluejoin = function() joins=joins+1; error("premature join") end
    debug.setupvalue = function() writes=writes+1; error("premature write") end
    _G.jit = { flush=function() flushes=flushes+1; error("premature flush") end }
    local state, changed, selection
    local ok, problem = pcall(function()
        state = assert(Versions.Seed(entry,"session-1",initial))
        eq(Versions.Kind,"SpellHotReload.FunctionVersions","kind")
        eq(Versions.Version,1,"version")
        eq(state.revision,0,"initial transaction revision")
        eq(state.session_id,"session-1","session carried")
        eq(state.entry,entry,"loaded entry held")
        eq(state.anchor,entry.anchor,"unique anchor held")
        eq(state.loaded_source,source,"initial structural source held")
        list(state.names,"helper,pattern,alias_user,other,setter","source order")
        list(state.units.helper.dependencies,"counter","actual helper upvalue")
        list(state.units.pattern.dependencies,"helper","actual consumer upvalue")
        list(state.units.alias_user.dependencies,"alias","alias is its own cell")
        eq(state.units.pattern.observed.helper,1,"initial dependency observation")
        eq(state.units.alias_user.observed.helper,nil,"alias does not observe helper version")
        eq(state.units.helper.fn,initial.helper,"genuine published identity held")
        eq(state.units.alias,nil,"alias not a function definition")
        eq(state.units.counter,nil,"state not a function definition")
        eq(state.units.helper.definition_version,1,"initial per-definition version")
        eq(#assert(Plan.Inspect(source)).bindings.names,8,"shared inspection declaration count")
        local inspection = assert(Plan.Inspect(source .. "\nerror('chunk ran')"))
        eq(#inspection.definitions.helper,1,"inspection never executes chunk")
        refuse(function() return Plan.Inspect("local function f( end") end,"compile","inspection syntax")
        local same = compare(state,source)
        list(same.changed,"","unchanged source")
        list(same.affected,"","unchanged impact")
        eq(same.by_name.pattern.action,"keep-definition","unchanged action")
        local no_op = select_report(same,{"pattern"})
        eq(#no_op.writes,0,"unchanged root no write")
        eq(Versions.Next(no_op),state,"no-op returns same snapshot")
        local whitespace = source:gsub("counter%+n","counter + -- inside literal\n n")
        whitespace = "-- leading comment\n" .. whitespace .. "\n-- trailing comment"
        list(compare(state,whitespace).changed,"","comments and whitespace ignored")
        local string_source = "local function f() return 'a -- b' end"
        local strings = capture(string_source)
        local string_state = seed(strings)
        list(compare(string_state,string_source:gsub("a %-%- b","a -- c")).changed,"f","opaque string bytes preserved")
        list(compare(string_state,string_source:gsub("'a %-%- b'",'"a -- b"')).changed,"f","literal spelling conservatively changed")
        local number_source = "local function f() return 1 end"
        local numbers = capture(number_source)
        local number_state = seed(numbers)
        list(compare(number_state,number_source:gsub("return 1","return 1.0")).changed,"f","numeric spelling preserved")
        list(compare(number_state,number_source:gsub("return 1","return -1")).changed,"f","operator preserved")

        changed = source:gsub("counter%+n","counter+n*10"):gsub("n%+100","n+200")
        local report = compare(state,changed)
        eq(report.scope,"local-functions","honest scope")
        eq(report.base,state,"actual published baseline")
        eq(report.content,changed,"complete candidate retained")
        list(report.changed,"helper,other","all pending definitions discovered")
        list(report.affected,"helper,pattern,other","reverse shared impact")
        eq(report.by_name.helper.action,"compile-write","changed action")
        eq(report.by_name.pattern.action,"shared-impact","unchanged consumer action")
        eq(report.by_name.alias_user.action,"keep-definition","independent alias not propagated")
        eq(#report.prepared.functions,5,"analysis closures are not publication selection")
        check(#report.capture_reads>0,"old binding identities included in read set")
        selection = select_report(report,{"pattern"})
        list(selection.selected,"helper","unchanged root selects changed dependency only")
        list(selection.pending,"other","unrelated candidate branch pending")
        list(selection.affected,"helper,pattern","post-selection effective impact")
        eq(#selection.functions,1,"only helper scheduled for publication")
        eq(#selection.writes,1,"only helper cell write")
        eq(selection.writes[1].before,initial.helper,"write old function identity")
        eq(#selection.publications,0,"no Card publication")
        eq(#selection.restarts,0,"no implicit restart")
        eq(selection.base_revision,0,"expected transaction revision")
        eq(selection.session_id,"session-1","selection session")
        eq(#selection.read_set,5,"all analyzed identities held for R4 recheck")
        eq(#selection.capture_reads,#report.capture_reads,"all old capture slots held for R4 recheck")
        local next_state = assert(Versions.Next(selection))
        eq(next_state.revision,1,"next transaction revision proposed")
        eq(state.revision,0,"old snapshot not advanced")
        eq(next_state.units.helper.definition_version,2,"only selected definition advances")
        eq(next_state.units.helper.fn,selection.functions[1].created.fn,"proposed new function identity")
        eq(next_state.units.pattern.definition_version,1,"consumer source version retained")
        eq(next_state.units.pattern.fn,initial.pattern,"consumer closure retained")
        eq(next_state.units.pattern.observed.helper,2,"consumer observed helper version advances")
        eq(state.units.pattern.observed.helper,1,"old observations not mutated")
        eq(next_state.units.other.definition_version,1,"pending source version retained")
        eq(next_state.units.other.signature,state.units.other.signature,"pending signature retained")
        eq(next_state.units.alias_user.observed.helper,nil,"alias has no helper observation")
        eq(next_state.loaded_source,source,"partial Apply never rewrites structural source")
        eq(Anchor.Get(entry,"helper"),initial.helper,"Next is not commit")
        refuse(function() return Versions.Compare(next_state,changed) end,"stale","uninstalled proposed snapshot")
        local empty = select_report(report,{})
        list(empty.selected,"","empty roots select nothing")
        list(empty.pending,"helper,other","empty roots preserve all pending")
        eq(Versions.Next(empty),state,"empty selection cannot acknowledge whole file")
        list(select_report(report,{"other"}).selected,"other","independent root")
        list(select_report(report,{"pattern","other"}).selected,"helper,other","two roots source order")
        list(select_report(report,{"other","pattern"}).selected,"helper,other","root order irrelevant")
        list(select_report(report,{"alias_user"}).selected,"","alias never follows helper")
        list(select_report(report,{"alias_user"}).pending,"helper,other","alias keeps helper pending")
        local initializer = changed:gsub("local counter=0","local counter=error('initializer ran')")
        local preserve = compare(state,initializer)
        eq(#preserve.initializers,1,"initializer change diagnosed")
        eq(preserve.initializers[1].name,"counter","state initializer name")
        eq(preserve.initializers[1].action,"preserve-state","state preserved")
        eq(preserve.initializers[1].requires_restart,true,"adopting initializer requires restart")
        eq(Anchor.Get(entry,"counter"),0,"initializer not executed")
        local preserve_next = assert(Versions.Next(select_report(preserve,{"pattern"})))
        eq(preserve_next.initializers.counter,state.initializers.counter,"initializer never marked published")
        eq(#compare(state,source:gsub("local alias=helper","local alias=other")).initializers,1,
            "alias initializer is state, not a shared definition")
        list(compare(state,changed.."\nerror('candidate chunk ran')").changed,"helper,other","unknown top-level call never executed")
        list(compare(state,source:gsub("return counter%+n","error('body ran')")).changed,"helper","body never executed")
        local bombs = source:gsub("counter%+n","counter+n*10") .. "\nfor i=1,0 do end"
        list(compare(state,bombs).changed,"helper","unrelated top-level block not executed")

        local newly_used = source:gsub("return counter%+n","return counter+n+#config.tag")
        local new_report = compare(state,newly_used)
        list(new_report.by_name.helper.dependencies,"config,counter","new capture of existing local")
        eq(#select_report(new_report,{"pattern"}).joins,2,"new capture joins planned")
        local shadow = source:gsub("return helper%(n%)","local helper=function() return 9 end return helper(n)")
        list(compare(state,shadow).by_name.pattern.dependencies,"","body shadow is not a graph edge")
        local removal = source:gsub("return helper%(n%)","return n")
        local removed = compare(state,removal)
        list(removed.changed,"pattern","edge removal is definition change")
        list(removed.by_name.pattern.dependencies,"","removed dependency")
        list(select_report(removed,{"pattern"}).selected,"pattern","changed root with removed edge")
        local pending_edge = source:gsub("return helper%(n%)","return other(n)"):gsub("n%+100","n+200")
        local pending_report = compare(state,pending_edge)
        local other_only = select_report(pending_report,{"other"})
        list(other_only.pending,"pattern","changed edge in pending source retained")
        list(other_only.affected,"other","pending edge not used for actual propagation")
        list(select_report(pending_report,{"pattern"}).selected,"pattern","later other local stays global")
        list(pending_report.by_name.pattern.dependencies,"","forward name not fabricated as capture")
        local edge_source = "local function a() return 1 end\nlocal function b() return 2 end\n"
            .. "local function root() return a() end"
        local edge_entry = capture(edge_source)
        local edge_state = seed(edge_entry)
        local edge_candidate = edge_source:gsub("return 2","return 20"):gsub("return a%(%)","return b()")
        local edge_report = compare(edge_state,edge_candidate)
        list(select_report(edge_report,{"root"}).selected,"b,root","changed root follows visible new dependency")
        list(select_report(edge_report,{"b"}).affected,"b","pending root edge not actually published")
        list(select_report(edge_report,{"b"}).pending,"root","pending root source preserved")

        local chain_source = "local function a() return 1 end\nlocal function b() return a() end\nlocal function c() return b() end"
        local chain_entry = capture(chain_source)
        local chain_state = seed(chain_entry)
        local chain_diff = compare(chain_state,chain_source:gsub("return 1","return 2"))
        list(chain_diff.affected,"a,b,c","transitive impact")
        list(select_report(chain_diff,{"c"}).selected,"a","transitive selection avoids recompiling consumers")
        local chain_next = assert(Versions.Next(select_report(chain_diff,{"c"})))
        eq(chain_next.units.c.observed.a,2,"transitive observed version")
        eq(chain_next.units.c.observed.b,1,"unchanged intermediate version")
        local cycle_source = "local a,b\na=function(n) if n==0 then return 0 end return 1+b(n-1) end\n"
            .. "b=function(n) if n==0 then return 0 end return 2+a(n-1) end"
        local cycle_entry = capture(cycle_source)
        local cycle_state = seed(cycle_entry)
        local cycle_diff = compare(cycle_state,cycle_source:gsub("1%+b","10+b"):gsub("2%+a","20+a"))
        list(cycle_diff.changed,"a,b","cycle both changed")
        list(select_report(cycle_diff,{"a"}).selected,"a,b","cycle selection terminates")
        eq(assert(Versions.Next(select_report(cycle_diff,{"a"}))).units.a.observed.b,2,"cycle observations terminate")
        local recursive_source = "local function f(n) if n==0 then return 0 end return 1+f(n-1) end"
        local recursive_entry = capture(recursive_source)
        local recursive_state = seed(recursive_entry)
        local recursive_diff = compare(recursive_state,recursive_source:gsub("1%+f","10+f"))
        list(select_report(recursive_diff,{"f"}).selected,"f","self recursion terminates")
        local global_source = "local function f() return later end\nlocal later=7"
        local global_entry = capture(global_source)
        local global_state = seed(global_entry)
        list(global_state.units.f.dependencies,"","unseen forward local remains global")
        local global_diff = compare(global_state,global_source:gsub("return later","return later+1"))
        eq(#select_report(global_diff,{"f"}).joins,0,"global not fabricated as local")
        local bom_entry = capture("\239\187\191"..source)
        local bom_state = seed(bom_entry)
        list(compare(bom_state,"\239\187\191"..changed).changed,"helper,other","BOM bytes preserved")
        local state_only = capture("local a=false\nlocal b\nlocal c={}")
        local state_only_versions = seed(state_only)
        eq(#state_only_versions.names,0,"no direct functions supported")
        eq(#compare(state_only_versions,"local a=true\nlocal b\nlocal c={}").initializers,1,"state-only initializer diagnostics")
        eq(Versions.Next(select_report(compare(state_only_versions,state_only.loaded_source),{})),
            state_only_versions,"state-only no-op revision")

        for _, test in ipairs({
            {function() return Versions.Seed({},"s",{}) end,"unsupported","bad entry"},
            {function() return Versions.Seed(entry,"",initial) end,"unsupported","empty session"},
            {function() return Versions.Seed(entry,1,initial) end,"unsupported","nonstr session"},
            {function() return Versions.Seed(entry,"s",{}) end,"stale","missing initial functions"},
            {function() local v={} for k,f in pairs(initial) do v[k]=f end v.alias=initial.helper return Versions.Seed(entry,"s",v) end,
                "unsupported","extra initial alias"},
            {function() return Versions.Compare({},changed) end,"unsupported","bad snapshot"},
            {function() return Versions.Compare(state,42) end,"unsupported","nonstring source"},
            {function() return Versions.Compare(state,"local function helper( end") end,"compile","candidate syntax"},
            {function() return Versions.Compare(state,changed.."\nlocal extra=1") end,"unsupported","add declaration"},
            {function() return Versions.Compare(state,changed:gsub("local alias=helper\n","")) end,"unsupported","remove declaration"},
            {function() return Versions.Compare(state,changed:gsub("local counter=0","local count=0")) end,"unsupported","rename declaration"},
            {function() return Versions.Compare(state,changed.."\nreturn 3") end,"unsupported","top-level return"},
            {function() return Versions.Compare(state,changed.."\nhelper=other") end,"unsupported","nonliteral overwrite"},
            {function() return Versions.Compare(state,changed.."\nhelper=function() end") end,"unsupported","repeated definition"},
            {function() return Versions.Compare(state,changed.."\nif false then helper=other end") end,"unsupported","conditional overwrite"},
            {function() return Versions.Compare(state,changed:gsub("local alias=helper","local alias=function() end")) end,
                "unsupported","state becoming function requires restart"},
            {function() return Versions.Compare(state,changed:gsub("local function other%(n%) return n%+200 end","local other=make()")) end,
                "unsupported","function becoming unknown RHS"},
            {function() return Versions.Select(report,{"pattern","pattern"}) end,"unsupported","duplicate root"},
            {function() return Versions.Select(report,{"alias"}) end,"unsupported","alias cannot be function root"},
            {function() return Versions.Select(report,{"nope"}) end,"unsupported","unknown root"},
            {function() return Versions.Select(report,{[2]="pattern"}) end,"unsupported","root hole"},
            {function() return Versions.Select(report,"pattern") end,"unsupported","nondense roots"},
            {function() return Versions.Select({}, {}) end,"unsupported","wrong diff"},
            {function() return Versions.Next({}) end,"unsupported","wrong selection"},
        }) do refuse(test[1],test[2],test[3]) end
        local meta_calls=0
        local meta=setmetatable({}, {__index=function() meta_calls=meta_calls+1; error("metamethod ran") end})
        refuse(function() return Versions.Seed(meta,"s",initial) end,"unsupported","entry metatable")
        refuse(function() return Versions.Seed(entry,"s",meta) end,"unsupported","identity metatable")
        refuse(function() return Versions.Compare(meta,changed) end,"unsupported","snapshot metatable")
        refuse(function() return Versions.Select(report,meta) end,"unsupported","root metatable")
        refuse(function() return Versions.Next(meta) end,"unsupported","selection metatable")
        eq(meta_calls,0,"no metamethod calls")
        local original_slot=entry.slots.helper
        entry.slots.helper=entry.slots.counter
        refuse(function() return Versions.Compare(state,changed) end,"stale","slot drift")
        entry.slots.helper=original_slot
        entry.missing=true
        refuse(function() return Versions.Compare(state,changed) end,"stale","missing live anchor")
        entry.missing=nil
        local original_source=entry.loaded_source
        entry.loaded_source=changed
        refuse(function() return Versions.Compare(state,changed) end,"unsupported","structural baseline rewritten")
        entry.loaded_source=original_source
        eq(joins,0,"zero premature join")
        eq(writes,0,"zero premature write")
        eq(flushes,0,"zero premature flush")
    end)
    debug.upvaluejoin,debug.setupvalue,_G.jit=original_join,original_set,original_jit
    check(ok,"metadata suite: "..tostring(problem))
    if ok and type(original_join)=="function" then
        local next_state=commit(selection)
        eq(next_state.revision,1,"test commit revision")
        eq(Anchor.Get(entry,"pattern"),initial.pattern,"old consumer kept")
        eq(initial.pattern(3),30,"old consumer sees helper-only update")
        eq(Anchor.Get(entry,"alias"),initial.helper,"alias identity kept")
        eq(Anchor.Get(entry,"alias_user")(3),3,"alias consumer not propagated")
        eq(Anchor.Get(entry,"other"),initial.other,"unapplied function kept")
        local remaining=compare(next_state,changed)
        list(remaining.changed,"other","partial Apply retains pending branch")
        local first_again=select_report(remaining,{"pattern"})
        eq(#first_again.writes,0,"same selected branch not republished")
        eq(Versions.Next(first_again),next_state,"same branch no revision advance")
        local second_selection=select_report(remaining,{"other"})
        local second_state=commit(second_selection)
        eq(second_state.revision,2,"second partial transaction")
        eq(second_state.units.helper.definition_version,2,"helper does not advance twice")
        eq(second_state.units.pattern.definition_version,1,"wrapper never published")
        eq(second_state.units.other.definition_version,2,"second branch version advances")
        list(compare(second_state,changed).changed,"","both branches now published")
        eq(initial.other(3),103,"escaped old unrelated function unchanged")
        eq(Anchor.Get(entry,"other")(3),203,"second branch new function")
        initial.setter(11)
        eq(initial.pattern(3),41,"state setter still live")
        local newer=changed:gsub("n%*10","n*20")
        local third_selection=select_report(compare(second_state,newer),{"pattern"})
        local third_state=commit(third_selection)
        eq(third_state.revision,3,"third transaction revision")
        eq(third_state.units.helper.definition_version,3,"third helper publication version")
        eq(initial.pattern(3),71,"continuous helper changes")
        eq(third_state.units.pattern.observed.helper,3,"observations distinguish helper version")
        eq(third_state.loaded_source,source,"loaded source never accepted wholesale")
        refuse(function() return Versions.Compare(state,changed) end,"stale","old snapshot after writes")
        assert(Anchor.Set(entry,"helper",function() return 99 end))
        refuse(function() return Versions.Compare(third_state,newer) end,"stale","external function setter not rebaselined")
        local csource="local x=1\nlocal function f() return x end"
        local centry=capture(csource)
        local cstate=seed(centry)
        local foreign=capture("local x=2\nlocal function f() return x end")
        local cf=Anchor.Get(centry,"f")
        original_join(cf,1,foreign.anchor,foreign.slots.x)
        refuse(function() return Versions.Compare(cstate,csource) end,"stale","external capture join detected")
        local independent=capture("local x=1\nlocal function f() return x end")
        local forged=capture(csource)
        assert(Anchor.Set(forged,"f",Anchor.Get(independent,"f")))
        refuse(function() return Versions.Seed(forged,"s",{f=Anchor.Get(independent,"f")}) end,
            "stale","initial foreign cells not treated as sharing")
    end
    -- Real cell-sharing integration cases are deliberately separate from the
    -- metadata suite with presence stubs. They never run on plain Lua 5.1.
    if type(original_join)=="function" then
        local function scenario(label, fn)
            local success, reason=pcall(fn)
            check(success,label..": "..tostring(reason))
        end
        scenario("edge removal and partial source baselines",function()
            local text="local function helper() return 1 end\n"
                .. "local function pattern() return helper() end\n"
                .. "local function root() return pattern() end"
            local e=capture(text)
            local s=seed(e)
            local old_helper,old_pattern,old_root=Anchor.Get(e,"helper"),Anchor.Get(e,"pattern"),Anchor.Get(e,"root")
            local candidate=text:gsub("return 1","return 2"):gsub("return helper%(%)","return 50")
            local diff=compare(s,candidate)
            list(diff.changed,"helper,pattern","both changed definitions visible")
            local helper_only=select_report(diff,{"helper"})
            list(helper_only.affected,"helper,pattern,root","old edge propagates before pending removal")
            list(helper_only.pending,"pattern","removal stays pending")
            local s1=commit(helper_only)
            eq(old_root(),2,"actual pending wrapper still follows helper")
            eq(s1.units.pattern.definition_version,1,"pending removal source version untouched")
            eq(s1.units.root.observed.helper,2,"actual old graph observation advances")
            local remove_edge=select_report(compare(s1,candidate),{"pattern"})
            list(remove_edge.selected,"pattern","second transaction removes the edge")
            list(remove_edge.affected,"pattern,root","removal impacts old root")
            local s2=commit(remove_edge)
            eq(old_root(),50,"old root reads new pattern")
            eq(old_pattern(),2,"escaped old pattern remains a different definition")
            eq(old_helper(),1,"escaped old helper never rewritten")
            eq(s2.units.root.observed.helper,nil,"new runtime graph no longer observes helper")
            eq(s2.units.root.observed.pattern,2,"root observes pattern version")
            eq(s2.units.root.definition_version,1,"root source still initial version")
            list(compare(s2,candidate).changed,"","both branches published")
            local further=candidate:gsub("return 2","return 3")
            local third=select_report(compare(s2,further),{"root"})
            list(third.selected,"","root no longer requests removed helper")
            list(third.pending,"helper","unreachable helper pending")
            eq(Versions.Next(third),s2,"no-op does not advance revision")
            local s3=commit(select_report(compare(s2,further),{"helper"}))
            eq(old_root(),50,"removed edge never resurrected")
            eq(old_pattern(),3,"escaped old pattern still shares helper cell")
            eq(s3.units.root.observed.helper,nil,"escaped closure not falsely a current definition")
        end)
        scenario("new captures and changing state after preparation",function()
            local text="local state=nil\nlocal enabled=false\nlocal config={tag='old'}\n"
                .. "local function helper() return 1 end\nlocal function root() return helper() end"
            local e=capture(text)
            local s=seed(e)
            local old_root=Anchor.Get(e,"root")
            local candidate=text:gsub("return 1","return state,enabled,config.tag")
            candidate=candidate:gsub("local state=nil\n","local state=error('initialization replayed')\n")
            local diff=compare(s,candidate)
            local selected=select_report(diff,{"root"})
            eq(#selected.joins,3,"all new captures are existing cells")
            eq(#selected.writes,1,"new state capture needs only helper write")
            eq(Anchor.Get(e,"state"),nil,"nil state retained before commit")
            assert(Anchor.Set(e,"state",{tick=7}))
            assert(Anchor.Set(e,"enabled",true))
            assert(Anchor.Set(e,"config",{tag="live"}))
            local next_s=commit(selected)
            local a,b,c=old_root()
            eq(a.tick,7,"ordinary state not frozen by diff")
            eq(b,true,"boolean cell not frozen")
            eq(c,"live","whole-table replacement read live")
            eq(next_s.units.helper.definition_version,2,"new capture body version")
            eq(next_s.units.root.definition_version,1,"new capture doesn't republish root")
            eq(#compare(next_s,candidate).initializers,1,"unapplied initializer still pending diagnostic")
            eq(#compare(next_s,candidate).changed,0,"function source already published")
            assert(Anchor.Set(e,"state",false))
            assert(Anchor.Set(e,"enabled",nil))
            assert(Anchor.Set(e,"config",{tag="replaced-again"}))
            a,b,c=old_root()
            eq(a,false,"false state after commit")
            eq(b,nil,"nil state after commit")
            eq(c,"replaced-again","table changes after commit")
            local stable=select_report(compare(next_s,candidate),{"root"})
            eq(#stable.writes,0,"state mutation alone is not definition change")
            eq(Versions.Next(stable),next_s,"state mutation does not advance definition revision")
        end)
        scenario("mutual recursion selected as one necessary group",function()
            local text="local a,b\na=function(n) if n==0 then return 0 end return 1+b(n-1) end\n"
                .. "b=function(n) if n==0 then return 0 end return 2+a(n-1) end"
            local e=capture(text)
            local s=seed(e)
            local old_a,old_b=Anchor.Get(e,"a"),Anchor.Get(e,"b")
            local candidate=text:gsub("1%+b","10+b"):gsub("2%+a","20+a")
            local selected=select_report(compare(s,candidate),{"b"})
            list(selected.selected,"a,b","changed recursive dependencies selected together")
            eq(#selected.writes,2,"deduplicated cycle writes")
            eq(#selected.joins,2,"deduplicated cycle joins")
            eq(old_a(2),3,"old recursive state unchanged by selection")
            local next_s=commit(selected)
            eq(Anchor.Get(e,"a")(2),30,"new recursive a")
            eq(Anchor.Get(e,"b")(2),30,"new recursive b")
            eq(old_a(2),21,"escaped old a calls new b")
            eq(old_b(2),12,"escaped old b calls new a")
            eq(next_s.units.a.observed.b,2,"a observes b definition version")
            eq(next_s.units.b.observed.a,2,"b observes a definition version")
            eq(next_s.revision,1,"cycle is one version transaction")
            local another=candidate:gsub("10%+b","100+b")
            local second=select_report(compare(next_s,another),{"b"})
            list(second.selected,"a","unchanged recursive consumer is not replaced")
            local s2=commit(second)
            eq(s2.units.a.definition_version,3,"a advances again")
            eq(s2.units.b.definition_version,2,"b source version stable")
            eq(s2.units.b.observed.a,3,"b shared observation advances")
            eq(Anchor.Get(e,"b")(2),120,"unchanged b reads second a")
        end)
        scenario("unchanged literal initializer self is global",function()
            local saved_f=rawget(_G,"f")
            local text="local f=function() return f end"
            local e=capture(text)
            local s=seed(e)
            _G.f=7
            eq(Anchor.Get(e,"f")(),7,"literal initializer global self")
            local selected=select_report(compare(s,text:gsub("return f","return f+1")),{"f"})
            eq(#selected.joins,0,"global self never wired to anchor")
            local next_s=commit(selected)
            eq(Anchor.Get(e,"f")(),8,"updated literal keeps global self")
            eq(next_s.units.f.observed.f,nil,"not a recursive local graph")
            _G.f=saved_f
        end)
        scenario("hot old consumers with partial publication",function()
            local text="local function a() return 1 end\nlocal function b() return a() end\n"
                .. "local function c() return b() end\nlocal independent=a"
            local e=capture(text)
            local s=seed(e)
            local old_c,alias=Anchor.Get(e,"c"),Anchor.Get(e,"independent")
            local acc=0
            for _=1,10000 do acc=acc+old_c() end
            eq(acc,10000,"old consumers warmed with ordinary JIT enabled")
            local selected=select_report(compare(s,text:gsub("return 1","return 20")),{"c"})
            local next_s=commit(selected)
            acc=0
            for _=1,10000 do acc=acc+old_c() end
            eq(acc,200000,"hot old consumers read new a after cell commit")
            eq(alias(),1,"independent function copy not refreshed")
            eq(next_s.units.b.definition_version,1,"hot intermediate not republished")
            eq(next_s.units.c.definition_version,1,"hot root not republished")
            eq(next_s.units.c.observed.a,2,"transitive observation of hot changed definition")
            eq(next_s.units.c.fn,old_c,"hot root closure identity kept")
        end)
    end
    -- Input hardening is pure; invalid bookkeeping must not mutate live state.
    if state then
        local function cloned()
            local r={}
            for k,v in pairs(state) do r[k]=v end
            r.names={}
            for i,v in ipairs(state.names) do r.names[i]=v end
            r.units={}
            for k,v in pairs(state.units) do r.units[k]=v end
            return r
        end
        for _,bad in ipairs({-1,0/0,math.huge,0.5,"1"}) do
            local r=cloned();r.revision=bad
            refuse(function() return Versions.Compare(r,changed) end,"unsupported","bad revision "..tostring(bad))
        end
        local duplicate=cloned();duplicate.names[#duplicate.names+1]=duplicate.names[1]
        refuse(function() return Versions.Compare(duplicate,changed) end,"unsupported","duplicate snapshot names")
        local extra=cloned();extra.units.unknown=extra.units.helper
        refuse(function() return Versions.Compare(extra,changed) end,"unsupported","unlisted function record")
        local missing=cloned();missing.units.helper=nil
        refuse(function() return Versions.Compare(missing,changed) end,"unsupported","missing function record")
        local hole=cloned();hole.names[2]=nil
        refuse(function() return Versions.Compare(hole,changed) end,"unsupported","snapshot name hole")
        local revision=cloned();revision.kind="wrong"
        refuse(function() return Versions.Compare(revision,changed) end,"unsupported","wrong snapshot kind")
        local version=cloned();version.version=2
        refuse(function() return Versions.Compare(version,changed) end,"unsupported","wrong snapshot protocol version")
        local session=cloned();session.session_id=""
        refuse(function() return Versions.Compare(session,changed) end,"unsupported","missing snapshot session")
        local frozen=cloned();frozen.initializers=false
        refuse(function() return Versions.Compare(frozen,changed) end,"unsupported","missing initializer baseline")
        local anchor=cloned();anchor.anchor=function() end
        refuse(function() return Versions.Compare(anchor,changed) end,"unsupported","different snapshot anchor")
        local records={}
        for _,bad in ipairs({-1,0,0.5,math.huge,0/0,"1"}) do records[#records+1]=bad end
        for _,bad in ipairs(records) do
            local r=cloned();local unit={}
            for k,v in pairs(r.units.helper) do unit[k]=v end
            unit.definition_version=bad;r.units.helper=unit
            refuse(function() return Versions.Compare(r,changed) end,"unsupported","bad definition version "..tostring(bad))
        end
        for _,bad in ipairs({ {"counter","counter"}, {false}, {[2]="counter"}, {{}} }) do
            local r=cloned();local unit={}
            for k,v in pairs(r.units.helper) do unit[k]=v end
            unit.dependencies=bad;r.units.helper=unit
            refuse(function() return Versions.Compare(r,changed) end,"unsupported","bad capture name array")
        end
    end
    for _, label in ipairs(failures) do print("[FunctionVersions] FAIL "..label) end
    return { passed=passed, failed=failed, failures=failures }
end
return M
