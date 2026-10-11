--------------------------------------------------------------------------------
--- SpellHotReload.Pipeline.UnitIndex
---
--- Deterministic, read-only index over one FileMatch snapshot.
---
--- FileMatch.Discover aggregates every adapter's units in registration order and
--- validates them, but the aggregated arrays stay adapter-ordered and each
--- unit's byte ranges stay exactly as the adapter supplied them. Anything that
--- wants to diff two scans, query an arbitrary unit, or reason about source
--- coverage needs a stable structural view first:
---
---   normalization  units are ordered by (span.first, span.last, carrier, key)
---                  and each unit's ranges are sorted and de-duplicated, so the
---                  index never depends on adapter iteration order; a unit's
---                  span is the extent of its ranges (min first, max last);
---   forward index  by_key (key -> record), by_carrier, by_adapter;
---   reverse index  every normalized range sorted by (first, last, key) plus an
---                  offset query that seeks in O(log n) and scans back while
---                  the prefix maximum still reaches the offset;
---   random access  Position / Get / RecordsFor / Covering / At;
---   deletion stub  Compare(previous, next) classifies claims and units as
---                  added / matched / removed purely from the index, so a unit
---                  a new scan no longer matches still enters the comparison.
---
--- Identity:
---   * unit.key is snapshot-local only (see R1-FILEMATCH.md); it is never a
---     cross-version identity and Compare does not treat it as one.
---   * Compare identities come from semantic claims: kind + byte length + key,
---     the same canonical string FileMatch uses for claim ownership.
---   * A unit with no semantic claim can never be matched across scans, so
---     Compare reports it as removed/added instead of guessing.
---   * Overlapping byte ranges are allowed and are never treated as ownership.
---
--- Nothing here executes analyzed source, calls an adapter hook, or publishes
--- anything: Build and Compare only read the snapshot/index they are given.
--------------------------------------------------------------------------------

local M = {}

local KIND = "SpellHotReload.UnitIndex"
local VERSION = 1

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

---Canonical claim identity: kind + byte length + key. Written the same way in
---FileMatch; the spec asserts the two agree instead of sharing a private
---function across modules.
---@param claim table
---@return string? identity
---@return string? reason
function M.Identity(claim)
    if not plain(claim) then return nil, "claim must be a plain table" end
    if not text(claim.kind) then return nil, "claim needs a non-empty kind" end
    if not text(claim.key) then return nil, "claim needs a non-empty key" end
    return claim.kind .. ":" .. #claim.key .. ":" .. claim.key
end

local function invalid_unit(unit)
    if not plain(unit) then return "snapshot contains a non-plain unit" end
    if not text(unit.key) then return "snapshot unit has no key" end
    if not text(unit.carrier) then return "snapshot unit has no carrier" end
    if not plain(unit.context) then return "snapshot unit has no plain context" end
    return nil
end

---Normalized, sorted, duplicate-free copy of one unit's ranges.
local function normalized_ranges(unit, content)
    local unit_problem = invalid_unit(unit)
    if unit_problem ~= nil then return nil, unit_problem end
    if dense(unit.source_ranges) == nil or #unit.source_ranges == 0 then
        return nil, "snapshot unit requires source ranges: " .. unit.key
    end
    local ranges, seen = {}, {}
    for _, range in ipairs(unit.source_ranges) do
        if not plain(range) or not integer(range.first) or not integer(range.last)
            or range.first < 1 or range.last < range.first then
            return nil, "snapshot unit has an invalid source range: " .. unit.key
        end
        if content ~= nil and range.last > #content then
            return nil, "snapshot unit range exceeds the file: " .. unit.key
        end
        local marker = range.first .. ":" .. range.last
        if not seen[marker] then
            seen[marker] = true
            ranges[#ranges + 1] = { first = range.first, last = range.last }
        end
    end
    table.sort(ranges, function(a, b)
        if a.first ~= b.first then return a.first < b.first end
        return a.last < b.last
    end)
    return ranges
end

---Structural order: by span, then carrier, then key. No adapter order leaks in.
local function before(a, b)
    if a.span.first ~= b.span.first then return a.span.first < b.span.first end
    if a.span.last ~= b.span.last then return a.span.last < b.span.last end
    if a.carrier ~= b.carrier then return a.carrier < b.carrier end
    return a.key < b.key
end

local function adapter_id(entry)
    local adapter = entry.adapter
    local id = type(adapter) == "table" and rawget(adapter, "Id") or nil
    if text(id) then return id end
    return "(anonymous)"
end

local function bucket(buckets, name)
    local list = buckets[name]
    if list == nil then
        list = {}
        buckets[name] = list
    end
    return list
end

---Build a deterministic index over one FileMatch snapshot.
---@param snapshot table
---@return table? index
---@return string? reason
function M.Build(snapshot)
    if not plain(snapshot) then
        return nil, "snapshot must be a plain table"
    end
    local unit_count, entry_count = dense(snapshot.units), dense(snapshot.entries)
    if unit_count == nil or entry_count == nil or unit_count ~= entry_count then
        return nil, "snapshot must provide matching dense units and entries"
    end
    if not plain(snapshot.by_key) or not plain(snapshot.claim_owners) then
        return nil, "snapshot must provide by_key and claim_owners"
    end
    if dense(snapshot.claims) == nil then
        return nil, "snapshot must provide a dense claim list"
    end
    local content = nil
    if plain(snapshot.common) and type(snapshot.common.content) == "string" then
        content = snapshot.common.content
    end

    local records, record_by_key = {}, {}
    for index = 1, unit_count do
        local unit = snapshot.units[index]
        local ranges, range_problem = normalized_ranges(unit, content)
        if ranges == nil then return nil, range_problem end
        local key = unit.key
        if record_by_key[key] ~= nil then
            return nil, "duplicate unit key: " .. key
        end
        local entry = snapshot.entries[index]
        if not plain(entry) or entry.unit ~= unit or not plain(entry.context) then
            return nil, "snapshot entry does not match its unit: " .. key
        end
        if snapshot.by_key[key] ~= entry then
            return nil, "snapshot by_key disagrees with entries: " .. key
        end
        local span_last = ranges[1].last
        for i = 2, #ranges do
            if ranges[i].last > span_last then span_last = ranges[i].last end
        end
        local record = {
            key = key, carrier = unit.carrier, unit = unit, entry = entry,
            adapter_id = adapter_id(entry),
            ranges = ranges,
            span = { first = ranges[1].first, last = span_last },
            claims = {},
        }
        record_by_key[key] = record
        records[#records + 1] = record
    end
    table.sort(records, before)

    local carriers, adapters, range_index = {}, {}, {}
    local first_byte, last_byte = nil, nil
    for position = 1, #records do
        local record = records[position]
        record.position = position
        local carrier_bucket = bucket(carriers, record.carrier)
        carrier_bucket[#carrier_bucket + 1] = record
        local adapter_bucket = bucket(adapters, record.adapter_id)
        adapter_bucket[#adapter_bucket + 1] = record
        for _, range in ipairs(record.ranges) do
            range_index[#range_index + 1] =
                { first = range.first, last = range.last, key = record.key }
        end
        if first_byte == nil or record.span.first < first_byte then first_byte = record.span.first end
        if last_byte == nil or record.span.last > last_byte then last_byte = record.span.last end
    end
    table.sort(range_index, function(a, b)
        if a.first ~= b.first then return a.first < b.first end
        if a.last ~= b.last then return a.last < b.last end
        return a.key < b.key
    end)

    -- prefix maximum of `last`: lets an offset query stop as soon as no earlier
    -- range can still reach the offset.
    local prefix_last, running = {}, nil
    for i = 1, #range_index do
        if running == nil or range_index[i].last > running then running = range_index[i].last end
        prefix_last[i] = running
    end

    local claims = {}
    for _, claim in ipairs(snapshot.claims) do
        local identity, identity_problem = M.Identity(claim)
        if identity == nil then return nil, identity_problem end
        if not text(claim.unit_key) then
            return nil, "claim needs a non-empty unit_key"
        end
        local record = record_by_key[claim.unit_key]
        if record == nil then
            return nil, "claim owner is not a unit: " .. claim.unit_key
        end
        if claims[identity] ~= nil then
            return nil, "duplicate claim identity: " .. identity
        end
        local owned = {
            kind = claim.kind, key = claim.key, unit_key = claim.unit_key,
            identity = identity, record = record,
        }
        claims[identity] = owned
        record.claims[#record.claims + 1] = owned
    end
    for _, record in ipairs(records) do
        table.sort(record.claims, function(a, b) return a.identity < b.identity end)
    end

    return {
        kind = KIND, version = VERSION, snapshot = snapshot,
        list = records, by_key = record_by_key,
        by_carrier = carriers, by_adapter = adapters,
        ranges = range_index, prefix_last = prefix_last, claims = claims,
        unit_count = #records, range_count = #range_index,
        span = (first_byte ~= nil) and { first = first_byte, last = last_byte } or nil,
    }
end

local function index_problem(index)
    if not plain(index) or rawget(index, "kind") ~= KIND
        or rawget(index, "version") ~= VERSION then
        return "a " .. KIND .. " index is required"
    end
    return nil
end

local function key_problem(key)
    if not text(key) then return "key must be a non-empty string" end
    return nil
end

---@return integer? position
---@return string? reason
function M.Position(index, key)
    local problem = index_problem(index) or key_problem(key)
    if problem ~= nil then return nil, problem end
    local record = index.by_key[key]
    if record == nil then return nil, "unknown unit key: " .. key end
    return record.position
end

---@return table? record
---@return string? reason
function M.Get(index, key)
    local problem = index_problem(index) or key_problem(key)
    if problem ~= nil then return nil, problem end
    local record = index.by_key[key]
    if record == nil then return nil, "unknown unit key: " .. key end
    return record
end

---Every unit with the given carrier, in normalized order. An unused carrier is
---an empty list, not an error. The list is a fresh copy, so mutating it cannot
---change the index.
---@return table[]? records
---@return string? reason
function M.RecordsFor(index, carrier)
    local problem = index_problem(index)
    if problem ~= nil then return nil, problem end
    if not text(carrier) then return nil, "carrier must be a non-empty string" end
    local list, copy = index.by_carrier[carrier], {}
    if list == nil then return copy end
    for i = 1, #list do copy[i] = list[i] end
    return copy
end

---Last range whose first byte is <= offset (0 when offset precedes them all).
local function seek(ranges, offset)
    local low, high, found = 1, #ranges, 0
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if ranges[middle].first <= offset then
            found = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return found
end

---Every unit whose normalized range covers `offset`, in normalized order. One
---unit appears once even when several of its own ranges cover the offset;
---overlap between different units legitimately returns more than one. An
---uncovered offset is an empty list, not an error.
---@param index table
---@param offset integer
---@return table[]? records
---@return string? reason
function M.Covering(index, offset)
    local problem = index_problem(index)
    if problem ~= nil then return nil, problem end
    if not integer(offset) then return nil, "offset must be an integer" end
    local ranges, prefix, hits = index.ranges, index.prefix_last, {}
    for i = seek(ranges, offset), 1, -1 do
        if prefix[i] < offset then break end
        if ranges[i].last >= offset then hits[#hits + 1] = i end
    end
    local ordered, seen = {}, {}
    for i = #hits, 1, -1 do
        local entry = ranges[hits[i]]
        if not seen[entry.key] then
            seen[entry.key] = true
            ordered[#ordered + 1] = index.by_key[entry.key]
        end
    end
    return ordered
end

---The single unit covering `offset`. Ambiguity is refused, never resolved by
---position or adapter order.
---@return table? record
---@return string? reason
function M.At(index, offset)
    local covering, reason = M.Covering(index, offset)
    if covering == nil then return nil, reason end
    if #covering == 0 then return nil, "no unit covers offset " .. tostring(offset) end
    if #covering > 1 then
        return nil, "ambiguous: " .. #covering .. " units cover offset " .. tostring(offset)
    end
    return covering[1]
end

local function claim_view(owned)
    return { kind = owned.kind, key = owned.key, unit_key = owned.unit_key }
end

---Classify two scans by canonical semantic claim identity. Read-only: it
---neither mutates the indexes nor decides what to publish or delete.
---
---A previous unit matches a next unit only when its surviving claims point at
---exactly one next unit and no other previous unit points at that same unit.
---Two-to-one and one-to-two shapes are reported as ambiguity instead of being
---guessed at, and ambiguous units are neither matched nor added nor removed.
---
---previous/next must both be indexes (UnitIndex.Build results); unit.key is
---snapshot-local and is only reported as diagnostics.
---@param previous table
---@param next table
---@return table? report
---@return string? reason
function M.Compare(previous, next)
    local problem = index_problem(previous) or index_problem(next)
    if problem ~= nil then return nil, problem end

    local identities, seen = {}, {}
    for _, index in ipairs({ previous, next }) do
        for identity in pairs(index.claims) do
            if not seen[identity] then
                seen[identity] = true
                identities[#identities + 1] = identity
            end
        end
    end
    table.sort(identities)

    local added_claims, removed_claims, kept_claims = {}, {}, {}
    for _, identity in ipairs(identities) do
        local old, new = previous.claims[identity], next.claims[identity]
        if old == nil then
            added_claims[#added_claims + 1] = claim_view(new)
        elseif new == nil then
            removed_claims[#removed_claims + 1] = claim_view(old)
        else
            kept_claims[#kept_claims + 1] = {
                kind = new.kind, key = new.key,
                previous_unit = old.unit_key, next_unit = new.unit_key,
            }
        end
    end

    local candidates, owner_count = {}, {}
    for _, record in ipairs(previous.list) do
        local hit, keys = {}, {}
        for _, owned in ipairs(record.claims) do
            local other = next.claims[owned.identity]
            if other ~= nil then hit[other.record.key] = true end
        end
        for key in pairs(hit) do keys[#keys + 1] = key end
        table.sort(keys)
        candidates[record.key] = keys
        for _, key in ipairs(keys) do
            owner_count[key] = (owner_count[key] or 0) + 1
        end
    end

    local matched_units, added_units, removed_units, ambiguous = {}, {}, {}, {}
    local consumed = {}
    for _, record in ipairs(previous.list) do
        local keys = candidates[record.key]
        if #keys == 0 then
            removed_units[#removed_units + 1] = record.key
        elseif #keys == 1 and owner_count[keys[1]] == 1 then
            consumed[keys[1]] = true
            matched_units[#matched_units + 1] =
                { previous = record.key, next = keys[1] }
        else
            for _, key in ipairs(keys) do consumed[key] = true end
            ambiguous[#ambiguous + 1] = { previous = record.key, candidates = keys }
        end
    end
    for _, record in ipairs(next.list) do
        if not consumed[record.key] then added_units[#added_units + 1] = record.key end
    end

    return {
        added_claims = added_claims, removed_claims = removed_claims,
        kept_claims = kept_claims, matched_units = matched_units,
        added_units = added_units, removed_units = removed_units,
        ambiguous = ambiguous,
        counts = {
            added_claims = #added_claims, removed_claims = #removed_claims,
            kept_claims = #kept_claims, matched_units = #matched_units,
            added_units = #added_units, removed_units = #removed_units,
            ambiguous = #ambiguous,
        },
    }
end

return M
