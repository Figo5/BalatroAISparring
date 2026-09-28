-- Narrow wire encoder for the two known envelope shapes.
--
-- The game-bundled JSON library is the rxi `json` module that Multiplayer gets
-- through `require("json")` (supplied by SMODS). It has two properties that must
-- not silently break the control channel:
--
--   * an EMPTY table encodes as `[]` (it is treated as an array); and
--   * there is no `null` sentinel: a missing table key is simply omitted, so a
--     required `null` (the host `start` request's `gauntlet` for normal mode)
--     cannot be produced from a table field.
--
-- This module is the pure, globals-free adapter that composes the *exact* bytes
-- for the two fixed envelopes the project owns, using the injected real encoder
-- for every value and forcing only the keys whose JSON type is part of the wire
-- contract:
--
--   * the control-service envelope is always exactly the six keys
--     { session, credential, role, op, sequence, observation }; an absent or
--     empty `observation` payload is emitted as `{}` (never `[]`), and nested
--     observation arrays keep the base encoder's own semantics;
--   * the practice-host request envelope is always exactly the four keys
--     { schema, op, auth, request }; its `request` object is exactly the seven
--     keys { session_id, difficulty, pacing, mode, gauntlet, live_pid,
--     live_create_time }, and an absent `gauntlet` is emitted as literal `null`.
--
-- It is not a general JSON serializer and it never does string substitution on
-- encoded output. Unknown, missing or wrongly typed keys are rejected with a
-- bounded code, so a malformed request can never be silently turned into a valid
-- one. Loading this file has no side effect.

local WireJson = {}

WireJson.CODE = {
	OK = "wire_ok",
	BAD_BASE = "wire_bad_base",
	BAD_ENVELOPE = "wire_bad_envelope",
	BAD_KEY = "wire_bad_key",
	BAD_VALUE = "wire_bad_value",
	ENCODE_FAILED = "wire_encode_failed",
}

local CODE = WireJson.CODE

local SERVICE_KEYS = {
	session = true,
	credential = true,
	role = true,
	op = true,
	sequence = true,
	observation = true,
}

local HOST_KEYS = {
	schema = true,
	op = true,
	auth = true,
	request = true,
}

local REQUEST_KEYS = {
	session_id = true,
	difficulty = true,
	pacing = true,
	mode = true,
	gauntlet = true,
	live_pid = true,
	live_create_time = true,
}

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function is_int(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	return value % 1 == 0
end

-- Count the keys of `value` and reject any key not present in `allowed`.
-- Returns the count, or nil when a key is unknown or the value is not a table.
local function key_count(value, allowed)
	if not is_plain(value) then
		return nil
	end
	local count = 0
	for key in next, value do
		if type(key) ~= "string" or allowed[key] ~= true then
			return nil
		end
		count = count + 1
	end
	return count
end

function WireJson.factory(base)
	if type(base) ~= "table"
		or type(rawget(base, "encode")) ~= "function"
		or type(rawget(base, "decode")) ~= "function" then
		return nil, CODE.BAD_BASE
	end
	local encode = base.encode

	-- Encode one ordinary value with the real codec. A nil value is only ever
	-- passed for a field whose wire contract requires an explicit null.
	local function value_text(value)
		if value == nil then
			return "null"
		end
		local ok, text = pcall(encode, value)
		if not ok or type(text) ~= "string" then
			return nil
		end
		return text
	end

	-- Encode a payload object. An absent or empty table becomes `{}` so the
	-- required key survives an encoder that maps an empty table to `[]`.
	local function payload_text(value)
		if value == nil then
			return "{}"
		end
		if type(value) ~= "table" then
			return nil
		end
		if next(value) == nil then
			return "{}"
		end
		return value_text(value)
	end

	local wire = {}

	-- Exact six-key control-service envelope.
	function wire.encode_service(envelope)
		if key_count(envelope, SERVICE_KEYS) ~= 6 then
			return nil, CODE.BAD_ENVELOPE
		end
		if type(rawget(envelope, "session")) ~= "string"
			or type(rawget(envelope, "credential")) ~= "string"
			or type(rawget(envelope, "role")) ~= "string"
			or type(rawget(envelope, "op")) ~= "string" then
			return nil, CODE.BAD_VALUE
		end
		if not is_int(rawget(envelope, "sequence")) then
			return nil, CODE.BAD_VALUE
		end
		local observation = rawget(envelope, "observation")
		if observation ~= nil and type(observation) ~= "table" then
			return nil, CODE.BAD_VALUE
		end
		local session = value_text(envelope.session)
		local credential = value_text(envelope.credential)
		local role = value_text(envelope.role)
		local op = value_text(envelope.op)
		local sequence = value_text(envelope.sequence)
		local payload = payload_text(observation)
		if session == nil or credential == nil or role == nil or op == nil
			or sequence == nil or payload == nil then
			return nil, CODE.ENCODE_FAILED
		end
		return '{"session":' .. session
			.. ',"credential":' .. credential
			.. ',"role":' .. role
			.. ',"op":' .. op
			.. ',"sequence":' .. sequence
			.. ',"observation":' .. payload .. '}'
	end

	-- Exact practice-host request envelope. `gauntlet` is optional in the input
	-- table but always emitted: a string label in gauntlet mode, literal null
	-- otherwise.
	function wire.encode_host(envelope)
		if key_count(envelope, HOST_KEYS) ~= 4 then
			return nil, CODE.BAD_ENVELOPE
		end
		if type(rawget(envelope, "schema")) ~= "string"
			or type(rawget(envelope, "op")) ~= "string"
			or type(rawget(envelope, "auth")) ~= "string" then
			return nil, CODE.BAD_VALUE
		end
		local request = rawget(envelope, "request")
		local count = key_count(request, REQUEST_KEYS)
		-- `gauntlet` is optional in the input (absent means null on the wire);
		-- the other six keys are mandatory.
		if count == nil or count < 6 or count > 7 then
			return nil, CODE.BAD_KEY
		end
		if rawget(request, "gauntlet") == nil and count ~= 6 then
			return nil, CODE.BAD_KEY
		end
		if type(rawget(request, "session_id")) ~= "string"
			or type(rawget(request, "difficulty")) ~= "string"
			or type(rawget(request, "pacing")) ~= "string"
			or type(rawget(request, "mode")) ~= "string" then
			return nil, CODE.BAD_VALUE
		end
		if not is_int(rawget(request, "live_pid")) then
			return nil, CODE.BAD_VALUE
		end
		local create_time = rawget(request, "live_create_time")
		if type(create_time) ~= "number" or create_time ~= create_time then
			return nil, CODE.BAD_VALUE
		end
		local gauntlet = rawget(request, "gauntlet")
		if gauntlet ~= nil and type(gauntlet) ~= "string" then
			return nil, CODE.BAD_VALUE
		end
		local schema = value_text(envelope.schema)
		local op = value_text(envelope.op)
		local auth = value_text(envelope.auth)
		local session_id = value_text(request.session_id)
		local difficulty = value_text(request.difficulty)
		local pacing = value_text(request.pacing)
		local mode = value_text(request.mode)
		local label = value_text(gauntlet)
		local live_pid = value_text(request.live_pid)
		local live_create_time = value_text(create_time)
		if schema == nil or op == nil or auth == nil or session_id == nil
			or difficulty == nil or pacing == nil or mode == nil or label == nil
			or live_pid == nil or live_create_time == nil then
			return nil, CODE.ENCODE_FAILED
		end
		return '{"schema":' .. schema
			.. ',"op":' .. op
			.. ',"auth":' .. auth
			.. ',"request":{"session_id":' .. session_id
			.. ',"difficulty":' .. difficulty
			.. ',"pacing":' .. pacing
			.. ',"mode":' .. mode
			.. ',"gauntlet":' .. label
			.. ',"live_pid":' .. live_pid
			.. ',"live_create_time":' .. live_create_time .. '}}'
	end

	function wire.decode(text)
		return base.decode(text)
	end

	function wire.describe()
		return {
			version = "aisp-wire-json/1",
			service_keys = { "session", "credential", "role", "op", "sequence", "observation" },
			host_keys = { "schema", "op", "auth", "request" },
			codes = {
				OK = CODE.OK,
				BAD_BASE = CODE.BAD_BASE,
				BAD_ENVELOPE = CODE.BAD_ENVELOPE,
				BAD_KEY = CODE.BAD_KEY,
				BAD_VALUE = CODE.BAD_VALUE,
				ENCODE_FAILED = CODE.ENCODE_FAILED,
			},
		}
	end

	return wire, CODE.OK
end

return WireJson
