--------------------------------------------------------------------------------
--- SpellHotReload.Host
---
--- The host-call adapter: rebuilds a registered stage-host registration through
--- the generic four-hook contract.
---
--- One callee is handled today, `stage.group.DefStageFunc(stagename, funcname,
--- f)`, whose host body is exactly
---
---     stage.stages[stagename][funcname] = f
---
--- (see game/data/THlib/ext/ext_stage_group.lua). The generator emits this call
--- for every stage entry point, usually with a dynamic stage name such as
--- `string.format("%s@%s", "Stage1", "Easy")`, so a node identity is the
--- evaluated (stagename, funcname) pair, not the literal argument text.
---
--- Hook mapping:
---   Locate  -> parse the call; structural identity only, never a live read
---   Inject  -> evaluate the two name expressions and rebuild the function
---              argument in an isolated sandbox (no function body ever runs)
---   Commit  -> stage.stages[stagename][funcname] = f     (the one live write)
---   Restart -> none. The host body is a plain assignment, so the next
---              invocation of the stage entry point already sees the new
---              definition; Host.Restartable is therefore false.
---
--- Injection uses the same "declare the captured siblings, then read the value"
--- technique as the Value adapter: the file-level locals captured at load are
--- bound by name, so the rebuilt body resolves them exactly as the generated
--- file did. When the driver walks a whole file, a changed top-level `local
--- function` is planned and committed first, and this adapter then picks the
--- recompiled function out of the same working map, which is what makes a stage
--- entry point that calls a named local function reload as a unit.
---
--- Registering the callee: TopLevelIR only classifies a call as the `host`
--- carrier when its callee path is registered. Pass `Host.Callees` as the
--- driver's `host_calls` option, or call `Host.Register()` to install it into
--- `TopLevelIR.HostCalls`.
--------------------------------------------------------------------------------

local Lexer = require("SpellHotReload.Lexer")
local TopLevelIR = require("SpellHotReload.TopLevelIR")

local Host = {}

Host.name = "Host"
Host.Restartable = false
Host.carriers = { host = true }

---Callee paths this adapter can rebuild. Register them with the IR analyser so
---that `stage.group.DefStageFunc(...)` is classified as a `host` node instead of
---an unadapted `effect` call.
---@type table<string, boolean>
Host.Callees = { ["stage.group.DefStageFunc"] = true }

local compile = loadstring or load
local unpack = table.unpack or unpack
local apply_env = setfenv

local OPEN = { ["("] = true, ["{"] = true, ["["] = true }
local CLOSE = { [")"] = true, ["}"] = true, ["]"] = true }

--------------------------------------------------------------------------------
--- registration
--------------------------------------------------------------------------------

---Copy every callee this adapter handles into `target` (default:
---`TopLevelIR.HostCalls`) and return it, so a caller can register the host
---carrier without hand-maintaining the callee list.
---@param target table?
---@return table
function Host.Register(target)
    target = target or TopLevelIR.HostCalls
    for callee in pairs(Host.Callees) do
        target[callee] = true
    end
    return target
end

--------------------------------------------------------------------------------
--- parsing
--------------------------------------------------------------------------------

local function slice(text, tokens, first, last)
    return text:sub(tokens[first].pos, tokens[last].pos + #tokens[last].value - 1)
end

---Collapse runs of whitespace so a signature stays stable across reformatting.
local function one_line(text)
    return (text:gsub("%s+", " "))
end

---Describe the `Callee(a, b, c)` call site of one node in a form the hooks can
---rebuild. The three fields stay source text here; Inject evaluates the first
---two and rebuilds the third.
---@param node table
---@return table? site  -- { callee, stagename_src, funcname_src, func_src }
---@return string? reason
function Host.Parse(node)
    if type(node) ~= "table" or type(node.text) ~= "string" then
        return nil, "node has no source text"
    end
    local text = node.text
    local tokens = Lexer.Tokenize(text)
    if #tokens == 0 then return nil, "empty statement" end

    -- The callee is a dotted path, so the first `(` opens the argument list.
    local paren = nil
    for i = 1, #tokens do
        if tokens[i].value == "(" then
            paren = i
            break
        end
    end
    if paren == nil then return nil, "call has no argument list" end

    local parts = {}
    for i = 1, paren - 1 do
        parts[#parts + 1] = tokens[i].value
    end
    local callee = table.concat(parts, "")
    if Host.Callees[callee] ~= true then
        return nil, "Host has no handler for call '" .. tostring(callee) .. "'"
    end

    -- Split the argument list into three ranges. Only the first two commas at
    -- the call's own nesting level are separators: the third argument is an
    -- inline function whose body can contain commas, brackets and further
    -- `function ... end` blocks at that same nesting level (e.g. the DPS Test
    -- stage has `local bx, by = ...` inside it), so the remainder of the list is
    -- taken whole instead of being re-split.
    local ranges, nest, start, close = {}, 0, paren + 1, nil
    for i = paren, #tokens do
        local value = tokens[i].value
        if OPEN[value] then
            nest = nest + 1
        elseif CLOSE[value] then
            nest = nest - 1
            if nest == 0 then
                close = i
                break
            end
        elseif value == "," and nest == 1 and #ranges < 2 then
            ranges[#ranges + 1] = { first = start, last = i - 1 }
            start = i + 1
        end
    end
    if close == nil then return nil, "unclosed argument list" end
    if #ranges == 2 and start <= close - 1 then
        ranges[3] = { first = start, last = close - 1 }
    end

    if #ranges ~= 3 then
        return nil, callee .. " expects 3 arguments, found " .. tostring(#ranges)
    end
    -- The third argument must be one complete function literal: the lexer marks
    -- the block depth, so the body's matching `end` sits exactly one level below
    -- the opening `function`. This rejects a bare value and any trailing
    -- argument smuggled past the second comma.
    local first_arg, last_arg = ranges[3].first, ranges[3].last
    if tokens[first_arg].value ~= "function"
        or tokens[last_arg].value ~= "end"
        or tokens[last_arg].depth ~= tokens[first_arg].depth + 1 then
        return nil, "the third argument is not a single inline function"
    end

    return {
        callee = callee,
        stagename_src = slice(text, tokens, ranges[1].first, ranges[1].last),
        funcname_src = slice(text, tokens, ranges[2].first, ranges[2].last),
        func_src = slice(text, tokens, ranges[3].first, ranges[3].last),
    }
end

---Mirror of Driver.Signature for a host node. Identity is the registration
---slot, so the callee plus both name expressions keep two entries of the same
---file apart.
---@param node table
---@return string
function Host.Signature(node)
    local site = type(node) == "table" and Host.Parse(node) or nil
    local key
    if site ~= nil then
        key = site.callee .. "(" .. one_line(site.stagename_src)
            .. ", " .. one_line(site.funcname_src) .. ")"
    elseif type(node) == "table" then
        key = tostring(node.callee)
    else
        key = ""
    end
    return table.concat({ "host", "call", key, "0" }, "|")
end

--------------------------------------------------------------------------------
--- hooks
--------------------------------------------------------------------------------

function Host.Locate(node, env)
    if type(node) ~= "table" or node.carrier ~= "host" then
        return nil, "Host does not handle carrier '"
            .. tostring(node ~= nil and node.carrier or nil) .. "'"
    end
    local site, reason = Host.Parse(node)
    if site == nil then return nil, reason end
    return { site = site }
end

---Sandbox whose writes never escape; reads fall through to the real globals.
local function isolated_env()
    return setmetatable({}, { __index = _G })
end

---Build the new function argument and resolve the registration slot. Nothing
---the running game can observe changes here: the sandbox isolates inject-time
---writes, and the function body is never executed.
---@return table? plan  -- { value, stagename, funcname, site }
---@return string? reason
function Host.Inject(handle, node, env)
    local site = type(handle) == "table" and handle.site or nil
    if type(site) ~= "table" then
        return nil, "Inject expects a located host handle"
    end
    env = env or {}
    local sibs = env.working or env.map or {}

    local names = {}
    for name in pairs(sibs) do
        names[#names + 1] = name
    end
    table.sort(names)

    local decl = ""
    if #names > 0 then
        decl = "local " .. table.concat(names, ", ") .. " = ...\n"
    end
    local src = decl .. "return (" .. site.func_src .. "), ("
        .. site.stagename_src .. "), (" .. site.funcname_src .. ")"

    local chunk, cerr = compile(src, "@Host.Inject:" .. tostring(env.file))
    if chunk == nil then
        return nil, "compile failed: " .. tostring(cerr)
    end
    if apply_env ~= nil then
        apply_env(chunk, isolated_env())
    end

    local args = {}
    for i = 1, #names do
        args[i] = sibs[names[i]]
    end

    local ok, fn, stagename, funcname = pcall(chunk, unpack(args, 1, #names))
    if not ok then
        return nil, "evaluation failed: " .. tostring(fn)
    end
    if type(fn) ~= "function" then
        return nil, "the third argument did not evaluate to a function"
    end
    if type(stagename) ~= "string" or stagename == "" then
        return nil, "the stage name did not evaluate to a non-empty string"
    end
    if type(funcname) ~= "string" or funcname == "" then
        return nil, "the function name did not evaluate to a non-empty string"
    end
    -- The sandbox isolates inject-time reads; a closure that escapes it must run
    -- against the real globals once committed, exactly as the source intended.
    if apply_env ~= nil then
        apply_env(fn, _G)
    end

    return { value = fn, stagename = stagename, funcname = funcname, site = site }
end

---The single live mutation: write the rebuilt function into the stage table.
---A reload replaces one entry, and the file's generated wiring is never
---re-executed, so no stage, class or card registration is duplicated.
---@return boolean
---@return string? reason
function Host.Commit(handle, plan, env)
    if type(plan) ~= "table" then
        return false, "Commit expects a host plan"
    end
    local stages = _G.stage ~= nil and _G.stage.stages or nil
    if type(stages) ~= "table" then
        return false, "the engine stage table is unavailable"
    end
    local group = stages[plan.stagename]
    if type(group) ~= "table" then
        return false, "stage group '" .. tostring(plan.stagename) .. "' is not registered"
    end
    group[plan.funcname] = plan.value
    if jit ~= nil and jit.flush ~= nil then
        pcall(jit.flush)
    end
    return true
end

return Host
