-- Shared fixtures for the companion-host harness.
--
-- Loads the real AISparring/integration/companion_host.lua, the reviewed menu
-- modules and (for the staged cases) the real runtime modules over synthetic
-- game globals. No game, Mods directory, process, socket, thread, network, save
-- or live runtime is touched; every privileged port is an injected fake.

local Support = {}

Support.NULL = setmetatable({}, { __tostring = function() return "json.null" end })

local cache = {}

local function load(repo_root, relative)
	local key = repo_root .. "|" .. relative
	if cache[key] == nil then
		local chunk, err = loadfile(repo_root .. "/" .. relative)
		if chunk == nil then
			error("cannot load " .. relative .. ": " .. tostring(err), 2)
		end
		cache[key] = chunk()
	end
	return cache[key]
end

Support.load = load

function Support.host(repo_root)
	return load(repo_root, "AISparring/integration/companion_host.lua")
end

function Support.menu(repo_root)
	return {
		PracticeMenu = load(repo_root, "AISparring/ui/practice_menu.lua"),
		MenuController = load(repo_root, "AISparring/integration/menu_controller.lua"),
	}
end

function Support.json(repo_root)
	return load(repo_root, "tests/runtime/json.lua")
end

function Support.runtime(repo_root)
	return load(repo_root, "tests/runtime/support.lua")
end

-- Minimal but honest fake UI tree with the exact port surface the reviewed menu
-- modules require.
function Support.fake_ui()
	local ustate = { overlays = {}, exits = 0, buttons = 0, notifications = {} }
	local UIT = { T = "t", R = "r", C = "c", S = "s" }
	local C = { UI = { TEXT_LIGHT = "text_light" }, GREEN = "green", BLUE = "blue", RED = "red", ORANGE = "orange", PURPLE = "purple", GOLD = "gold" }
	local function button(cfg)
		ustate.buttons = ustate.buttons + 1
		return { n = "button", config = cfg }
	end
	local function options(cfg)
		return { n = "options", config = cfg, nodes = cfg.contents }
	end
	local funcs = {}
	local G = { UIT = UIT, C = C, UIDEF = {}, FUNCS = funcs, STAGES = { MAIN_MENU = 1, RUN = 2 }, STAGE = 1 }
	funcs.overlay_menu = function(definition)
		ustate.overlays[#ustate.overlays + 1] = definition
	end
	funcs.exit_overlay_menu = function()
		ustate.exits = ustate.exits + 1
	end
	-- Mirrors the real generic-options node nesting the menu controller walks:
	-- root -> outer -> column -> contents row. The AI Sparring button is appended
	-- to the contents row without touching any original node.
	G.UIDEF.override_main_menu_play_button = function()
		return {
			n = "root",
			config = {},
			nodes = {
				{
					n = "outer",
					config = {},
					nodes = {
						{
							n = "column",
							config = {},
							nodes = {
								{
									n = "row",
									config = {},
									nodes = {
										button({ id = "base_singleplayer", button = "start_vanilla_sp", label = { "Single Player" } }),
										button({ id = "base_create_lobby", button = "create_lobby", label = { "Create Lobby" } }),
									},
								},
							},
						},
					},
				},
			},
		}
	end
	local ui = {
		G = G,
		funcs = funcs,
		UIBox_button = button,
		create_UIBox_generic_options = options,
		overlay_menu = funcs.overlay_menu,
		exit_overlay_menu = funcs.exit_overlay_menu,
		notify = function(level, message)
			ustate.notifications[#ustate.notifications + 1] = { level = level, message = message }
		end,
	}
	return ui, ustate
end

function Support.marker(overrides)
	local marker = {
		schema = "aisparring.practice_host.discovery.v1",
		version = "practice_host/1",
		daemon_id = "host-1",
		session = "host-session-1",
		pid = 4242,
		create_time = 100000.0,
		module_sha256 = "abcdef",
		host = "127.0.0.1",
		port = 8788,
		secret = string.rep("a", 64),
		started_unix = 100000.0,
		ops = { "available", "start", "poll", "status" },
		enums = {
			difficulty = { "rookie", "competitive", "major_league" },
			pacing = { "instant", "normal" },
			mode = { "normal", "gauntlet" },
			gauntlet = { "Test1", "Test2", "Test3", "Test4", "Test5" },
		},
	}
	for key, value in pairs(overrides or {}) do
		marker[key] = value
	end
	return marker
end

function Support.identity(opts)
	opts = opts or {}
	local pid = opts.pid or 4242
	local created = opts.create_time or 100000.0
	local current_pid = opts.current_pid or 777
	local current_created = opts.current_create_time or 200000.0
	local identity = {}
	function identity.process(value)
		if value == pid then
			return { pid = value, create_time = created }
		end
		return nil
	end
	function identity.current()
		return { pid = current_pid, create_time = current_created }
	end
	return identity
end

-- A controllable stand-in for the LuaJIT `ffi` module and a loaded C library.
-- The production adapter is exercised against table-shaped symbols exactly as it
-- would index a real userdata library, while every scenario (missing symbol,
-- failed load, failed query, absent handle) can be driven from a test. Nothing
-- here touches the OS.
--
-- opts: ticks (FILETIME 100 ns ticks reported as creation time; default
-- 50000000), result (GetProcessTimes return value; default 1), raise_query
-- (make GetProcessTimes throw), handle_factory(pid) / handle = false / handle,
-- current_pid (default 777), missing = symbol name to omit, load_error, libnil.
function Support.fake_ffi(opts)
	opts = opts or {}
	local state = {
		cdefs = 0,
		opens = {},
		closes = {},
		symbol_lookups = {},
	}
	local ticks = opts.ticks or 50000000
	local low = ticks % 4294967296
	local high = math.floor(ticks / 4294967296)
	local function filetime()
		return { dwLowDateTime = 0, dwHighDateTime = 0 }
	end
	local ffi = {}
	function ffi.cdef()
		state.cdefs = state.cdefs + 1
	end
	function ffi.new()
		return { [0] = filetime() }
	end
	function ffi.load(name)
		state.library = name
		if opts.load_error then
			error("load failed")
		end
		if opts.libnil then
			return nil
		end
		if opts.library ~= nil then
			return opts.library
		end
		local library = {}
		local function add(symbol, fn)
			if opts.missing ~= symbol then
				library[symbol] = fn
			end
		end
		add("OpenProcess", function(access, inherit, pid)
			state.opens[#state.opens + 1] = { access = access, inherit = inherit, pid = pid }
			if type(opts.handle_factory) == "function" then
				return opts.handle_factory(pid)
			end
			if opts.handle == false then
				return nil
			end
			return opts.handle or { process = pid }
		end)
		add("GetProcessTimes", function(handle, creation)
			state.query_handle = handle
			if opts.raise_query then
				error("query failed")
			end
			creation[0].dwLowDateTime = low
			creation[0].dwHighDateTime = high
			return opts.result or 1
		end)
		add("CloseHandle", function(handle)
			state.closes[#state.closes + 1] = handle
			return 1
		end)
		add("GetCurrentProcessId", function()
			return opts.current_pid or 777
		end)
		return library
	end
	return ffi, state
end

function Support.transport()
	local transport = { sent = {}, responses = {}, error_code = nil }
	function transport.send(text)
		transport.sent[#transport.sent + 1] = text
		return true
	end
	function transport.push(response)
		transport.responses[#transport.responses + 1] = response
	end
	function transport.poll()
		if #transport.responses == 0 then
			return nil
		end
		local response = transport.responses[1]
		table.remove(transport.responses, 1)
		return response
	end
	function transport.last_error()
		return transport.error_code
	end
	function transport.connected()
		return true
	end
	function transport.close()
		transport.closed = true
		return true
	end
	return transport
end

function Support.encoder(store)
	return function(envelope)
		store[#store + 1] = envelope
		return "ENCODED"
	end
end

-- A controllable stand-in for the injected love.window API. Records every call so
-- tests can assert titles, the exact-once AI minimize and that nothing happens
-- before attestation. `fail_title` / `fail_minimize` make the corresponding
-- method throw a bounded failure; `missing_title` / `missing_minimize` omit it.
function Support.window(opts)
	opts = opts or {}
	local state = { titles = {}, minimizes = 0, calls = {} }
	local window = {}
	if not opts.missing_title then
		window.setTitle = function(title)
			state.titles[#state.titles + 1] = title
			state.calls[#state.calls + 1] = { op = "setTitle", value = title }
			if opts.fail_title then
				error("setTitle failed")
			end
			return true
		end
	end
	if not opts.missing_minimize then
		window.minimize = function()
			state.minimizes = state.minimizes + 1
			state.calls[#state.calls + 1] = { op = "minimize" }
			if opts.fail_minimize then
				error("minimize failed")
			end
			return true
		end
	end
	return window, state
end

function Support.env_reader(values)
	return function(name)
		return values[name]
	end
end

function Support.descriptors(overrides)
	local descriptors = {
		role = "ai",
		session = "session-1",
		credential = "credential-1",
		nonce = "nonce1",
		content_hash = "content1",
		control_port = 49321,
		save_root = "/stage/AppData/Balatro",
		mods_root = "/stage/Mods",
		mode = "normal",
		difficulty = "competitive",
		pacing = "normal",
		gauntlet = "",
	}
	for key, value in pairs(overrides or {}) do
		descriptors[key] = value
	end
	-- The companion derives the module root from the expected Mods root.
	descriptors.mod_root = descriptors.mods_root .. "/AISparring"
	return descriptors
end

-- The exact canonical launcher session-descriptor environment names (see
-- docs/PLAYABLE_WIRING_CONTRACT.md); no speculative aliases.
function Support.env_values(overrides)
	overrides = overrides or {}
	local descriptors = Support.descriptors(overrides)
	local values = {
		BALATRO_AI_ROLE = descriptors.role,
		AISP_SESSION_ID = descriptors.session,
		AISP_ROLE_CREDENTIAL = descriptors.credential,
		AISP_PROBE_NONCE = descriptors.nonce,
		AISP_CONTENT_HASH = descriptors.content_hash,
		AISP_CONTROL_PORT = tostring(descriptors.control_port),
		AISP_EXPECTED_ROLE_SAVE_ROOT = descriptors.save_root,
		AISP_EXPECTED_ROLE_MODS_ROOT = descriptors.mods_root,
		AISP_MODE = descriptors.mode,
		AISP_DIFFICULTY = descriptors.difficulty,
		AISP_PACING = descriptors.pacing,
		AISP_GAUNTLET = descriptors.gauntlet,
	}
	return values, descriptors
end

function Support.paths(save_root, mods_root)
	return {
		save_dir = function()
			return save_root
		end,
		mods_root = function()
			return mods_root
		end,
		mod_root = function()
			return mods_root .. "/AISparring"
		end,
	}
end

-- Build a launcher verdict port that matches the descriptors, or an override.
function Support.attestation(descriptors, overrides)
	overrides = overrides or {}
	return function(d)
		return {
			schema = "aisparring.launcher_attestation.v1",
			ok = overrides.ok ~= false,
			nonce = overrides.nonce or d.nonce,
			session = overrides.session or d.session,
			role = overrides.role or d.role,
			content_hash = overrides.content_hash or d.content_hash,
			control_port = overrides.control_port or d.control_port,
			expected_role_save_root = overrides.save_root or d.save_root,
			expected_role_mods_root = overrides.mods_root or d.mods_root,
		}
	end
end

-- A file-backed attestation resolver: returns nothing until armed with a blob.
-- Returns the reader function plus its mutable state (Lua functions cannot hold
-- fields).
function Support.attestation_reader()
	local state = { blob = nil, calls = 0 }
	local reader = function()
		state.calls = state.calls + 1
		return state.blob
	end
	return reader, state
end

function Support.attestation_blob(descriptors, overrides)
	overrides = overrides or {}
	return {
		schema = "aisparring.launcher_attestation.v1",
		ok = overrides.ok ~= false,
		session = overrides.session or descriptors.session,
		role = overrides.role or descriptors.role,
		nonce = overrides.nonce or descriptors.nonce,
		content_hash = overrides.content_hash or descriptors.content_hash,
		control_port = overrides.control_port or descriptors.control_port,
		match_port = overrides.match_port,
		expected_role_save_root = overrides.save_root or descriptors.save_root,
		expected_role_mods_root = overrides.mods_root or descriptors.mods_root,
		probe_sha256 = {},
		written_unix = 0,
	}
end

-- Build the real staged module set required by RuntimeBootstrap for a role.
-- Every module the runtime validates is loaded from its real file; the bundle
-- helper does not include the broker/loop.
function Support.staged_modules(repo_root, role)
	local runtime = Support.runtime(repo_root)
	-- The pure codec is a COMMON staged module for both roles: the runtime driver
	-- needs Codec.hash_string for the source-derived digest even on the human
	-- host. The policy/executor set stays AI-only.
	local modules = {
		MPDriver = load(repo_root, "AISparring/integration/mp_driver.lua"),
		codec = load(repo_root, "AISparring/ai/codec.lua"),
	}
	if role == "ai" then
		modules.StateReader = load(repo_root, "AISparring/integration/state_reader.lua")
		modules.EngineAdapter = load(repo_root, "AISparring/integration/engine_adapter.lua")
		modules.ProductionExecutor = load(repo_root, "AISparring/integration/production_executor.lua")
		modules.StateRevision = load(repo_root, "AISparring/integration/state_revision.lua")
		modules.ActionBroker = load(repo_root, "AISparring/integration/action_broker.lua")
		modules.DecisionLoop = load(repo_root, "AISparring/integration/decision_loop.lua")
		modules.observation = load(repo_root, "AISparring/ai/observation.lua")
		modules.actions = load(repo_root, "AISparring/ai/actions.lua")
	end
	return modules, runtime
end

function Support.staged_ports(repo_root, opts)
	opts = opts or {}
	local runtime = Support.runtime(repo_root)
	local descriptors = Support.descriptors(opts.descriptors)
	local engine = opts.engine or runtime.engine(repo_root, {
		state = runtime.engine_support(repo_root).STATES.BLIND_SELECT,
		blind_select = { config = {} },
		blind_on_deck = "Small",
		blind_states = { Small = "Select", Big = "Select", Boss = "Upcoming" },
	})
	local modules = opts.modules
	if modules == nil then
		modules = Support.staged_modules(repo_root, descriptors.role)
	end
	local channels = { to_worker = runtime.channel(), from_worker = runtime.channel() }
	local json = runtime.json(repo_root)
	local window, window_state = opts.window, opts.window_state
	if window == nil then
		window, window_state = Support.window()
	end
	-- A staged AI boot aborts without the real Client send guard, so supply a
	-- synthetic client for the AI role (mirrors tests/runtime/support.lua).
	local client = opts.client
	if client == nil and descriptors.role == "ai" then
		client = { send = function() end }
	end
	local attestation
	if opts.attestation ~= nil then
		attestation = opts.attestation
	elseif opts.attestation_reader ~= nil then
		attestation = nil
	else
		attestation = Support.attestation(descriptors)
	end
	local ports = {
		role = opts.role or "staged",
		runtime_bootstrap = load(repo_root, "AISparring/integration/runtime_bootstrap.lua"),
		control_protocol = runtime.protocol(repo_root),
		control_transport_factory = load(repo_root, "AISparring/integration/control_transport.lua").factory,
		control_thread = load(repo_root, "AISparring/integration/control_thread.lua"),
		channels = channels,
		spawn_thread = function()
			return true
		end,
		clock = opts.clock or runtime.clock(),
		encode = json.encode,
		decode = json.decode,
		descriptors = descriptors,
		paths = Support.paths(descriptors.save_root, descriptors.mods_root),
		launcher_attestation = attestation,
		attestation_reader = opts.attestation_reader,
		attestation_path = opts.attestation_path,
		modules = modules,
		G = engine.G,
		MP = engine.MP,
		funcs = engine.G.FUNCS,
		client = client,
		element_for = opts.element_for,
		hook_targets = opts.hook_targets,
		terminal_probe = opts.terminal_probe,
		env_reader = opts.env_reader,
		window = window,
	}
	return ports, { channels = channels, engine = engine, descriptors = descriptors, json = json, runtime = runtime, window = window, window_state = window_state }
end

-- Full core.lua fixture: real entrypoint + real modules over synthetic globals.
function Support.core_env(repo_root, opts)
	opts = opts or {}
	local record = { loads = {}, logs = {}, quits = 0, updates = 0, publish_writes = 0 }
	record.window = { titles = {}, minimizes = 0, calls = {} }
	local env = setmetatable({}, { __index = _G })
	env._G = env

	local mp = nil
	if opts.mp_present ~= false then
		mp = {
			id = "Multiplayer",
			version = opts.mp_version or "0.5.5",
			can_load = opts.mp_can_load ~= false,
			disabled = false,
			GAME = {},
			ACTIONS = { connect = function() end },
			MOD_ACTIONS = {},
			register_mod_action = function() end,
			current_ruleset = function()
				return {}
			end,
			LOBBY = { connected = opts.mp_connected == true, code = opts.mp_lobby_code },
			lovely = true,
		}
	end

	local own = {
		id = "AISparring",
		version = "0.1.0-dev",
		can_load = true,
		disabled = false,
		config = { ai_enabled = opts.ai_enabled == true, companion = opts.companion },
	}

	local smods = { Mods = {}, current_mod = own }
	smods.MODS_DIR = opts.mods_root or "/stage/Mods"
	own.path = opts.mod_root or "/stage/Mods/AISparring"
	smods.Mods["AISparring"] = own
	if mp ~= nil then
		smods.Mods["Multiplayer"] = mp
	end
	env.SMODS = smods
	env.MP = mp
	smods.load_file = function(path, id)
		record.loads[#record.loads + 1] = path
		local chunk, err = loadfile(repo_root .. "/AISparring/" .. path)
		if chunk == nil then
			return nil, tostring(err)
		end
		setfenv(chunk, env)
		-- An optional fixture intercept observes the real module value the
		-- entrypoint receives (it never changes the pristine game globals).
		local intercept = opts.intercept
		if type(intercept) == "function" then
			return function(...)
				local value = chunk(...)
				return intercept(path, value)
			end
		end
		return chunk
	end

	local ui = Support.fake_ui()
	env.G = ui.G
	env.UIBox_button = ui.UIBox_button
	env.create_UIBox_generic_options = ui.create_UIBox_generic_options
	env.JSON = Support.json(repo_root)

	local thread_channels = {}
	local function channel_for(name)
		if thread_channels[name] == nil then
			local queue = {}
			local head = 1
			thread_channels[name] = {
				push = function(self, message)
					queue[#queue + 1] = message
				end,
				pop = function(self)
					if head > #queue then
						return nil
					end
					local value = queue[head]
					queue[head] = nil
					head = head + 1
					return value
				end,
				size = function(self)
					return #queue - head + 1
				end,
			}
		end
		return thread_channels[name]
	end

	env.love = {
		timer = { getTime = function() return 1000 end },
		event = { quit = function() record.quits = record.quits + 1; return true end },
		filesystem = {
			getSaveDirectory = function()
				return opts.save_dir or "/stage/AppData/Balatro"
			end,
		},
		window = {
			setTitle = function(title)
				record.window.titles[#record.window.titles + 1] = title
				record.window.calls[#record.window.calls + 1] = { op = "setTitle", value = title }
				return true
			end,
			minimize = function()
				record.window.minimizes = record.window.minimizes + 1
				record.window.calls[#record.window.calls + 1] = { op = "minimize" }
				return true
			end,
		},
		thread = {
			newThread = function()
				return { start = function() end }
			end,
			getChannel = function(name)
				return channel_for(name)
			end,
		},
	}
	local original_update = function()
		record.updates = record.updates + 1
		return "orig"
	end
	env.Game = { update = original_update }
	env.Client = opts.client or { send = function() end }
	-- Real engine classes the AI hook targets are derived from (absent in the
	-- synthetic fixture, so the root passes no hooks).
	env.CardArea = opts.card_area
	env.Card = opts.card
	env.ffi = opts.ffi

	local files = opts.files
	if files == nil and opts.discovery_marker ~= nil then
		local path = (opts.companion and opts.companion.discovery_path) or "__marker__"
		files = { [path] = env.JSON.encode(opts.discovery_marker) }
	end
	files = files or {}
	env.NFS = {
		getInfo = function(path)
			if files[path] ~= nil then
				return { type = "file" }
			end
			return nil
		end,
		read = function(path)
			return files[path]
		end,
	}
	env.os = {
		getenv = function(name)
			if opts.env_values ~= nil then
				return opts.env_values[name]
			end
			return nil
		end,
	}
	env.sendInfoMessage = function(message) record.logs[#record.logs + 1] = "info:" .. tostring(message) end
	env.sendWarnMessage = function(message) record.logs[#record.logs + 1] = "warn:" .. tostring(message) end
	env.sendErrorMessage = function(message) record.logs[#record.logs + 1] = "error:" .. tostring(message) end
	env.sendDebugMessage = function(message) record.logs[#record.logs + 1] = "debug:" .. tostring(message) end

	local ctx = {
		env = env,
		record = record,
		own = own,
		smods = smods,
		mp = mp,
		ui = ui,
		original_update = original_update,
	}
	function ctx:run()
		local chunk, err = loadfile(repo_root .. "/AISparring/core.lua")
		if chunk == nil then
			return false, "compile:" .. tostring(err)
		end
		setfenv(chunk, env)
		return pcall(chunk)
	end
	function ctx:status()
		if type(own.aisparring) ~= "table" then
			return nil
		end
		return own.aisparring.get_status()
	end
	return ctx
end

return Support
