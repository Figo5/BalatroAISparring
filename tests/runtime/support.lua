-- Shared fixtures for the staged runtime harness.
--
-- Loads the real control protocol/transport/thread, MP driver and runtime
-- bootstrap sources plus the real M2/engine modules (from tests/engine/support).
-- Only the game environment is fake: an in-memory channel pair, a fake monotonic
-- clock and a synthetic G/MP engine. No game, Mods directory, socket, thread or
-- live runtime is touched.

local Support = {}

local cache = {}

local function load(repo_root, relative)
	local key = repo_root .. "|" .. relative
	if cache[key] == nil then
		cache[key] = dofile(repo_root .. "/" .. relative)
	end
	return cache[key]
end

Support.load = load

function Support.mod(repo_root, relative)
	return load(repo_root, relative)
end

function Support.engine_support(repo_root)
	return load(repo_root, "tests/engine/support.lua")
end

function Support.engine(repo_root, opts)
	return Support.engine_support(repo_root).engine(opts)
end

function Support.bundle(repo_root)
	return Support.engine_support(repo_root).bundle(repo_root)
end

function Support.json(repo_root)
	return load(repo_root, "tests/runtime/json.lua")
end

-- Source-shaped Multiplayer coordination surface for the bootstrap fixtures.
-- Mirrors the pinned modules: a real Major League ruleset registry with the
-- real `force_lobby_options`, the real `lobby_ready_up` toggle (which mutates
-- the real element), `start_lobby` reset/force ordering, the guest
-- `join_lobby`/`lobbyInfo` config application and the real guest ready element
-- `G.MAIN_MENU_UI:get_UIE_by_ID("lobby_menu_start")`. Only the engine is fake.
function Support.shape_mp(engine, opts)
	opts = opts or {}
	local MP = engine.MP
	local G = engine.G
	local funcs = G.FUNCS
	local code = opts.code

	local forced = {
		timer_base_seconds = 180,
		timer_forgiveness = 0,
		the_order = false,
		preview_disabled = true,
		enemy_location_disabled = true,
		timer_display_threshold = 180,
	}
	local ruleset = {
		forced_gamemode = "gamemode_mp_attrition",
		forced_lobby_options = true,
		standard = true,
		multiplayer_content = true,
		pvp_timer_base_seconds = 60,
		pvp_timer_hand_played_increment_seconds = 10,
		_layer_order = { "standard", "ranked", "pvp_timer" },
		is_disabled = function()
			return false
		end,
		force_lobby_options = function()
			for key, value in next, forced do
				MP.LOBBY.config[key] = value
			end
			return true
		end,
	}
	local ruleset_key = opts.ruleset_key or "ruleset_mp_standard_ranked"
	MP.Rulesets = { [ruleset_key] = ruleset }
	-- The real `MP.current_ruleset()` returns a metatable proxy over the active
	-- layer/ruleset view (work/reference/mp/rulesets/_rulesets.lua): an empty
	-- table answering every field through its metatable. Reproduce that exact
	-- shape so a rawget of `force_lobby_options` fails just like in the game.
	MP.current_ruleset = function()
		return setmetatable({}, {
			__index = function(_, key)
				return ruleset[key]
			end,
		})
	end

	-- The reviewed `reset_lobby_config` defaults, so the actual-config Ranked
	-- digest sees every required field with its real type (missing required
	-- fields are a field-type refusal, not typed nil).
	local function base_config()
		local config = MP.LOBBY.config or {}
		config.ruleset = ruleset_key
		config.gamemode = "gamemode_mp_attrition"
		config.gold_on_life_loss = true
		config.no_gold_on_round_loss = false
		config.death_on_round_loss = true
		config.different_seeds = false
		config.the_order = true
		config.starting_lives = 4
		config.pvp_start_round = 2
		config.timer_base_seconds = 150
		config.timer_increment_seconds = 60
		config.pvp_countdown_seconds = 3
		config.showdown_starting_antes = 3
		config.custom_seed = "random"
		config.different_decks = false
		config.random_loadout = false
		config.back = "Red Deck"
		config.sleeve = "sleeve_casl_none"
		config.stake = 1
		config.challenge = ""
		config.cocktail = "1H"
		config.multiplayer_jokers = true
		config.timer = true
		config.timer_forgiveness = 0
		config.forced_config = true
		config.preview_disabled = false
		config.legacy_smallworld = false
		config.hide_score_until_played = true
		config.enemy_location_disabled = false
		config.timer_display_threshold = 0
		config.modifier_layers = ""
		config.disable_live_and_timer_hud = false
		MP.LOBBY.config = config
		return config
	end
	base_config()

	local function ready_element()
		return {
			config = { colour = nil },
			children = { { children = { { config = { text = "" } } } } },
			UIBox = { recalculate = function() end },
		}
	end
	local element = ready_element()
	G.MAIN_MENU_UI = {
		get_UIE_by_ID = function(_, id)
			if id == "lobby_menu_start" then
				return element
			end
			return nil
		end,
	}

	engine.start_lobby_calls = 0
	funcs.start_lobby = function()
		engine.start_lobby_calls = engine.start_lobby_calls + 1
		base_config()
		MP.current_ruleset():force_lobby_options()
		if opts.deferred_code then
			-- The real create is asynchronous: the code arrives later.
			engine.lobby_pending = true
		else
			MP.LOBBY.code = opts.code or "ABC12"
		end
	end
	engine.complete_lobby = function(code)
		engine.lobby_pending = nil
		MP.LOBBY.code = code or opts.code or "ABC12"
	end
	funcs.lobby_ready_up = function(e)
		MP.LOBBY.ready_to_start = not MP.LOBBY.ready_to_start
		if type(e) == "table" then
			e.config.colour = MP.LOBBY.ready_to_start and "green" or "red"
			e.children[1].children[1].config.text = MP.LOBBY.ready_to_start and "unready" or "ready"
			e.UIBox:recalculate()
		end
	end
	funcs.lobby_start_game = function()
		-- The ordinary Multiplayer start advances the engine to the real RUN
		-- stage. There is no `MP.LOBBY.started` in the pinned source.
		G.STAGE = G.STAGES.RUN
	end

	MP.ACTIONS = MP.ACTIONS or {}
	MP.ACTIONS.set_username = function(name)
		MP.LOBBY.username = name
	end
	MP.ACTIONS.join_lobby = function(join_code)
		base_config()
		for key, value in next, forced do
			MP.LOBBY.config[key] = value
		end
		MP.LOBBY.code = join_code
	end
	MP.ACTIONS.leave_lobby = function()
		MP.LOBBY.code = nil
	end
	MP.ACTIONS.stop_game = function()
		G.STAGE = G.STAGES.MAIN_MENU
	end

	MP.LOBBY.code = code
	MP.LOBBY.ready_to_start = false
	MP.LOBBY.connected = opts.connected ~= false
	MP.LOBBY.username = "Guest"
	-- The real match-started observable is the ordinary RUN stage reached while
	-- the lobby is joined. The fixture never invents `MP.is_started` or
	-- `MP.LOBBY.started`; it drives the real stage and state enums instead.
	local run = opts.started ~= false and code ~= nil
	G.STAGES = G.STAGES or { MAIN_MENU = 1, RUN = 2 }
	if run then
		G.STAGE = G.STAGES.RUN
	else
		G.STAGE = G.STAGES.MAIN_MENU
		G.STATE = G.STATES.MENU
	end
	engine.set_run = function()
		G.STAGE = G.STAGES.RUN
	end
	engine.set_main_menu = function()
		G.STAGE = G.STAGES.MAIN_MENU
		G.STATE = G.STATES.MENU
	end
	engine.set_match_code = function(value)
		MP.LOBBY.code = value
	end
	-- The already-resolved run seed of an initialized run (source:
	-- G.GAME.pseudorandom.seed). Never exported to policy.
	G.GAME.pseudorandom = { seed = opts.run_seed or "RUNSEED42" }

	engine.ready_element = element
	return engine
end

function Support.protocol(repo_root)
	return load(repo_root, "AISparring/integration/control_protocol.lua")
end

-- In-memory channel with the same push/pop surface as a LÖVE thread Channel.
function Support.channel()
	-- Source-faithful FIFO: an explicit tail counter keeps the queue gap-free
	-- after a pop. Using `#queue` after clearing a head slot would truncate the
	-- array and silently drop every later message.
	local queue = {}
	local head = 1
	local tail = 0
	local channel = {}
	function channel:push(message)
		tail = tail + 1
		queue[tail] = message
	end
	function channel:pop()
		if head > tail then
			return nil
		end
		local value = queue[head]
		queue[head] = nil
		head = head + 1
		if head > tail then
			queue = {}
			head = 1
			tail = 0
		end
		return value
	end
	function channel:size()
		return tail - head + 1
	end
	function channel:clear()
		queue = {}
		head = 1
		tail = 0
	end
	return channel
end

function Support.clock(start)
	local state = { time = start or 1000 }
	local clock = {}
	function clock.now()
		return state.time
	end
	function clock.advance(delta)
		state.time = state.time + delta
		return state.time
	end
	return clock, state
end

-- Build a control transport over fake channels. Returns transport, code, ctx.
function Support.transport(repo_root, overrides)
	overrides = overrides or {}
	local protocol = Support.protocol(repo_root)
	local ControlTransport = load(repo_root, "AISparring/integration/control_transport.lua")
	local json = Support.json(repo_root)
	local channels = overrides.channels or {
		to_worker = Support.channel(),
		from_worker = Support.channel(),
	}
	local clock = overrides.clock or Support.clock()
	local options = {
		role = overrides.role or "ai",
		session = overrides.session or "session-1",
		credential = overrides.credential or "credential-1",
		protocol = protocol,
		channels = channels,
		clock = clock,
		encode = json.encode,
		decode = json.decode,
		decision_base = overrides.decision_base or 1000000,
		poll_interval = overrides.poll_interval == nil and 0.25 or overrides.poll_interval,
		request_timeout = overrides.request_timeout or 10,
		max_send = overrides.max_send,
		max_receive = overrides.max_receive,
		logger = overrides.logger,
	}
	local transport, code = ControlTransport.factory(options)
	return transport, code, { channels = channels, clock = clock, protocol = protocol, json = json }
end

-- Interpret outbound request envelopes pushed by the transport.
function Support.drain_outbound(ctx)
	local messages = {}
	while true do
		local message = ctx.channels.to_worker:pop()
		if message == nil then
			return messages
		end
		messages[#messages + 1] = ctx.json.decode(message)
	end
end

-- Simulate a service response arriving on the worker channel.
function Support.inbound(ctx, response)
	ctx.channels.from_worker:push(ctx.json.encode(response))
end

-- Build a runtime bootstrap wired to the real modules and a synthetic engine.
function Support.bootstrap(repo_root, overrides)
	overrides = overrides or {}
	local RuntimeBootstrap = load(repo_root, "AISparring/integration/runtime_bootstrap.lua")
	local ControlTransport = load(repo_root, "AISparring/integration/control_transport.lua")
	local ControlThread = load(repo_root, "AISparring/integration/control_thread.lua")
	local protocol = Support.protocol(repo_root)
	local json = Support.json(repo_root)
	local MPDriver = load(repo_root, "AISparring/integration/mp_driver.lua")
	local StateReader = load(repo_root, "AISparring/integration/state_reader.lua")
	local EngineAdapter = load(repo_root, "AISparring/integration/engine_adapter.lua")
	local ProductionExecutor = load(repo_root, "AISparring/integration/production_executor.lua")
	local StateRevision = load(repo_root, "AISparring/integration/state_revision.lua")
	local ActionBroker = load(repo_root, "AISparring/integration/action_broker.lua")
	local DecisionLoop = load(repo_root, "AISparring/integration/decision_loop.lua")
	local codec = load(repo_root, "AISparring/ai/codec.lua")
	local observation = load(repo_root, "AISparring/ai/observation.lua")
	local actions = load(repo_root, "AISparring/ai/actions.lua")
	local ranked_config = load(repo_root, "AISparring/integration/ranked_config.lua")

	local role = overrides.role or "ai"
	local session = overrides.session or "session-1"
	local credential = overrides.credential or "credential-1"
	local nonce = overrides.nonce or "nonce1"
	local content_hash = overrides.content_hash or "content-1"
	local control_port = overrides.control_port or 49321

	local save_dir = overrides.save_dir or "/stage/AppData/Balatro"
	local mods_root = overrides.mods_root or "/stage/Mods"
	local mod_root = overrides.mod_root or "/stage/Mods/AISparring"

	local env = overrides.env or {
		save_dir = function() return save_dir end,
		mods_root = function() return mods_root end,
		mod_root = function() return mod_root end,
	}
	local launcher = overrides.launcher or {
		verify = function()
			return {
				ok = true,
				nonce = nonce,
				session = session,
				role = role,
				content_hash = content_hash,
				control_port = control_port,
			}
		end,
	}
	-- When neither an explicit channel pair nor a `get_channel` lookup is
	-- injected, fall back to the in-memory fixture pair. Injecting `get_channel`
	-- exercises the bootstrap's default `love.thread.getChannel` route.
	local channels = overrides.channels
	if channels == nil and overrides.get_channel == nil then
		channels = {
			to_worker = Support.channel(),
			from_worker = Support.channel(),
		}
	end
	local clock = overrides.clock or Support.clock()
	local engine = overrides.engine or Support.engine(repo_root, {
		state = Support.engine_support(repo_root).STATES.BLIND_SELECT,
		blind_select = { config = {} },
		blind_on_deck = "Small",
		blind_states = { Small = "Select", Big = "Select", Boss = "Upcoming" },
		lives = overrides.lives,
		enemy_lives = overrides.enemy_lives,
	})
	if not overrides.engine then
		Support.shape_mp(engine, {
			connected = overrides.connected,
			code = overrides.lobby_code,
			started = overrides.started,
			run_seed = overrides.run_seed,
			deferred_code = overrides.deferred_code,
			ruleset_key = overrides.ruleset_key,
			ruleset_short = overrides.ruleset_short,
		})
	end

	local modules = overrides.modules or {
		codec = codec,
		observation = observation,
		actions = actions,
		StateReader = StateReader,
		EngineAdapter = EngineAdapter,
		ProductionExecutor = ProductionExecutor,
		StateRevision = StateRevision,
		ActionBroker = ActionBroker,
		DecisionLoop = DecisionLoop,
		MPDriver = MPDriver,
		ranked_config = ranked_config,
	}

	-- The send guard wraps the real game Client.send and is required for BOTH
	-- staged roles before any create/join. Provide a synthetic client unless the
	-- test explicitly injects or disables one.
	local client = overrides.client
	if client == nil and not overrides.no_client then
		client = {
			send = function()
				return true
			end,
		}
	end

	local options = {
		role = role,
		session = session,
		credential = credential,
		nonce = nonce,
		content_hash = content_hash,
		control_port = control_port,
		expected = {
			save_dir = save_dir,
			mods_root = mods_root,
			mod_root = mod_root,
		},
		env = env,
		launcher = launcher,
		control_protocol = protocol,
		control_transport_factory = ControlTransport.factory,
		control_thread = ControlThread,
		channels = channels,
		get_channel = overrides.get_channel,
		clock = clock,
		modules = modules,
		G = engine.G,
		MP = engine.MP,
		funcs = engine.G.FUNCS,
		-- Only an explicit override is injected; otherwise the driver uses the
		-- real `G.MAIN_MENU_UI:get_UIE_by_ID("lobby_menu_start")` lookup.
		element_for = overrides.element_for,
		encode = overrides.encode or json.encode,
		decode = overrides.decode or json.decode,
		spawn_thread = overrides.spawn_thread or function()
			return true
		end,
		seed = overrides.seed,
		mode = overrides.mode,
		difficulty = overrides.difficulty,
		pacing = overrides.pacing,
		-- H2: only an explicit override wires the thinking dwell, so every
		-- existing fixture keeps the legacy immediate path; dwell tests pass a
		-- table here.
		dwell = overrides.dwell,
		auto_coordinate = overrides.auto_coordinate,
		client = client,
		logger = overrides.logger,
		ui_notify = overrides.ui_notify,
		terminal_probe = overrides.terminal_probe,
		config_digest = overrides.config_digest,
		hook_targets = overrides.hook_targets,
		ruleset_key = overrides.ruleset_key,
		ruleset_short = overrides.ruleset_short,
		-- Readiness producers/ports: a fixture override for the record, plus the
		-- real release-mode and approved-inventory producers when supplied.
		readiness_override = overrides.readiness_override,
		release_mode = overrides.release_mode,
		approved_mods = overrides.approved_mods,
	}

	local instance, code = RuntimeBootstrap.factory(options)
	return instance, code, {
		channels = channels,
		clock = clock,
		protocol = protocol,
		json = json,
		engine = engine,
		modules = modules,
		save_dir = save_dir,
		mods_root = mods_root,
		mod_root = mod_root,
	}
end

return Support
