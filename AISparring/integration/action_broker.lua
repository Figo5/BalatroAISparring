-- Trusted action broker.
--
-- Two construction paths:
--
--   * ActionBroker.factory(observation, actions, ports): the legacy M2 path. Real
--     dispatch stays disabled; only the distinctive fixture sentinel enables it.
--   * ActionBroker.production_factory(verifier): trusted bootstrap only. The
--     returned authority mints opaque capabilities and authorizes production
--     brokers whose dispatch path requires an explicit boolean true result.
--
-- The capability is an in-process identity object. It cannot be serialized (the
-- codec refuses metatables) and it is never handed to policy or transport. It is
-- provenance, not a sandbox: any code able to call this module could mint one
-- too, so this is a guard against accidental or misrouted enablement, not a
-- defence against arbitrary trusted local code.
--
-- This module references no game globals, no require/dofile, no io/os/debug and
-- no randomness.

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
	BAD_VERIFIER = "broker_bad_verifier",
	VERIFIER_REJECTED = "broker_verifier_rejected",
	BAD_CAPABILITY = "broker_bad_capability",
	REVOKED = "broker_revoked",
	CANCELED = "broker_canceled",
	NO_PENDING = "broker_no_pending",
}

-- Candidate types the AI may still choose while the runtime is legitimately
-- waiting for its opponent (reported as `meta.wait_action_count`), so the
-- decision loop asks the policy about them instead of silently waiting.
local WAIT_ACTION_TYPES = {
	START_TIMER = true,
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

local CAPABILITY_TAG = "AISparring.ActionBroker.capability"
local CAPABILITY_META = { __metatable = CAPABILITY_TAG }

-- L4/N4: bounded executor port codes the broker passes through unchanged instead
-- of collapsing to `broker_capture_failed`. `exec_pending` is the production
-- executor's "a committed action's visible effect has not appeared yet" latch; the
-- loop must see it to treat the wait as a bounded transient rather than a fatal
-- capture failure. `exec_stall_timeout` and `exec_revoked` are the executor's
-- *terminal* faults: they are passed through so the loop can stop immediately and
-- revoke rather than sit dead for the whole transient window. Only these explicit
-- allowlists are passed through; every other port code still collapses to a fixed
-- broker code.
local PORT_TRANSIENT_CODES = {
	exec_pending = true,
}
local PORT_FATAL_CODES = {
	exec_stall_timeout = true,
	exec_revoked = true,
}

local MODE_DISABLED = 1
local MODE_FIXTURE = 2
local MODE_PRODUCTION = 3

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
	return out, count
end

local function check_observation(observation)
	if type(observation) ~= "table"
		or type(observation.export) ~= "function"
		or type(observation.canonical) ~= "function"
		or type(observation.is_handle) ~= "function" then
		return nil, CODE.BAD_OBSERVATION
	end
	return true
end

local function check_actions(actions)
	if type(actions) ~= "table"
		or type(actions.generate) ~= "function"
		or type(actions.validate) ~= "function" then
		return nil, CODE.BAD_ACTIONS
	end
	return true
end

local function check_ports(ports)
	if type(ports) ~= "table" or type(ports.capture) ~= "function" or type(ports.validate) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	return true
end

local function build_broker(observation, actions, ports, mode, capability_record)
	local fixture = (mode == MODE_FIXTURE)
	local dispatch_enabled = (mode == MODE_FIXTURE) or (mode == MODE_PRODUCTION)
	local production = (mode == MODE_PRODUCTION)

	-- L2: production snapshots the three trusted port functions at authorize
	-- time, so a later swap of the ports table cannot redirect an already
	-- authorized broker. The legacy fixture/disabled path keeps dynamic access
	-- to preserve the M2 boundary semantics (a swapped/metatable ports table is
	-- an internal error, not a silent port substitution).
	local capture_port = rawget(ports, "capture")
	local validate_port = rawget(ports, "validate")
	local dispatch_port = rawget(ports, "dispatch")

	local local_revocation = { revoked = false }
	local pending_token = nil
	local pending_record = nil
	local in_flight = false
	local reentry_flag = false
	local last_epoch = nil
	local instance = {}

	local function revoked_now()
		if local_revocation.revoked then
			return true
		end
		if capability_record ~= nil and capability_record.revoked then
			return true
		end
		return false
	end

	local function clear_pending()
		pending_token = nil
		pending_record = nil
	end

	local function capture()
		local capture_fn
		if production then
			capture_fn = capture_port
		else
			capture_fn = ports.capture
		end
		local ok, handle, epoch = pcall(capture_fn)
		if not ok or handle == nil then
			if not ok then
				return nil, CODE.CAPTURE_FAILED
			end
			if type(epoch) == "string"
				and (PORT_TRANSIENT_CODES[epoch] == true or PORT_FATAL_CODES[epoch] == true) then
				return nil, epoch
			end
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
		local ok, first, second, third = pcall(fn, ...)
		in_flight = false
		if not ok then
			return nil, CODE.INTERNAL
		end
		return first, second, third
	end

	local function issue_impl()
		if revoked_now() then
			return nil, CODE.REVOKED
		end
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
		local count = 0
		local wait_count = 0
		for _, candidate in next, copied_actions do
			count = count + 1
			if type(candidate) == "table" and WAIT_ACTION_TYPES[rawget(candidate, "type")] == true then
				wait_count = wait_count + 1
			end
		end
		local token = setmetatable({}, TOKEN_META)
		pending_token = token
		pending_record = { epoch = epoch, canonical = canonical }
		local meta = { epoch = epoch, candidate_count = count, wait_action_count = wait_count }
		return token, { observation = copied_data, actions = copied_actions }, meta
	end

	local function submit_impl(token, action)
		if revoked_now() then
			return nil, CODE.REVOKED
		end
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

		local ok_trusted, accepted
		if production then
			ok_trusted, accepted = pcall(validate_port, validator_view, handle_start)
		else
			ok_trusted, accepted = pcall(ports.validate, validator_view, handle_start)
		end
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
		if revoked_now() then
			return nil, CODE.REVOKED
		end

		if not dispatch_enabled then
			return nil, CODE.EXECUTOR_DISABLED
		end
		if production then
			local ok_dispatch, explicit = pcall(dispatch_port, validated)
			if not ok_dispatch or explicit ~= true then
				return nil, CODE.DISPATCH_FAILED
			end
		else
			local ok_dispatch = pcall(ports.dispatch, validated)
			if not ok_dispatch then
				return nil, CODE.DISPATCH_FAILED
			end
		end
		-- L1: a dispatch that already committed is reported as committed even if
		-- the dispatch callback reentered the broker. Returning `broker_reentrant`
		-- here would make the loop count a completed action as DISPATCH_FAILED and
		-- could retry an action the engine already applied.
		return true, CODE.OK
	end

	function instance.issue()
		return guarded(issue_impl)
	end

	function instance.submit(token, action)
		return guarded(submit_impl, token, action)
	end

	function instance.cancel()
		local had = pending_token ~= nil
		clear_pending()
		if had then
			return true, CODE.CANCELED
		end
		return false, CODE.NO_PENDING
	end

	function instance.revoke()
		local_revocation.revoked = true
		clear_pending()
		return true, CODE.REVOKED
	end

	function instance._revoke_local()
		clear_pending()
	end

	function instance.is_revoked()
		return revoked_now()
	end

	function instance.has_pending()
		return pending_token ~= nil
	end

	function instance.fixture_only()
		return fixture
	end

	function instance.describe()
		local name = "disabled"
		if production then
			name = "production"
		elseif fixture then
			name = "fixture"
		end
		return {
			mode = name,
			has_pending = pending_token ~= nil,
			revoked = revoked_now(),
			codes = shallow_copy(CODE),
		}
	end

	instance.CODE = shallow_copy(CODE)
	instance.LIMITS = shallow_copy(LIMITS)

	return instance
end

function ActionBroker.factory(observation, actions, ports)
	local ok, code = check_observation(observation)
	if ok ~= true then
		return nil, code
	end
	ok, code = check_actions(actions)
	if ok ~= true then
		return nil, code
	end
	ok, code = check_ports(ports)
	if ok ~= true then
		return nil, code
	end
	local fixture = ports.fixture == "M2_FIXTURE_ONLY"
	if fixture and type(ports.dispatch) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local mode = MODE_DISABLED
	if fixture then
		mode = MODE_FIXTURE
	end
	return build_broker(observation, actions, ports, mode, nil)
end

function ActionBroker.production_factory(verifier)
	if type(verifier) ~= "function" then
		return nil, CODE.BAD_VERIFIER
	end

	local capabilities = {}
	local closed = false
	local instance = {}

	function instance.mint()
		-- L3: once every capability has been revoked the authority is closed and
		-- can never mint a fresh capability.
		if closed then
			return nil, CODE.REVOKED
		end
		local capability = setmetatable({}, CAPABILITY_META)
		capabilities[capability] = { revoked = false, brokers = {} }
		return capability
	end

	function instance.authorize(observation, actions, ports, capability)
		if type(capability) ~= "table" or getmetatable(capability) ~= CAPABILITY_TAG then
			return nil, CODE.BAD_CAPABILITY
		end
		local record = capabilities[capability]
		if record == nil then
			return nil, CODE.BAD_CAPABILITY
		end
		if record.revoked then
			return nil, CODE.REVOKED
		end
		local ok, code = check_observation(observation)
		if ok ~= true then
			return nil, code
		end
		ok, code = check_actions(actions)
		if ok ~= true then
			return nil, code
		end
		ok, code = check_ports(ports)
		if ok ~= true then
			return nil, code
		end
		if rawget(ports, "fixture") ~= nil then
			return nil, CODE.BAD_PORTS
		end
		if type(rawget(ports, "dispatch")) ~= "function" then
			return nil, CODE.BAD_PORTS
		end
		local ok_verify, verdict = pcall(verifier, ports, capability)
		if not ok_verify or verdict ~= true then
			return nil, CODE.VERIFIER_REJECTED
		end
		local broker = build_broker(observation, actions, ports, MODE_PRODUCTION, record)
		record.brokers[#record.brokers + 1] = broker
		return broker
	end

	function instance.revoke(capability)
		if type(capability) ~= "table" or getmetatable(capability) ~= CAPABILITY_TAG then
			return false, CODE.BAD_CAPABILITY
		end
		local record = capabilities[capability]
		if record == nil then
			return false, CODE.BAD_CAPABILITY
		end
		record.revoked = true
		for i = 1, #record.brokers do
			record.brokers[i]._revoke_local()
		end
		return true, CODE.REVOKED
	end

	function instance.revoke_all()
		closed = true
		local count = 0
		for _, record in next, capabilities do
			record.revoked = true
			count = count + 1
			for i = 1, #record.brokers do
				record.brokers[i]._revoke_local()
			end
		end
		return count
	end

	function instance.describe()
		local total = 0
		local revoked = 0
		for _, record in next, capabilities do
			total = total + 1
			if record.revoked then
				revoked = revoked + 1
			end
		end
		return { capabilities = total, revoked = revoked, codes = shallow_copy(CODE) }
	end

	instance.CODE = shallow_copy(CODE)

	return instance
end

return ActionBroker
