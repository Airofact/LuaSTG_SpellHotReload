--------------------------------------------------------------------------------
--- SpellHotReload.GeneratedBossLoader
---
--- The hot-reload harvest + inject mechanism.
---
--- 1. Intercept `lstg.DoFile` so that when a `*_Boss.lua` file loads (during normal
---    mod load), its top-level `local function`s are captured into an
---    UpvalueRegistry. Capture is done by appending a trailer
---    `return { [name] = name, ... }` and running the file exactly as the engine
---    would — no sandbox, no env table, no re-execution of wiring.
---
---    (A return-hook + `debug.getlocal` capture was rejected: at a function's own
---    `return` event its locals are already cleared in Lua 5.1, so the hook cannot
---    enumerate them.)
---
--- 2. Recompile a single changed `local function` fragment from the new file and
---    inject the captured sibling upvalues into it via `debug.setupvalue`, so its
---    free variables resolve to the currently-loaded siblings without re-running
---    the whole file.
--- CardCallbacks additionally extracts and rebuilds the current card's callbacks.
--------------------------------------------------------------------------------

local Loader = {}

--------------------------------------------------------------------------------
--- helpers
--------------------------------------------------------------------------------

-- LuaJIT's `load` accepts a string; Lua 5.1 needs `loadstring`.
local function compile(src, name)
	if loadstring then
		return loadstring(src, name)
	end
	return load(src, name)
end

-- basename must match this pattern and be a direct child of the watch root
local BOSS_FILE_PATTERN = "^[A-Za-z0-9_%%%-]+_Boss%.lua$"

---Return the basename when `name` is a Boss file, else nil.
---@param name string
---@return string?
local function boss_basename(name)
	if type(name) ~= "string" then return nil end
	local base = name:match("([^/\\]+)$") or name
	if base:match(BOSS_FILE_PATTERN) then
		return base
	end
	return nil
end

---Read the source text of a Boss file (search-path aware, then mod directory).
---@param filename string
---@param base string
---@return string?
local function read_text(filename, base)
	local ok, content = pcall(lstg.LoadTextFile, filename)
	if ok and type(content) == "string" then
		return content
	end
	local mod = setting and setting.mod
	if type(mod) == "string" and mod ~= "" and mod ~= "launcher" then
		local path = "mod/" .. mod .. "/" .. base
		local ok2, content2 = pcall(lstg.LoadTextFile, path)
		if ok2 and type(content2) == "string" then
			return content2
		end
		local f = io.open(path, "rb")
		if f ~= nil then
			local c = f:read("*a")
			f:close()
			return c
		end
	end
	return nil
end

--------------------------------------------------------------------------------
--- capability probe
--------------------------------------------------------------------------------

---Verify the primitives the plugin relies on: `debug.setupvalue` on Lua closures
---(with non-empty upvalue names), `compile`, and the name-list/capture path.
---@return boolean, string?
function Loader.Probe()
	local function make_closure()
		local captured = function() return 7 end
		return function() return captured() end
	end
	local f = make_closure()
	local name = debug.getupvalue(f, 1)
	if name == nil or name == "" then
		return false, "upvalue names unavailable (debug info stripped)"
	end
	local sok, serr = pcall(debug.setupvalue, f, 1, function() return 8 end)
	if not sok then
		return false, "debug.setupvalue on Lua closure failed: " .. tostring(serr)
	end
	if f() ~= 8 then
		return false, "setupvalue patch not effective"
	end

	local src = "local function __probe_capture() return 1 end"
	local names = Loader.ListFunctionNames(src)
	if #names == 0 or names[1] ~= "__probe_capture" then
		return false, "top-level local-function name extraction unavailable"
	end
	local chunk = compile(src .. "\n" .. Loader.BuildTrailer(names), "@SpellHotReload.probe")
	if chunk == nil then
		return false, "compile unavailable"
	end
	local t = chunk()
	if type(t) ~= "table" or type(t["__probe_capture"]) ~= "function" then
		return false, "capture (trailer return) unavailable"
	end

	return true
end

--------------------------------------------------------------------------------
--- interception
--------------------------------------------------------------------------------

---Build `return { [name] = name, ... }` for the given names.
---@param names string[]
---@return string
local function build_trailer(names)
	if #names == 0 then return "return {}" end
	local parts = { "return {" }
	for i, name in ipairs(names) do
		parts[#parts + 1] = "[" .. string.format("%q", name) .. "]=" .. name
			.. (i < #names and "," or "")
	end
	parts[#parts + 1] = "}"
	return table.concat(parts)
end

function Loader.BuildTrailer(names)
	return build_trailer(names)
end

local _installed = false

---Replace `lstg.DoFile` with a wrapper that captures Boss-file locals. The first
---installation wins, so the hook stays bound to the registries it was handed.
---
---`capture` is an optional extension the anchor wiring supplies. When present,
---`capture.trailer(names)` may return the richer dual trailer (legacy value map
---plus anchor closure) and `capture.on_capture(base, content, names, results)`
---runs once the file has executed, so the anchor half of `results` can be
---registered without this module depending on the anchor service - which would
---be a require cycle, since TopLevelIR already requires this module.
---@param registry table  -- UpvalueRegistry instance
---@param capture table?  -- { trailer = function(names), on_capture = function(base, content, names, results) }
function Loader.InstallDoFileHook(registry, capture)
	if _installed then return end
	_installed = true

	local trailer_of = capture and capture.trailer or nil
	local on_capture = capture and capture.on_capture or nil

	local orig_DoFile = lstg.DoFile
	lstg.DoFile = function(filename, ...)
		local base = boss_basename(filename)
		if base ~= nil then
			local content = read_text(filename, base)
			if content ~= nil then
				local names = Loader.ListFunctionNames(content)
				-- The plain map trailer stays the default, so a capture extension
				-- that cannot build its richer trailer changes nothing.
				local trailer = build_trailer(names)
				if trailer_of ~= nil then
					local dual = trailer_of(names)
					if dual ~= nil then
						trailer = dual
					end
				end
				local chunk = compile(content .. "\n" .. trailer, "@" .. tostring(filename))
				if chunk ~= nil then
					local results = { chunk() }
					if type(results[1]) == "table" then
						registry:SetAll(base, results[1])
						registry:SetSource(base, content)
					end
					if on_capture ~= nil then
						on_capture(base, content, names, results)
					end
					return nil -- Boss files carry no meaningful return value
				end
			end
		end
		return orig_DoFile(filename, ...)
	end
end

--------------------------------------------------------------------------------
--- lexer + fragment extraction
--------------------------------------------------------------------------------

local BLOCK_OPEN = { ["function"] = true, ["if"] = true, ["do"] = true, ["repeat"] = true }
local BLOCK_CLOSE = { ["end"] = true, ["until"] = true }

---Tokenize, recording byte offset and block depth per token.
---@param content string
---@return table[]
local function lex(content)
	local tokens = {}
	local n = #content
	local i = 1
	local depth = 0

	local function emit(kind, value, pos)
		tokens[#tokens + 1] = { kind = kind, value = value, pos = pos, depth = depth }
	end

	local function long_bracket(p)
		if content:sub(p, p) ~= "[" then return nil end
		local j = p + 1
		while j <= n and content:sub(j, j) == "=" do j = j + 1 end
		if content:sub(j, j) == "[" then
			return "]" .. string.rep("=", j - (p + 1)) .. "]", j + 1
		end
		return nil
	end

	while i <= n do
		local c = content:sub(i, i)

		if c == " " or c == "\t" or c == "\r" or c == "\n" or c == "\f" or c == "\v" then
			i = i + 1

		elseif c == "-" and content:sub(i, i + 1) == "--" then
			local close, body_start = long_bracket(i + 2)
			if close then
				local close_pos = content:find(close, body_start, true)
				i = close_pos and (close_pos + #close) or (n + 1)
			else
				while i <= n and content:sub(i, i) ~= "\n" do i = i + 1 end
			end

		elseif c == "'" or c == '"' then
			local start = i
			local q = c
			i = i + 1
			while i <= n do
				local ch = content:sub(i, i)
				if ch == "\\" then
					i = i + 2
				elseif ch == q then
					i = i + 1
					break
				else
					i = i + 1
				end
			end
			emit("string", content:sub(start, i - 1), start)

		elseif c == "[" then
			local start = i
			local close, body_start = long_bracket(i)
			if close then
				local close_pos = content:find(close, body_start, true)
				i = close_pos and (close_pos + #close) or (n + 1)
				emit("string", content:sub(start, i - 1), start)
			else
				emit("symbol", "[", i)
				i = i + 1
			end

		elseif c:match("[%a_]") then
			local start = i
			local j = i
			while j <= n and content:sub(j, j):match("[%w_]") do j = j + 1 end
			local word = content:sub(i, j - 1)
			i = j
			if BLOCK_OPEN[word] then
				emit("word", word, start)
				depth = depth + 1
			elseif BLOCK_CLOSE[word] then
				emit("word", word, start)
				depth = depth - 1
			else
				emit("word", word, start)
			end

		else
			emit("symbol", c, i)
			i = i + 1
		end
	end

	return tokens
end

-- Shared with the generated-card reader; strings/comments never become code tokens.
Loader.Tokenize = lex

---List the names of top-level `local function` declarations, in source order.
---@param content string
---@return string[]
function Loader.ListFunctionNames(content)
	local result = {}
	if type(content) ~= "string" then return result end
	if content:sub(1, 3) == "\239\187\191" then
		content = content:sub(4)
	end

	local tokens = lex(content)
	local seen = {}
	for t = 1, #tokens do
		local tok = tokens[t]
		if tok.kind == "word" and tok.value == "local" and tok.depth == 0 then
			local a, b = tokens[t + 1], tokens[t + 2]
			if a ~= nil and a.kind == "word" and a.value == "function" and a.depth == 0
				and b ~= nil and b.kind == "word" and not seen[b.value] then
				seen[b.value] = true
				result[#result + 1] = b.value
			end
		end
	end
	return result
end

---Extract the source span of `local function NAME ... end` from generated source.
---@param content string
---@param name string
---@return string?
function Loader.ExtractFunction(content, name)
	if type(content) ~= "string" or type(name) ~= "string" then return nil end
	if content:sub(1, 3) == "\239\187\191" then
		content = content:sub(4)
	end

	local tokens = lex(content)
	local nt = #tokens
	local t = 1
	while t <= nt do
		local tok = tokens[t]
		if tok.kind == "word" and tok.value == "local" and tok.depth == 0 then
			local a, b = tokens[t + 1], tokens[t + 2]
			if a ~= nil and a.kind == "word" and a.value == "function" and a.depth == 0
				and b ~= nil and b.kind == "word" and b.value == name then
				local end_tok = nil
				for j = t + 1, nt do
					local jt = tokens[j]
					if jt.kind == "word" and jt.value == "end" and jt.depth == 1 then
						end_tok = jt
						break
					end
				end
				if end_tok ~= nil then
					return content:sub(tok.pos, end_tok.pos + 2)
				end
			end
		end
		t = t + 1
	end
	return nil
end

--------------------------------------------------------------------------------
--- fragment build (compile + inject)
--------------------------------------------------------------------------------

---Compile a fragment into a function and inject the captured sibling upvalues.
---@param fragment string  -- `local function NAME(...) ... end`
---@param name string
---@param registry_entry table<string, any>?  -- the file's captured locals
---@return function?, string?
function Loader.BuildFunction(fragment, name, registry_entry)
	if type(fragment) ~= "string" or type(name) ~= "string" then
		return nil, "fragment or name is not a string"
	end

	-- declare captured sibling names as locals so the fragment's free variables
	-- become upvalue slots (exclude the target name, which the fragment redeclares)
	local decl = ""
	if type(registry_entry) == "table" then
		local names = {}
		for n in pairs(registry_entry) do
			if n ~= name then
				names[#names + 1] = n
			end
		end
		if #names > 0 then
			decl = "local " .. table.concat(names, ", ") .. "\n"
		end
	end

	local src = decl .. fragment .. "\nreturn " .. name
	local chunk, cerr = compile(src, "@frag:" .. name)
	if chunk == nil then
		return nil, "compile fragment failed: " .. tostring(cerr)
	end

	local ok, new_fn = pcall(chunk)
	if not ok then
		return nil, "fragment execution failed: " .. tostring(new_fn)
	end
	if type(new_fn) ~= "function" then
		return nil, "fragment did not produce a function"
	end

	-- inject captured sibling values by upvalue name
	if type(registry_entry) == "table" then
		local i = 1
		while true do
			local uname = debug.getupvalue(new_fn, i)
			if uname == nil then break end
			if registry_entry[uname] ~= nil then
				debug.setupvalue(new_fn, i, registry_entry[uname])
			end
			i = i + 1
		end
	end

	return new_fn
end

return Loader
