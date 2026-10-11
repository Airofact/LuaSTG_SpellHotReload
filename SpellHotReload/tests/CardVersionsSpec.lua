local M = {}
function M.run()
    local Versions = require("SpellHotReload.CardVersions")
    local Functions = require("SpellHotReload.FunctionVersions")
    local Source = require("SpellHotReload.Source.FunctionPlan")
    local Anchor = require("SpellHotReload.Load.Anchor")
    local Compose = require("SpellHotReload.Source.Compose")
    local Callbacks = require("SpellHotReload.CardCallbacks")
    local names = { "before", "init", "frame", "render", "beforedel", "del", "after" }
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
        eq(value, nil, label .. " refused")
        eq(type(err), "table", label .. " structured error")
        if type(err) == "table" then
            eq(err.code, code, label .. " code")
            check(type(err.message) == "string" and err.message ~= "", label .. " message")
        end
    end
    local function must(value, err)
        assert(value, type(err) == "table" and err.message or err)
        return value
    end
    local caps = { getupvalue = true, setupvalue = true, upvaluejoin = true }
    local defaults = {}
    for _, name in ipairs(names) do defaults[name] = function() return "default" end end
    local saved_boss, saved_classes, saved_tmp = rawget(_G, "boss"), rawget(_G, "_editor_class"), rawget(_G, "_tmp_sc")
    local saved_join, saved_set, saved_jit = debug.upvaluejoin, debug.setupvalue, rawget(_G, "jit")
    local function capture(source)
        -- Test-only genuine FIRST publication of a synthetic generated file.
        -- Only these miniature fixtures run, never a real game source.
        _G.boss = { card = { New = function(name)
            local card = { name = name }
            for _, cb in ipairs(names) do card[cb] = defaults[cb] end
            return card
        end } }
        _G._editor_class = { K = {}, L = {} }
        local entry = must(Anchor.Capture(source, { name = "Cards_Boss.lua", capability = caps }))
        entry.file = "Cards_Boss.lua"
        local identities = {}
        local scan = must(Source.Inspect(source))
        for name in pairs(scan.definitions) do identities[name] = Anchor.Get(entry, name) end
        return entry, identities, _editor_class
    end
    local function owners(classes)
        local result = {}
        for _, class_key in ipairs({ "K", "L" }) do
            for slot, card in ipairs(classes[class_key].cards or {}) do
                local callbacks = {}
                for _, name in ipairs(names) do callbacks[name] = rawget(card, name) end
                result[#result + 1] = { class_key = class_key, slot = slot,
                    card = card, callbacks = callbacks }
            end
        end
        return result
    end
    local function seed(entry, identities, initial)
        local functions = must(Functions.Seed(entry, "session", identities))
        return must(Versions.Seed(functions, initial, defaults))
    end
    local function compare(state, content) return must(Versions.Compare(state, content)) end
    local function select_cards(report, keys) return must(Versions.Select(report, keys)) end
    local function commit(selection)
        -- Manual TEST-ONLY publication. No phase/atomicity/rollback guarantee.
        for _, item in ipairs(selection.functions.functions) do must(Compose.Join(item.join_plan)) end
        for _, publication in ipairs(selection.publications) do
            if publication.callback.join_plan then must(Compose.Join(publication.callback.join_plan)) end
        end
        for _, write in ipairs(selection.writes) do must(Anchor.Set(selection.entry, write.name, write.value)) end
        for _, publication in ipairs(selection.publications) do rawset(publication.target, publication.key, publication.value) end
        return must(Versions.Next(selection))
    end
    local source = table.concat({
        "local counter=4", "local flag=false", "local empty",
        "local function helper(n) return counter+n end",
        "local function other(n) return n+100 end",
        "local function pattern(n) return helper(n) end",
        "local alias=helper",
        "_editor_class['K'].cards={}",
        "_tmp_sc=boss.card.New('A',1,2,3,100)",
        "function _tmp_sc:init(n) return pattern(n) end",
        "_tmp_sc.frame=function(self,n) return alias(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('B',1,2,3,100)",
        "function _tmp_sc:init(n) return pattern(n)+10 end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
        "_tmp_sc=boss.card.New('C',1,2,3,100)",
        "function _tmp_sc:init(n) return other(n) end",
        "table.insert(_editor_class['K'].cards,_tmp_sc)",
    }, "\n")
    local ok, problem = pcall(function()
        local entry, identities, classes = capture(source)
        local initial = owners(classes)
        local a, b, c = initial[1].card, initial[2].card, initial[3].card
        local keya, keyb, keyc = "card:1:K:1", "card:1:K:2", "card:1:K:3"
        if not saved_join then
            debug.upvaluejoin = function() error("presence-only fixture") end
            local functions = must(Functions.Seed(entry, "session", identities))
            debug.upvaluejoin = nil
            refuse(function() return Versions.Seed(functions, initial, defaults) end,
                "capability", "real Lua5.1 without join")
        end
        local joins, writes, flushes = 0, 0, 0
        debug.upvaluejoin = function() joins=joins+1; error("premature join") end
        debug.setupvalue = function() writes=writes+1; error("premature write") end
        _G.jit = { flush = function() flushes=flushes+1; error("premature flush") end }
        local state = seed(entry, identities, initial)
        eq(Versions.Kind, "SpellHotReload.CardVersions", "kind")
        eq(Versions.Version, 1, "version")
        eq(state.revision, 0, "first aggregate revision")
        eq(state.functions.revision, 0, "first function revision")
        eq(state.loaded_source, source, "immutable load baseline")
        eq(state.anchor, entry.anchor, "same sole anchor")
        eq(state.session_id, "session", "session carried")
        list(state.order, keya .. "," .. keyb .. "," .. keyc, "complete card discovery")
        eq(state.units[keya].card, a, "first raw target")
        eq(state.units[keyb].card, b, "second raw target")
        eq(state.units[keyc].card, c, "third raw target")
        eq(state.units[keya].definition_version, 1, "initial card source version")
        list(state.units[keya].callbacks.init.dependencies, "pattern", "actual init capture")
        list(state.units[keya].callbacks.frame.dependencies, "alias", "alias terminal capture")
        eq(state.units[keya].callbacks.init.fn, a.init, "genuine first callback identity")
        eq(state.units[keya].callbacks.after.fn, defaults.after, "saved default")
        eq(state.units[keya].observed.helper, 1, "transitive shared observation")
        eq(state.units[keya].observed.pattern, 1, "direct observation")
        eq(state.units[keya].observed.other, nil, "independent function not observed")
        eq(state.units[keya].observed.alias, nil, "alias not a direct function record")
        local same = compare(state, source)
        list(same.changed, "", "unchanged card")
        list(same.affected, "", "unchanged impact")
        list(same.functions.changed, "", "unchanged function")
        local empty = select_cards(same, {})
        eq(#empty.writes, 0, "empty writes")
        eq(#empty.publications, 0, "empty publications")
        eq(Versions.Next(empty), state, "empty selection keeps snapshot")
        local current = select_cards(same, { keya })
        list(current.function_roots, "pattern", "roots from actual upvalues not source word mentions")
        eq(#current.publications, 0, "unchanged current callbacks not rebuilt for publication")
        eq(Versions.Next(current), state, "unchanged current revision unchanged")
        eq(#same.read_set, 21, "all raw callback identities rechecked")
        check(#same.capture_reads >= 4, "actual old capture reads retained")
        local formatted = compare(state, source:gsub("return pattern%(n%) end", "return -- comment\n pattern ( n ) end", 1))
        list(formatted.changed, "", "comment/format token equality")
        local all = source:gsub("counter%+n", "counter+n+1")
            :gsub("pattern%(n%) end", "pattern(n)+20 end", 1)
            :gsub("pattern%(n%)%+10", "pattern(n)+30")
            :gsub("n%+100", "n+200")
        local diff = compare(state, all)
        list(diff.changed, keya .. "," .. keyb, "two wrappers edited")
        list(diff.functions.changed, "helper,other", "two functions edited")
        list(diff.affected, keya .. "," .. keyb .. "," .. keyc, "both graph impact")
        local selected = select_cards(diff, { keya })
        list(selected.selected, keya, "only explicit current card")
        list(selected.pending, keyb, "other wrapper pending")
        list(selected.functions.selected, "helper", "only needed helper cell")
        list(selected.functions.pending, "other", "independent function pending")
        list(selected.affected, keya .. "," .. keyb, "shared propagation without unrelated pending edge")
        eq(#selected.publications, 1, "only changed current init raw publication")
        eq(selected.publications[1].target, a, "publication exact table")
        eq(selected.publications[1].key, "init", "publication exact callback")
        eq(selected.publications[1].before, a.init, "expected old identity")
        eq(selected.content, all, "complete pending candidate retained")
        eq(#selected.restarts, 0, "restart ownership still R4")
        local proposed = must(Versions.Next(selected))
        eq(proposed.revision, 1, "aggregate proposed group")
        eq(proposed.functions.revision, 1, "function proposed group")
        eq(proposed.units[keya].definition_version, 2, "selected wrapper proposed version")
        eq(proposed.units[keya].callbacks.init.definition_version, 2, "selected init source version")
        eq(proposed.units[keya].callbacks.frame.definition_version, 1, "unchanged frame version")
        eq(proposed.units[keya].callbacks.frame.fn, a.frame, "unchanged frame identity retained")
        eq(proposed.units[keyb].callbacks.init.fn, b.init, "unselected callback identity retained")
        eq(proposed.units[keyb].definition_version, 1, "unselected wrapper source not acknowledged")
        eq(proposed.units[keyb].observed.helper, 2, "shared observation independent of source version")
        eq(proposed.units[keyc].observed.other, 1, "pending unrelated observation retained")
        eq(proposed.loaded_source, source, "proposed never replaces loaded source")
        eq(proposed.layout, state.layout, "original layout held")
        eq(proposed.defaults, state.defaults, "initial default identity held")
        eq(state.revision, 0, "Next does not install")
        eq(state.units[keya].definition_version, 1, "Next leaves base records intact")
        eq(a.init, initial[1].callbacks.init, "preparation never publishes current")
        eq(b.init, initial[2].callbacks.init, "preparation never publishes other")
        eq(Anchor.Get(entry, "helper"), identities.helper, "preparation never writes cell")
        refuse(function() return Versions.Compare(proposed, all) end, "stale", "pure Next not an installed baseline")
        local helper_only = compare(state, source:gsub("counter%+n", "counter+n+1"))
        local shared = select_cards(helper_only, { keya })
        eq(#shared.publications, 0, "helper only no wrapper publication")
        list(shared.functions.selected, "helper", "helper only necessary definition")
        list(shared.affected, keya .. "," .. keyb, "helper only current and shared consumers")
        local observed_only = must(Versions.Next(shared))
        eq(observed_only.units[keya].definition_version, 1, "helper only keeps wrapper version")
        eq(observed_only.units[keya].callbacks.init.fn, a.init, "helper only keeps callback identity")
        eq(observed_only.units[keya].observed.helper, 2, "helper only advances observation")
        local removed = source:gsub("_tmp_sc.frame=function%(self,n%) return alias%(n%) end\n", "")
        local deletion = select_cards(compare(state, removed), { keya })
        eq(#deletion.publications, 1, "deleted optional callback one publication")
        eq(deletion.publications[1].key, "frame", "deletion names frame")
        eq(deletion.publications[1].value, defaults.frame, "deletion restores exact saved default")
        eq(deletion.publications[1].callback.body, nil, "deletion tombstone retains no source")
        list(deletion.function_roots, "pattern", "deleted alias capture gone")
        local added = source:gsub("table.insert", "function _tmp_sc:render() return flag,empty end\ntable.insert", 1)
        local addition = select_cards(compare(state, added), { keya })
        eq(#addition.publications, 1, "added optional callback one publication")
        list(addition.publications[1].callback.dependencies, "empty,flag", "new nil/false captures have real slots")
        eq(#addition.publications[1].callback.join_plan.joins, 2, "new captures join original cells")
        local switched = source:gsub("return pattern%(n%) end", "return other(n) end", 1):gsub("n%+100", "n+200")
        local switch = select_cards(compare(state, switched), { keya })
        list(switch.function_roots, "other", "changed wrapper uses new roots")
        list(switch.functions.selected, "other", "new capture picks needed definition")
        local misleading = source:gsub("return pattern%(n%) end", "local other=9;return pattern(n),other end", 1)
        local shadowed = select_cards(compare(state, misleading:gsub("n%+100", "n+200")), { keya })
        list(shadowed.function_roots, "pattern", "inner local shadow is not a function root")
        list(shadowed.functions.pending, "other", "shadowed word does not consume pending function")
        local blocked = source:gsub("return pattern%(n%) end", "return pattern(n),'other' end", 1)
        list(select_cards(compare(state, blocked), { keya }).function_roots, "pattern", "string word is not capture")
        refuse(function() return Versions.Select(diff, { keya, keya }) end, "unsupported", "duplicate roots")
        refuse(function() return Versions.Select(diff, { "missing" }) end, "unsupported", "unknown root")
        refuse(function() return Versions.Select(diff, { [2]=keya }) end, "unsupported", "sparse roots")
        refuse(function() return Versions.Select({}, {}) end, "unsupported", "not a report")
        refuse(function() return Versions.Next({}) end, "unsupported", "not a selection")
        refuse(function() return Versions.Compare({}, source) end, "unsupported", "not a snapshot")
        refuse(function() return Versions.Compare(state, "bad function(") end, "compile", "full source syntax rejected")
        refuse(function() return Versions.Compare(state, source .. "\nlocal added=1") end,
            "unsupported", "fixed local set refused")
        refuse(function() return Versions.Compare(state, source:gsub("'A'", "'Renamed'")) end,
            "ambiguous", "constructor/name remapping not guessed")
        refuse(function() return Versions.Compare(state, source:gsub("return pattern%(n%) end", "return pattern(n) end\n_tmp_sc.perform=true", 1)) end,
            "ambiguous", "perform metadata drift")
        refuse(function() return Versions.Compare(state, source:gsub("function _tmp_sc:init%(n%) return pattern%(n%) end\n", "", 1)) end,
            "ambiguous", "required init deletion not combat")
        refuse(function() return Versions.Seed(state.functions, {}, defaults) end,
            "ownership", "all first-load owners required")
        refuse(function() return Versions.Seed(state.functions, {initial[1],initial[1]}, defaults) end,
            "ownership", "duplicate owner")
        local bad_owner = { class_key="K",slot=2,card=a,callbacks=initial[1].callbacks }
        refuse(function() return Versions.Seed(state.functions, {initial[1],bad_owner,initial[3]}, defaults) end,
            "ownership", "same target cannot have two owners")
        refuse(function() return Versions.Seed(state.functions, initial, {}) end,
            "unsupported", "complete defaults required")
        refuse(function() return Versions.Seed(proposed.functions, initial, defaults) end,
            "unsupported", "no reseed after partial function versions")
        local function replacement() end
        rawset(a, "render", replacement)
        refuse(function() return Versions.Compare(state, source) end, "stale", "external default replacement")
        rawset(a, "render", defaults.render)
        local genuine = initial[1].callbacks.init
        rawset(a, "init", replacement)
        refuse(function() return Versions.Compare(state, source) end, "stale", "external defined callback replacement")
        refuse(function() return Versions.Seed(state.functions, initial, defaults) end,
            "stale", "genuine identities not substituted after external setter")
        rawset(a, "init", genuine)
        eq(joins, 0, "Seed/Compare/Select/Next never join")
        eq(writes, 0, "Seed/Compare/Select/Next never setupvalue")
        eq(flushes, 0, "Seed/Compare/Select/Next never flush")
        debug.upvaluejoin, debug.setupvalue, _G.jit = saved_join, saved_set, saved_jit
        if saved_join then
            local first = commit(selected)
            eq(a:init(1), 26, "first current wrapper + selected helper")
            eq(b:init(1), 16, "unchanged second wrapper sees shared helper")
            eq(c:init(1), 101, "unselected function stays old")
            eq(a:frame(1), 5, "alias frame still old function identity")
            local rest = compare(first, all)
            list(rest.changed, keyb, "first Apply leaves second wrapper pending")
            list(rest.functions.changed, "other", "first Apply leaves unrelated function pending")
            local second_selection = select_cards(rest, { keyb })
            eq(#second_selection.writes, 0, "second same helper no cell write")
            eq(#second_selection.publications, 1, "second only its wrapper")
            local second = commit(second_selection)
            eq(second.revision, 2, "second aggregate publication revision")
            eq(second.functions.revision, 1, "callback-only group does not fake local write")
            eq(b:init(1), 36, "second wrapper published")
            local third = commit(select_cards(compare(second, all), { keyc }))
            eq(third.revision, 3, "third partial group")
            eq(third.functions.revision, 2, "third updates unrelated local")
            eq(c:init(1), 201, "third actual function update")
            list(compare(third, all).changed, "", "all wrapper changes finally acknowledged")
            list(compare(third, all).functions.changed, "", "all function changes finally acknowledged")
            eq(third.units[keya].callbacks.init.definition_version, 2, "other Apply never advances first wrapper")
            eq(third.units[keyb].callbacks.init.definition_version, 2, "second wrapper own version")
            eq(third.units[keyc].callbacks.init.definition_version, 1, "third only shared function version")

            local old_frame = a.frame
            local deleted_state = commit(select_cards(compare(third,
                all:gsub("_tmp_sc.frame=function%(self,n%) return alias%(n%) end\n", "")), { keya }))
            eq(a.frame, defaults.frame, "optional deletion actually restores raw default")
            eq(deleted_state.units[keya].callbacks.frame.definition_version, 2, "deleted callback own version advances")
            eq(old_frame(a,1), 5, "escaped old alias callback stays old")
            local restored = commit(select_cards(compare(deleted_state, all), { keya }))
            eq(a:frame(1), 5, "optional callback re-add joins original alias cell")
            eq(restored.units[keya].callbacks.frame.definition_version, 3, "re-add increments actual callback history")
            eq(restored.units[keya].callbacks.init.definition_version, 2, "delete/readd frame does not advance init")
            local nil_false_source = all:gsub("table.insert",
                "function _tmp_sc:render() return flag,empty end\ntable.insert", 1)
            local nil_false = commit(select_cards(compare(restored, nil_false_source), { keya }))
            local flag_value, empty_value = a:render()
            eq(flag_value, false, "new false capture actually reads old cell")
            eq(empty_value, nil, "new nil capture actually reads old cell")
            must(Anchor.Set(entry, "flag", true))
            must(Anchor.Set(entry, "empty", 7))
            flag_value, empty_value = a:render()
            eq(flag_value, true, "new false cell external setter propagation")
            eq(empty_value, 7, "new nil cell external setter propagation")
            must(compare(nil_false, nil_false_source))
            eq(nil_false.units[keya].observed.helper, 2, "ordinary state mutation leaves versions intact")
            local literal = nil_false.units[keya].callbacks.render
            check(Anchor.Shared(entry, "flag", literal.fn,
                must(Compose.Upvalues(literal.fn))[1].name == "flag" and 1 or 2),
                "callback physically shares original state holder")
            local counter_value = Anchor.Get(entry,"counter")
            for i = 1, 20000 do a:init(i) end -- ordinary JIT, no -joff
            must(Anchor.Set(entry, "counter", counter_value+10))
            eq(a:init(1), 36, "hot old wrapper reads externally updated shared counter")
            eq(b:init(1), 46, "hot indirect old shared consumer reads updated counter")
            local detached = must(Compose.Create(literal.body,nil,literal.visible,{form="expression"}))
            local captured_slot = must(Compose.Upvalues(literal.fn))[1]
            debug.upvaluejoin(literal.fn,captured_slot.index,detached.fn,captured_slot.index)
            refuse(function() return Versions.Compare(nil_false,nil_false_source) end,
                "stale","external physical callback rejoin")
            must(Compose.Join(must(Compose.Plan(literal.fn,entry))))
            must(compare(nil_false,nil_false_source))
        end

        -- Callback definition-point locals are NOT constructor-time locals.
        local point_source = table.concat({
            "_editor_class['K'].cards={}",
            "_tmp_sc=boss.card.New('Late',1,2,3,100)",
            "local late=false",
            "function _tmp_sc:init() return late end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)",
        }, "\n")
        local point_entry, point_ids, point_classes = capture(point_source)
        if not saved_join then debug.upvaluejoin=function() error("presence stub") end end
        local point_state = seed(point_entry, point_ids, owners(point_classes))
        list(point_state.units[keya].callbacks.init.visible,"late","callback sees intervening declaration")
        list(point_state.units[keya].callbacks.init.dependencies,"late","actual late state capture")
        local point_layout = must(Callbacks.Read(point_source,"K"))
        eq(point_layout[1].locals.late,nil,"legacy constructor locals remain unchanged")
        check(point_layout[1].callback_points.init.first>0,"callback source point explicitly exposed")
        local new_point = compare(point_state,point_source:gsub("return late end","return late,1 end"))
        local point_selection = select_cards(new_point,{keya})
        eq(#point_selection.publications,1,"late local callback change prepares")
        eq(#point_selection.publications[1].callback.join_plan.joins,1,"late declaration uses anchor donor")
        if saved_join then
            local point_next=commit(point_selection)
            eq(point_classes.K.cards[1]:init(),false,"intervening local stays false after publication")
            must(Anchor.Set(point_entry,"late",9))
            eq(point_classes.K.cards[1]:init(),9,"late original cell setter stays shared")
            must(compare(point_next,point_source:gsub("return late end","return late,1 end")))
        end
        local moved = point_source:gsub("local late=false\n",""):gsub(
            "table.insert","local late=false\ntable.insert")
        refuse(function() return Versions.Compare(point_state,moved) end,
            saved_join and "stale" or "unsupported","definition binding/mismatched old snapshot never guessed")
        -- Recreate a fresh genuine first publication for binding drift alone.
        local moved_entry,moved_ids,moved_classes=capture(point_source)
        local moved_state=seed(moved_entry,moved_ids,owners(moved_classes))
        refuse(function() return Versions.Compare(moved_state,moved) end,
            "unsupported","callback moved before visible declaration")
        local bom_entry,bom_ids,bom_classes=capture("\239\187\191"..point_source)
        local bom_state=seed(bom_entry,bom_ids,owners(bom_classes))
        list(bom_state.order,keya,"BOM first-load layout")
        list(compare(bom_state,"\239\187\191"..point_source).changed,"","BOM offsets preserved")
        local future_source=point_source:gsub("local late=false\n",""):gsub(
            "table.insert","local late=false\ntable.insert")
        local future_entry,future_ids,future_classes=capture(future_source)
        local future_state=seed(future_entry,future_ids,owners(future_classes))
        list(future_state.units[keya].callbacks.init.dependencies,"","future local remains global")
        local future_diff=compare(future_state,future_source:gsub("return late end","return late,2 end"))
        eq(#select_cards(future_diff,{keya}).publications[1].callback.join_plan.joins,0,"future global not silently bound")

        local cross_source=table.concat({
            "local function shared(n) return n+1 end",
            "_editor_class['K'].cards={}",
            "_tmp_sc=boss.card.New('One',1,2,3,100)",
            "function _tmp_sc:init(n) return shared(n) end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)",
            "_editor_class['L'].cards={}",
            "_tmp_sc=boss.card.New('Two',1,2,3,100)",
            "function _tmp_sc:init(n) return shared(n)+10 end",
            "table.insert(_editor_class['L'].cards,_tmp_sc)",
        },"\n")
        local cross_entry,cross_ids,cross_classes=capture(cross_source)
        local cross_state=seed(cross_entry,cross_ids,owners(cross_classes))
        local keyl="card:1:L:1"
        list(cross_state.order,keya..","..keyl,"multiple class owners discovered")
        local cross_new=cross_source:gsub("n%+1 end","n+2 end"):gsub("shared%(n%)%+10","shared(n)+20")
        local cross_selection=select_cards(compare(cross_state,cross_new),{keya})
        list(cross_selection.functions.selected,"shared","cross-class helper selected")
        list(cross_selection.pending,keyl,"cross-class edited wrapper pending")
        list(cross_selection.affected,keya..","..keyl,"cross-class actual shared observation")
        eq(#cross_selection.publications,0,"unmodified current wrapper reused across classes")
        if saved_join then
            local cross_next=commit(cross_selection)
            eq(cross_classes.K.cards[1]:init(1),3,"cross-class current old closure updated")
            eq(cross_classes.L.cards[1]:init(1),13,"cross-class unselected old wrapper updated")
            list(compare(cross_next,cross_new).changed,keyl,"cross-class pending survives")
            local pending_graph=cross_new:gsub("shared%(n%)%+20","999")
            local pending_diff=compare(cross_next,pending_graph:gsub("n%+2 end","n+3 end"))
            local pending_selection=select_cards(pending_diff,{keya})
            list(pending_selection.affected,keya..","..keyl,"pending capture removal not already installed")
        end

        local recursive_source=table.concat({
            "local f,g", "f=function(n) if n==0 then return 0 end return g(n-1)+1 end",
            "g=function(n) if n==0 then return 0 end return f(n-1)+1 end",
            "_editor_class['K'].cards={}", "_tmp_sc=boss.card.New('Loop',1,2,3,100)",
            "function _tmp_sc:init(n) return f(n) end",
            "table.insert(_editor_class['K'].cards,_tmp_sc)",
        },"\n")
        local recursive_entry,recursive_ids,recursive_classes=capture(recursive_source)
        local recursive_state=seed(recursive_entry,recursive_ids,owners(recursive_classes))
        local recursive_selection=select_cards(compare(recursive_state,recursive_source:gsub("%+1 end","+2 end")),{keya})
        list(recursive_selection.functions.selected,"f,g","card root selects resolvable cycle")
        eq(#recursive_selection.publications,0,"recursive shared update does not rebuild wrapper")
        if saved_join then
            local recursive_next=commit(recursive_selection)
            eq(recursive_classes.K.cards[1]:init(6),12,"recursive cycle actually joined and published")
            eq(recursive_next.units[keya].definition_version,1,"recursive propagation keeps wrapper version")
            eq(recursive_next.units[keya].observed.f,2,"recursive f observation")
            eq(recursive_next.units[keya].observed.g,2,"recursive g observation")
        end

        -- Complete first-load identity and malformed-owner refusals. No caller
        -- data is normalized through metamethods or rebuilt from current values.
        local audit_entry,audit_ids,audit_classes=capture(source)
        local audit_owners=owners(audit_classes)
        local audit_state=seed(audit_entry,audit_ids,audit_owners)
        local audit_functions=audit_state.functions
        local audit_report=compare(audit_state,source)
        local function shallow(value)
            local result={}
            for k,v in pairs(value) do result[k]=v end
            return result
        end
        local missing_cb=shallow(audit_owners[1])
        missing_cb.callbacks=shallow(missing_cb.callbacks)
        missing_cb.callbacks.after=nil
        refuse(function() return Versions.Seed(audit_functions,
            {missing_cb,audit_owners[2],audit_owners[3]},defaults) end,
            "stale","all seven genuine identities even defaults required")
        local extra_cb=shallow(audit_owners[1])
        extra_cb.callbacks=shallow(extra_cb.callbacks)
        extra_cb.callbacks.update=defaults.frame
        refuse(function() return Versions.Seed(audit_functions,
            {extra_cb,audit_owners[2],audit_owners[3]},defaults) end,
            "unsupported","extra unsupported callback identity refused")
        local extra_owner=shallow(audit_owners[1])
        extra_owner.slot=4
        refuse(function() return Versions.Seed(audit_functions,
            {audit_owners[1],audit_owners[2],audit_owners[3],extra_owner},defaults) end,
            "ownership","extra unknown combat owner refused")
        local wrong_kind=shallow(audit_owners[1])
        wrong_kind.class_key=""
        refuse(function() return Versions.Seed(audit_functions,{wrong_kind},defaults) end,
            "unsupported","empty owner class refused")
        wrong_kind=shallow(audit_owners[1])
        wrong_kind.slot=1.5
        refuse(function() return Versions.Seed(audit_functions,{wrong_kind},defaults) end,
            "unsupported","fractional owner slot refused")
        wrong_kind.slot=math.huge
        refuse(function() return Versions.Seed(audit_functions,{wrong_kind},defaults) end,
            "unsupported","infinite owner slot refused")
        refuse(function() return Versions.Seed(audit_functions,{[2]=audit_owners[1]},defaults) end,
            "unsupported","sparse owner array refused")
        local metamethods=0
        local function trap() metamethods=metamethods+1;error("metamethod ran") end
        refuse(function() return Versions.Seed(audit_functions,
            setmetatable({}, {__index=trap}),defaults) end,
            "unsupported","owner container metamethod refused")
        refuse(function() return Versions.Seed(audit_functions,audit_owners,
            setmetatable({}, {__index=trap})) end,
            "unsupported","default container metamethod refused")
        refuse(function() return Versions.Select(audit_report,
            setmetatable({}, {__index=trap})) end,
            "unsupported","selection container metamethod refused")
        local raw_target=audit_owners[1].card
        setmetatable(raw_target,{__newindex=trap})
        refuse(function() return Versions.Compare(audit_state,source) end,
            "unsupported","published target acquired a metatable")
        setmetatable(raw_target,nil)
        eq(metamethods,0,"refusals never invoke unknown table metamethods")
        local changed_defaults=shallow(defaults)
        changed_defaults.before=function() end
        refuse(function() return Versions.Seed(audit_functions,audit_owners,changed_defaults) end,
            "stale","source-absent callback must match standard default")
        local wrong_capture=function() return 7 end
        local genuine=audit_owners[1].callbacks.init
        raw_target.init=wrong_capture
        local substituted=shallow(audit_owners[1])
        substituted.callbacks=shallow(substituted.callbacks)
        substituted.callbacks.init=wrong_capture
        refuse(function() return Versions.Seed(audit_functions,
            {substituted,audit_owners[2],audit_owners[3]},defaults) end,
            "stale","matching live replacement still must have source capture set")
        raw_target.init=genuine
        local state_only=source:gsub("counter=4","counter=99")
        local preservation=compare(audit_state,state_only)
        eq(#preservation.functions.initializers,1,"initializer change diagnostic retained")
        list(preservation.changed,"","initializer not a callback publication")
        local preserved=select_cards(preservation,{keya})
        eq(Versions.Next(preserved),audit_state,"initializer never acknowledged as published")
        eq(Anchor.Get(audit_entry,"counter"),4,"initializer never replayed")
        local all_changed=source:gsub("counter%+n","counter+n+1")
            :gsub("pattern%(n%) end","pattern(n)+20 end",1)
            :gsub("pattern%(n%)%+10","pattern(n)+30"):gsub("n%+100","n+200")
        local pending_report=compare(audit_state,all_changed)
        local no_current=select_cards(pending_report,{})
        list(no_current.pending,keya..","..keyb,"empty current selection retains every edited wrapper")
        list(no_current.functions.pending,"helper,other","empty current retains every changed local")
        eq(#no_current.joins,0,"empty current no prebuilt join publication plan")
        eq(#no_current.writes,0,"empty current no cell writes")
        eq(#no_current.publications,0,"empty current no callback publications")
        eq(Versions.Next(no_current),audit_state,"empty current with pending does not advance")
        local batch=select_cards(pending_report,{keyb,keya})
        list(batch.selected,keya..","..keyb,"explicit batch normalized to source order")
        eq(#batch.publications,2,"two explicitly selected wrappers")
        eq(#batch.writes,1,"shared helper writes deduplicated")
        list(batch.functions.pending,"other","multi-card selection preserves unrelated function")
        local broken=shallow(audit_state)
        broken.revision=-1
        refuse(function() return Versions.Compare(broken,source) end,
            "unsupported","invalid aggregate revision refused")
        broken=shallow(audit_state)
        broken.anchor=function() end
        refuse(function() return Versions.Compare(broken,source) end,
            "unsupported","different anchor snapshot refused")
        audit_entry.missing=true
        refuse(function() return Versions.Compare(audit_state,source) end,
            "stale","missing anchor file cannot prepare")
        audit_entry.missing=false
        must(compare(audit_state,source))
    end)
    debug.upvaluejoin, debug.setupvalue, _G.jit = saved_join, saved_set, saved_jit
    _G.boss, _G._editor_class, _G._tmp_sc = saved_boss, saved_classes, saved_tmp
    if not ok then failed=failed+1; failures[#failures+1]="unexpected: "..tostring(problem) end
    for _, label in ipairs(failures) do print("FAIL CardVersions: " .. label) end
    return { passed = passed, failed = failed }
end
return M
