--- R3 preparation spec: all mutations below are explicit test-only manual
--- commits, never FunctionPlan.Prepare. No target engine/real source execution.
local Plan = require("SpellHotReload.Source.FunctionPlan")
local Anchor = require("SpellHotReload.Load.Anchor")
local Compose = require("SpellHotReload.Source.Compose")
local M = {}

function M.run()
    local passed, failed, failures = 0, 0, {}
    local function check(value, label)
        if value then passed = passed + 1 else
            failed = failed + 1; failures[#failures + 1] = label
        end
    end
    local function eq(a, b, label) check(a == b, label .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
    local function reject(content, entry, names, published, code, label)
        local result, err = Plan.Prepare(content, entry, names, published)
        eq(result, nil, label .. " refused")
        eq(type(err), "table", label .. " structured error")
        if type(err) == "table" then
            eq(err.phase, "inject", label .. " phase")
            eq(err.code, code, label .. " code")
            check(type(err.message) == "string" and err.message ~= "", label .. " message")
        end
    end
    local caps = { getupvalue = true, setupvalue = true, upvaluejoin = true }
    local function capture(source)
        return assert(Anchor.Capture(source, { name = "FunctionPlan_Boss.lua", capability = caps }))
    end
    local function current(entry, names)
        local values = {}
        for _, name in ipairs(names) do values[name] = assert(Anchor.Get(entry, name)) end
        return values
    end
    local function commit(plan)
        for _, item in ipairs(plan.functions) do assert(Compose.Join(item.join_plan)) end
        for _, write in ipairs(plan.writes) do assert(Anchor.Set(plan.entry, write.name, write.value)) end
    end
    local source = table.concat({
        "local counter = 0",
        "local config = { tag = 'old' }",
        "local function helper(n) return counter + n end",
        "local function pattern(n) return helper(n) end",
        "local alias = helper",
        "local function setter(v) counter = v end",
    }, "\n")
    local entry = capture(source)
    local identity = entry.anchor
    local helper, pattern, alias = Anchor.Get(entry, "helper"), Anchor.Get(entry, "pattern"), Anchor.Get(entry, "alias")
    local published = { helper = helper, pattern = pattern }
    eq(Plan.Kind, "SpellHotReload.FunctionPlan", "kind")
    eq(Plan.Version, 1, "version")
    eq(helper(2), 2, "initial helper")
    eq(pattern(2), 2, "initial pattern")
    eq(alias, helper, "independent alias")
    local candidate = source:gsub("counter %+ n", "counter + n * 10")
    if type(debug.upvaluejoin) ~= "function" then
        reject(candidate, entry, { "helper" }, published, "capability", "real runtime without join")
        eq(Anchor.Get(entry, "helper"), helper, "refusal retains helper")
        eq(Anchor.Get(entry, "counter"), 0, "refusal retains state")
    end

    -- Metadata validation is still exercised on Lua5.1 through a temporary
    -- existence stub. Prepare must NEVER call it (or setupvalue/flush).
    local original_join, original_set, original_jit = debug.upvaluejoin, debug.setupvalue, rawget(_G, "jit")
    local join_calls, set_calls, flush_calls = 0, 0, 0
    debug.upvaluejoin = function() join_calls = join_calls + 1; error("premature join") end
    debug.setupvalue = function() set_calls = set_calls + 1; error("premature write") end
    _G.jit = { flush = function() flush_calls = flush_calls + 1; error("premature flush") end }
    local ok, problem = pcall(function()
        local plan = assert(Plan.Prepare(candidate, entry, { "helper" }, published))
        eq(plan.kind, Plan.Kind, "plan kind")
        eq(plan.version, 1, "plan version")
        eq(plan.anchor, identity, "same anchor")
        eq(plan.entry, entry, "same entry")
        eq(plan.loaded_source, source, "loaded baseline held")
        eq(plan.content, candidate, "full candidate held")
        eq(#plan.functions, 1, "helper-only compilation")
        eq(plan.functions[1].name, "helper", "helper selected")
        eq(plan.functions[1].join_plan.joined, false, "no join yet")
        eq(#plan.writes, 1, "one cell write")
        eq(plan.writes[1].name, "helper", "write name")
        eq(plan.writes[1].before, helper, "published identity")
        eq(plan.writes[1].index, Anchor.Slot(entry, "helper"), "real write index")
        eq(plan.writes[1].value, plan.functions[1].created.fn, "new closure value")
        eq(#plan.read_set, 1, "only write value frozen")
        eq(plan.read_set[1].value, helper, "read identity")
        eq(#plan.publications, 0, "no callback publications")
        eq(#plan.restarts, 0, "no restart contexts")
        eq(#plan.joins, 1, "one actual capture")
        eq(plan.joins[1].anchor_name, "counter", "counter capture")
        eq(plan.joins[1].donor, Anchor.Slot(entry, "counter"), "counter donor")
        eq(Anchor.Get(entry, "helper"), helper, "helper unchanged")
        eq(Anchor.Get(entry, "pattern"), pattern, "pattern unchanged")
        eq(Anchor.Get(entry, "alias"), alias, "alias unchanged")
        eq(Anchor.Get(entry, "counter"), 0, "state unchanged")

        local both = assert(Plan.Prepare(candidate, entry, { "pattern", "helper" }, published))
        eq(#both.functions, 2, "two selected")
        eq(both.functions[1].name, "helper", "source order not input order")
        eq(both.functions[2].name, "pattern", "consumer follows")
        eq(#both.joins, 2, "flattened two joins")
        eq(both.functions[2].created.used[1], "helper", "real consumer dependency")
        local empty = assert(Plan.Prepare(candidate, entry, {}, {}))
        eq(#empty.functions, 0, "empty plan")
        eq(#empty.joins, 0, "empty joins")
        eq(#empty.writes, 0, "empty writes")

        local nil_source = "local unused\nlocal function f() return unused end"
        local nil_entry = capture(nil_source)
        local nil_plan = assert(Plan.Prepare(nil_source, nil_entry, { "f" }, current(nil_entry, { "f" })))
        eq(nil_plan.joins[1].anchor_name, "unused", "nil captures have donors")
        eq(#nil_plan.read_set, 1, "nil state not frozen")
        local false_source = "local unused=false\nlocal function f() return unused end"
        local false_entry = capture(false_source)
        local false_plan = assert(Plan.Prepare(false_source, false_entry, { "f" }, current(false_entry, { "f" })))
        eq(false_plan.joins[1].anchor_name, "unused", "false captures have donors")
        eq(Anchor.Get(false_entry, "unused"), false, "false unchanged")

        -- Never executes candidate top-level calls, initializers or function body.
        local safe = source .. "\nerror('candidate executed')"
        local safe_plan = assert(Plan.Prepare(safe, entry, { "helper" }, published))
        eq(#safe_plan.functions, 1, "unknown top-level call not executed")
        local body_bomb = source:gsub("return counter %+ n", "error('body executed')")
        eq(#assert(Plan.Prepare(body_bomb, entry, { "helper" }, published)).functions, 1,
            "literal body never called")
        local state_bomb = source:gsub("local counter = 0", "local counter = error('initializer executed')")
        eq(#assert(Plan.Prepare(state_bomb, entry, { "helper" }, published)).functions, 1,
            "state initializer never called")
        eq(Anchor.Get(entry, "counter"), 0, "state initializer not adopted")
        eq(entry.loaded_source, source, "loaded source never rewritten")

        local tests = {
            { 9, entry, {"helper"}, published, "unsupported", "nonstring" },
            { "local function helper( end", entry, {"helper"}, published, "compile", "syntax" },
            { candidate, {}, {"helper"}, published, "unsupported", "dead entry" },
            { candidate, entry, "helper", published, "unsupported", "nonarray" },
            { candidate, entry, {[2]="helper"}, published, "unsupported", "hole" },
            { candidate, entry, { "helper", "helper" }, published, "unsupported", "duplicate selection" },
            { candidate, entry, { "1bad" }, published, "unsupported", "identifier" },
            { candidate, entry, { "helper" }, {}, "stale", "no publication" },
            { candidate, entry, { "helper" }, {helper=function() end}, "stale", "wrong identity" },
            { candidate, entry, { "counter" }, {counter=function() end}, "unsupported", "state not a definition" },
            { candidate, entry, { "alias" }, {alias=alias}, "unsupported", "alias not a definition" },
            { candidate .. "\nlocal extra=1", entry, {"helper"}, published, "unsupported", "add declaration" },
            { candidate:gsub("local alias = helper\n", ""), entry, {"helper"}, published, "unsupported", "delete declaration" },
            { candidate:gsub("local counter = 0", "local count = 0"), entry, {"helper"}, published, "unsupported", "rename declaration" },
            { "local config={}\nlocal counter=0\n" .. candidate:match("(local function helper.*)"), entry,
                {"helper"}, published, "unsupported", "reordered declarations" },
            { candidate .. "\nlocal counter=9", entry, {"helper"}, published, "unsupported", "duplicate declaration" },
            { candidate .. "\nreturn 42", entry, {"helper"}, published, "unsupported", "top return" },
            { candidate .. "\nhelper = alias", entry, {"helper"}, published, "unsupported", "nonliteral overwrite" },
            { candidate .. "\nhelper = function() return 9 end", entry, {"helper"}, published, "unsupported", "two definitions" },
            { candidate .. "\nif true then helper = alias end", entry, {"helper"}, published,
                "unsupported", "conditional overwrite" },
            { candidate .. "\ndo local helper_shadow = helper end", entry, {"helper"}, published,
                "unsupported", "control block conservatively refused" },
            { candidate:gsub("local function helper%(n%) return counter %+ n %* 10 end",
                "local helper = make_helper()"), entry, {"helper"}, published, "unsupported", "unknown RHS" },
            { candidate:gsub("local function helper%(n%) return counter %+ n %* 10 end",
                "local helper = function(n) return n end"), entry, {"helper"}, published,
                "unsupported", "declaration kind change" },
        }
        for _, test in ipairs(tests) do reject(unpack(test)) end
        local missing = {}
        for k,v in pairs(entry) do missing[k]=v end
        missing.missing = true
        reject(candidate, missing, {"helper"}, published, "unsupported", "missing")
        local drift = {}
        for k,v in pairs(entry) do drift[k]=v end
        drift.slots = {}
        for k,v in pairs(entry.slots) do drift.slots[k]=v end
        drift.slots.helper = drift.slots.counter
        reject(candidate, drift, {"helper"}, published, "stale", "slot drift")
        local conditional = source .. "\nif true then helper = alias end"
        local conditional_entry = capture(conditional)
        reject(conditional, conditional_entry, {"helper"}, current(conditional_entry, {"helper"}),
            "unsupported", "loaded conditional replacement")
        local meta_calls = 0
        local meta = setmetatable({}, { __index=function() meta_calls=meta_calls+1 error("metamethod") end })
        reject(candidate, meta, {"helper"}, published, "unsupported", "entry metatable")
        reject(candidate, entry, meta, published, "unsupported", "selection metatable")
        reject(candidate, entry, {"helper"}, meta, "unsupported", "publication metatable")
        eq(meta_calls, 0, "no metamethods")
        local keyword, keyword_error = Plan.Prepare(candidate, entry, {"end"}, {["end"]=function() end})
        eq(keyword,nil,"keyword cannot select a definition")
        eq(keyword_error.code,"unsupported","keyword refusal")
        local bom = "\239\187\191" .. source
        local bom_entry = capture(bom)
        local bom_plan = assert(Plan.Prepare("\239\187\191"..candidate,bom_entry,{"helper"},
            current(bom_entry,{"helper"})))
        eq(bom_plan.functions[1].definition.source_range.first,
            bom:find("local function helper",1,true),"BOM byte range")
        eq(bom_plan.functions[1].created.used[1],"counter","BOM actual capture")
        local semicolon_source = "local function f() return 1 end;"
        local semicolon_entry = capture(semicolon_source)
        eq(#assert(Plan.Prepare(semicolon_source,semicolon_entry,{"f"},current(semicolon_entry,{"f"}))).writes,
            1,"safe semicolon tail")

        -- Semicolon tails / same-line multiple statements cannot become a
        -- wrapper that executes arbitrary code while obtaining the closure.
        for _, suffix in ipairs({ "; error('tail executed')", "; helper = function() end",
            "; local x=1", " error('tail executed')" }) do
            local tailed = "local function f() return 1 end" .. suffix
            local base = "local function f() return 1 end"
            local e = capture(base)
            local value, err = Plan.Prepare(tailed, e, {"f"}, current(e, {"f"}))
            eq(value, nil, "unsafe tail refused " .. suffix)
            check(type(err) == "table", "unsafe tail error")
        end

        -- Supported direct forms all have real, definition-point captures.
        for _, form in ipairs({
            "local function f(n) return state+n end",
            "local f = function(n) return state+n end",
            "local f\nf = function(n) return state+n end",
            "local f\nfunction f(n) return state+n end",
        }) do
            local base = "local state=2\n" .. form
            local e = capture(base)
            local p = assert(Plan.Prepare(base:gsub("state%+n", "state+n*3"), e, {"f"}, current(e, {"f"})))
            eq(#p.functions, 1, "direct form " .. form)
            eq(#p.joins, 1, "direct form captures state")
            eq(p.joins[1].anchor_name, "state", "direct form donor")
            eq(Anchor.Get(e, "state"), 2, "direct form state unchanged")
        end

        local forward = "local function f() return late end\nlocal late=7"
        local e = capture(forward)
        local p = assert(Plan.Prepare(forward, e, {"f"}, current(e, {"f"})))
        eq(#p.joins, 0, "unseen later local stays global")
        eq(#p.functions[1].created.used, 0, "no fabricated capture")
        local capture_more = source:gsub("return counter %+ n", "return counter + n + #config.tag")
        local more = assert(Plan.Prepare(capture_more, entry, {"helper"}, published))
        eq(#more.joins, 2, "new capture of existing local")
        local shadow = source:gsub("return counter %+ n", "local counter=5 return counter+n")
        local shaded = assert(Plan.Prepare(shadow, entry, {"helper"}, published))
        eq(#shaded.joins, 0, "body shadow not guessed from token deps")

        eq(join_calls, 0, "zero premature joins")
        eq(set_calls, 0, "zero premature writes")
        eq(flush_calls, 0, "zero premature flushes")
        local set_stub = debug.setupvalue
        debug.setupvalue = nil
        reject(candidate,entry,{"helper"},published,"capability","no write capability")
        debug.setupvalue = set_stub
        local get_api = debug.getupvalue
        debug.getupvalue = nil
        reject(candidate,entry,{"helper"},published,"capability","no enumeration capability")
        debug.getupvalue = get_api
    end)
    debug.upvaluejoin, debug.setupvalue, _G.jit = original_join, original_set, original_jit
    check(ok, "preparation suite: " .. tostring(problem))

    if type(original_join) == "function" then
        -- Test-only commit proves helper propagation, without rebuilding old
        -- consumers or refreshing independent aliases.
        local p = assert(Plan.Prepare(candidate, entry, {"helper"}, published))
        commit(p)
        eq(Anchor.Get(entry, "pattern"), pattern, "old consumer identity retained")
        eq(Anchor.Get(entry, "alias"), alias, "alias cell retained")
        eq(pattern(3), 30, "old consumer reads new helper")
        eq(alias(3), 3, "independent alias keeps old function")
        Anchor.Get(entry, "setter")(11)
        eq(pattern(3), 41, "external state setter remains live")
        eq(alias(3), 14, "alias shares state but not function cell")
        local newer = candidate:gsub("n %* 10", "n * 20")
        local p2 = assert(Plan.Prepare(newer, entry, {"helper"}, current(entry, {"helper"})))
        commit(p2)
        eq(pattern(3), 71, "second publication follows actual function identity")
        eq(entry.loaded_source, source, "two commits do not rewrite loaded baseline")
        reject(newer, entry, {"helper"}, published, "stale", "old publication after commit")
        assert(Anchor.Set(entry, "helper", function() return 99 end))
        reject(newer, entry, {"helper"}, {helper=p2.writes[1].value}, "stale", "external function setter")

        local recursion = "local function f(n) if n<=0 then return 0 end return 1+f(n-1) end"
        local r = capture(recursion)
        local old = Anchor.Get(r, "f")
        local rp = assert(Plan.Prepare(recursion:gsub("1%+f", "10+f"), r, {"f"}, current(r, {"f"})))
        eq(#rp.joins, 1, "self-recursive real capture")
        eq(rp.joins[1].anchor_name, "f", "self-recursive donor")
        eq(old(4), 4, "no early recursion mutation")
        commit(rp)
        eq(Anchor.Get(r, "f")(4), 40, "new self recursion")
        eq(old(4), 31, "old recursive closure follows cell")

        local mutual = "local a,b\na=function(n) if n<=0 then return 0 end return 1+b(n-1) end\n"
            .. "b=function(n) if n<=0 then return 0 end return 2+a(n-1) end"
        local e = capture(mutual)
        local a,b = Anchor.Get(e,"a"),Anchor.Get(e,"b")
        local changed = mutual:gsub("1%+b","10+b"):gsub("2%+a","20+a")
        local mp = assert(Plan.Prepare(changed,e,{"b","a"},current(e,{"a","b"})))
        eq(#mp.functions,2,"mutual definitions prepared before writes")
        eq(mp.functions[1].name,"a","mutual source order")
        eq(#mp.joins,2,"mutual two real captures")
        eq(a(2),3,"mutual old values before commit")
        commit(mp)
        eq(Anchor.Get(e,"a")(2),30,"mutual new a")
        eq(Anchor.Get(e,"b")(2),30,"mutual new b")
        eq(a(2),21,"old a calls new b")
        eq(b(2),12,"old b calls new a")

        -- State values need not remain frozen between prepare and test commit.
        local s = capture("local value\nlocal function f() return value end")
        local sp = assert(Plan.Prepare(s.loaded_source,s,{"f"},current(s,{"f"})))
        assert(Anchor.Set(s,"value",false))
        commit(sp)
        eq(Anchor.Get(s,"f")(),false,"state can change after preparation")
        assert(Anchor.Set(s,"value",{tag="live"}))
        eq(Anchor.Get(s,"f")().tag,"live","whole-table state replacement")

        local q = capture("local f = function() return f end")
        local qp = assert(Plan.Prepare(q.loaded_source,q,{"f"},current(q,{"f"})))
        eq(#qp.joins,0,"local literal initializer self is global")
        local saved = _G.f
        _G.f = "global-tag"
        commit(qp)
        eq(Anchor.Get(q,"f")(),"global-tag","initializer self remains late-bound global")
        _G.f = saved
    end
    for _, label in ipairs(failures) do print("[FunctionPlan] FAIL " .. label) end
    return { passed = passed, failed = failed, failures = failures }
end
return M
