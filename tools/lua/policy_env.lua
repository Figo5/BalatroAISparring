local PolicyEnv = {}

PolicyEnv.CODE = {
	OK = "policy_ok",
	BAD_INPUT = "policy_bad_input",
	BAD_SOURCE = "policy_bad_source",
	BYTECODE_REJECTED = "policy_bytecode_rejected",
	COMPILE_FAILED = "policy_compile_failed",
	LOAD_FAILED = "policy_load_failed",
	RUNTIME_ERROR = "policy_runtime_error",
	BUDGET_EXCEEDED = "policy_budget_exceeded",
	NO_ACTION = "policy_no_action",
	BAD_INDEX = "policy_bad_index",
	BAD_ACTION = "policy_bad_action",
	NOT_CONFIGURED = "policy_not_configured",
	CONFIGURE_FAILED = "policy_configure_failed",
	BAD_OBSERVATION = "policy_bad_observation",
	BAD_ACTIONS = "policy_bad_actions",
	ENGINE_VM_REFUSED = "policy_engine_vm_refused",
}

local CODE = PolicyEnv.CODE

local MAX_DEPTH = 16
local MAX_NODES = 8192
local MAX_STRING = 4096
local MAX_SOURCE_BYTES = 65536
local INSTRUCTION_BUDGET = 2000000
local HOOK_STRIDE = 1000
local BUDGET_STEPS = INSTRUCTION_BUDGET / HOOK_STRIDE
local ENGINE_GLOBALS = { "G", "MP", "SMODS", "love" }

PolicyEnv.INSTRUCTION_BUDGET = INSTRUCTION_BUDGET

local STRING_FUNCS = {
	"byte", "char", "sub", "len", "rep", "lower", "upper",
	"format", "find", "match", "gsub", "gmatch", "reverse",
}
local TABLE_FUNCS = { "insert", "remove", "concat", "sort" }
local MATH_FUNCS = { "floor", "ceil", "abs", "min", "max", "huge" }

local BUDGET_ERROR = {}

local CodecModule = nil
local Observer = nil
local ActionSet = nil

local function is_int(n)
	if type(n) ~= "number" then
		return false
	end
	if n ~= n or n == math.huge or n == -math.huge then
		return false
	end
	if n % 1 ~= 0 then
		return false
	end
	return n >= -2147483648 and n <= 2147483647
end

local function copy_plain(value)
	local state = { nodes = 0, stack = {} }
	local function walk(item, depth)
		state.nodes = state.nodes + 1
		if state.nodes > MAX_NODES or depth > MAX_DEPTH then
			return nil
		end
		local kind = type(item)
		if kind == "boolean" then
			return item
		end
		if kind == "number" then
			if not is_int(item) then
				return nil
			end
			return item
		end
		if kind == "string" then
			if #item > MAX_STRING then
				return nil
			end
			return item
		end
		if kind ~= "table" or getmetatable(item) ~= nil then
			return nil
		end
		if state.stack[item] then
			return nil
		end
		state.stack[item] = true
		local out = {}
		local count = 0
		for key, child in next, item do
			local key_kind = type(key)
			if key_kind ~= "string" and not (key_kind == "number" and is_int(key)) then
				state.stack[item] = nil
				return nil
			end
			count = count + 1
			if count > MAX_NODES then
				state.stack[item] = nil
				return nil
			end
			local copied = walk(child, depth + 1)
			if copied == nil then
				state.stack[item] = nil
				return nil
			end
			out[key] = copied
		end
		state.stack[item] = nil
		return out
	end
	return walk(value, 1)
end

local STRING_CAP = 65536

local function pick(library, names)
	local out = {}
	for i = 1, #names do
		local key = names[i]
		out[key] = library[key]
	end
	return out
end

local function bounded_rep(value, count)
	if type(value) ~= "string" then
		error("policy_bad_string_argument", 2)
	end
	if type(count) ~= "number" or count ~= count or count == math.huge or count == -math.huge then
		error("policy_bad_string_argument", 2)
	end
	if count % 1 ~= 0 or count < 0 then
		error("policy_bad_string_argument", 2)
	end
	if count > STRING_CAP then
		error("policy_string_cap", 2)
	end
	if count == 0 or value == "" then
		return ""
	end
	if #value > STRING_CAP / count then
		error("policy_string_cap", 2)
	end
	return string.rep(value, count)
end

local function safe_tostring(value)
	local kind = type(value)
	if kind == "string" then
		return value
	end
	if kind == "boolean" then
		return value and "true" or "false"
	end
	if kind == "nil" then
		return "nil"
	end
	if kind == "number" then
		if value ~= value then
			return "nan"
		end
		if value == math.huge then
			return "inf"
		end
		if value == -math.huge then
			return "-inf"
		end
		return tostring(value)
	end
	error("policy_bad_tostring_argument", 2)
end

local FORMAT_CONVERSIONS = {
	["d"] = true, ["i"] = true, ["o"] = true, ["u"] = true, ["x"] = true, ["X"] = true,
	["e"] = true, ["E"] = true, ["f"] = true, ["g"] = true, ["G"] = true,
	["c"] = true, ["q"] = true, ["s"] = true,
}

local function validate_format(fmt)
	local i = 1
	local length = #fmt
	while i <= length do
		if string.sub(fmt, i, i) ~= "%" then
			i = i + 1
		else
			i = i + 1
			if i > length then
				error("policy_bad_format", 2)
			end
			if string.sub(fmt, i, i) == "%" then
				i = i + 1
			else
				while i <= length do
					local c = string.sub(fmt, i, i)
					if c == "." or c == "*" or (c >= "0" and c <= "9") or string.find("-+ #0", c, 1, true) ~= nil then
						i = i + 1
					else
						break
					end
				end
				if i > length then
					error("policy_bad_format", 2)
				end
				local conversion = string.sub(fmt, i, i)
				if FORMAT_CONVERSIONS[conversion] ~= true then
					error("policy_bad_format", 2)
				end
				i = i + 1
			end
		end
	end
end

local function bounded_format(fmt, ...)
	if type(fmt) ~= "string" then
		error("policy_bad_format", 2)
	end
	validate_format(fmt)
	local count = select("#", ...)
	for i = 1, count do
		local kind = type(select(i, ...))
		if kind ~= "string" and kind ~= "number" then
			error("policy_bad_format_argument", 2)
		end
	end
	local result = string.format(fmt, ...)
	if type(result) == "string" and #result > STRING_CAP then
		error("policy_string_cap", 2)
	end
	return result
end

local function bounded_concat(list, sep)
	if type(list) ~= "table" then
		error("policy_bad_string_argument", 2)
	end
	local total = 0
	local count = #list
	for i = 1, count do
		local item = list[i]
		if type(item) == "string" then
			total = total + #item
		elseif type(item) == "number" then
			total = total + 12
		else
			total = total + 8
		end
		if total > STRING_CAP then
			error("policy_string_cap", 2)
		end
	end
	if type(sep) == "string" and count > 1 then
		total = total + (count - 1) * #sep
		if total > STRING_CAP then
			error("policy_string_cap", 2)
		end
	end
	return table.concat(list, sep)
end

local function build_env(observation, actions)
	local env = {}
	local strlib = pick(string, STRING_FUNCS)
	strlib.rep = bounded_rep
	strlib.format = bounded_format
	local tblib = pick(table, TABLE_FUNCS)
	tblib.concat = bounded_concat
	env.string = strlib
	env.table = tblib
	env.math = pick(math, MATH_FUNCS)
	env.type = type
	env.tostring = safe_tostring
	env.tonumber = tonumber
	env.ipairs = ipairs
	env.pairs = pairs
	env.next = next
	env.select = select
	env.unpack = unpack
	env.rawget = rawget
	env.rawset = rawset
	env.rawequal = rawequal
	env.observation = observation
	env.actions = actions
	return env, strlib
end

local function compile(source, env)
	if type(source) ~= "string" or #source == 0 then
		return nil, CODE.BAD_SOURCE
	end
	if #source > MAX_SOURCE_BYTES then
		return nil, CODE.BAD_SOURCE
	end
	if string.byte(source, 1) == 27 then
		return nil, CODE.BYTECODE_REJECTED
	end
	local chunk = loadstring(source, "=policy")
	if not chunk then
		return nil, CODE.COMPILE_FAILED
	end
	setfenv(chunk, env)
	return chunk
end

local function with_budget(fn)
	local prev_hook, prev_mask, prev_count = debug.gethook()
	local exhausted = false
	local counter = 0
	local function hook()
		counter = counter + 1
		if counter > BUDGET_STEPS then
			exhausted = true
			debug.sethook()
			error(BUDGET_ERROR)
		end
	end
	debug.sethook(hook, "", HOOK_STRIDE)
	local ok, result, reason = pcall(fn)
	if prev_hook ~= nil then
		debug.sethook(prev_hook, prev_mask, prev_count)
	else
		debug.sethook()
	end
	if exhausted then
		return nil, CODE.BUDGET_EXCEEDED
	end
	if not ok then
		return nil, CODE.RUNTIME_ERROR
	end
	return result, reason
end

local function load_module(source, name)
	if type(source) ~= "string" then
		return nil
	end
	local chunk = loadstring(source, "=AISparring/" .. name)
	if not chunk then
		return nil
	end
	local ok, value = pcall(chunk)
	if not ok or type(value) ~= "table" then
		return nil
	end
	return value
end

local function engine_vm_present()
	for i = 1, #ENGINE_GLOBALS do
		if _G[ENGINE_GLOBALS[i]] ~= nil then
			return true
		end
	end
	return false
end

function PolicyEnv.configure(codec_src, observation_src, actions_src)
	if engine_vm_present() then
		return false
	end
	local codec = load_module(codec_src, "ai/codec.lua")
	if codec == nil then
		return false
	end
	local module = load_module(observation_src, "ai/observation.lua")
	if module == nil or type(module.factory) ~= "function" then
		return false
	end
	local observer = module.factory(codec)
	if type(observer) ~= "table" then
		return false
	end
	local actions_module = load_module(actions_src, "ai/actions.lua")
	if actions_module == nil or type(actions_module.factory) ~= "function" then
		return false
	end
	local action_set = actions_module.factory(observer, codec)
	if type(action_set) ~= "table" then
		return false
	end
	CodecModule = codec
	Observer = observer
	ActionSet = action_set
	return true
end

local function reconstruct(export)
	local frame = copy_plain(export)
	if frame == nil then
		return nil
	end
	if type(frame.opponent) == "table" then
		frame.opponent.certified = true
	end
	return frame
end

function PolicyEnv.run(source, observation)
	if engine_vm_present() then
		return { ok = false, code = CODE.ENGINE_VM_REFUSED }
	end
	if type(Observer) ~= "table" or type(ActionSet) ~= "table" then
		return { ok = false, code = CODE.NOT_CONFIGURED }
	end
	if type(observation) ~= "table" or getmetatable(observation) ~= nil then
		return { ok = false, code = CODE.BAD_INPUT }
	end

	local frame = reconstruct(observation)
	if frame == nil then
		return { ok = false, code = CODE.BAD_INPUT }
	end

	local ok_observe, handle = pcall(Observer.observe, frame)
	if not ok_observe or handle == nil then
		return { ok = false, code = CODE.BAD_OBSERVATION }
	end

	local ok_export, sanitized = pcall(Observer.export, handle)
	if not ok_export or sanitized == nil then
		return { ok = false, code = CODE.BAD_OBSERVATION }
	end

	local ok_generate, generated = pcall(ActionSet.generate, handle)
	if not ok_generate or generated == nil then
		return { ok = false, code = CODE.BAD_ACTIONS }
	end

	local observation_copy = copy_plain(sanitized)
	local action_copy = copy_plain(generated)
	if observation_copy == nil or action_copy == nil then
		return { ok = false, code = CODE.BAD_ACTIONS }
	end

	local env, strlib = build_env(observation_copy, action_copy)
	local chunk, compile_code = compile(source, env)
	if chunk == nil then
		return { ok = false, code = compile_code }
	end

	local string_meta = getmetatable("")
	local previous_index = nil
	if type(string_meta) == "table" then
		previous_index = string_meta.__index
		string_meta.__index = strlib
	end

	local selected, reason = with_budget(function()
		local policy = chunk()
		if type(policy) ~= "function" then
			return nil, CODE.LOAD_FAILED
		end
		return policy(observation_copy, action_copy)
	end)

	if type(string_meta) == "table" then
		string_meta.__index = previous_index or string
	end

	if selected == nil then
		return { ok = false, code = reason or CODE.NO_ACTION }
	end

	local candidate
	if type(selected) == "number" and is_int(selected) and selected >= 1 then
		candidate = action_copy[selected]
		if candidate == nil then
			return { ok = false, code = CODE.BAD_INDEX }
		end
	else
		candidate = selected
	end

	if type(candidate) ~= "table" then
		return { ok = false, code = CODE.BAD_ACTION }
	end

	local plain_candidate = copy_plain(candidate)
	if plain_candidate == nil then
		return { ok = false, code = CODE.BAD_ACTION }
	end

	local ok_validate, normalized = pcall(ActionSet.validate, handle, plain_candidate)
	if not ok_validate or normalized == nil then
		return { ok = false, code = CODE.BAD_ACTION }
	end

	local out = copy_plain(normalized)
	if out == nil then
		return { ok = false, code = CODE.BAD_ACTION }
	end

	return { ok = true, code = CODE.OK, action = out }
end

if (not engine_vm_present()) and jit and jit.off then
	pcall(jit.off)
end

return PolicyEnv
