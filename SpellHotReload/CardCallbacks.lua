-- Read Editor Sharp's card registrations without executing generated wiring.
-- Build only callback closures, retaining captured locals from the running card.
local Lexer = require("SpellHotReload.Lexer")
local M = {}
local compile = loadstring or load
local CALLBACKS = { "before", "init", "frame", "render", "beforedel", "del", "after" }
local allowed = {}
for _, name in ipairs(CALLBACKS) do allowed[name] = true end

local function matches(tokens, at, ...)
    for i = 1, select("#", ...) do
        local token = tokens[at + i - 1]
        if not token or token.value ~= select(i, ...) then return false end
    end
    return true
end

local function closing_paren(tokens, at)
    local depth = 0
    for i = at, #tokens do
        if tokens[i].value == "(" then depth = depth + 1 end
        if tokens[i].value == ")" then
            depth = depth - 1
            if depth == 0 then return i end
        end
    end
end

-- Split a `{ ... }` literal (starting at its `{`) into element token ranges.
-- Braces/parens/brackets are counted here because the lexer only tracks block
-- keywords. Also returns the index of the closing brace, or nil when the
-- literal is never closed.
local function table_elements(tokens, at)
    local depth = 0
    local ranges, first = {}, nil
    for i = at, #tokens do
        local value = tokens[i].value
        if value == "{" or value == "(" or value == "[" then
            depth = depth + 1
        elseif value == "}" or value == ")" or value == "]" then
            depth = depth - 1
            if depth == 0 then
                if first ~= nil and first <= i - 1 then
                    ranges[#ranges + 1] = { first = first, last = i - 1 }
                end
                return ranges, i
            end
        elseif value == "," and depth == 1 then
            if first ~= nil and first <= i - 1 then
                ranges[#ranges + 1] = { first = first, last = i - 1 }
            end
            first = nil
        elseif depth == 1 and first == nil then
            first = i
        end
    end
end

---Derive the registration kind of an inline constructor expression.
---`boss.move.New(...)` inside a rebuilt list behaves like the `move` slot a
---`_tmp_sc = boss.move.New(...)` registration would produce.
---@param tokens table[]
---@param first integer
---@param last integer
---@return string
local function constructor_kind(tokens, first, last)
    if tokens[first] ~= nil and tokens[first].value == "boss"
        and tokens[first + 1] ~= nil and tokens[first + 1].value == "."
        and tokens[first + 2] ~= nil and tokens[first + 2].kind == "word"
        and tokens[first + 3] ~= nil and tokens[first + 3].value == "."
        and tokens[first + 4] ~= nil and tokens[first + 4].value == "New" then
        local kind = tokens[first + 2]
        return kind.value
    end
    return "other"
end

local function signature(tokens, first, last)
    local parts = {}
    for i = first, last do parts[#parts + 1] = tokens[i].value end
    return table.concat(parts, " ")
end

local function string_value(token)
    if not token or token.kind ~= "string" then return nil end
    local chunk = compile("return " .. token.value)
    if not chunk then return nil end
    return chunk() -- a lexer-validated string literal only
end

---Extract the literal first argument of `boss.<kind>.New("name", ...)`.
---Moves, dialogs, and names held in a variable have no string literal here and
---are reported as the empty name, matching the `c.name = ""` those constructors
---set at runtime.
---@param tokens table[]
---@param first integer  -- first token of the constructor expression
---@return string
local function constructor_name(tokens, first)
    if tokens[first] ~= nil and tokens[first].value == "boss"
        and tokens[first + 4] ~= nil and tokens[first + 4].value == "New"
        and tokens[first + 5] ~= nil and tokens[first + 5].value == "(" then
        return string_value(tokens[first + 6]) or ""
    end
    return ""
end

-- Slots count every registration, including dialogs and movement phases.
-- Generated sources may rebuild a class list with `cards={<expr>,...}`, which
-- resets the runtime array, so the returned layout mirrors the list the engine
-- actually builds (live index) instead of the textual order of every
-- registration. Return the entire layout so insertion/removal/reordering is
-- rejected.
-- Optional shared TopLevelIR analysis belongs to these exact bytes. Tokens are
-- read-only/trusted analysis, not a parser sandbox. Legacy two-arg reads re-lex.
function M.Read(content, class_key, analysis)
    local source = content:gsub("^\239\187\191", "")
    local offset = 0
    if analysis ~= nil then
        local expected = #content - #source
        if type(analysis) ~= "table" or getmetatable(analysis) ~= nil
            or analysis.source ~= source or analysis.source_offset ~= expected
            or type(analysis.tokens) ~= "table" or getmetatable(analysis.tokens) ~= nil then
            return nil, "shared analysis does not match card source"
        end
        offset = expected
    end
    local chunk, err = compile(source, "@SpellHotReload.card_check")
    if not chunk then return nil, "syntax: " .. tostring(err) end
    local tokens = analysis and analysis.tokens or Lexer.Tokenize(content)
    local layout, locals, pending, held = {}, {}, nil, nil
    local found = false
    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        if t.depth == 0 then
            if t.value == "local" then
                local j = i + 1
                if tokens[j] and tokens[j].value == "function" then j = j + 1 end
                while tokens[j] and tokens[j].kind == "word" do
                    locals[tokens[j].value] = true
                    if not matches(tokens, j + 1, ",") then break end
                    j = j + 2
                end
            end
            if matches(tokens, i, "_editor_class", "[")
                and string_value(tokens[i + 2]) == class_key
                and matches(tokens, i + 3, "]", ".", "cards", "=", "{") then
                local elements, close = table_elements(tokens, i + 7)
                if not elements then return nil, "unclosed class card list" end
                -- only the empty initializer is unique; later rebuilds are resets
                if #elements == 0 and found then return nil, "duplicate class card list" end
                found = true
                local rebuilt = {}
                for _, range in ipairs(elements) do
                    if range.first == range.last and tokens[range.first].value == "_tmp_sc" then
                        if not held then return nil, "card list reuses an unknown _tmp_sc" end
                        rebuilt[#rebuilt + 1] = held
                    else
                        rebuilt[#rebuilt + 1] = {
                            kind = constructor_kind(tokens, range.first, range.last),
                            name = constructor_name(tokens, range.first),
                            constructor = signature(tokens, range.first, range.last),
                            callbacks = {}, locals = {}, perform = "",
                        }
                    end
                end
                layout = rebuilt
                i = close
            elseif matches(tokens, i, "_tmp_sc", "=") then
                pending, held = nil, nil
                if matches(tokens, i + 2, "boss", ".")
                    and matches(tokens, i + 5, ".", "New", "(") then
                    local last = closing_paren(tokens, i + 7)
                    if not last then return nil, "unclosed card constructor" end
                    local visible = {}
                    for name in pairs(locals) do visible[name] = true end
                    pending = {
                        kind = tokens[i + 4].value,
                        name = constructor_name(tokens, i + 2),
                        constructor = signature(tokens, i + 2, last),
                        callbacks = {}, callback_points = {}, locals = visible, perform = "",
                    }
                    -- `_tmp_sc` keeps referring to this object until it is
                    -- reassigned, so a later list rebuild can reuse it.
                    held = pending
                end
            elseif pending and (matches(tokens, i, "function", "_tmp_sc", ":")
                or matches(tokens, i, "_tmp_sc", ".")) then
                local method = t.value == "function"
                local name_at = method and i + 3 or i + 2
                local name = tokens[name_at] and tokens[name_at].value
                local paren = method and i + 4 or i + 5
                local is_callback = method or matches(tokens, i + 3, "=", "function", "(")
                if is_callback then
                    if not allowed[name] then return nil, "unsupported card callback: " .. tostring(name) end
                    if pending.callbacks[name] then return nil, "duplicate card callback: " .. name end
                    local last
                    for j = paren + 1, #tokens do
                        if tokens[j].value == "end" and tokens[j].depth == 1 then last = j; break end
                    end
                    if not last then return nil, "unclosed card callback" end
                    local params = tokens[paren].pos + offset
                    local tail = content:sub(params + 1, tokens[last].pos + offset + 2)
                    if method then
                        local empty = tokens[paren + 1].value == ")"
                        tail = "self" .. (empty and "" or ",") .. tail
                    end
                    pending.callbacks[name] = "function(" .. tail
                    -- Byte offsets refer to the original input, including BOM.
                    pending.callback_points[name] = { first = t.pos + offset,
                        last = tokens[last].pos + offset + 2 }
                    i = last
                elseif name == "perform" and matches(tokens, i + 3, "=") then
                    pending.perform = tokens[i + 4].value
                else
                    return nil, "unsupported card assignment: " .. tostring(name)
                end
            elseif matches(tokens, i, "table", ".", "insert", "(", "_editor_class", "[") then
                local key = string_value(tokens[i + 6])
                if key == class_key and matches(tokens, i + 7, "]", ".", "cards", ",") then
                    if not found then return nil, "card registration before class card list" end
                    local last = closing_paren(tokens, i + 3)
                    if not last then return nil, "unclosed card registration" end
                    if pending and matches(tokens, i + 11, "_tmp_sc", ")") then
                        layout[#layout + 1] = pending
                    else
                        layout[#layout + 1] = {
                            kind = constructor_kind(tokens, i + 11, last - 1),
                            name = constructor_name(tokens, i + 11),
                            constructor = signature(tokens, i + 11, last - 1),
                            callbacks = {}, locals = {}, perform = "",
                        }
                    end
                    pending = nil
                end
            end
        end
        i = i + 1
    end
    if not found then return nil, "class not found" end
    return layout
end

local function normalize_name(name)
    return type(name) == "string" and name or ""
end

---Exact-layout path: the caller already knows the live index and both sources
---must describe the same card list. `slot` is the live card index, the same
---index the engine uses in `_sc_table`; it can differ from textual registration
---order when the generated source rebuilds the list.
local function select_strict(before, after, slot)
    if #before ~= #after then return nil, "card layout changed; restart game" end
    for i, entry in ipairs(before) do
        if entry.constructor ~= after[i].constructor or entry.perform ~= after[i].perform then
            return nil, "card layout/metadata changed at slot " .. i .. "; restart game"
        end
    end
    local selected = after[slot]
    if selected == nil then
        return nil, "slot " .. tostring(slot) .. " is past the candidate card list"
    end
    return selected, "slot"
end

---Two slots describe the same shape when registration kind, constructor
---arguments and perform flag agree. A literal name is part of the constructor
---signature, so a renamed slot counts as a different shape here.
local function same_shape(a, b)
    return a.kind == b.kind and a.constructor == b.constructor and a.perform == b.perform
end

---Line the live list up with the candidate at a fixed `offset`. The slot being
---reloaded is allowed to differ, and movements are position placeholders
---without card identity: an SC Debug export collapses the omitted prefix into
---`cards={boss.move.New(...),_tmp_sc}`, so a leading placeholder must not break
---a tail alignment.
local function aligns(before, after, offset, slot)
    for i = 1, #before do
        local entry = before[i]
        if i ~= slot and entry.kind ~= "move" then
            local other = after[i + offset]
            if other == nil or not same_shape(entry, other) then return false end
        end
    end
    return true
end

-- Rebind a captured live card onto a candidate list that may describe a
-- different layout. The live `_editor_class[...].cards` array is never rebuilt
-- by this plugin, so `binding.slot` stays the restart index; only the descriptor
-- (the callback source to compile) has to be found in the candidate.
--
-- Detection order:
--   1. the live slot still carries the same name        -> that slot
--      (an unnamed slot needs both lists to have the same shape)
--   2. the captured name sits at one unique new position -> SC Debug/full
--      package layouts that omit or add placeholder slots before this card
--   3. every other slot kept its name and only this one
--      changed                                            -> renamed in place
--   4. an unnamed live slot (which has no name to follow) lines up with the
--      candidate from exactly one end                     -> head or tail index
-- Anything else is ambiguous and must not silently reload a different card.
local function select_binding(before, after, binding)
    local slot = binding.slot
    if type(slot) ~= "number" then return nil, "current slot is unknown" end
    local name = normalize_name(binding.name)
    local live = type(binding.names) == "table" and binding.names or nil
    local live_count = live ~= nil and #live or #before
    local same_layout = live_count == #after
    local function before_name(i)
        if live ~= nil and live[i] ~= nil then return normalize_name(live[i]) end
        return before[i] ~= nil and normalize_name(before[i].name) or ""
    end

    local selected = after[slot]
    -- An unnamed slot (move / dialog / non-spell card) carries no identity, so
    -- its position is only trusted while both lists have the same shape.
    if selected ~= nil and normalize_name(selected.name) == name
        and (name ~= "" or same_layout) then
        return selected, "slot " .. tostring(slot)
    end

    if name ~= "" then
        local hit, count = nil, 0
        for i = 1, #after do
            if normalize_name(after[i].name) == name then
                count, hit = count + 1, i
            end
        end
        if count == 1 then return after[hit], "name match at slot " .. tostring(hit) end
    end

    if selected ~= nil and same_layout then
        local only_here = true
        for i = 1, #after do
            if i ~= slot and before_name(i) ~= normalize_name(after[i].name) then
                only_here = false
                break
            end
        end
        if only_here then return selected, "renamed in place" end
    end

    -- An unnamed slot (SC Debug phase / non-spell card) has no name at all, so
    -- position is the only link. A candidate that dropped a prefix (SC Debug
    -- export) or appended a suffix still lines up with the live list from one
    -- end, so try the head- and the tail-aligned offsets and accept one fit.
    if name == "" and live_count == #before then
        local forward = aligns(before, after, 0, slot)
        local reverse_offset = #after - #before
        local reverse = reverse_offset ~= 0 and aligns(before, after, reverse_offset, slot)
        if forward and reverse then
            return nil, "the new layout lines up from both ends; restart game"
        end
        local offset = forward and 0 or (reverse and reverse_offset or nil)
        local entry = before[slot]
        local other = offset ~= nil and after[slot + offset] or nil
        if entry ~= nil and other ~= nil and entry.kind == other.kind then
            local aligned = offset == 0 and "forward index at slot " or "reverse index at slot "
            return other, aligned .. tostring(slot + offset)
        end
    end

    return nil, "current card is not in the new layout (slot " .. tostring(slot)
        .. ', name "' .. name .. '"); restart game'
end

---Verify the candidate and return the descriptor of the card to reload.
---
---`target` is either the live card index (strict: both sources must describe the
---same list) or a captured binding `{ slot, name, names }`. The binding form
---tolerates the shift between an SC Debug package and a full package and an
---in-place rename of the current card; see `select_binding`.
---@param original string   -- the source as it was loaded at mod load
---@param candidate string  -- the newly generated source
---@param class_key string
---@param target integer|table
---@return table? descriptor
---@return string match or rejection reason
function M.Select(original, candidate, class_key, target)
    local before, err = M.Read(original, class_key)
    if not before then return nil, "loaded source: " .. tostring(err) end
    local after, aerr = M.Read(candidate, class_key)
    if not after then return nil, aerr end
    local selected, reason
    if type(target) == "table" then
        selected, reason = select_binding(before, after, target)
    else
        selected, reason = select_strict(before, after, target)
    end
    if not selected then return nil, reason end
    if selected.kind ~= "card" or not selected.callbacks.init then
        return nil, "current slot is not a generated combat card"
            .. " (slot kind: " .. tostring(selected.kind) .. ")"
    end
    return selected, reason
end

local function upvalues(fn)
    local result = {}
    if type(fn) ~= "function" then return result end
    local i = 1
    while true do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        result[#result + 1] = { name = name, value = value, fn = fn, index = i }
        i = i + 1
    end
    return result
end

-- Preparation never invokes callback bodies or changes a live upvalue.
function M.Build(descriptor, card, content, registry)
    -- Legacy constructors are loaded only when the legacy Build is requested.
    local Loader = require("SpellHotReload.GeneratedBossLoader")
    registry = registry or {}
    local captured, references = {}, {}
    for _, name in ipairs(CALLBACKS) do
        for _, up in ipairs(upvalues(card[name])) do
            if captured[up.name] and captured[up.name].value ~= up.value then
                return nil, "ambiguous captured local: " .. up.name
            end
            captured[up.name] = up
            references[#references + 1] = up
        end
    end
    for name in pairs(captured) do
        if not descriptor.locals[name] then
            return nil, "captured local removed or moved out of scope: " .. name .. "; restart game"
        end
    end
    local names = {}
    for name in pairs(descriptor.locals) do names[#names + 1] = name end
    table.sort(names)
    local source = #names > 0 and ("local " .. table.concat(names, ",") .. "\n") or ""
    source = source .. "return {\n"
    for _, name in ipairs(CALLBACKS) do
        if descriptor.callbacks[name] then
            source = source .. name .. "=" .. descriptor.callbacks[name] .. ",\n"
        end
    end
    local factory, err = compile(source .. "}", "@SpellHotReload.card_callbacks")
    if not factory then return nil, "compile callbacks: " .. tostring(err) end
    local callbacks = factory()
    local functions, links = {}, {}
    for _, name in ipairs(CALLBACKS) do
        for _, up in ipairs(upvalues(callbacks[name])) do
            local old = captured[up.name]
            local value = registry[up.name]
            if old then value = old.value end
            -- Do not silently reinterpret a new, uncaptured local as a global.
            if not old and registry[up.name] == nil then
                return nil, "uncaptured local: " .. up.name .. "; restart game"
            end
            if type(registry[up.name]) == "function" and (not old or old.value == registry[up.name]) then
                if not functions[up.name] then
                    local fragment = Loader.ExtractFunction(content, up.name)
                    if not fragment then return nil, "local function removed: " .. up.name end
                    local fn, ferr = Loader.BuildFunction(fragment, up.name, registry)
                    if not fn then return nil, ferr end
                    functions[up.name] = fn
                end
                value = functions[up.name]
            end
            debug.setupvalue(up.fn, up.index, value)
            if old then links[#links + 1] = { new = up, old = old } end
        end
    end
    -- Missing callbacks revert to the standard card defaults (e.g. deleting frame).
    local defaults = boss and boss.card and boss.card._default_card
    for _, name in ipairs(CALLBACKS) do
        if not callbacks[name] then
            if not defaults or type(defaults[name]) ~= "function" then
                return nil, "card callback default unavailable: " .. name
            end
            callbacks[name] = defaults[name]
        end
    end
    return { callbacks = callbacks, functions = functions, links = links, references = references }
end

function M.Publish(card, plan)
    -- Preserve the existing shared-function behavior across difficulty variants.
    for _, up in ipairs(plan.references) do
        if plan.functions[up.name] then debug.setupvalue(up.fn, up.index, plan.functions[up.name]) end
    end
    if debug.upvaluejoin then
        for _, link in ipairs(plan.links) do
            debug.upvaluejoin(link.new.fn, link.new.index, link.old.fn, link.old.index)
        end
    end
    for _, name in ipairs(CALLBACKS) do card[name] = plan.callbacks[name] end
    if jit and jit.flush then pcall(jit.flush) end
end

return M
