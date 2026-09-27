local ActionBroker = {}

local CODE = {
	OK = "broker_ok",
	BAD_OBSERVATION = "broker_bad_observation",
	BAD_ACTIONS = "broker_bad_actions",
	BAD_PORTS = "broker_bad_ports",
	CAPTURE_FAILED = "broker_capture_failed",
	EPOCH_INVALID = "broker_epoch_invalid",
	EPOCH_REGRESSION = "broker_epoch_regression",
	CANONICAL_FAILED = "broker_canonical_failed",
	GENERATE_FAILED = "broker_generate_failed",
	BUSY = "broker_busy",
	TOKEN_INVALID = "broker_token_invalid",
	TOKEN_UNKNOWN = "broker_token_unknown",
	STALE_EPOCH = "broker_stale_epoch",
	OBSERVATION_CHANGED = "broker_observation_changed",
	ACTION_MALFORMED = "broker_action_malformed",
	ACTION_NOT_CANDIDATE = "broker_action_not_candidate",
	VALIDATE_FAILED = "broker_validate_failed",
	REENTRANT = "broker_reentrant",
	EXECUTOR_DISABLED = "broker_executor_disabled",
	DISPATCH_FAILED = "broker_dispatch_failed",
	INTERNAL = "broker_internal_error",
}

local LIMITS = {
	max_depth = 16,
	max_nodes = 8192,
	max_actions = 256,
	max_string = 4096,
	int_min = -2147483648,
	int_max = 2147483647,
}

local TOKEN_TAG = "AISparring.ActionBroker.token"
local TOKEN_META = { __metatable = TOKEN_TAG }

local function shallow_copy(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

ActionBroker.CODE = shallow_copy(CODE)
ActionBroker.LIMITS = shallow_copy(LIMITS)

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
	return n >= LIMITS.int_min and n <= LIMITS.int_max
end

local function copy_plain(value, bad_code)
	local state = { nodes = 0, stack = {} }
	local function walk(item, depth)
		state.nodes = state.nodes + 1
		if state.nodes > LIMITS.max_nodes or depth > LIMITS.max_depth then
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
			if #item > LIMITS.max_string then
				return nil
			end
			return item
		end
		if kind ~= "table" then
			return nil
		end
		if getmetatable(item) ~= nil then
			return nil
		end
		if state.stack[item] then
			return nil
		end
		state.stack[item] = true
		local out = {}
		for key, child in next, item do
			local key_kind = type(key)
			if key_kind ~= "string" and not (key_kind == "number" and is_int(key)) then
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
	local result = walk(value, 1)
	if result == nil then
		return nil, bad_code
	end
	return result
end

local function copy_actions(list)
	if type(list) ~= "table" or getmetatable(list) ~= nil then
		return nil, CODE.BAD_ACTIONS
	end
	local out = {}
	local count = 0
	local maxn = 0
	for key, item in next, list do
		if type(key) ~= "number" or not is_int(key) or key < 1 then
			return nil, CODE.BAD_ACTIONS
		end
		count = count + 1
		if count > LIMITS.max_actions then
			return nil, CODE.BAD_ACTIONS
		end
		if key > maxn then
			maxn = key
		end
		local copied, code = copy_plain(item, CODE.BAD_ACTIONS)
		if copied == nil then
			return nil, code
		end
		out[key] = copied
	end
	if count ~= maxn then
		return nil, CODE.BAD_ACTIONS
	end
	return out
end

function ActionBroker.factory(observation, actions, ports)
	if type(observation) ~= "table"
		or type(observation.export) ~= "function"
		or type(observation.canonical) ~= "function"
		or type(observation.is_handle) ~= "function" then
		return nil, CODE.BAD_OBSERVATION
	end
	if type(actions) ~= "table"
		or type(actions.generate) ~= "function"
		or type(actions.validate) ~= "function" then
		return nil, CODE.BAD_ACTIONS
	end
	if type(ports) ~= "table" or type(ports.capture) ~= "function" or type(ports.validate) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local fixture = ports.fixture == "M2_FIXTURE_ONLY"
	if fixture and type(ports.dispatch) ~= "function" then
		return nil, CODE.BAD_PORTS
	end

	local pending_token = nil
	local pending_record = nil
	local in_flight = false
	local reentry_flag = false
	local last_epoch = nil
	local instance = {}

	local function capture()
		local ok, handle, epoch = pcall(ports.capture)
		if not ok or handle == nil then
			return nil, CODE.CAPTURE_FAILED
		end
		local ok_check, valid = pcall(observation.is_handle, handle)
		if not ok_check or valid ~= true then
			return nil, CODE.CAPTURE_FAILED
		end
		if not is_int(epoch) or epoch < 0 then
			return nil, CODE.EPOCH_INVALID
		end
		if last_epoch ~= nil and epoch < last_epoch then
			return nil, CODE.EPOCH_REGRESSION
		end
		if last_epoch == nil or epoch > last_epoch then
			last_epoch = epoch
		end
		return handle, epoch
	end

	local function read_canonical(handle)
		local ok, canonical = pcall(observation.canonical, handle)
		if not ok or type(canonical) ~= "string" then
			return nil
		end
		return canonical
	end

	local function guarded(fn, ...)
		if in_flight then
			reentry_flag = true
			return nil, CODE.BUSY
		end
		reentry_flag = false
		in_flight = true
		local ok, first, second = pcall(fn, ...)
		in_flight = false
		if not ok then
			return nil, CODE.INTERNAL
		end
		return first, second
	end

	local function issue_impl()
		local handle, epoch_or_code = capture()
		if handle == nil then
			return nil, epoch_or_code
		end
		local epoch = epoch_or_code
		local canonical = read_canonical(handle)
		if canonical == nil then
			return nil, CODE.CANONICAL_FAILED
		end
		local ok_export, data = pcall(observation.export, handle)
		if not ok_export or data == nil then
			return nil, CODE.BAD_OBSERVATION
		end
		local copied_data, data_code = copy_plain(data, CODE.BAD_OBSERVATION)
		if copied_data == nil then
			return nil, data_code
		end
		local ok_generate, list = pcall(actions.generate, handle)
		if not ok_generate or list == nil then
			return nil, CODE.GENERATE_FAILED
		end
		local copied_actions, action_code = copy_actions(list)
		if copied_actions == nil then
			return nil, action_code
		end
		local token = setmetatable({}, TOKEN_META)
		pending_token = token
		pending_record = { epoch = epoch, canonical = canonical }
		return token, { observation = copied_data, actions = copied_actions }
	end

	local function submit_impl(token, action)
		if type(token) ~= "table" or getmetatable(token) ~= TOKEN_TAG then
			return nil, CODE.TOKEN_INVALID
		end
		if pending_token == nil or not rawequal(pending_token, token) then
			return nil, CODE.TOKEN_UNKNOWN
		end
		local record = pending_record
		pending_token = nil
		pending_record = nil

		if type(action) ~= "table" or getmetatable(action) ~= nil then
			return nil, CODE.ACTION_MALFORMED
		end
		local _, action_code = copy_plain(action, CODE.ACTION_MALFORMED)
		if action_code ~= nil then
			return nil, action_code
		end

		local handle_start, epoch_start_or_code = capture()
		if handle_start == nil then
			return nil, epoch_start_or_code
		end
		local epoch_start = epoch_start_or_code
		if epoch_start ~= record.epoch then
			return nil, CODE.STALE_EPOCH
		end
		local canonical_start = read_canonical(handle_start)
		if canonical_start == nil then
			return nil, CODE.CANONICAL_FAILED
		end
		if canonical_start ~= record.canonical then
			return nil, CODE.OBSERVATION_CHANGED
		end

		local ok_validate, normalized = pcall(actions.validate, handle_start, action)
		if not ok_validate then
			return nil, CODE.VALIDATE_FAILED
		end
		if normalized == nil then
			return nil, CODE.ACTION_NOT_CANDIDATE
		end
		local validated = copy_plain(normalized, CODE.ACTION_MALFORMED)
		if validated == nil then
			return nil, CODE.ACTION_MALFORMED
		end
		local validator_view = copy_plain(normalized, CODE.ACTION_MALFORMED)
		if validator_view == nil then
			return nil, CODE.ACTION_MALFORMED
		end

		local ok_trusted, accepted = pcall(ports.validate, validator_view, handle_start)
		if reentry_flag then
			return nil, CODE.REENTRANT
		end
		if not ok_trusted or accepted ~= true then
			return nil, CODE.VALIDATE_FAILED
		end

		local handle_end, epoch_end_or_code = capture()
		if handle_end == nil then
			return nil, epoch_end_or_code
		end
		local epoch_end = epoch_end_or_code
		if epoch_end ~= epoch_start then
			return nil, CODE.STALE_EPOCH
		end
		local canonical_end = read_canonical(handle_end)
		if canonical_end == nil then
			return nil, CODE.CANONICAL_FAILED
		end
		if canonical_end ~= canonical_start then
			return nil, CODE.OBSERVATION_CHANGED
		end
		if reentry_flag then
			return nil, CODE.REENTRANT
		end

		if not fixture then
			return nil, CODE.EXECUTOR_DISABLED
		end
		local ok_dispatch = pcall(ports.dispatch, validated)
		if not ok_dispatch then
			return nil, CODE.DISPATCH_FAILED
		end
		if reentry_flag then
			return nil, CODE.REENTRANT
		end
		return true, CODE.OK
	end

	function instance.issue()
		return guarded(issue_impl)
	end

	function instance.submit(token, action)
		return guarded(submit_impl, token, action)
	end

	function instance.has_pending()
		return pending_token ~= nil
	end

	function instance.fixture_only()
		return fixture
	end

	instance.CODE = shallow_copy(CODE)
	instance.LIMITS = shallow_copy(LIMITS)

	return instance
end

return ActionBroker
