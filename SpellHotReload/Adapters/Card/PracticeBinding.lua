-- Read the current practice/SC Debug binding and inspect named init functions.
-- Publication and practice switching are owned by their runtime workflows.
local PracticeBinding = {}

---@class SpellHotReload.CurrentBinding
---@field class_key string
---@field name string
---@field card table
---@field slot integer  -- live index in `_editor_class[class_key].cards`
---@field include_previous boolean
---@field mode string  -- "practice" | "debug"
---@field names string[]  -- live `cls.cards[i].name` snapshot ("" for moves/dialogs)

---Snapshot the live class card names. Index i is `cls.cards[i].name`; moves and
---dialogs carry no name and are recorded as "". The hot-reload rebinding uses
---this snapshot as the description of the running (possibly SC Debug) layout,
---which the plugin never rebuilds.
---@param cls table
---@return string[]
local function live_names(cls)
	local names = {}
	if type(cls) ~= "table" or type(cls.cards) ~= "table" then
		return names
	end
	for i = 1, #cls.cards do
		local card = cls.cards[i]
		names[i] = (type(card) == "table" and type(card.name) == "string") and card.name or ""
	end
	return names
end

---Capture the current binding while in the normal Spell Practice stage group.
---`slot` stays the engine's live list index (as `_sc_table` records it); the
---generated source may rebuild a class list, so textual registration order is
---not used here. CardTarget resolves it against Card's complete matched layout.
---@return SpellHotReload.CurrentBinding?, string?
local function capture_practice()
	if lstg.var.sc_index == nil then
		return nil, "not in Spell Practice"
	end
	local record = _sc_table[lstg.var.sc_index]
	if type(record) ~= "table" then
		return nil, "no _sc_table record for current sc_index"
	end
	local class_key = record[1]
	local card = record[3]
	local slot = record[4]
	if class_key == nil or slot == nil then
		return nil, "malformed _sc_table record"
	end
	local cls = _editor_class[class_key]
	if type(cls) ~= "table" or type(cls.cards) ~= "table" then
		return nil, "class not found in _editor_class"
	end
	if cls.cards[slot] ~= card then
		return nil, "current card/slot mismatch in live class"
	end
	return {
		class_key = class_key,
		name = record[2],
		card = card,
		slot = slot,
		include_previous = record[5],
		mode = "practice",
		names = live_names(cls),
	}
end

---Capture the current binding while running SC Debugger output.
---SC Debugger never sets `lstg.var.sc_index`; it stores the class in
---`lstg.var._boss_class_name` and creates `New(class, class.cards)`, so the live
---boss's current card can be matched back to its class slot by identity.
---@return SpellHotReload.CurrentBinding?, string?
local function capture_debug()
	local class_key = lstg.var._boss_class_name
	if type(class_key) ~= "string" or class_key == "" then
		return nil, "not in Spell Practice or SC Debugger"
	end
	local cls = _editor_class[class_key]
	if type(cls) ~= "table" or type(cls.cards) ~= "table" then
		return nil, "debug class not found in _editor_class"
	end
	local live = (lstg.tmpvar and lstg.tmpvar.boss) or _boss
	if type(live) ~= "table" then
		return nil, "debug boss has not spawned yet"
	end
	if IsValid ~= nil and not IsValid(live) then
		return nil, "debug boss is no longer valid"
	end
	local card
	if type(boss) == "table" and type(boss.GetCurrentCard) == "function" then
		local ok, value = pcall(boss.GetCurrentCard, live)
		if ok and type(value) == "table" then card = value end
	end
	if card == nil and type(live.cards) == "table" then
		card = live.cards[live.card_num]
	end
	if type(card) ~= "table" then
		return nil, "debug boss is not on a card yet"
	end
	local slot
	for i = 1, #cls.cards do
		if cls.cards[i] == card then slot = i break end
	end
	if slot == nil then
		return nil, "current debug card is not part of the generated class card list"
	end
	return {
		class_key = class_key,
		name = card.name,
		card = card,
		slot = slot,
		include_previous = false,
		mode = "debug",
		names = live_names(cls),
	}
end

---Capture the current binding from live state (Spell Practice first, then SC
---Debugger). The debugger's `Include 'THlib\UI\scdebugger.lua'` is never run by
---this plugin; only the live card object is inspected.
---@return SpellHotReload.CurrentBinding?, string?
function PracticeBinding.CaptureCurrent()
	local practice, perr = capture_practice()
	if practice ~= nil then
		return practice
	end
	local debug, derr = capture_debug()
	if debug ~= nil then
		return debug
	end
	return nil, tostring(perr) .. "; " .. tostring(derr)
end

---@return boolean
function PracticeBinding.IsReplay()
	if ext and ext.replay and ext.replay.IsReplay then
		return ext.replay.IsReplay()
	end
	return false
end

---Inspect the function-typed upvalues of a card's `init` closure.
---@param card table
---@return table[]  -- { {index=, name=, value=}, ... }
function PracticeBinding.InspectInitFunctions(card)
	local result = {}
	if type(card) ~= "table" or type(card.init) ~= "function" then
		return result
	end
	local i = 1
	while true do
		local name, value = debug.getupvalue(card.init, i)
		if name == nil then break end
		if type(value) == "function" then
			result[#result + 1] = { index = i, name = name, value = value }
		end
		i = i + 1
	end
	return result
end

return PracticeBinding
