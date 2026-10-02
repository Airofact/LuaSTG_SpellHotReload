--- Full-file discovery only: no candidate execution or publication.
--- Inputs/outputs are read-only by contract, not protected Lua tables.
local IR = require("SpellHotReload.TopLevelIR")
local Adapter = require("SpellHotReload.Adapter")
local M = {}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function text(value)
    return type(value) == "string" and value ~= ""
end

local function integer(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
        and value == math.floor(value)
end

-- Do not use # alone: holes and extra keys must not be silently discarded.
local function dense(value)
    if not plain(value) then return nil end
    local count, max = 0, 0
    for key in next, value do
        if not integer(key) or key < 1 then return nil end
        count = count + 1
        max = math.max(max, key)
    end
    if count ~= max then return nil end
    return count
end

local function message(value)
    if type(value) == "string" then return value end
    return "non-string error (" .. type(value) .. ")"
end

local function failure(phase, code, detail, file, unit_key)
    return nil, {
        phase = phase, code = code, message = message(detail),
        file = file, unit_key = unit_key,
    }
end

local CLAIM_KINDS = {
    declaration = true, definition = true, constructor = true,
    callback = true, ["host-slot"] = true,
}

--- Claim keys are canonical semantic identities supplied by adapters.
--- Length-prefixing prevents accidental delimiter collisions; byte-range overlap
--- is NOT ownership. This layer cannot prove an adapter's semantic key is correct.
local function claim_key(claim)
    return claim.kind .. ":" .. #claim.key .. ":" .. claim.key
end

---Discover(registry, content, common?, options?) -> snapshot | nil, error.
---common is shallow-copied; file/session/generation/version references survive.
---Each Match sees the same full analysis, including unchanged/unselected units.
---unit.key is snapshot-local only. context/binding/deps remain adapter-owned.
function M.Discover(registry, content, supplied, options)
    if supplied ~= nil and not plain(supplied) then
        return failure("analyze", "unsupported", "common must be a plain table")
    end
    local common = {}
    for key, value in next, supplied or {} do common[key] = value end
    local file = common.file
    if not text(file) or type(content) ~= "string" then
        return failure("analyze", "unsupported", "file/content must be strings", file)
    end
    if type(registry) ~= "table" then
        return failure("match", "unsupported", "discovery registry required", file)
    end
    local ok, adapters = pcall(function() return registry:Discoveries() end)
    local count = ok and dense(adapters) or nil
    if count == nil then
        return failure("match", "unsupported", "invalid discovery enumeration", file)
    end
    local ids = {}
    for _, adapter in ipairs(adapters) do
        local valid, reason = Adapter.ValidateDiscovery(adapter)
        if not valid then return failure("match", "unsupported", reason, file) end
        local id = rawget(adapter, "Id")
        if ids[id] then
            return failure("match", "ownership", "duplicate adapter Id: " .. id, file)
        end
        ids[id] = true
    end

    local analyzed, nodes, reason, analysis = pcall(IR.Analyze, content, options)
    if not analyzed or nodes == nil or analysis == nil then
        return failure("analyze", "unsupported", analyzed and reason or nodes, file)
    end
    common.content, common.analysis = content, analysis
    local snapshot = {
        common = common, analysis = analysis, units = {}, entries = {},
        by_key = {}, adapter_contexts = {}, claims = {}, claim_owners = {},
    }
    for _, adapter in ipairs(adapters) do
        local id = rawget(adapter, "Id")
        local matched, result, err = pcall(rawget(adapter, "Match"), analysis, common)
        if not matched then
            return failure("match", "unsupported", result, file)
        end
        if result == nil then
            if plain(err) and text(err.code) and text(err.message) then
                return failure("match", err.code, err.message, file,
                    text(err.unit_key) and err.unit_key or nil)
            end
            return failure("match", "unsupported", err or "Match returned nil", file)
        end
        if not plain(result) or dense(result.units) == nil
            or dense(result.claims) == nil or not plain(result.context) then
            return failure("match", "unsupported", "invalid Match result: " .. id, file)
        end
        snapshot.adapter_contexts[id] = result.context
        local own = {}
        for _, unit in ipairs(result.units) do
            if not plain(unit) or not text(unit.key) or not text(unit.carrier)
                or not plain(unit.context) then
                return failure("match", "unsupported", "invalid unit: " .. id, file)
            end
            local key = unit.key
            if snapshot.by_key[key] ~= nil then
                return failure("match", "ownership", "duplicate unit key", file, key)
            end
            local ranges = dense(unit.source_ranges)
            if ranges == nil or ranges == 0 then
                return failure("match", "unsupported", "source_ranges required", file, key)
            end
            for _, range in ipairs(unit.source_ranges) do
                if not plain(range) or not integer(range.first)
                    or not integer(range.last) or range.first < 1
                    or range.last < range.first or range.last > #content then
                    return failure("match", "unsupported", "invalid source range", file, key)
                end
            end
            local entry = {
                unit = unit, adapter = adapter,
                context = {
                    common = common,
                    adapter = { file = result.context, unit = unit.context },
                },
            }
            own[key], snapshot.by_key[key] = entry, entry
            snapshot.units[#snapshot.units + 1] = unit
            snapshot.entries[#snapshot.entries + 1] = entry
        end
        for _, claim in ipairs(result.claims) do
            if not plain(claim) or not CLAIM_KINDS[claim.kind]
                or not text(claim.key) or not text(claim.unit_key)
                or own[claim.unit_key] == nil then
                return failure("match", "unsupported", "invalid semantic claim: " .. id, file)
            end
            local key = claim_key(claim)
            if snapshot.claim_owners[key] ~= nil then
                return failure("match", "ownership", "semantic claim already owned",
                    file, claim.unit_key)
            end
            snapshot.claim_owners[key] = own[claim.unit_key]
            snapshot.claims[#snapshot.claims + 1] = claim
        end
    end
    return snapshot
end

return M
