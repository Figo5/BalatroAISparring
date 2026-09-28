-- Minimal JSON encoder/decoder for the runtime harness only.
--
-- The staged runtime uses the game-bundled `json` module; tests must not depend
-- on LÖVE, so this file provides a small, dependency-free equivalent sufficient
-- for the bounded control envelopes (objects, arrays, strings, finite numbers,
-- booleans, null). It is test support, never shipped in AISparring/.

local Json = {}

local function is_array(value)
	local count = 0
	for key in next, value do
		if type(key) ~= "number" then
			return false
		end
		count = count + 1
	end
	if count == 0 then
		return false
	end
	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end
	return true, count
end

local function escape(value)
	value = string.gsub(value, "\\", "\\\\")
	value = string.gsub(value, '"', '\\"')
	value = string.gsub(value, "\n", "\\n")
	value = string.gsub(value, "\r", "\\r")
	value = string.gsub(value, "\t", "\\t")
	return value
end

local function encode_value(value)
	local kind = type(value)
	if value == nil then
		return "null"
	end
	if kind == "boolean" then
		return value and "true" or "false"
	end
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("json: non-finite number")
		end
		if value % 1 == 0 then
			return string.format("%d", value)
		end
		return string.format("%.17g", value)
	end
	if kind == "string" then
		return '"' .. escape(value) .. '"'
	end
	if kind == "table" then
		local array, count = is_array(value)
		if array then
			local parts = {}
			for i = 1, count do
				parts[i] = encode_value(value[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for key, item in next, value do
			if type(key) ~= "string" then
				error("json: non-string object key")
			end
			parts[#parts + 1] = '"' .. escape(key) .. '":' .. encode_value(item)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("json: unsupported type " .. kind)
end

function Json.encode(value)
	return encode_value(value)
end

local function skip_ws(source, index)
	while index <= #source do
		local char = string.sub(source, index, index)
		if char == " " or char == "\t" or char == "\n" or char == "\r" then
			index = index + 1
		else
			break
		end
	end
	return index
end

local parse_value

local function parse_string(source, index)
	index = index + 1
	local out = {}
	while index <= #source do
		local char = string.sub(source, index, index)
		if char == '"' then
			return table.concat(out), index + 1
		end
		if char == "\\" then
			local escape_char = string.sub(source, index + 1, index + 1)
			if escape_char == '"' or escape_char == "\\" or escape_char == "/" then
				out[#out + 1] = escape_char
			elseif escape_char == "n" then
				out[#out + 1] = "\n"
			elseif escape_char == "r" then
				out[#out + 1] = "\r"
			elseif escape_char == "t" then
				out[#out + 1] = "\t"
			elseif escape_char == "b" then
				out[#out + 1] = "\b"
			elseif escape_char == "f" then
				out[#out + 1] = "\f"
			else
				error("json: bad escape")
			end
			index = index + 2
		else
			out[#out + 1] = char
			index = index + 1
		end
	end
	error("json: unterminated string")
end

local function parse_number(source, index)
	local start = index
	if string.sub(source, index, index) == "-" then
		index = index + 1
	end
	while index <= #source do
		local char = string.sub(source, index, index)
		if string.match(char, "^[0-9%.eE%+%-]$") then
			index = index + 1
		else
			break
		end
	end
	local number = tonumber(string.sub(source, start, index - 1))
	if number == nil then
		error("json: bad number")
	end
	return number, index
end

local function parse_array(source, index)
	index = index + 1
	local out = {}
	index = skip_ws(source, index)
	if string.sub(source, index, index) == "]" then
		return out, index + 1
	end
	while true do
		local value
		value, index = parse_value(source, index)
		out[#out + 1] = value
		index = skip_ws(source, index)
		local char = string.sub(source, index, index)
		if char == "," then
			index = skip_ws(source, index + 1)
		elseif char == "]" then
			return out, index + 1
		else
			error("json: bad array")
		end
	end
end

local function parse_object(source, index)
	index = index + 1
	local out = {}
	index = skip_ws(source, index)
	if string.sub(source, index, index) == "}" then
		return out, index + 1
	end
	while true do
		index = skip_ws(source, index)
		if string.sub(source, index, index) ~= '"' then
			error("json: bad object key")
		end
		local key
		key, index = parse_string(source, index)
		index = skip_ws(source, index)
		if string.sub(source, index, index) ~= ":" then
			error("json: missing colon")
		end
		local value
		value, index = parse_value(source, skip_ws(source, index + 1))
		out[key] = value
		index = skip_ws(source, index)
		local char = string.sub(source, index, index)
		if char == "," then
			index = index + 1
		elseif char == "}" then
			return out, index + 1
		else
			error("json: bad object")
		end
	end
end

parse_value = function(source, index)
	index = skip_ws(source, index)
	local char = string.sub(source, index, index)
	if char == "{" then
		return parse_object(source, index)
	end
	if char == "[" then
		return parse_array(source, index)
	end
	if char == '"' then
		return parse_string(source, index)
	end
	if string.sub(source, index, index + 3) == "true" then
		return true, index + 4
	end
	if string.sub(source, index, index + 4) == "false" then
		return false, index + 5
	end
	if string.sub(source, index, index + 3) == "null" then
		return nil, index + 4
	end
	return parse_number(source, index)
end

function Json.decode(source)
	if type(source) ~= "string" then
		return nil
	end
	local ok, value = pcall(parse_value, source, 1)
	if not ok then
		return nil
	end
	return value
end

return Json
