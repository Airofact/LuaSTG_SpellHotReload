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

-- Validate spelling only; numeric values are never evaluated here.
local function numeral(value)
    if value:match("^0[xX]") then return value:match("^0[xX]%x+$")~=nil end
    local base=value:match("^(.-)[eE][+-]?%d+$") or value
    return base:match("^%d+%.?%d*$")~=nil or base:match("^%.%d+$")~=nil
end

-- Decode one already delimited Lua 5.1 string token. Never compile a literal.
local function string_literal(raw)
    if raw:sub(1,1)=="[" then
        local open=raw:find("[",2,true)
        local value=raw:sub(open+1,#raw-open)
        value=value:gsub("\r\n","\n"):gsub("\n\r","\n"):gsub("\r","\n")
        if value:sub(1,1)=="\n" then value=value:sub(2) end
        return value
    end
    local escapes={a="\a",b="\b",f="\f",n="\n",r="\r",t="\t",v="\v"}
    local result,i={},2
    while i<#raw do
        local c=raw:sub(i,i)
        if c=="\\" then
            i=i+1;c=raw:sub(i,i)
            if c:match("%d") then
                local digits=raw:sub(i):match("^%d%d?%d?")
                result[#result+1]=string.char(tonumber(digits));i=i+#digits
            elseif c=="\r" or c=="\n" then
                result[#result+1]="\n";i=i+1
                local nextc=raw:sub(i,i)
                if nextc~=c and (nextc=="\r" or nextc=="\n") then i=i+1 end
            else result[#result+1]=escapes[c] or c;i=i+1 end
        else result[#result+1]=c;i=i+1 end
    end
    return table.concat(result)
end

---Tokenize, recording byte offset and block depth per token.
---@param content string
---@return table[]
---@return string? lexical_error
local function lex(content)
	local tokens = {}
	local n = #content
	local i = 1
	local depth = 0

	local function emit(kind, value, pos)
		tokens[#tokens + 1] = { kind = kind, value = value, pos = pos, depth = depth,
            literal = kind == "string" and string_literal(value) or nil }
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
				if not close_pos then return tokens, "unfinished long bracket at byte " .. i end
				i = close_pos + #close
			else
				while i <= n and content:sub(i, i) ~= "\n" and content:sub(i, i) ~= "\r" do i = i + 1 end
			end

		elseif c == "'" or c == '"' then
			local start = i
			local q = c
			local closed = false
			i = i + 1
			while i <= n do
				local ch = content:sub(i, i)
				if ch == "\\" then
                    local escaped = content:sub(i+1,i+1)
                    if escaped:match("%d") then
                        local digits=content:sub(i+1):match("^%d%d?%d?")
                        if tonumber(digits)>255 then return tokens,"string escape out of range at byte "..i end
                        i=i+1+#digits
                    elseif escaped=="\r" or escaped=="\n" then
                        i=i+2
                        local nextc=content:sub(i,i)
                        if nextc~=escaped and (nextc=="\r" or nextc=="\n") then i=i+1 end
                    elseif escaped=="\\" or escaped=="'" or escaped=='"' or escaped:match("^[abfnrtv]$") then
                        i=i+2
                    else return tokens,"unsupported string escape at byte "..i end
				elseif ch == "\r" or ch == "\n" then
                    return tokens,"unescaped newline in string at byte "..start
                elseif ch == q then
					closed = true
					i = i + 1
					break
				else
					i = i + 1
				end
			end
			if not closed then return tokens, "unfinished string at byte " .. start end
			emit("string", content:sub(start, i - 1), start)

		elseif c == "[" then
			local start = i
			local close, body_start = long_bracket(i)
			if close then
				local close_pos = content:find(close, body_start, true)
				if not close_pos then return tokens, "unfinished long bracket at byte " .. i end
				i = close_pos + #close
				emit("string", content:sub(start, i - 1), start)
			else
				emit("symbol", "[", i)
				i = i + 1
			end

        elseif c:match("%d") or (c=="." and content:sub(i+1,i+1):match("%d")) then
            local start=i
            local hexadecimal=content:sub(i,i+1):lower()=="0x"
            while i<=n do
                local ch=content:sub(i,i)
                local prev=content:sub(i-1,i-1)
                if ch:match("[%w_%.]") or ((ch=="+" or ch=="-") and not hexadecimal and prev:match("[eE]")) then
                    i=i+1
                else break end
            end
            local value=content:sub(start,i-1)
            if not numeral(value) then return tokens,"malformed or unsupported numeral at byte "..start end
            emit("number",value,start)

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
            local symbol=c
            local pair=content:sub(i,i+1)
            if content:sub(i,i+2)=="..." then symbol="..."
            elseif pair==".." or pair=="==" or pair=="~=" or pair=="<=" or pair==">=" then symbol=pair end
            emit("symbol",symbol,i)
            i=i+#symbol
        end
	end

	return tokens
end


M.Tokenize = lex

return M
