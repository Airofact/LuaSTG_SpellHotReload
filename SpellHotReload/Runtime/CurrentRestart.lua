-- Current-practice workflow. No discovery, compilation, publication or adapter hook.
-- Plugin owns the request lifetime/UI scope; this module owns frozen receipt-linked
-- targets, validation and the concrete practice handoff. Accepted means requested,
-- not that a new stage or Boss has become ready.
local Binding = require("SpellHotReload.Adapters.Card.PracticeBinding")
local M = {}
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function message(err)
    if type(err)=="string" then return err end
    if plain(err) and type(rawget(err,"message"))=="string" then return rawget(err,"message") end
    return "operation refused"
end
local function refuse(run, detail)
    return nil, {phase="restart",code="restart",message=detail,
        file=plain(run) and rawget(run,"file") or nil}
end

-- Allocate before commit; candidate metadata never replaces the live target.
function M.Freeze(target, capture)
    return {kind="versioned-card-restart", state="prepared", attempts=0, ready="unobserved", file=target.file, session_id=target.session_id,
        entry=target.entry, anchor=target.entry.anchor, capture=capture, classes=target.classes,
        class_key=target.class_key, class=target.class, list=target.list, card=target.card,
        slot=target.slot, name=target.name, raw_name=rawget(target.card,"name"),
        include_previous=target.include_previous, key=target.key}
end

-- Only the trusted successful transaction receipt binds a prepared request.
-- A no-op receipt may legitimately retain the same installed snapshot.
function M.BindReceipt(run, receipt, capture)
    if not plain(run) or run.kind~="versioned-card-restart" or run.state~="prepared"
        or not plain(capture) or run.capture~=capture or not plain(receipt)
        or not plain(receipt.snapshot) or receipt.snapshot~=capture.snapshot then
        return refuse(run,"successful receipt for the frozen capture required")
    end
    run.receipt,run.snapshot,run.state=receipt,receipt.snapshot,"pending"
    return true
end

-- Fresh lifecycle data only. No candidate/plan/current-selection is consumed.
function M.Request(run, live)
    if not plain(run) or run.kind~="versioned-card-restart" or not plain(live)
        or not plain(run.entry) or not plain(run.capture) or not plain(run.snapshot)
        or not plain(run.receipt) or run.receipt.snapshot~=run.snapshot
        or not plain(run.snapshot.units) or not plain(rawget(run.snapshot.units,run.key))
        or not plain(rawget(run.snapshot.units,run.key).callbacks)
        or not plain(run.classes) or not plain(run.class) or not plain(run.list) or not plain(run.card)
        or not plain(run.capture.ownership) then
        return refuse(run,"committed frozen Card restart and explicit lifecycle view required")
    end
    if run.state=="issuing" then return refuse(run,"restart is already active") end
    if run.state~="pending" and run.state~="failed" and run.state~="accepted" then
        return refuse(run,"committed frozen request state required")
    end
    if live.released or live.poisoned
        or live.publication_error or run.session_id ~= live.session_id
        or live.entry ~= run.entry or run.entry.anchor ~= run.anchor
        or (run.entry.reloadable ~= true and not run.entry.missing)
        or live.classes ~= run.classes
        or rawget(run.classes,run.class_key) ~= run.class
        or rawget(run.class,"cards") ~= run.list or rawget(run.list,run.slot) ~= run.card
        or rawget(run.card,"name") ~= run.raw_name or run.capture.snapshot ~= run.snapshot then
        return refuse(run, "frozen restart target or session changed; restart game")
    end
    if Binding.IsReplay() then return refuse(run, "replay mode not supported") end
    -- include_previous can consume preceding slots too. Check original complete
    -- ownership, not merely a still-present selected card in a changed list.
    for _, owner in ipairs(run.capture.ownership) do
        if rawget(run.classes,owner.class_key) ~= owner.class
            or getmetatable(owner.class) ~= nil or getmetatable(owner.list) ~= nil
            or rawget(owner.class,"cards") ~= owner.list or #owner.list ~= #owner.slots then
            return refuse(run, "frozen class/list ownership changed; restart game")
        end
        local count = 0
        for slot in next, owner.list do
            if type(slot) ~= "number" or slot < 1 or slot > #owner.slots or slot ~= math.floor(slot)
                or rawget(owner.list,slot) ~= owner.slots[slot] then
                return refuse(run, "frozen slot ownership changed; restart game")
            end
            count = count + 1
        end
        if count ~= #owner.slots then return refuse(run, "frozen slot ownership changed; restart game") end
    end
    local unit = run.snapshot.units[run.key]
    for name, cb in next, unit.callbacks do
        if rawget(run.card,name) ~= cb.fn then return refuse(run, "committed callback changed; restart game") end
    end
    -- Revalidate even an accepted request; never issue the same successful run twice.
    if run.state=="accepted" then return true end
    run.state,run.attempts="issuing",run.attempts+1
    local ok, err = pcall(M.Handoff,run.class_key,run.name,run.card,run.slot,run.include_previous)
    if not ok then
        run.state="failed"
        return refuse(run,message(err))
    end
    run.state="accepted"
    return true
end

-- Concrete practice operation owned by this workflow.
-- Production always reaches it through Request after the checks above.
function M.Handoff(class_key, name, card, slot, include_previous)
	_sc_table["EXT_POS"] = { class_key, name, card, slot, include_previous }
	lstg.var.sc_index = "EXT_POS"
	stage.group.PracticeStart("Spell Practice@Spell Practice")
	M.FlyOut()
end

---Close the pause menu if it is currently open.
function M.FlyOut()
	if ext and ext.pause_menu then
		if not ext.pause_menu:IsKilled() then
			ext.pause_menu:FlyOut()
		end
	end
end

return M
