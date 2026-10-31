-- Shared trial/rollback syntax discovery. No execution or publication.
local Source = require("SpellHotReload.Source.FileAnalysis")
local Adapter = require("SpellHotReload.Pipeline.Adapter")
local Cursor = require("SpellHotReload.Source.SyntaxCursor")
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

-- Match consumes one or more items and returns units immediately. BuildContext
-- derives owner-private file facts from accepted units; it never creates units.
function M.Discover(registry, source, supplied)
    if supplied~=nil and not plain(supplied) then return failure("analyze","unsupported","plain common required") end
    local common={};for k,v in next,supplied or {} do common[k]=v end
    local file=common.file
    if not text(file) or not Source.Validate(source) then return failure("analyze","unsupported","complete source and file required",file) end
    if common.source~=nil and common.source~=source then return failure("analyze","ownership","common source disagrees",file) end
    common.source=source
    local called,adapters=pcall(function() return registry:Discoveries() end)
    if not called or dense(adapters)==nil then return failure("match","unsupported","discovery registry required",file) end
    local snapshot={kind="SpellHotReload.FileMatch",version=7,common=common,units={},entries={},by_key={},
        adapter_contexts={},claims={},claim_owners={},mappings={},unmatched={},owners={}}
    local owned={}
    for _,adapter in ipairs(adapters) do
        local ok,why=Adapter.ValidateDiscovery(adapter)
        if not ok then return failure("match","unsupported",why,file) end
        if owned[adapter.Id] then return failure("match","ownership","duplicate adapter Id",file) end
        owned[adapter.Id]={units={},by_key={},mappings={}}
        snapshot.owners[adapter.Id]=adapter
    end
    local cursor=Cursor.New(source.analysis.statements)
    while not cursor:AtEnd() do
        local start=cursor:Mark()
        local selected,owner,finish
        for _,adapter in ipairs(adapters) do
            cursor:Reset(start)
            local ran,result,err=pcall(adapter.Match,cursor,common,owned[adapter.Id].by_key)
            local endpoint=cursor:Mark()
            cursor:Reset(start)
            if not ran then return failure("match","unsupported",result,file) end
            if err~=nil then
                return failure("match",plain(err) and text(err.code) and err.code or "unsupported",
                    plain(err) and err.message or err,file,plain(err) and err.unit_key or nil)
            end
            if result~=nil then
                if selected~=nil then return failure("match","ambiguous","multiple adapters match the same syntax start",file) end
                if endpoint<=start then return failure("match","unsupported","successful Match must advance",file) end
                selected,owner,finish=result,adapter,endpoint
            end
        end
        if selected==nil then
            snapshot.unmatched[#snapshot.unmatched+1]=start
            cursor:Take()
        else
            local own=owned[owner.Id]
            if not plain(selected) or dense(selected.units)==nil or #selected.units==0
                or dense(selected.claims)==nil or dense(selected.mappings)==nil then
                return failure("match","unsupported","units, claims and mappings required",file)
            end
            local returned,returned_keys={},{}
            for _,unit in ipairs(selected.units) do
                if not plain(unit) or not text(unit.key) or not text(unit.carrier) or not plain(unit.context)
                    or returned[unit] or returned_keys[unit.key] then return failure("match","unsupported","invalid or duplicate returned unit",file) end
                local existing=snapshot.by_key[unit.key]
                if existing and (existing.adapter~=owner or existing.unit~=unit) then
                    return failure("match","ownership","duplicate unit key",file,unit.key)
                end
                returned[unit]=true;returned_keys[unit.key]=unit
            end
            local covered={}
            for _,mapping in ipairs(selected.mappings) do
                if not plain(mapping) or not returned[mapping.unit] or not integer(mapping.first) or not integer(mapping.last)
                    or mapping.first<start or mapping.last<mapping.first or mapping.last>=finish then
                    return failure("match","unsupported","mapping must name returned units and consumed syntax",file)
                end
                for i=mapping.first,mapping.last do covered[i]=true end
            end
            for i=start,finish-1 do
                if not covered[i] then return failure("match","unsupported","consumed syntax has no unit mapping",file) end
            end
            local claim_keys={}
            for _,claim in ipairs(selected.claims) do
                if not plain(claim) or not CLAIM_KINDS[claim.kind] or not text(claim.key)
                    or not text(claim.unit_key) or not returned_keys[claim.unit_key] then
                    return failure("match","unsupported","claim must name a returned unit",file)
                end
                local key=claim_key(claim)
                if snapshot.claim_owners[key] or claim_keys[key] then
                    return failure("match","ownership","semantic claim already owned",file,claim.unit_key)
                end
                claim_keys[key]=true
            end
            -- No accepted unit/state is changed before the entire result passes.
            for _,unit in ipairs(selected.units) do
                if not snapshot.by_key[unit.key] then
                    unit.source_ranges={}
                    local entry={unit=unit,adapter=owner,context={common=common,adapter={unit=unit.context}}}
                    own.units[#own.units+1]=unit;own.by_key[unit.key]=unit
                    snapshot.units[#snapshot.units+1]=unit;snapshot.entries[#snapshot.entries+1]=entry
                    snapshot.by_key[unit.key]=entry
                end
            end
            for _,mapping in ipairs(selected.mappings) do
                local rows=source.analysis.statements
                local range={first=rows[mapping.first].source_range.first,last=rows[mapping.last].source_range.last}
                local unit=mapping.unit
                unit.source_ranges[#unit.source_ranges+1]=range
                local item={unit=unit,first=mapping.first,last=mapping.last}
                own.mappings[#own.mappings+1]=item;snapshot.mappings[#snapshot.mappings+1]=item
            end
            for _,claim in ipairs(selected.claims) do
                snapshot.claim_owners[claim_key(claim)]=snapshot.by_key[claim.unit_key]
                snapshot.claims[#snapshot.claims+1]=claim
            end
            cursor:Reset(finish)
        end
    end
    for _,adapter in ipairs(adapters) do
        local own=owned[adapter.Id]
        local ran,context,err=pcall(adapter.BuildContext,source,own.units,own.mappings,common)
        if not ran or not plain(context) or context.source~=source or context.units~=own.units then
            return failure("match",plain(err) and err.code or "unsupported",
                not ran and context or plain(err) and err.message or err or "same-source owner context required",file)
        end
        snapshot.adapter_contexts[adapter.Id]=context
    end
    for _,entry in ipairs(snapshot.entries) do entry.context.adapter.file=snapshot.adapter_contexts[entry.adapter.Id] end
    return snapshot
end

-- Called only with the completed shared discovery during genuine first load.
function M.ForOwner(snapshot,owner,source)
    if not plain(snapshot) or snapshot.kind~="SpellHotReload.FileMatch" or snapshot.version~=7
        or not plain(snapshot.common) or snapshot.common.source~=source or not Source.Validate(source)
        or not plain(snapshot.owners) or snapshot.owners[owner.Id]~=owner
        or not plain(snapshot.adapter_contexts) then return nil,"same completed discovery and owner required" end
    return snapshot.adapter_contexts[owner.Id]
end
return M
