-- Legacy value-map function rebuilding. NOT the Anchor/FunctionPlan pipeline.
-- Isolated compatibility for Value.Inject and historical CardCallbacks.Build.
-- No engine hook, file reader, watcher, registry/session cache, joins or flush.
-- BuildFunction predeclares map names and injects VALUES, not shared cells.
-- Trusted legacy fragments only: its factory is executed in the real environment;
-- this module is neither a sandbox nor a safe arbitrary-source evaluation API.
-- Nil slots/lexical identity/full dependency impact require the versioned model.
local Lexer = require("SpellHotReload.Source.Lexer")
local Functions = {}

local function compile(src, name)
	if loadstring then
		return loadstring(src, name)
	end
	return load(src, name)
end

local function lex(content)
    return Lexer.Tokenize(content)
end

---List the names of top-level `local function` declarations, in source order.
---@param content string
---@return string[]
function Functions.ListFunctionNames(content)
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
function Functions.ExtractFunction(content, name)
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
function Functions.BuildFunction(fragment, name, registry_entry)
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

return Functions
