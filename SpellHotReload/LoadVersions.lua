--- First-load publication metadata, captured synchronously by Plugin:AdoptLoad.
--- Capture(entry, session_id, classes, defaults) must run before the load hook
--- returns, never later from Tick/afterMod/Apply or to repair a stale snapshot.
--- Functions use the ORIGINAL trailer map identities, not a fresh Anchor.Get.
--- Cards/defaults and full class/list/slot ownership are raw reads at first load.
--- Seed refusal is not a file-load failure; callers remember it without retry.
--- This service never executes source/bodies, joins, writes cells, publishes,
--- registers anything or owns a cache. Snapshot tables are read-only by contract.
--- R4 must recheck ownership and install subsequent versions atomically; this
--- capture is NOT a transaction, current-card remapper or production Apply.
local Source = require("SpellHotReload.FunctionPlan")
local Functions = require("SpellHotReload.FunctionVersions")
local Cards = require("SpellHotReload.CardVersions")
local Card = require("SpellHotReload.Card")
local M = { Kind = "SpellHotReload.LoadVersions", Version = 1 }
local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function fail(code, message, entry, key)
    return nil, { phase = "capture", code = code, message = message,
        file = plain(entry) and rawget(entry, "file") or nil, unit_key = key }
end
function M.Capture(entry, session_id, classes, defaults)
    if not plain(entry) or type(rawget(entry, "file")) ~= "string" or entry.file == ""
        or entry.reloadable ~= true or entry.missing or not plain(entry.map)
        or type(session_id) ~= "string" or session_id == "" then
        return fail("unsupported", "genuine reloadable first load and session required", entry)
    end
    if not plain(classes) or not plain(defaults) then
        return fail("unsupported", "plain first-load class registry and standard defaults required", entry)
    end
    local scan, err = Source.Inspect(entry.loaded_source)
    if not scan then return nil, err end
    local initial = {}
    for name in next, scan.definitions do initial[name] = rawget(entry.map, name) end
    local functions, ferr = Functions.Seed(entry, session_id, initial)
    if not functions then return nil, ferr end
    local match, merr = Card.Match(scan.analysis, { content = entry.loaded_source })
    if not match then return nil, merr end
    local owners, ownership = Card.CaptureOwnership(match, classes, entry)
    if not owners then return nil, ownership end
    local snapshot, cerr = Cards.Seed(functions, owners, defaults)
    if not snapshot then return nil, cerr end
    return { kind = M.Kind, version = M.Version, snapshot = snapshot,
        classes = classes, ownership = ownership }
end
return M
