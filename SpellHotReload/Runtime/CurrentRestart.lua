-- Current-practice workflow. No discovery, compilation, publication or adapter hook.
-- Plugin owns request lifetime/UI scope; CardTarget owns frozen publication proof.
-- This module owns request state and concrete practice handoff. Accepted means requested,
-- not that a new stage or Boss has become ready.
local Target = require("SpellHotReload.Adapters.Card.CardTarget")
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

-- Allocate before commit; Card owns frozen identity and actual-version proof.
function M.Freeze(target,capture)
    local run,err=Target.FreezeRestart(target,capture)
    if not run then return refuse(target,message(err)) end
    run.state,run.attempts,run.ready="prepared",0,"unobserved"
    return run
end
function M.BindReceipt(run,receipt,capture)
    if not plain(run) or run.kind~="versioned-card-restart" or run.state~="prepared" then
        return refuse(run,"prepared frozen restart request required")
    end
    local ok,err=Target.BindRestart(run,receipt,capture)
    if not ok then return refuse(run,message(err)) end
    run.receipt,run.snapshot,run.state=receipt,receipt.snapshot,"pending"
    return true
end
-- Fresh lifecycle only. No current selection, source read, analysis or publish.
function M.Request(run,live)
    if not plain(run) or run.kind~="versioned-card-restart" then
        return refuse(run,"committed frozen Card restart required")
    end
    if run.state=="issuing" then return refuse(run,"restart is already active") end
    if run.state~="pending" and run.state~="failed" and run.state~="accepted" then
        return refuse(run,"committed frozen request state required")
    end
    local valid,why=Target.CheckRestart(run,live)
    if not valid then return refuse(run,message(why)) end
    if Binding.IsReplay() then return refuse(run,"replay mode not supported") end
    -- Accepted is revalidated but never handed off twice or called Boss-ready.
    if run.state=="accepted" then return true end
    run.state,run.attempts="issuing",run.attempts+1
    local ok,err=pcall(M.Handoff,run.class_key,run.name,run.card,run.slot,run.include_previous)
    if not ok then run.state="failed";return refuse(run,message(err)) end
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
