local Codec = {}

local INT_MIN = -2147483648
local INT_MAX = 2147483647
local MAX_DEPTH = 16
local MAX_ARRAY = 256
local MAX_MAP = 256
local MAX_STRING = 4096
local MAX_NODES = 8192
local MAX_CANONICAL = 262144

Codec.LIMITS = {
	max_depth = MAX_DEPTH,
	max_array = MAX_ARRAY,
	max_map = MAX_MAP,
	max_string = MAX_STRING,
	max_nodes = MAX_NODES,
	max_canonical = MAX_CANONICAL,
	int_min = INT_MIN,
	int_max = INT_MAX,
}

Codec.CODE = {
	OK = "ok",
	BAD_TYPE = "codec_bad_type",
	BAD_NUMBER = "codec_bad_number",
	BAD_KEY = "codec_bad_key",
	BAD_STRING = "codec_bad_string",
	TOO_DEEP = "codec_too_deep",
	TOO_LARGE = "codec_too_large",
	CYCLE = "codec_cycle",
}

local DIGIT = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
local HEX = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f" }

local function is_int(n)
	if type(n) ~= "number" then
		return false
	end
	if n ~= n then
		return false
	end
	if n == math.huge or n == -math.huge then
		return false
	end
	if n % 1 ~= 0 then
		return false
	end
	return n >= INT_MIN and n <= INT_MAX
end

local function int_to_string(n)
	if n < 0 then
		return "-" .. int_to_string(-n)
	end
	if n < 10 then
		return DIGIT[n + 1]
	end
	local out = {}
	while n > 0 do
		local q = math.floor(n / 10)
		local r = n - q * 10
		out[#out + 1] = DIGIT[r + 1]
		n = q
	end
	local s = {}
	for i = #out, 1, -1 do
		s[#s + 1] = out[i]
	end
	return table.concat(s)
end

local function byte_less(a, b)
	local na = #a
	local nb = #b
	local n = na
	if nb < n then
		n = nb
	end
	for i = 1, n do
		local ba = string.byte(a, i)
		local bb = string.byte(b, i)
		if ba ~= bb then
			return ba < bb
		end
	end
	return na < nb
end

local function enc(state, value, depth, out)
	state.nodes = state.nodes + 1
	if state.nodes > MAX_NODES then
		return false, Codec.CODE.TOO_LARGE
	end
	if depth > MAX_DEPTH then
		return false, Codec.CODE.TOO_DEEP
	end
	local kind = type(value)
	if kind == "boolean" then
		out[#out + 1] = value and "b1" or "b0"
		return true
	elseif kind == "number" then
		if not is_int(value) then
			return false, Codec.CODE.BAD_NUMBER
		end
		out[#out + 1] = "i" .. int_to_string(value) .. ";"
		return true
	elseif kind == "string" then
		local len = #value
		if len > MAX_STRING then
			return false, Codec.CODE.BAD_STRING
		end
		out[#out + 1] = "s" .. int_to_string(len) .. ":" .. value .. ";"
		return true
	elseif kind ~= "table" then
		return false, Codec.CODE.BAD_TYPE
	end
	if getmetatable(value) ~= nil then
		return false, Codec.CODE.BAD_TYPE
	end
	if state.stack[value] then
		return false, Codec.CODE.CYCLE
	end
	state.stack[value] = true

	local count = 0
	local maxn = 0
	local array_only = true
	for key in next, value do
		count = count + 1
		if count > MAX_MAP then
			state.stack[value] = nil
			return false, Codec.CODE.TOO_LARGE
		end
		if type(key) == "number" and is_int(key) and key >= 1 then
			if key > maxn then
				maxn = key
			end
		else
			array_only = false
		end
	end

	if array_only and count == maxn then
		if maxn > MAX_ARRAY then
			state.stack[value] = nil
			return false, Codec.CODE.TOO_LARGE
		end
		out[#out + 1] = "a" .. int_to_string(maxn) .. ":"
		for i = 1, maxn do
			local ok, err = enc(state, rawget(value, i), depth + 1, out)
			if not ok then
				state.stack[value] = nil
				return false, err
			end
		end
		state.stack[value] = nil
		return true
	end

	if count > MAX_MAP then
		state.stack[value] = nil
		return false, Codec.CODE.TOO_LARGE
	end
	local entries = {}
	for key, item in next, value do
		local key_kind = type(key)
		local encoded_key
		if key_kind == "string" then
			local len = #key
			if len > MAX_STRING then
				state.stack[value] = nil
				return false, Codec.CODE.BAD_KEY
			end
			encoded_key = "s" .. int_to_string(len) .. ":" .. key .. ";"
		elseif key_kind == "number" then
			if not is_int(key) then
				state.stack[value] = nil
				return false, Codec.CODE.BAD_KEY
			end
			encoded_key = "i" .. int_to_string(key) .. ";"
		else
			state.stack[value] = nil
			return false, Codec.CODE.BAD_KEY
		end
		local buffer = {}
		local ok_value, err_value = enc(state, item, depth + 1, buffer)
		if not ok_value then
			state.stack[value] = nil
			return false, err_value
		end
		entries[#entries + 1] = { k = encoded_key, v = table.concat(buffer) }
	end
	table.sort(entries, function(a, b)
		return byte_less(a.k, b.k)
	end)
	out[#out + 1] = "o" .. int_to_string(#entries) .. ":"
	for i = 1, #entries do
		out[#out + 1] = entries[i].k .. entries[i].v
	end
	state.stack[value] = nil
	return true
end

local function xor8(a, b)
	local result = 0
	local bit = 1
	for _ = 1, 8 do
		local abit = a % 2
		local bbit = b % 2
		if abit ~= bbit then
			result = result + bit
		end
		a = (a - abit) / 2
		b = (b - bbit) / 2
		bit = bit * 2
	end
	return result
end

local function mulmod32(a, b)
	local high = math.floor(a / 65536)
	local low = a - high * 65536
	local lo = (low * b) % 4294967296
	local hi = ((high * b) % 65536) * 65536
	return (lo + hi) % 4294967296
end

local function to_hex8(n)
	local out = {}
	for i = 1, 8 do
		local nib = n % 16
		out[i] = HEX[nib + 1]
		n = (n - nib) / 16
	end
	local s = {}
	for i = 8, 1, -1 do
		s[#s + 1] = out[i]
	end
	return table.concat(s)
end

local OFFSET = 2166136261
local PRIME = 16777619

local function fnv1a(str)
	local hash = OFFSET
	for i = 1, #str do
		local byte = string.byte(str, i)
		local low = hash % 256
		local high = hash - low
		hash = high + xor8(low, byte)
		hash = mulmod32(hash, PRIME)
	end
	return to_hex8(hash)
end

function Codec.encode(value)
	local state = { nodes = 0, stack = {} }
	local out = {}
	local ok, code = enc(state, value, 1, out)
	if not ok then
		return nil, code or Codec.CODE.TOO_LARGE
	end
	local str = table.concat(out)
	if #str > MAX_CANONICAL then
		return nil, Codec.CODE.TOO_LARGE
	end
	return str
end

function Codec.hash_string(str)
	if type(str) ~= "string" then
		return nil, Codec.CODE.BAD_TYPE
	end
	if #str > MAX_CANONICAL then
		return nil, Codec.CODE.TOO_LARGE
	end
	return fnv1a(str)
end

function Codec.hash(value)
	local str, code = Codec.encode(value)
	if str == nil then
		return nil, code or Codec.CODE.TOO_LARGE
	end
	return fnv1a(str)
end

function Codec.equal(a, b)
	local left = Codec.encode(a)
	if left == nil then
		return false
	end
	local right = Codec.encode(b)
	if right == nil then
		return false
	end
	return left == right
end

function Codec.int_string(n)
	if not is_int(n) then
		return nil
	end
	return int_to_string(n)
end

function Codec.is_int(n)
	return is_int(n)
end

return Codec
