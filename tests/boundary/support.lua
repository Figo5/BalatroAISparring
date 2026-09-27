local Support = {}

function Support.load(repo)
	local env = {}
	env.codec = dofile(repo .. "/AISparring/ai/codec.lua")
	env.observation = dofile(repo .. "/AISparring/ai/observation.lua")
	env.actions = dofile(repo .. "/AISparring/ai/actions.lua")
	env.broker = dofile(repo .. "/AISparring/integration/action_broker.lua")
	return env
end

function Support.play_frame()
	return {
		schema_version = 1,
		phase = "PLAY_HAND",
		match = {
			ruleset = "majorleague",
			ante = 1,
			round = 1,
			lives = 1,
			hands_per_round = 4,
			discards_per_round = 3,
			hand_size = 8,
			joker_slots = 5,
			consumable_slots = 2,
		},
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
			},
		},
	}
end

function Support.consumable_frame()
	return {
		schema_version = 1,
		phase = "CONSUMABLE_SELECTION",
		match = Support.play_frame().match,
		self = {
			money = 10,
			credit_limit = 0,
			hands = 3,
			discards = 3,
			current_score = "0",
			blind_requirement = "300",
			hand_visible = false,
			jokers = {},
			consumables = { { center = "c_hermit", face_down = false } },
			vouchers = {},
			tags = {},
			deck = { total = 52 },
		},
		context = {
			blocked = false,
			timer_expired = false,
			target_selection = true,
			min_targets = 0,
			max_targets = 2,
		},
		consumable_target = {
			source = { center = "c_hermit", face_down = false },
			source_ref = "consumable:1",
			min_targets = 0,
			max_targets = 2,
			targets = {
				{ kind = "card", rank = "A", suit = "Spades", center = "c_ace", face_down = false },
			},
		},
		certificates = {
			version = 1,
			items = {
				{ type = "USE_CONSUMABLE", certified = true, source_ref = "consumable:1", target_refs = {} },
			},
		},
	}
end

function Support.deep_copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in next, value do
		out[key] = Support.deep_copy(item)
	end
	return out
end

function Support.count_functions(value)
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
		total = total + Support.count_functions(item)
	end
	return total
end

function Support.rig(repo, opts)
	opts = opts or {}
	local env = Support.load(repo)
	local obs = env.observation.factory(env.codec)
	assert(type(obs) == "table", "observation_factory")
	local acts = env.actions.factory(obs, env.codec)
	assert(type(acts) == "table", "actions_factory")
	local frame = opts.frame or Support.play_frame()
	local state = { epoch = opts.epoch or 7, handle = nil, builds = 0 }

	local function observe_only()
		local handle, code = obs.observe(frame)
		assert(handle ~= nil, tostring(code))
		state.handle = handle
		state.builds = state.builds + 1
	end

	local function rebuild()
		state.epoch = state.epoch + 1
		observe_only()
	end

	observe_only()

	local world = { obs = obs, frame = frame, state = state }
	function world.capture()
		state.builds = state.builds + 1
		return state.handle, state.epoch
	end
	function world.set_epoch(value)
		state.epoch = value
	end
	function world.bump_epoch()
		state.epoch = state.epoch + 1
	end
	function world.set_money(value)
		frame.self.money = value
		rebuild()
	end
	function world.set_phase(value)
		frame.phase = value
		rebuild()
	end
	function world.rebuild()
		rebuild()
	end
	function world.rebuild_constant_revision()
		observe_only()
	end

	local fixture_value = opts.fixture_raw
	if fixture_value == nil and opts.fixture == true then
		fixture_value = "M2_FIXTURE_ONLY"
	end

	local ports = {
		fixture = fixture_value,
		validate_result = opts.validate_result,
		dispatch_calls = 0,
		last_action = nil,
	}
	local capture_fail_times = opts.capture_fail_times or 0
	ports.capture = function()
		if opts.capture_throws then
			error("capture_failure")
		end
		if capture_fail_times > 0 then
			capture_fail_times = capture_fail_times - 1
			error("capture_failure")
		end
		return world.capture()
	end
	ports.validate = function(normalized, handle)
		if opts.validate_throws then
			error("validate_failure")
		end
		if opts.on_validate then
			opts.on_validate(normalized, handle, ports)
		end
		if ports.validate_result == false then
			return false
		end
		return true
	end
	ports.dispatch = function(action)
		ports.dispatch_calls = ports.dispatch_calls + 1
		ports.last_action = action
		if opts.dispatch_throws then
			error("dispatch_failure")
		end
		return true
	end

	local broker = env.broker.factory(obs, acts, ports)
	assert(type(broker) == "table", "broker_factory")

	return {
		env = env,
		obs = obs,
		acts = acts,
		world = world,
		ports = ports,
		broker = broker,
		frame = frame,
		state = state,
	}
end

function Support.arm_capture_escape(rig)
	rig.ports.stashed_capture = rig.ports.capture
	rig.ports.capture = nil
	setmetatable(rig.ports, {
		__index = function(_, key)
			if key == "capture" then
				error("escape_fault")
			end
			return nil
		end,
	})
end

function Support.disarm_capture_escape(rig)
	setmetatable(rig.ports, nil)
	rig.ports.capture = rig.ports.stashed_capture
	rig.ports.stashed_capture = nil
end

return Support
