-- Read Editor Sharp's card registrations without executing generated wiring.
-- Parsing only; publication is owned by the transaction service.
local Lexer = require("SpellHotReload.Source.Lexer")
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
-- read-only/trusted analysis, not a parser sandbox. Calls without shared analysis tokenize their own input.
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
            elseif matches(tokens, i, "_BOSS_ESCAPE", "(")
                and not matches(tokens, i - 1, ".")
                and not matches(tokens, i - 1, ":") then
                -- DiMS's escape node appends a dialog and a deletion card.
                -- Preserve both positions/identities, never execute the call
                -- (its arguments can consume RNG) or publish their callbacks.
                local args, last = table_elements(tokens, i + 1)
                local target = args and args[1] and args[1].first == args[1].last
                    and string_value(tokens[args[1].first]) or nil
                if not args or #args ~= 4 or target == nil or locals._BOSS_ESCAPE then
                    return nil, "unsupported _BOSS_ESCAPE call; literal class and four arguments required"
                end
                if target == class_key then
                    if not found then return nil, "escape registration before class card list" end
                    local call = signature(tokens, i, last)
                    for slot = 1, 2 do
                        layout[#layout + 1] = {
                            kind = "other", name = "",
                            constructor = call .. " :escape-slot:" .. slot,
                            callbacks = {}, locals = {}, perform = "",
                        }
                    end
                end
                i = last
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

return M
