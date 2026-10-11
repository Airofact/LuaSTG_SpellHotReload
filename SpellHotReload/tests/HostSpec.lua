--------------------------------------------------------------------------------
--- SpellHotReload tests/HostSpec.lua
---
--- Spec for the host-call adapter. Host.lua rebuilds a registered host
--- registration (today `stage.group.DefStageFunc`) through the generic
--- four-hook contract, so this spec covers parsing (dynamic and literal stage
--- names, bodies whose own commas must not split the arguments), identity,
--- inject-time isolation, the single-slot commit, the driver's whole-file
--- pipeline, and every failure path.
---
--- Runs under plain Lua 5.1 and LuaJIT with the game directory as cwd
--- (see tests/Run.lua).
--------------------------------------------------------------------------------

local Adapter = require("SpellHotReload.Adapter")
local NodeRegistry = require("SpellHotReload.NodeRegistry")
local Driver = require("SpellHotReload.Driver")
local Value = require("SpellHotReload.Value")
local Host = require("SpellHotReload.Host")
local IR = require("SpellHotReload.Source.TopLevelIR")

local M = {}
local passed, failed = 0, 0
local failures = {}

local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = label
    end
end

local function eq(actual, expected, label)
    check(actual == expected,
        label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

local CALLEE = "stage.group.DefStageFunc"
local OPTS = { host_calls = Host.Callees }
local GLOBALS = { "stage", "jit" }

local function host_registry()
    local registry = NodeRegistry.New()
    assert(registry:Register("host", Host))
    return registry
end

local function host_driver()
    return Driver.New({ adapters = host_registry() })
end

local function full_driver()
    local registry = NodeRegistry.New()
    assert(registry:Register({ "global", "field", "local" }, Value))
    assert(registry:Register("host", Host))
    return Driver.New({ adapters = registry })
end

local function parse(text)
    return Host.Parse({ text = text })
end

function M.run()
    local saved = {}
    for _, key in ipairs(GLOBALS) do saved[key] = rawget(_G, key) end

    local ok, err = xpcall(function()
        --------------------------------------------------------------------
        -- contract and registration
        --------------------------------------------------------------------
        do
            eq(Adapter.Validate(Host), true, "adapter: host satisfies the contract")
            eq(Host.Restartable, false, "adapter: a plain assignment needs no restart")
            eq(Host.carriers.host, true, "adapter: the host carrier is declared")
            eq(Host.Callees[CALLEE], true, "adapter: DefStageFunc is a handled callee")

            local registry = NodeRegistry.New()
            eq(registry:Register("host", Host), true, "registry: the host carrier registers")
            eq(registry:For({ carrier = "host" }), Host, "registry: host nodes route to the adapter")
            eq(registry:For({ carrier = "global" }), Adapter.Fallback,
                "registry: other carriers still fall back")
        end

        do
            -- Host.Register installs the callee list into TopLevelIR so a bare
            -- analyzer classifies the call as `host`; the change is restored.
            local prior = IR.HostCalls[CALLEE]
            IR.HostCalls[CALLEE] = nil

            local before = IR.Analyze("stage.group.DefStageFunc('A@Easy', 'init', function(self) end)")[1]
            eq(before.carrier, "effect", "register: an unregistered callee is an effect node")

            local returned = Host.Register()
            eq(returned, IR.HostCalls, "register: the default target is TopLevelIR.HostCalls")
            eq(IR.HostCalls[CALLEE], true, "register: the callee is installed")

            local after = IR.Analyze("stage.group.DefStageFunc('A@Easy', 'init', function(self) end)")[1]
            eq(after.carrier, "host", "register: the analysed callee is now a host node")
            eq(after.callee, CALLEE, "register: the host node keeps its callee path")

            IR.HostCalls[CALLEE] = prior
        end

        --------------------------------------------------------------------
        -- parsing
        --------------------------------------------------------------------
        do
            local site = assert(parse("stage.group.DefStageFunc('A@Easy', 'init', function(self) end)"))
            eq(site.callee, CALLEE, "parse: callee path")
            eq(site.stagename_src, "'A@Easy'", "parse: literal stage name slice")
            eq(site.funcname_src, "'init'", "parse: literal function name slice")
            eq(site.func_src, "function(self) end", "parse: function body slice")

            -- The generator's real shape: a dynamic stage name, nested call body.
            local dynamic = [[stage.group.DefStageFunc(string.format("%s@%s","Stage1","Easy"),'init',function(self)
        stage.group.initTask(self, function(self)
            ST1_FLOW(self, difficulty, "Easy")
        end)
    end)]]
            site = assert(parse(dynamic))
            eq(site.stagename_src, [[string.format("%s@%s","Stage1","Easy")]],
                "parse: a dynamic stage name is kept whole")
            eq(site.funcname_src, "'init'", "parse: the function name after a dynamic stage name")
            eq(site.func_src:sub(1, 8), "function", "parse: the nested body starts at `function`")
            eq(site.func_src:sub(-3), "end", "parse: the nested body ends at its matching `end`")
            check(site.func_src:find("ST1_FLOW", 1, true) ~= nil,
                "parse: the nested body is inside the slice")

            -- A body whose own top-level commas sit at the call's nesting level
            -- must not be mistaken for argument separators (DPS Test does this).
            local commafull = [[stage.group.DefStageFunc('A@Easy', 'init', function(self)
        local bx, by = 1, 2
        return bx + by
    end)]]
            site = assert(parse(commafull))
            eq(site.stagename_src, "'A@Easy'", "parse: body commas leave the stage-name slot alone")
            eq(site.funcname_src, "'init'", "parse: body commas leave the function-name slot alone")
            check(site.func_src:find("local bx, by", 1, true) ~= nil,
                "parse: body top-level commas stay inside the function slice")
            check(site.func_src:find("return bx + by", 1, true) ~= nil,
                "parse: the body tail is inside the slice")
        end

        do
            local site, reason = parse("stage.group.DefStageFunc('A@Easy', 'init')")
            eq(site, nil, "parse: two arguments are rejected")
            check(tostring(reason):find("3 arguments", 1, true) ~= nil, "parse: the arity is named")

            site, reason = parse("stage.group.DefStageFunc('A@Easy', 'init', 5)")
            eq(site, nil, "parse: a non-function third argument is rejected")
            check(tostring(reason):find("inline function", 1, true) ~= nil,
                "parse: the reason names the function")

            site = parse("stage.group.DefStageFunc('A@Easy', 'init', function(self) end, 7)")
            eq(site, nil, "parse: a trailing fourth argument is rejected")

            site, reason = parse("other.mod.Func('A@Easy', 'init', function(self) end)")
            eq(site, nil, "parse: an unhandled callee is rejected")
            check(tostring(reason):find("no handler", 1, true) ~= nil,
                "parse: the unhandled callee is named")

            site = parse("DefStageFunc('A@Easy', 'init', function(self) end)")
            eq(site, nil, "parse: a bare callee name is not handled")

            site, reason = parse("not a call")
            eq(site, nil, "parse: a non-call statement is rejected")
            check(tostring(reason):find("argument list", 1, true) ~= nil, "parse: the non-call reason")
        end

        --------------------------------------------------------------------
        -- identity
        --------------------------------------------------------------------
        do
            local nodes = assert(IR.Analyze([[
stage.group.DefStageFunc('A@Easy', 'init', function(self) return 1 end)
stage.group.DefStageFunc('B@Easy', 'init', function(self) return 2 end)
]], OPTS))
            eq(#nodes, 2, "signature: two host nodes are found")
            eq(nodes[1].carrier, "host", "signature: the first node is a host node")
            check(Host.Signature(nodes[1]) ~= Host.Signature(nodes[2]),
                "signature: two registrations in one file differ")

            local reflowed = assert(IR.Analyze(
                "stage.group.DefStageFunc(  'A@Easy'  ,  'init'  , function(self) return 1 end)", OPTS))[1]
            eq(Host.Signature(reflowed), Host.Signature(nodes[1]),
                "signature: reformatting the whitespace is stable")

            eq(Host.Signature({ callee = CALLEE }),
                Host.Signature({ callee = CALLEE, text = "garbage" }),
                "signature: an unparseable node keys on its callee")
        end

        --------------------------------------------------------------------
        -- locate and inject never touch the live definition
        --------------------------------------------------------------------
        do
            local filler = function() end
            stage = { stages = { ['A@Easy'] = { init = function() return "old" end, frame = filler } } }
            local group = stage.stages['A@Easy']

            local text = "stage.group.DefStageFunc('A@Easy', 'init', function(self) return 'new' end)"
            local node = assert(IR.Analyze(text, OPTS))[1]
            eq(node.carrier, "host", "locate: the call is a host node")

            local handle = assert(Host.Locate(node))
            eq(group.init(), "old", "locate: the live definition is untouched")
            eq(group.frame, filler, "locate: sibling slots are untouched")

            local plan = assert(Host.Inject(handle, node, {}))
            eq(group.init(), "old", "inject: the live definition is still untouched")
            eq(type(plan.value), "function", "inject: a fresh function is built")
            eq(plan.stagename, "A@Easy", "inject: the stage name is evaluated")
            eq(plan.funcname, "init", "inject: the function name is evaluated")
            eq(plan.value(), "new", "inject: the rebuilt body runs the new source")
        end

        do
            local handle, reason = Host.Locate({ carrier = "global" })
            eq(handle, nil, "locate: a non-host carrier is declined")
            check(tostring(reason):find("carrier 'global'", 1, true) ~= nil,
                "locate: the decline names the carrier")

            local plan, ireason = Host.Inject(nil, {}, {})
            eq(plan, nil, "inject: a missing handle is refused")
            check(tostring(ireason):find("located host handle", 1, true) ~= nil,
                "inject: the refusal names the handle")
        end

        --------------------------------------------------------------------
        -- inject-time isolation and the escaped closure
        --------------------------------------------------------------------
        do
            _G.HOST_LEAK = nil
            local text = [[stage.group.DefStageFunc((function() HOST_LEAK = 1 return 'A@Easy' end)(), 'init', function(self) end)]]
            local node = assert(IR.Analyze(text, OPTS))[1]
            local plan = assert(Host.Inject(assert(Host.Locate(node)), node, {}))
            eq(plan.stagename, "A@Easy", "sandbox: the stage-name expression still evaluates")
            eq(rawget(_G, "HOST_LEAK"), nil, "sandbox: an inject-time global write does not leak")
        end

        do
            _G.HOST_BODY = nil
            local text = "stage.group.DefStageFunc('A@Easy', 'init', function(self) HOST_BODY = 7 end)"
            local node = assert(IR.Analyze(text, OPTS))[1]
            local plan = assert(Host.Inject(assert(Host.Locate(node)), node, {}))
            plan.value()
            eq(rawget(_G, "HOST_BODY"), 7,
                "sandbox: a committed body writes the real global, not the sandbox")
        end

        --------------------------------------------------------------------
        -- a sibling local reaches the rebuilt function
        --------------------------------------------------------------------
        do
            stage = { stages = { ['A@Easy'] = { init = function() return "old" end } } }
            local driver = full_driver()
            local content =
                "local base = 5\nstage.group.DefStageFunc('A@Easy', 'init', function(self) return base end)"
            local store = {}

            local run = assert(driver:Plan("f.lua", content, { map = store, host_calls = Host.Callees }))
            eq(run.planned, 2, "local: the sibling local and the host node are both planned")
            eq(store.base, nil, "local: plan does not write the capture map")

            assert(driver:Commit(run))
            eq(store.base, 5, "local: the sibling local is committed")
            eq(stage.stages['A@Easy'].init(), 5,
                "local: the rebuilt host function sees the new sibling local")
        end

        --------------------------------------------------------------------
        -- commit writes exactly one slot
        --------------------------------------------------------------------
        do
            local filler = function() end
            stage = { stages = { ['A@Easy'] = { init = filler, frame = filler, render = filler } } }
            local stages_ref = stage.stages
            local group_ref = stage.stages['A@Easy']
            local keys_before = 0
            for _ in pairs(group_ref) do keys_before = keys_before + 1 end

            local result = assert(host_driver():Apply("f.lua",
                "stage.group.DefStageFunc('A@Easy', 'init', function(self) return 'new' end)", OPTS))
            eq(result.report.committed, 1, "commit: a single live mutation")
            check(stage.stages == stages_ref, "commit: the stage registry table is not rebuilt")
            check(stage.stages['A@Easy'] == group_ref, "commit: the stage group table is not rebuilt")
            eq(group_ref.init(), "new", "commit: the entry point is replaced")
            eq(group_ref.frame, filler, "commit: a sibling entry is untouched")
            eq(group_ref.render, filler, "commit: an unrelated entry is untouched")

            local keys_after = 0
            for _ in pairs(group_ref) do keys_after = keys_after + 1 end
            eq(keys_after, keys_before, "commit: no key is added or removed")
        end

        --------------------------------------------------------------------
        -- whole-file pipeline with the generator's dynamic names
        --------------------------------------------------------------------
        do
            stage = { stages = {
                ['Stage1@Easy'] = { init = function() return "old1" end },
                ['Stage2@Easy'] = { init = function() return "old2" end },
            } }
            local content = [[
stage.group.DefStageFunc(string.format("%s@%s","Stage1","Easy"),'init',function(self)
    return "new1"
end)
stage.group.DefStageFunc(string.format("%s@%s","Stage2","Easy"),'init',function(self)
    return "new2"
end)
]]
            local driver = full_driver()
            local run = assert(driver:Plan("f.lua", content, OPTS))
            eq(run.planned, 2, "pipeline: both stage entry points are planned")
            eq(stage.stages['Stage1@Easy'].init(), "old1", "pipeline: plan leaves stage1 live")
            eq(stage.stages['Stage2@Easy'].init(), "old2", "pipeline: plan leaves stage2 live")

            local report = driver:Commit(run)
            eq(report.committed, 2, "pipeline: both entry points commit")
            eq(stage.stages['Stage1@Easy'].init(), "new1", "pipeline: stage1 takes the new definition")
            eq(stage.stages['Stage2@Easy'].init(), "new2", "pipeline: stage2 takes the new definition")
        end

        --------------------------------------------------------------------
        -- change detection against a baseline
        --------------------------------------------------------------------
        do
            local driver = host_driver()
            local previous = [[
stage.group.DefStageFunc('A@Easy', 'init', function(self) return 1 end)
stage.group.DefStageFunc('B@Easy', 'init', function(self) return 2 end)
]]
            local edited = [[
stage.group.DefStageFunc('A@Easy', 'init', function(self) return 1 end)
stage.group.DefStageFunc('B@Easy', 'init', function(self) return 99 end)
]]
            local run = assert(driver:Plan("f.lua", edited,
                { previous = previous, host_calls = Host.Callees }))
            eq(Driver.Count(run, "unchanged"), 1, "change: the untouched registration is detected")
            eq(run.planned, 1, "change: only the edited registration is planned")
        end

        --------------------------------------------------------------------
        -- real generated file (skipped when the runtime mod is absent)
        --------------------------------------------------------------------
        do
            local f = io.open("mod/DiMS/DiMS_Main.lua", "rb")
            if f ~= nil then
                local content = f:read("*a")
                f:close()
                local nodes = assert(IR.Analyze(content, OPTS))

                local host_nodes, parsed, unparsed, dynamic_ok = 0, 0, 0, false
                for _, node in ipairs(nodes) do
                    if node.carrier == "host" then
                        host_nodes = host_nodes + 1
                        local site = Host.Parse(node)
                        if site == nil then
                            unparsed = unparsed + 1
                        else
                            parsed = parsed + 1
                            if not dynamic_ok
                                and site.stagename_src:find("string.format", 1, true) ~= nil then
                                local plan = Host.Inject(assert(Host.Locate(node)), node, {})
                                dynamic_ok = plan ~= nil and type(plan.stagename) == "string"
                                    and plan.stagename ~= ""
                            end
                        end
                    end
                end
                check(host_nodes > 0, "real file: has DefStageFunc registrations")
                eq(unparsed, 0, "real file: every DefStageFunc parses")
                eq(parsed, host_nodes, "real file: the parse count matches the host nodes")
                check(dynamic_ok, "real file: a dynamic stage name resolves through Inject")
            end
        end

        --------------------------------------------------------------------
        -- failure paths
        --------------------------------------------------------------------
        do
            stage = { stages = { ['A@Easy'] = { init = function() return "old" end } } }
            local run = assert(host_driver():Plan("f.lua",
                "stage.group.DefStageFunc('Missing@Easy', 'init', function(self) return 'x' end)", OPTS))
            eq(run.planned, 1, "fail: the slot is only checked at commit time")

            local report = host_driver():Commit(run)
            eq(report.committed, 0, "fail: commit refuses an unregistered stage group")
            eq(#report.failed, 1, "fail: the refusal is reported")
            check(tostring(report.failed[1].reason):find("not registered", 1, true) ~= nil,
                "fail: the refusal names the missing group")
            eq(stage.stages['A@Easy'].init(), "old", "fail: the existing slot is untouched")
            eq(stage.stages['Missing@Easy'], nil, "fail: no stage group is created as a side effect")
        end

        do
            local function plan_text(text)
                local node = assert(IR.Analyze(text, OPTS))[1]
                return Host.Inject(assert(Host.Locate(node)), node, {})
            end

            local plan, reason = plan_text("stage.group.DefStageFunc(nil, 'init', function(self) end)")
            eq(plan, nil, "fail: a nil stage name is refused at inject time")
            check(tostring(reason):find("stage name", 1, true) ~= nil,
                "fail: the refusal names the stage name")

            plan = plan_text("stage.group.DefStageFunc('', 'init', function(self) end)")
            eq(plan, nil, "fail: an empty stage name is refused")

            plan, reason = plan_text("stage.group.DefStageFunc('A@Easy', nil, function(self) end)")
            eq(plan, nil, "fail: a nil function name is refused")
            check(tostring(reason):find("function name", 1, true) ~= nil,
                "fail: the refusal names the function name")

            local direct, dreason = Host.Inject({
                site = { callee = CALLEE, stagename_src = "'A@Easy'",
                    funcname_src = "'init'", func_src = "5" },
            }, {}, {})
            eq(direct, nil, "fail: a third argument that is not a function is refused")
            check(tostring(dreason):find("function", 1, true) ~= nil, "fail: the non-function refusal")
        end

        do
            local prior = _G.stage
            _G.stage = nil
            local accepted = Host.Commit({}, { stagename = "A@Easy", funcname = "init", value = function() end })
            eq(accepted, false, "fail: commit refuses when the stage table is unavailable")
            _G.stage = prior

            accepted = Host.Commit({}, nil)
            eq(accepted, false, "fail: commit refuses a missing plan")
        end
    end, debug.traceback)

    for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
    _G.HOST_LEAK, _G.HOST_BODY = nil, nil
    if not ok then error(err, 0) end

    print(string.format("[SpellHotReload host] %d passed, %d failed", passed, failed))
    for _, label in ipairs(failures) do
        print("  FAIL: " .. label)
    end
    return { passed = passed, failed = failed, failures = failures }
end

return M
