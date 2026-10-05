--- R4 read-only commit preflight for CardVersions selections.
--- Check(selection, capture, live) -> true | nil, structured commit error.
--- live must be freshly read by the orchestrator: {capture, snapshot, entry,
--- session_id, classes, content, released?, poisoned?}. Do not cache this view.
--- Byte equality is exact; capture/snapshot identity AND revisions are checked.
--- Complete FIRST-load class/list/slot ownership (including placeholders) and
--- all planned reads, live closure captures, writes and raw publications checked.
--- Ordinary state values are not frozen; only values read for selection/writes.
--- No compilation, business calls, joins, writes, flush, publication or restart.
--- Success is NOT a token/lock: the caller must check in its valid UI phase and
--- immediately transact without yielding/calling user code between check/write.
--- Phase lifetime, current-card remapping, journal/rollback/poison, version
--- installation and production Plugin/Driver wiring are separate R4 work.
--- Located selections additionally recheck their CardTarget source/current-root
--- proof with live.binding freshly read by trusted orchestration, including after
--- cache invalidation. Legacy fixed-layout selections need no binding.
--- Inputs are read-only by contract, not a hostile-plan sandbox. upvalueid is
--- optional: absent it, physical external rejoin cannot be proved, not probed.
local Target = require("SpellHotReload.CardTarget")
local Card = require("SpellHotReload.Card")
local M = { Kind = "SpellHotReload.CommitCheck", Version = 1 }
local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function integer(v)
    return type(v) == "number" and v >= 1 and v < math.huge and v == math.floor(v)
end
local function dense(v)
    if not plain(v) then return nil end
    local count, maximum = 0, 0
    for k in next, v do
        if not integer(k) then return nil end
        count, maximum = count + 1, math.max(maximum, k)
    end
    if count == maximum then return count end
end
local function fail(code, message, file, key)
    return nil, { phase="commit", code=code, message=message, file=file, unit_key=key }
end
local function check(selection, capture, live)
    if not plain(selection) or selection.kind ~= "SpellHotReload.CardVersions.Selection"
        or selection.version ~= 1 or not plain(selection.base)
        or not plain(capture) or capture.kind ~= "SpellHotReload.LoadVersions"
        or capture.version ~= 1 or not plain(live) then
        return fail("unsupported", "card selection, load capture and fresh live view required")
    end
    local base, entry = selection.base, live.entry
    local file = type(base.file) == "string" and base.file or nil
    if live.released or live.poisoned or not rawequal(live.capture, capture)
        or not rawequal(live.snapshot, base) or not rawequal(capture.snapshot, base)
        or live.session_id ~= base.session_id or selection.session_id ~= base.session_id
        or not plain(entry) or not rawequal(entry, base.entry) or not rawequal(selection.entry, entry)
        or entry.reloadable ~= true or entry.missing
        or entry.anchor ~= base.anchor or selection.anchor ~= base.anchor
        or type(base.anchor) ~= "function" or not plain(entry.slots)
        or entry.file ~= base.file or entry.loaded_source ~= base.loaded_source
        or selection.base_revision ~= base.revision
        or not plain(base.functions) or not plain(selection.functions)
        or not rawequal(selection.functions.base, base.functions)
        or selection.functions.base_revision ~= base.functions.revision then
        return fail("stale", "session, capture, anchor or publication revision changed", file)
    end
    if type(selection.content) ~= "string" or live.content ~= selection.content then
        return fail("stale", "candidate bytes changed", file)
    end
    if selection.location ~= nil then
        local checked, err = Target.CheckDiscovery(selection.location, live.binding, capture, live)
        if not checked then return fail(err.code, err.message, file, selection.location.key) end
    end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function"
        or type(debug.setupvalue) ~= "function" or type(debug.upvaluejoin) ~= "function" then
        return fail("capability", "shared-cell debug APIs unavailable", file)
    end
    local thread, main = coroutine.running()
    if thread and not main then return fail("unsupported", "commit check cannot run in a coroutine", file) end
    local seen, ownership_error = Card.CheckOwnership(capture, base, live.classes)
    if not seen then return nil, ownership_error end
    for _, name in ipairs({ "read_set", "capture_reads", "joins", "writes", "publications" }) do
        if dense(selection[name]) == nil then return fail("unsupported", "dense plan arrays required", file) end
    end
    local function cell(anchor, index, name)
        return anchor == base.anchor and integer(index) and type(name) == "string"
            and rawget(entry.slots, name) == index and debug.getupvalue(anchor, index) == name
    end
    for _, read in ipairs(selection.read_set) do
        if not plain(read) then return fail("unsupported", "invalid read record", file) end
        if read.target ~= nil then
            local valid, callback_error = Card.CheckCallbackRead(read, seen, file)
            if not valid then return nil, callback_error end
        else
            if not cell(read.anchor, read.index, read.name) then
                return fail("stale", "anchor read slot changed", file)
            end
            local _, value = debug.getupvalue(read.anchor, read.index)
            if not rawequal(value, read.value) then return fail("stale", "published function read changed", file) end
        end
    end
    local function join_valid(join)
        return plain(join) and type(join.fn) == "function" and integer(join.index)
            and type(join.name) == "string" and join.name == join.anchor_name
            and cell(join.anchor, join.donor, join.anchor_name)
            and debug.getupvalue(join.fn, join.index) == join.name
    end
    for _, read in ipairs(selection.capture_reads) do
        if not join_valid(read) then return fail("stale", "published capture slot changed", file) end
        if type(debug.upvalueid) == "function" then
            local a = debug.upvalueid(read.fn, read.index)
            local b = debug.upvalueid(read.anchor, read.donor)
            if a == nil or b == nil or a ~= b then
                return fail("stale", "published closure no longer shares the anchor cell", file)
            end
        end
    end
    for _, join in ipairs(selection.joins) do
        if not join_valid(join) then return fail("stale", "candidate join slot changed", file) end
    end
    local writes = {}
    for _, write in ipairs(selection.writes) do
        if not plain(write) or type(write.value) ~= "function" then
            return fail("unsupported", "function cell write required", file)
        end
        if writes[write.name] or not cell(write.anchor, write.index, write.name) then
            return fail("stale", "duplicate or changed write slot", file)
        end
        local _, value = debug.getupvalue(write.anchor, write.index)
        if not rawequal(value, write.before) then return fail("stale", "function write preimage changed", file) end
        writes[write.name] = true
    end
    local valid, publication_error = Card.CheckPublications(selection.publications, base, seen)
    if not valid then return nil, publication_error end
    return true
end

function M.Check(selection, capture, live)
    local ok, result, reason = pcall(check, selection, capture, live)
    if ok then return result, reason end
    -- Never stringify unknown error objects or consult their metamethods.
    local entry = plain(live) and rawget(live, "entry") or nil
    local file = plain(entry) and rawget(entry, "file") or nil
    return fail("stale", type(result) == "string" and result or "commit read failed",
        type(file) == "string" and file or nil)
end
return M
