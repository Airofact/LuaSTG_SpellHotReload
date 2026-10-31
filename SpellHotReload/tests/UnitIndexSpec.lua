local UnitIndex = require("SpellHotReload.Pipeline.UnitIndex")
local FileMatch = require("SpellHotReload.Pipeline.FileMatch")
local Registry = require("SpellHotReload.Pipeline.NodeRegistry")
local Source = require("SpellHotReload.Source.FileAnalysis")
local M = {}

function M.run()
    local passed = 0
    local function eq(actual, expected, label)
        assert(actual == expected, label)
        passed = passed + 1
    end
    local function hook() error("execution hooks must not run") end
    local nan = 0 / 0

    local function claim(key, owner, kind)
        return { kind = kind or "callback", key = key, unit_key = owner }
    end
    local function unit(key, carrier, list, context)
        return {
            key = key, carrier = carrier or "card",
            context = context or { marker = key }, source_ranges = list,
        }
    end
    local function ranges(...)
        local list = {}
        for i = 1, select("#", ...), 2 do
            local first, last = select(i, ...)
            list[#list + 1] = { first = first, last = last }
        end
        return list
    end
    local function keys(list)
        local out = {}
        for i = 1, #list do out[i] = list[i].key end
        return table.concat(out, ",")
    end

    -- Hand-built snapshots mirror the FileMatch shape without running Match.
    local fixture_adapter = { Id = "fixture" }
    local function snapshot(units, claims, content, adapter)
        local snap = {
            units = units, entries = {}, by_key = {}, claim_owners = {},
            claims = claims or {}, adapter_contexts = {},
            common = { file = "F.lua" },
        }
        -- Structural-only fixture: UnitIndex checks byte bounds, not analysis provenance.
        if content ~= nil then snap.common.source = { content = content } end
        for i, one in ipairs(units) do
            local entry = {
                unit = one, adapter = adapter or fixture_adapter,
                context = {
                    common = snap.common,
                    adapter = { file = { file = "F.lua" }, unit = one.context },
                },
            }
            snap.entries[i] = entry
            snap.by_key[one.key] = entry
        end
        for _, owned in ipairs(snap.claims) do
            snap.claim_owners[UnitIndex.Identity(owned)] = snap.by_key[owned.unit_key]
        end
        return snap
    end
    local function build(snap)
        local index, reason = UnitIndex.Build(snap)
        assert(index ~= nil, reason)
        return index
    end
    local function reject(snap, label, fragment)
        local index, reason = UnitIndex.Build(snap)
        eq(index, nil, label)
        assert(type(reason) == "string" and reason ~= "", label .. ": reason")
        if fragment ~= nil then
            assert(reason:find(fragment, 1, true) ~= nil, label .. ": " .. reason)
        end
        passed = passed + 1
    end
    local function adapter(id, match)
        return {
            ContractVersion = 7, Id = id, Match = match,
            BuildContext=function(source,units) return {source=source,units=units,all=true,count=#units} end,
            Reconcile = function() error("unexpected reconciliation") end,
            Locate = hook, Inject = hook, Commit = hook, Restart = hook,
        }
    end
    local function registry(...)
        local r = Registry.New()
        for _, a in ipairs({ ... }) do assert(r:RegisterDiscovery(a)) end
        return r
    end
    local function discover(r, content)
        local snap, err = FileMatch.Discover(r, assert(Source.Build(content)), { file = "F.lua" })
        assert(snap ~= nil, err and err.message or "discovery failed")
        return snap
    end

    ----------------------------------------------------------------------------
    -- canonical identity: the same form FileMatch uses for claim ownership
    ----------------------------------------------------------------------------

    eq(UnitIndex.Identity(claim("ab", "u")), "callback:2:ab", "identity form")
    eq(UnitIndex.Identity(claim("1:b", "u", "a")), "a:3:1:b", "length prefix kept")
    eq(UnitIndex.Identity(claim("b", "u", "a"))
        ~= UnitIndex.Identity(claim("1:b", "u", "a")), true, "no delimiter collision")
    local identity, reason = UnitIndex.Identity(nil)
    eq(identity, nil, "nil claim rejected")
    eq(type(reason), "string", "identity carries a reason")
    eq(UnitIndex.Identity(setmetatable({}, { __index = hook })), nil, "claim metatable rejected")
    eq(UnitIndex.Identity({ key = "x" }), nil, "missing kind rejected")
    eq(UnitIndex.Identity({ kind = "callback" }), nil, "missing key rejected")
    eq(UnitIndex.Identity({ kind = "", key = "x" }), nil, "empty kind rejected")
    eq(UnitIndex.Identity({ kind = "callback", key = "" }), nil, "empty key rejected")

    ----------------------------------------------------------------------------
    -- a real FileMatch snapshot: structure and ownership parity
    ----------------------------------------------------------------------------

    local source = "local a = 1\nG = a\n"
    local found=discover(registry(adapter("unit",function(cursor)
        local position=cursor:Mark();local key=position==1 and "a" or "g"
        local value=unit(key,"card");cursor:Take()
        return {units={value},claims={claim(position==1 and "slot-a" or "stmt-g",key,
            position==1 and "callback" or "declaration")},mappings={{unit=value,first=position,last=position}}}
    end)),source)
    local index = build(found)
    eq(index.kind, "SpellHotReload.UnitIndex", "index kind")
    eq(index.version, 1, "index version")
    eq(index.snapshot, found, "index keeps its snapshot")
    eq(index.unit_count, 2, "unit count")
    eq(index.range_count, 2, "range count")
    eq(keys(index.list), "a,g", "units in span order")
    eq(index.list[1].position, 1, "position is 1-based")
    eq(index.list[2].position, 2, "second position")
    eq(index.by_key.g.unit, found.by_key.g.unit, "record keeps the unit reference")
    eq(index.by_key.g.entry, found.by_key.g, "record keeps the entry reference")
    eq(index.by_key.g.carrier, "card", "record keeps the carrier")
    eq(index.by_key.g.adapter_id, "unit", "adapter id comes from the owning entry")
    eq(keys(index.by_carrier.card), "a,g", "carrier bucket in normalized order")
    eq(keys(index.by_adapter.unit), "a,g", "adapter bucket in normalized order")
    eq(index.span.first, 1, "overall span starts at the first byte")
    eq(index.span.last, 17, "overall span ends at the last byte")
    eq(index.ranges[1].key, "a", "reverse index sorted by first byte")
    eq(index.ranges[2].key, "g", "reverse index continues")
    eq(index.ranges[1] == found.units[1].source_ranges[1], false, "range entries are copies")
    eq(index.prefix_last[2], 17, "prefix maximum of range ends")
    eq(index.claims["callback:6:slot-a"].record, index.by_key.a, "claims resolve to records")
    eq(index.claims["declaration:6:stmt-g"].key, "stmt-g", "declaration claim resolved")
    eq(index.list[1].claims[1].identity, "callback:6:slot-a", "per-record claim order")
    eq(index.list[1].claims[1].unit_key, "a", "claim owner kept")
    eq(#index.by_key.g.claims, 1, "one claim on the second unit")
    for _, owned in ipairs(found.claims) do
        eq(found.claim_owners[UnitIndex.Identity(owned)],
            found.by_key[owned.unit_key], "identity parity with FileMatch")
    end

    local empty = build(discover(registry(), "G = 1"))
    eq(empty.unit_count, 0, "an empty file match indexes nothing")
    eq(empty.span, nil, "an empty index has no span")
    eq(#empty.ranges, 0, "an empty index has no ranges")
    eq(keys(empty.list), "", "an empty index has an empty list")
    eq(#UnitIndex.RecordsFor(empty, "card"), 0, "an empty index has no carrier")
    local empty_report = UnitIndex.Compare(empty, empty)
    eq(empty_report.counts.kept_claims + empty_report.counts.added_claims, 0,
        "an empty comparison has no claims")

    ----------------------------------------------------------------------------
    -- normalization never depends on adapter registration order
    ----------------------------------------------------------------------------

    local function add_unit(r, id, key, first)
        assert(r:RegisterDiscovery(adapter(id, function(cursor)
            if cursor:Peek().source_range.first~=first then return nil end
            local position=cursor:Mark();local value=unit(key,"card")
            cursor:Take()
            return {units={value},claims={},mappings={{unit=value,first=position,last=position}}}
        end)))
    end
    local body = "local a = 1\nlocal z = 2\n"
    local forward_registry = Registry.New()
    add_unit(forward_registry, "z", "zed", 13)
    add_unit(forward_registry, "a", "alpha", 1)
    local forward = build(discover(forward_registry, body))
    local backward_registry = Registry.New()
    add_unit(backward_registry, "a", "alpha", 1)
    add_unit(backward_registry, "z", "zed", 13)
    local backward = build(discover(backward_registry, body))
    eq(keys(forward.list), "alpha,zed", "units sorted by first byte")
    eq(keys(backward.list), keys(forward.list), "registration order does not leak")
    eq(UnitIndex.Position(backward, "zed"), UnitIndex.Position(forward, "zed"),
        "positions are stable across adapter order")
    eq(forward.by_adapter.z[1].key, "zed", "adapter buckets follow normalization")
    eq(backward.by_adapter.a[1].key, "alpha", "reverse order keeps its own bucket")
    eq(forward.by_key.zed.span.first,13,"matched syntax starts at the original second declaration")
    eq(forward.by_key.zed.span.last,23,"mapping covers the complete declaration, not a fabricated prefix")

    ----------------------------------------------------------------------------
    -- ranges are sorted, de-duplicated, and span the full extent
    ----------------------------------------------------------------------------

    local payload = string.rep("x", 40)
    local raw = ranges(7, 9, 1, 5, 3, 20, 1, 5)
    local messy_unit = unit("m", "card", raw)
    local messy = build(snapshot({ messy_unit }, { claim("slot-m", "m") }, payload))
    local record = messy.by_key.m
    eq(#record.ranges, 3, "duplicate ranges collapse")
    eq(record.ranges[1].first, 1, "sorted by first byte")
    eq(record.ranges[1].last, 5, "first range preserved")
    eq(record.ranges[2].first, 3, "second range")
    eq(record.ranges[2].last, 20, "second range end")
    eq(record.ranges[3].first, 7, "third range")
    eq(record.ranges[3].last, 9, "third range end")
    eq(record.span.first, 1, "span starts at the smallest first byte")
    eq(record.span.last, 20, "span is the extent, not the last sorted range")
    eq(messy.range_count, 3, "range count counts normalized ranges")
    eq(record.ranges[1] == raw[4], false, "normalized ranges are copies")
    eq(raw[1].first, 7, "the caller's range order is not rewritten")
    eq(messy.prefix_last[3], 20, "prefix maximum at the tail")
    eq(messy.span.first, 1, "index span from one unit")
    eq(messy.span.last, 20, "index span end from one unit")

    ----------------------------------------------------------------------------
    -- span ties fall back to carrier then key; random access
    ----------------------------------------------------------------------------

    local tied = build(snapshot({
        unit("c", "card", ranges(1, 2)),
        unit("a", "host", ranges(1, 2)),
        unit("b", "card", ranges(1, 2)),
    }, {}))
    eq(keys(tied.list), "b,c,a", "carrier then key break span ties")
    eq(keys(tied.by_carrier.card), "b,c", "carrier bucket order")
    eq(keys(tied.by_carrier.host), "a", "second carrier bucket")
    eq(UnitIndex.Position(tied, "c"), 2, "position follows normalized order")
    eq(UnitIndex.Position(tied, "a"), 3, "last position")
    eq(UnitIndex.Get(tied, "a"), tied.by_key.a, "Get returns the record")
    local missing, why = UnitIndex.Position(tied, "ghost")
    eq(missing, nil, "an unknown key has no position")
    assert(why:find("unknown unit key", 1, true) ~= nil, why)
    missing, why = UnitIndex.Get(tied, "ghost")
    eq(missing, nil, "an unknown key has no record")
    missing, why = UnitIndex.Get(tied, 5)
    eq(missing, nil, "a non-string key is rejected")
    eq(why, "key must be a non-empty string", "key reason")
    eq(UnitIndex.Position(tied, ""), nil, "an empty key is rejected")
    missing, why = UnitIndex.Get({}, "a")
    eq(missing, nil, "a foreign table is not an index")
    eq(type(why), "string", "index reason")
    local list = UnitIndex.RecordsFor(tied, "card")
    eq(keys(list), "b,c", "carrier list in normalized order")
    eq(#UnitIndex.RecordsFor(tied, "ghost"), 0, "an unknown carrier is empty, not an error")
    list[1] = nil
    eq(#UnitIndex.RecordsFor(tied, "card"), 2, "the carrier list is a copy")
    missing, why = UnitIndex.RecordsFor(tied, 5)
    eq(missing, nil, "a non-string carrier is rejected")
    eq(why, "carrier must be a non-empty string", "carrier reason")
    eq(UnitIndex.RecordsFor(nil, "card"), nil, "a nil index is rejected")

    ----------------------------------------------------------------------------
    -- offset queries: inclusive bounds, overlap, gaps, ambiguity
    ----------------------------------------------------------------------------

    local covering = build(snapshot({
        unit("left", "card", ranges(1, 10)),
        unit("right", "card", ranges(8, 20)),
        unit("far", "card", ranges(30, 31)),
    }, {}))
    local hits = UnitIndex.Covering(covering, 5)
    eq(#hits, 1, "one unit covers a plain offset")
    eq(hits[1].key, "left", "the left unit covers 5")
    eq(#UnitIndex.Covering(covering, 1), 1, "the first byte is inclusive")
    eq(#UnitIndex.Covering(covering, 8), 2, "an overlap returns every unit")
    eq(keys(UnitIndex.Covering(covering, 8)), "left,right", "overlap follows normalized order")
    eq(#UnitIndex.Covering(covering, 20), 1, "the last byte is inclusive")
    eq(UnitIndex.At(covering, 5), covering.by_key.left, "a single cover resolves")
    record, why = UnitIndex.At(covering, 9)
    eq(record, nil, "ambiguity is refused")
    assert(why:find("ambiguous", 1, true) ~= nil, why)
    eq(#UnitIndex.Covering(covering, 25), 0, "a gap is empty")
    record, why = UnitIndex.At(covering, 25)
    eq(record, nil, "a gap has no unit")
    assert(why:find("no unit covers", 1, true) ~= nil, why)
    eq(#UnitIndex.Covering(covering, 0), 0, "offsets before the file are empty")
    eq(#UnitIndex.Covering(covering, -1), 0, "negative offsets are empty too")
    eq(#UnitIndex.Covering(covering, 1000), 0, "offsets past the file are empty")
    eq(keys(UnitIndex.Covering(covering, 31)), "far", "a later unit is still reachable")
    local doubled = build(snapshot({ unit("one", "card", ranges(1, 10, 5, 15)) }, {}))
    eq(keys(UnitIndex.Covering(doubled, 7)), "one", "a unit's own overlapping ranges collapse")
    eq(#UnitIndex.Covering(doubled, 7), 1, "one unit is one hit")
    eq(UnitIndex.At(doubled, 7), doubled.by_key.one, "one unit stays unambiguous")
    eq(keys(UnitIndex.Covering(doubled, 12)), "one", "the second own range is indexed")
    for _, bad in ipairs({ 1.5, nan, math.huge, "5", {} }) do
        local value, defect = UnitIndex.Covering(covering, bad)
        eq(value, nil, "a non-integer offset is rejected")
        eq(defect, "offset must be an integer", "offset reason")
        eq(UnitIndex.At(covering, bad), nil, "At rejects the same offsets")
    end
    eq(UnitIndex.Covering(covering, nil), nil, "a nil offset is rejected")
    eq(UnitIndex.At(nil, 1), nil, "At rejects a foreign index")

    ----------------------------------------------------------------------------
    -- deletion comparison: claims and units, read-only
    ----------------------------------------------------------------------------

    local previous = build(snapshot({
        unit("p1", "card", ranges(1, 4)),
        unit("p2", "card", ranges(6, 9)),
        unit("p3", "card", ranges(11, 14)),
    }, {
        claim("slot-a", "p1"),
        claim("slot-b", "p2"),
    }, payload))
    local current = build(snapshot({
        unit("n1", "card", ranges(1, 4)),
        unit("n2", "card", ranges(20, 24)),
    }, {
        claim("slot-a", "n1"),
        claim("slot-c", "n2"),
    }, payload))
    local report = UnitIndex.Compare(previous, current)
    eq(report.counts.added_claims, 1, "one new claim")
    eq(report.added_claims[1].key, "slot-c", "the added claim")
    eq(report.added_claims[1].unit_key, "n2", "the added claim owner")
    eq(report.counts.removed_claims, 1, "one dropped claim")
    eq(report.removed_claims[1].key, "slot-b", "the removed claim")
    eq(report.removed_claims[1].unit_key, "p2", "the removed claim owner")
    eq(report.counts.kept_claims, 1, "one surviving claim")
    eq(report.kept_claims[1].previous_unit, "p1", "surviving claim previous owner")
    eq(report.kept_claims[1].next_unit, "n1", "surviving claim next owner")
    eq(report.counts.matched_units, 1, "one matched unit")
    eq(report.matched_units[1].previous .. ">" .. report.matched_units[1].next,
        "p1>n1", "matched pair")
    eq(table.concat(report.removed_units, ","), "p2,p3", "claim-less units are removed too")
    eq(table.concat(report.added_units, ","), "n2", "added units")
    eq(report.counts.ambiguous, 0, "no ambiguity here")

    -- a unit with no semantic claim can never be matched across scans
    local anonymous = build(snapshot({ unit("same", "card", ranges(1, 4)) }, {}))
    local anonymous_again = build(snapshot({ unit("same", "card", ranges(1, 4)) }, {}))
    local same = UnitIndex.Compare(anonymous, anonymous_again)
    eq(same.counts.matched_units, 0, "claim-less units are not matched by key")
    eq(table.concat(same.removed_units, ","), "same", "claim-less unit is removed")
    eq(table.concat(same.added_units, ","), "same", "claim-less unit is added")

    -- one unit splitting into two is ambiguous, not two matches
    local split = UnitIndex.Compare(
        build(snapshot({ unit("p", "card", ranges(1, 4)) },
            { claim("one", "p"), claim("two", "p") })),
        build(snapshot({ unit("x", "card", ranges(1, 4)), unit("y", "card", ranges(6, 9)) },
            { claim("one", "x"), claim("two", "y") })))
    eq(split.counts.ambiguous, 1, "one-to-many is ambiguous")
    eq(split.ambiguous[1].previous, "p", "ambiguous previous unit")
    eq(table.concat(split.ambiguous[1].candidates, ","), "x,y", "sorted candidates")
    eq(split.counts.matched_units, 0, "ambiguous units are not matched")
    eq(split.counts.added_units, 0, "ambiguous candidates are not new")
    eq(split.counts.removed_units, 0, "ambiguous previous unit is not removed")

    -- two units merging into one is ambiguous in the same way
    local merge = UnitIndex.Compare(
        build(snapshot({ unit("p1", "card", ranges(1, 4)), unit("p2", "card", ranges(6, 9)) },
            { claim("one", "p1"), claim("two", "p2") })),
        build(snapshot({ unit("m", "card", ranges(1, 4)) },
            { claim("one", "m"), claim("two", "m") })))
    eq(merge.counts.ambiguous, 2, "many-to-one is ambiguous")
    eq(table.concat(merge.ambiguous[1].candidates, ","), "m", "both previous units point at it")
    eq(merge.counts.matched_units, 0, "a merge is not matched")
    eq(merge.counts.added_units, 0, "a merge adds no unit")
    eq(merge.counts.removed_units, 0, "a merge removes no unit")
    eq(merge.ambiguous[1].previous, "p1", "first ambiguous previous unit")
    eq(merge.ambiguous[2].previous, "p2", "second ambiguous previous unit")

    -- comparing an index with itself keeps everything and changes nothing
    local identity_index = build(snapshot({ unit("only", "card", ranges(1, 4)) },
        { claim("slot", "only") }))
    local stable = UnitIndex.Compare(identity_index, identity_index)
    eq(stable.counts.kept_claims, 1, "a self comparison keeps its claim")
    eq(stable.counts.matched_units, 1, "a self comparison matches its unit")
    eq(stable.counts.added_claims + stable.counts.removed_claims, 0, "no claim churn")
    eq(stable.counts.added_units + stable.counts.removed_units, 0, "no unit churn")
    eq(stable.counts.ambiguous, 0, "no ambiguity against itself")

    -- Compare is read-only and repeatable
    local before = {
        #previous.list, #previous.claims, previous.list[1].key,
        #previous.by_key.p1.claims, next(previous.by_key),
    }
    local again = UnitIndex.Compare(previous, current)
    eq(#previous.list, before[1], "Compare does not reorder the previous list")
    eq(#previous.claims, before[2], "Compare does not change the claim map")
    eq(previous.list[1].key, before[3], "previous order intact")
    eq(#previous.by_key.p1.claims, before[4], "per-record claims intact")
    eq(next(previous.by_key), before[5], "by_key intact")
    eq(#current.list, 2, "Compare does not change the next list")
    eq(#identity_index.list[1].claims, 1, "Compare does not change a self compared index")
    eq(again.kept_claims[1].next_unit, report.kept_claims[1].next_unit, "Compare repeats")
    eq(again.kept_claims ~= report.kept_claims, true, "each report is fresh")
    eq(again.added_claims ~= report.added_claims, true, "claim lists are fresh")
    eq(UnitIndex.Compare(nil, current), nil, "a nil previous index is rejected")
    eq(select(2, UnitIndex.Compare(previous, {})) ~= nil, true, "a foreign next index is rejected")

    ----------------------------------------------------------------------------
    -- Build rejections: the snapshot must be a well-formed FileMatch result
    ----------------------------------------------------------------------------

    local function valid()
        return snapshot({
            unit("a", "card", ranges(1, 4)),
            unit("b", "card", ranges(6, 9)),
        }, { claim("slot-a", "a") }, "local a = 1\nG = 1\n")
    end
    reject(nil, "a nil snapshot", "plain table")
    reject(42, "a non-table snapshot", "plain table")
    reject(setmetatable({}, { __index = hook }), "a snapshot with a metatable", "plain table")
    local bad = valid(); bad.units[3] = unit("c", "card", ranges(1, 1))
    reject(bad, "unit/entry count mismatch", "matching dense units and entries")
    bad = valid(); bad.entries[2] = nil
    reject(bad, "a sparse entry list", "matching dense units and entries")
    bad = valid(); bad.units.named = unit("c", "card", ranges(1, 1))
    reject(bad, "a unit list with an extra key", "matching dense units and entries")
    bad = valid(); bad.by_key = nil
    reject(bad, "a missing by_key", "by_key and claim_owners")
    bad = valid(); bad.claim_owners = setmetatable({}, { __index = hook })
    reject(bad, "claim_owners with a metatable", "by_key and claim_owners")
    bad = valid(); bad.claims = { [2] = claim("slot", "a") }
    reject(bad, "a sparse claim list", "dense claim list")

    bad = valid(); bad.units[1] = setmetatable(unit("a", "card", ranges(1, 4)), { __index = hook })
    reject(bad, "a unit with a metatable", "non-plain unit")
    bad = valid(); bad.units[1].key = ""
    reject(bad, "a unit without a key", "no key")
    bad = valid(); bad.units[1].carrier = false
    reject(bad, "a unit without a carrier", "no carrier")
    bad = valid(); bad.units[1].context = nil
    reject(bad, "a unit without a context", "no plain context")
    bad = valid(); bad.units[1].context = setmetatable({}, { __index = hook })
    reject(bad, "a unit context with a metatable", "no plain context")
    bad = valid(); bad.units[1].source_ranges = {}
    reject(bad, "a unit without ranges", "requires source ranges")
    bad = valid(); bad.units[1].source_ranges[3] = { first = 1, last = 1 }
    reject(bad, "a sparse range list", "requires source ranges")
    bad = valid(); bad.units[1].source_ranges = { setmetatable({ first = 1, last = 4 }, { __index = hook }) }
    reject(bad, "a range with a metatable", "invalid source range")
    for _, range in ipairs({
        { first = 0, last = 1 }, { first = 2, last = 1 }, { first = 1.5, last = 2 },
        { first = nan, last = 2 }, { first = 1, last = math.huge },
    }) do
        bad = valid(); bad.units[1].source_ranges = { range }
        reject(bad, "an out-of-bounds range", "invalid source range")
    end
    bad = valid(); bad.units[1].source_ranges = ranges(1, 99)
    reject(bad, "a range past the end of the content", "exceeds the file")
    bad = valid(); bad.units[2] = unit("a", "card", ranges(6, 9))
    reject(bad, "a duplicate unit key", "duplicate unit key")

    bad = valid(); bad.entries[2] = bad.entries[1]
    reject(bad, "an entry that does not match its unit", "does not match its unit")
    bad = valid(); bad.entries[2].context = nil
    reject(bad, "an entry without a context", "does not match its unit")
    bad = valid(); bad.entries[2] = setmetatable({ unit = bad.units[2], context = {} }, { __index = hook })
    reject(bad, "an entry with a metatable", "does not match its unit")
    bad = valid(); bad.by_key.b = {}
    reject(bad, "by_key disagreeing with entries", "by_key disagrees")

    bad = valid(); bad.claims[1] = { key = "slot-a", unit_key = "a" }
    reject(bad, "a claim without a kind", "non-empty kind")
    bad = valid(); bad.claims[1] = { kind = "callback", unit_key = "a" }
    reject(bad, "a claim without a key", "non-empty key")
    bad = valid(); bad.claims[1] = { kind = "callback", key = "slot-a" }
    reject(bad, "a claim without an owner", "non-empty unit_key")
    bad = valid(); bad.claims[1] = claim("slot-a", "ghost")
    reject(bad, "a claim owned by an absent unit", "claim owner is not a unit")
    bad = valid(); bad.claims[1] = setmetatable(claim("slot-a", "a"), { __index = hook })
    reject(bad, "a claim with a metatable", "plain table")
    bad = valid(); bad.claims[2] = claim("slot-a", "b")
    reject(bad, "a duplicate claim identity", "duplicate claim identity")

    ----------------------------------------------------------------------------
    -- Build only reads what it is given
    ----------------------------------------------------------------------------

    local raw_ranges = ranges(6, 9, 1, 6, 6, 9)
    local held = snapshot({ unit("a", "card", raw_ranges) }, { claim("slot-a", "a") },
        "local a = 1\nG = 9\n")
    local kept = {
        unit = held.units[1], range = held.units[1].source_ranges[1],
        by_key = held.by_key.a, claimed = held.claims[1],
    }
    local fields = 0
    for _ in next, held do fields = fields + 1 end
    local read = build(held)
    eq(held.units[1], kept.unit, "the unit table is untouched")
    eq(held.units[1].source_ranges[1], kept.range, "range tables are not replaced")
    eq(held.units[1].source_ranges[1].first, 6, "ranges are not sorted in place")
    eq(held.units[1].source_ranges[2].first, 1, "the caller's range order survives")
    eq(held.by_key.a, kept.by_key, "the ownership map is untouched")
    eq(held.claims[1], kept.claimed, "claim tables are untouched")
    local after = 0
    for _ in next, held do after = after + 1 end
    eq(after, fields, "no new field appears on the snapshot")
    eq(#read.by_key.a.ranges, 2, "the index normalizes a private copy")
    eq(read.by_key.a.ranges ~= held.units[1].source_ranges, true, "normalized ranges are a copy")
    eq(read.by_key.a.span.last, 9, "span computed from the normalized copy")
    local functions = 0
    for _, value in pairs(read) do
        if type(value) == "function" then functions = functions + 1 end
    end
    eq(functions, 0, "the index carries data only")

    local executions = 0
    local counting = { ContractVersion = 7, Id = "counting", Reconcile=function() error("unexpected reconciliation") end }
    for _, name in ipairs({ "Match", "BuildContext", "Reconcile", "Locate", "Inject", "Commit", "Restart" }) do
        counting[name] = function() executions = executions + 1 end
    end
    local trapped = setmetatable({ Id = "trapped" }, {
        __index = function() error("adapter fields must be read with rawget") end,
        __newindex = function() error("an adapter must not be written") end,
    })
    local hooked = snapshot({
        unit("a", "card", ranges(1, 4)), unit("b", "card", ranges(6, 9)),
    }, { claim("slot-a", "a") }, nil, counting)
    hooked.entries[2].adapter = trapped
    local indexed = build(hooked)
    eq(executions, 0, "Build never runs an adapter hook")
    eq(keys(indexed.by_adapter.counting), "a", "adapter bucket from a raw Id")
    eq(keys(indexed.by_adapter.trapped), "b", "rawget reads Id past an erroring __index")

    ----------------------------------------------------------------------------
    -- real generated file (skipped when the runtime mod is absent)
    ----------------------------------------------------------------------------

    do
        local f = io.open("mod/DiMS/DiMS_Stage1_Boss.lua", "rb")
        if f ~= nil then
            local body = f:read("*a")
            f:close()
            local fixture=build(discover(registry(adapter("fixture",function(cursor)
                local position=cursor:Mark();local key="stmt"..position
                local value={key=key,carrier="fixture",context={statement=position}}
                cursor:Take()
                return {units={value},claims={{kind="declaration",key=key,unit_key=key}},
                    mappings={{unit=value,first=position,last=position}}}
            end)),body))
            eq(fixture.unit_count > 300, true, "real file: many units")
            eq(fixture.unit_count, #fixture.snapshot.units, "real file: every unit is indexed")
            eq(fixture.range_count, fixture.unit_count, "real file: one range per statement")
            eq(fixture.unit_count, #fixture.snapshot.claims, "real file: one claim per statement")
            local first_unit = fixture.list[1]
            eq(fixture.span.first, first_unit.span.first, "real file: span starts at the first unit")
            eq(UnitIndex.At(fixture, first_unit.span.first), first_unit,
                "real file: the first byte resolves to the first unit")
            eq(UnitIndex.At(fixture, first_unit.span.last), first_unit,
                "real file: the last byte resolves to the first unit")
            local self_report = UnitIndex.Compare(fixture, fixture)
            eq(self_report.counts.matched_units, fixture.unit_count,
                "real file: a self comparison matches every unit")
            eq(self_report.counts.added_units + self_report.counts.removed_units, 0,
                "real file: a self comparison has no unit churn")
            eq(self_report.counts.ambiguous, 0, "real file: a self comparison has no ambiguity")
        end
    end

    print(string.format("[SpellHotReload unit index] %d passed, 0 failed", passed))
    return { passed = passed, failed = 0 }
end

return M
