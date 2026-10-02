-- Test framework for the AI Sparring menu controller.
--
-- Loads the real AISparring/ui/practice_menu.lua and
-- AISparring/integration/menu_controller.lua sources inside a restricted Lua
-- environment and wires them to an honest fake UI tree (tests/menu/fakeui.lua).
-- No game files, Mods directory, process, network or engine callback is touched.

local F = {}

F.cases = {}
F.vectors = {}

local function load_chunk(path, env)
	local chunk, err = loadfile(path)
	if chunk == nil then
		error("cannot load " .. path .. ": " .. tostring(err), 2)
	end
	if env ~= nil then
		setfenv(chunk, env)
	end
	return chunk()
end

function F.safe_env()
	local env = {}
	env.math = math
	env.string = string
	env.table = table
	env.type = type
	env.next = next
	env.rawget = rawget
	env.rawset = rawset
	env.getmetatable = getmetatable
	env.setmetatable = setmetatable
	env.pcall = pcall
	env.error = error
	env.assert = assert
	env.select = select
	env.tostring = tostring
	env.tonumber = tonumber
	env.ipairs = ipairs
	env.pairs = pairs
	env.unpack = unpack

	local fired = { count = 0 }
	local function forbid(name)
		return function()
			fired.count = fired.count + 1
			error("forbidden global access: " .. name, 2)
		end
	end
	local function canary(name)
		return setmetatable({}, { __index = forbid(name), __newindex = forbid(name) })
	end

	env.G = canary("G")
	env.MP = canary("MP")
	env.SMODS = canary("SMODS")
	env.Client = canary("Client")
	env.love = canary("love")
	env.io = canary("io")
	env.os = canary("os")
	env.debug = canary("debug")
	env.require = forbid("require")
	env.load = forbid("load")
	env.loadstring = forbid("loadstring")
	env.dofile = forbid("dofile")
	env.setfenv = forbid("setfenv")
	env.getfenv = forbid("getfenv")
	env.collectgarbage = forbid("collectgarbage")
	env._G = env
	return env, fired
end

function F.load_modules(repo_root, env)
	return {
		PracticeMenu = load_chunk(repo_root .. "/AISparring/ui/practice_menu.lua", env),
		MenuController = load_chunk(repo_root .. "/AISparring/integration/menu_controller.lua", env),
	}
end

function F.collect_buttons(menu)
	local out = {}
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		local cfg = node.config
		if type(cfg) == "table" and cfg.button ~= nil then
			out[#out + 1] = { id = cfg.id, button = cfg.button }
		end
		local nodes = node.nodes
		if type(nodes) == "table" then
			for i = 1, #nodes do
				walk(nodes[i])
			end
		end
	end
	walk(menu)
	return out
end

function F.collect_ids(menu)
	local out = {}
	local buttons = F.collect_buttons(menu)
	for i = 1, #buttons do
		if type(buttons[i].id) == "string" then
			out[#out + 1] = buttons[i].id
		end
	end
	return out
end

local function default_base_builder(ui, specs)
	return function()
		local contents = {}
		for i = 1, #specs do
			contents[#contents + 1] = ui.UIBox_button(specs[i])
		end
		return ui.create_UIBox_generic_options({ contents = contents })
	end
end

function F.fixture(repo_root, cfg)
	cfg = cfg or {}
	local env, fired = F.safe_env()
	local modules = F.load_modules(repo_root, env)
	local fakeui = load_chunk(repo_root .. "/tests/menu/fakeui.lua", nil)
	local ui, ustate = fakeui.new()

	local base_specs = cfg.base_buttons or {
		{ id = "base_singleplayer", label = "Single Player", button = "start_vanilla_sp" },
		{ id = "base_ruleset", label = "Single Player with Ruleset", button = "setup_practice_mode" },
		{ id = "base_create", label = "Create Lobby", button = "create_lobby" },
	}
	local original_builder = default_base_builder(ui, base_specs)
	ui.G.UIDEF[modules.MenuController.BUILDER_KEY] = original_builder

	local menu, menu_code = modules.PracticeMenu.factory(ui)
	if menu == nil then
		error("practice_menu.factory failed: " .. tostring(menu_code), 2)
	end

	local fx = {
		repo_root = repo_root,
		modules = modules,
		menu = menu,
		menu_code = menu_code,
		ui = ui,
		ustate = ustate,
		fired = fired,
		env = env,
		base_specs = base_specs,
		original_builder = original_builder,
		starts = {},
		quits = 0,
		ends = 0,
		polls = 0,
		now = cfg.now or 0,
		probe_result = cfg.probe or {
			main_menu = true,
			active_run = false,
			mp_connected = false,
			mp_compatible = true,
		},
		available = cfg.available ~= false,
		quit_fails = cfg.quit_fails == true,
		diagnostics_path = cfg.diagnostics_path or "C:/logs/aisparring/practice.log",
		poll_result = cfg.poll_result,
		draft_begins = {},
		draft_actions = {},
		draft_cancels = {},
		draft_polls = 0,
		draft_begin_ok = cfg.draft_begin_ok ~= false,
		draft_responses = {},
	}
	for index = 1, #(cfg.draft_responses or {}) do
		fx.draft_responses[index] = cfg.draft_responses[index]
	end

	local host = {
		available = function()
			return fx.available == true
		end,
		request_start = function(payload)
			if type(cfg.request_start) == "function" then
				return cfg.request_start(payload)
			end
			if cfg.request_nil == true then
				return nil, "no_launcher"
			end
			fx.starts[#fx.starts + 1] = payload
			return "req-1"
		end,
		poll_start = function()
			fx.polls = fx.polls + 1
			return fx.poll_result
		end,
		quit = function()
			fx.quits = fx.quits + 1
			if fx.quit_fails then
				error("synthetic quit failure")
			end
			return true
		end,
		diagnostics_path = function()
			return fx.diagnostics_path
		end,
	}
	if type(cfg.request_end) == "function" then
		host.request_end = function(reason)
			fx.ends = fx.ends + 1
			return cfg.request_end(reason)
		end
	end
	host.draft_begin = function(payload)
		fx.draft_begins[#fx.draft_begins + 1] = payload
		if not fx.draft_begin_ok then
			return nil, "ranked_catalog_unmeasured"
		end
		return "draft-1"
	end
	host.draft_action = function(action)
		fx.draft_actions[#fx.draft_actions + 1] = action
		return "draft-2"
	end
	host.draft_cancel = function(draft_id)
		fx.draft_cancels[#fx.draft_cancels + 1] = draft_id
		return "draft-3"
	end
	host.poll_draft = function(request_id)
		fx.draft_polls = fx.draft_polls + 1
		if type(cfg.poll_draft) == "function" then
			return cfg.poll_draft(request_id, fx)
		end
		return table.remove(fx.draft_responses, 1)
	end

	local status = {
		probe = function()
			return fx.probe_result
		end,
	}
	local clock = {
		now = function()
			return fx.now
		end,
	}

	local controller, factory_code = modules.MenuController.factory({
		ui = ui,
		menu = menu,
		host = host,
		status = status,
		clock = clock,
		logger = cfg.logger,
	})
	if controller == nil then
		error("menu_controller.factory failed: " .. tostring(factory_code), 2)
	end

	fx.host = host
	fx.status = status
	fx.clock = clock
	fx.controller = controller
	fx.factory_code = factory_code
	return fx
end

function F.install(g, repo_root)
	g.repo_root = repo_root
	g.test = function(name, fn)
		if type(name) ~= "string" or name == "" then
			error("test name must be a non-empty string", 2)
		end
		if type(fn) ~= "function" then
			error("test body must be a function", 2)
		end
		F.cases[#F.cases + 1] = { name = name, fn = fn }
	end
	g.eq = function(actual, expected, label)
		if actual ~= expected then
			error((label or "eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
		end
	end
	g.neq = function(actual, expected, label)
		if actual == expected then
			error((label or "neq") .. ": both " .. tostring(actual), 2)
		end
	end
	g.truthy = function(value, label)
		if not value then
			error((label or "truthy") .. ": got " .. tostring(value), 2)
		end
	end
	g.falsy = function(value, label)
		if value then
			error((label or "falsy") .. ": got " .. tostring(value), 2)
		end
	end
	g.vec = function(name, value)
		F.vectors[name] = tostring(value)
	end
	g.safe_env = F.safe_env
	g.load_modules = function(env)
		return F.load_modules(repo_root, env)
	end
	g.fixture = function(cfg)
		return F.fixture(repo_root, cfg)
	end
	g.collect_buttons = F.collect_buttons
	g.collect_ids = F.collect_ids
	g.join_ids = function(menu)
		local ids = F.collect_ids(menu)
		table.sort(ids)
		return table.concat(ids, ",")
	end
end

function F.finish()
	local results = {}
	for i = 1, #F.cases do
		local item = F.cases[i]
		local ok, err = pcall(item.fn)
		results[i] = { name = item.name, ok = ok, err = ok and "" or tostring(err) }
	end
	return { cases = results, vectors = F.vectors }
end

return F
