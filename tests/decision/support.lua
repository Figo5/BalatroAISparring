-- Shared fixtures for the production broker / decision loop harness.
--
-- Loads the real M2 codec, observation and actions plus the real action broker
-- and decision loop. Only the transport and clock are fake; the broker,
-- observation schema and legal-action generation are the real modules.

local Support = {}

function Support.load(repo)
	local env = {}
	env.codec = dofile(repo .. "/AISparring/ai/codec.lua")
	env.observation = dofile(repo .. "/AISparring/ai/observation.lua")
	env.actions = dofile(repo .. "/AISparring/ai/actions.lua")
	env.broker = dofile(repo .. "/AISparring/integration/action_broker.lua")
	env.loop = dofile(repo .. "/AISparring/integration/decision_loop.lua")
	return env
end

local function match_block()
	return {
		ruleset = "majorleague",
		ante = 1,
		round = 1,
		lives = 1,
		hands_per_round = 4,
		discards_per_round = 3,
		hand_size = 8,
		joker_slots = 5,
		consumable_slots = 2,
	}
end

function Support.play_frame()
	return {
		schema_version = 1,
		phase = "PLAY_HAND",
		match = match_block(),
		self = {
			money = 10,
			credit_limit = 0,
			hands = 3,
			discards = 3,
			current_score = "0",
			blind_requirement = "300",
			hand_visible = true,
			hand = {
				{ kind = "card", rank = "A", suit = "Spades", center = "c_ace", face_down = false },
				{ kind = "card", rank = "K", suit = "Hearts", center = "c_king", face_down = false },
			},
			jokers = {},
			consumables = {},
			vouchers = {},
			tags = {},
			deck = { total = 52 },
		},
		context = {
			blocked = false,
			timer_expired = false,
			max_play = 5,
			max_discard = 5,
		},
		certificates = {
			version = 1,
			items = {
				{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1" } },
				{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:2" } },
			},
		},
	}
end

function Support.blocked_frame()
	local frame = Support.play_frame()
	frame.context.blocked = true
	return frame
end

function Support.empty_cert_frame()
	local frame = Support.play_frame()
	frame.certificates.items = {}
	return frame
end

function Support.shop_frame()
	return {
		schema_version = 1,
		phase = "SHOP",
		match = match_block(),
		self = {
			money = 10,
			credit_limit = 0,
			hands = 3,
			discards = 3,
			current_score = "0",
			blind_requirement = "300",
			hand_visible = false,
			jokers = {},
			consumables = {},
			vouchers = {},
			tags = {},
			deck = { total = 52 },
		},
		shop = { reroll_cost = 5, items = {}, boosters = {}, vouchers = {} },
		context = { blocked = false, timer_expired = false },
		certificates = {
			version = 1,
			items = { { type = "LEAVE_SHOP", certified = true } },
		},
	}
end

function Support.terminal_frame()
	return {
		schema_version = 1,
		phase = "MATCH_COMPLETE",
		match = match_block(),
	}
end

function Support.action(env, content)
	local action = {}
	for key, value in next, content do
		action[key] = value
	end
	action.id = env.codec.encode(action)
	return action
end

function Support.ports(opts)
	opts = opts or {}
	local ports = {
		dispatch_calls = 0,
		last_action = nil,
	}
	ports.capture = function()
		return nil, 0
	end
	ports.validate = function()
		return true
	end
	ports.dispatch = function(action)
		ports.dispatch_calls = ports.dispatch_calls + 1
		ports.last_action = action
		if opts.dispatch_result == false then
			return false
		end
		return true
	end
	if opts.mode ~= nil then
		ports.mode = opts.mode
	end
	if opts.production_flag ~= nil then
		ports.production = opts.production_flag
	end
	if opts.fixture ~= nil then
		ports.fixture = opts.fixture
	end
	return ports
end

function Support.rig(repo, opts)
	opts = opts or {}
	local env = Support.load(repo)
	local obs = env.observation.factory(env.codec)
	local acts = env.actions.factory(obs, env.codec)
	local frame = opts.frame or Support.play_frame()
	local state = { epoch = opts.epoch or 5, handle = nil }

	local function observe_only()
		local handle, code = obs.observe(frame)
		assert(handle ~= nil, tostring(code))
		state.handle = handle
	end

	local function rebuild()
		state.epoch = state.epoch + 1
		observe_only()
	end

	observe_only()

	local ports = {
		dispatch_calls = 0,
		last_action = nil,
	}
	local capture_fail_times = opts.capture_fail_times or 0
	local default_capture = function()
		if opts.capture_throws then
			error("capture_fault")
		end
		if capture_fail_times > 0 then
			capture_fail_times = capture_fail_times - 1
			return nil
		end
		return state.handle, state.epoch
	end
	if type(opts.capture_impl) == "function" then
		-- The override receives the default capture so it can observe or defer
		-- to the real handle/epoch provider.
		ports.capture = opts.capture_impl(default_capture)
	elseif opts.capture_code ~= nil then
		ports.capture = function()
			return nil, opts.capture_code
		end
	else
		ports.capture = default_capture
	end
	ports.validate = function(action, handle)
		if opts.validate_throws then
			error("validate_fault")
		end
		if opts.on_validate then
			opts.on_validate(action, handle)
		end
		if opts.validate_result == false then
			return false
		end
		return true
	end
	ports.dispatch = function(action)
		ports.dispatch_calls = ports.dispatch_calls + 1
		ports.last_action = action
		if opts.on_dispatch then
			opts.on_dispatch(action)
		end
		if opts.dispatch_throws then
			error("dispatch_fault")
		end
		if opts.dispatch_result == false then
			return false
		end
		return true
	end
	if opts.mode ~= nil then
		ports.mode = opts.mode
	end
	if opts.production_flag ~= nil then
		ports.production = opts.production_flag
	end
	if opts.fixture ~= nil then
		ports.fixture = opts.fixture
	end

	local authority, authority_code = env.broker.production_factory(opts.verifier or function()
		return true
	end)
	local capability
	if opts.capability ~= nil then
		capability = opts.capability
	elseif authority ~= nil then
		capability = authority.mint()
	end

	local broker
	local broker_code
	if opts.legacy then
		broker, broker_code = env.broker.factory(obs, acts, ports)
	else
		broker, broker_code = authority.authorize(obs, acts, ports, capability)
	end

	local world = {
		frame = frame,
		state = state,
	}

	function world.bump_epoch()
		state.epoch = state.epoch + 1
	end

	function world.set_money(value)
		frame.self.money = value
		rebuild()
	end

	function world.rebuild()
		rebuild()
	end

	function world.replace_frame(value)
		frame = value
		world.frame = value
		rebuild()
	end

	return {
		env = env,
		obs = obs,
		actions = acts,
		ports = ports,
		authority = authority,
		capability = capability,
		broker = broker,
		broker_code = broker_code,
		authority_code = authority_code,
		world = world,
	}
end

function Support.clock(start)
	local instance = { t = start or 0, ticks = 0 }
	function instance.now()
		return instance.t
	end
	function instance.tick()
		instance.ticks = instance.ticks + 1
		return instance.ticks
	end
	function instance.advance(delta)
		instance.t = instance.t + delta
		return instance.t
	end
	function instance.set(value)
		instance.t = value
	end
	return instance
end

function Support.transport()
	local instance = {
		requests = {},
		outbox = {},
		sent = 0,
		canceled = 0,
		request_fault = false,
		poll_fault = false,
	}
	function instance.request(payload)
		if instance.request_fault then
			error("transport_request_fault")
		end
		instance.sent = instance.sent + 1
		instance.requests[#instance.requests + 1] = payload
		return instance.sent
	end
	function instance.poll()
		if instance.poll_fault then
			error("transport_poll_fault")
		end
		if #instance.outbox > 0 then
			return table.remove(instance.outbox, 1)
		end
		return nil
	end
	function instance.cancel()
		instance.canceled = instance.canceled + 1
	end
	function instance.push(response)
		instance.outbox[#instance.outbox + 1] = response
	end
	return instance
end

function Support.logger()
	local instance = { records = {} }
	function instance.record(fields)
		instance.records[#instance.records + 1] = fields
	end
	return instance
end

function Support.controls(opts)
	opts = opts or {}
	local instance = { name = nil, advanced = 0, advanced_name = nil, captures = 0 }
	function instance.next()
		return instance.name
	end
	function instance.advance(name)
		instance.advanced = instance.advanced + 1
		instance.advanced_name = name
		if opts.sticky ~= true then
			instance.name = nil
		end
		return true
	end
	function instance.clear()
		instance.name = nil
	end
	return instance
end

function Support.loop(rig, opts)
	opts = opts or {}
	local clock = opts.clock or Support.clock()
	local transport = opts.transport or Support.transport()
	local logger = opts.logger or Support.logger()
	local options = {
		broker = rig.broker,
		transport = transport,
		clock = clock,
		logger = logger,
		controls = opts.controls,
		checksum = opts.checksum or function(observation)
			local value = rig.env.codec.hash(observation)
			if type(value) == "string" then
				return value
			end
			return nil
		end,
		pacing = opts.pacing,
		pacing_mode = opts.pacing_mode,
		readiness = opts.readiness,
		dwell = opts.dwell,
		dwell_max = opts.dwell_max,
		overlay_grace = opts.overlay_grace,
		dwell_timer_reserve = opts.dwell_timer_reserve,
		dwell_timer_fraction = opts.dwell_timer_fraction,
		min_interval = opts.min_interval,
		timeout = opts.timeout,
		transient_backoff = opts.transient_backoff,
		max_transient_streak = opts.max_transient_streak,
		max_transient_seconds = opts.max_transient_seconds,
		control_latch_seconds = opts.control_latch_seconds,
		transient_codes = opts.transient_codes,
		get_revision = opts.get_revision,
		wait_state = opts.wait_state,
		wait_max_backoff = opts.wait_max_backoff,
		max_consecutive_errors = opts.max_consecutive_errors,
		terminal_phase = opts.terminal_phase,
		sequence_start = opts.sequence_start,
		on_stop = opts.on_stop,
	}
	local loop, code = rig.env.loop.factory(options)
	local bundle = {
		loop = loop,
		clock = clock,
		transport = transport,
		logger = logger,
		controls = opts.controls,
		code = code,
		rig = rig,
	}
	return bundle
end

function Support.count_nonplain(value)
	if type(value) ~= "table" then
		if type(value) == "function" or type(value) == "userdata" or type(value) == "thread" then
			return 1
		end
		return 0
	end
	if getmetatable(value) ~= nil then
		return 1
	end
	local total = 0
	for _, item in next, value do
		total = total + Support.count_nonplain(item)
	end
	return total
end

function Support.has_key(value, key)
	if type(value) ~= "table" then
		return false
	end
	return rawget(value, key) ~= nil
end

return Support
