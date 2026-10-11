--------------------------------------------------------------------------------
--- SpellHotReload.Source.Lexer
---
--- Shared, engine-independent lexer for source analysis and closure composition.
--- Tokens preserve the existing kind/value/byte-pos/block-depth contract. This
--- is a lexical splitter, NOT a Lua parser or a proof of binding visibility.
--- Comments are skipped, strings stay opaque, and symbols remain single bytes.
--- BOM stripping belongs to callers that need offsets in the original source.
--- Tokenization never compiles or executes source and touches no engine state.
--------------------------------------------------------------------------------

local M = {}

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


M.Tokenize = lex

return M
