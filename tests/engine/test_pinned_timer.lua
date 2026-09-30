-- START_TIMER against the *pinned* Multiplayer 0.5.5 timer code.
--
-- The real `MP.UI.can_timer_opponent`, `G.FUNCS.mp_timer_button`,
-- `action_start_ante_timer` and `MP.ACTIONS.start_ante_timer` are extracted
-- verbatim from the gitignored upstream checkout (work/reference/mp, pinned
-- 3dff16a) and run against the engine fixture, so the certificate, the executor
-- and the real button agree, including the timer_display_threshold branch.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	local function read(path)
		local handle = assert(io.open(ctx.repo_root .. "/" .. path, "rb"))
		local content = handle:read("*a")
		handle:close()
		return content
	end

	-- Lines from the one starting with `header` through the next line that is
	-- exactly "end" (top-level function bodies in the pinned files).
	local function extract(source, header)
		local out = {}
		local inside = false
		for line in (source .. "\n"):gmatch("([^\n]*)\n") do
			line = line:gsub("\r$", "")
			if not inside and line:sub(1, #header) == header then
				inside = true
			end
			if inside then
				out[#out + 1] = line
				if line == "end" then
					break
				end
			end
		end
		assert(inside and out[#out] == "end", "pinned function not found: " .. header)
		return table.concat(out, "\n")
	end

	local timer_src = read("work/reference/mp/ui/game/timer.lua")
	local handlers_src = read("work/reference/mp/networking/action_handlers.lua")
	local PINNED = table.concat({
		extract(timer_src, "function MP.UI.can_timer_opponent()"),
		extract(timer_src, "function G.FUNCS.mp_timer_button(e)"),
		extract(handlers_src, "local function action_start_ante_timer(p)"),
		extract(handlers_src, "local function action_pause_ante_timer(p)"),
		extract(handlers_src, "function MP.ACTIONS.start_ante_timer()"),
		extract(handlers_src, "function MP.ACTIONS.pause_ante_timer()"),
	}, "\n")

	-- Real Major League values (rulesets/majorleague.lua force_lobby_options).
	local function pinned_engine(opts)
		opts = opts or {}
		local engine = support.engine({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = opts.ready_blind ~= false,
			blind_select = {},
			config_timer = true,
			timer = opts.timer or 180,
		})
		local MP = engine.MP
		MP.LOBBY.config.timer_base_seconds = 180
		MP.LOBBY.config.timer_forgiveness = 0
		MP.LOBBY.config.timer_display_threshold = 180
		MP.GAME.enemy.location_type = opts.enemy_location
		MP.GAME.nemesis_timer_started = opts.nemesis_started or false
		MP.GAME.pvp_countdown_in_progress = opts.countdown
		MP.UI = {}
		MP.ACTIONS = {}
		MP.is_pvp_boss = function() return false end
		MP.is_layer_active = function() return false end
		MP.timer_is_local = function() return false end
		local sent = {}
		local env = setmetatable({
			MP = MP,
			G = engine.G,
			SMODS = { Mods = { Multiplayer = { config = { timersfx = 3 } } } },
			Client = { send = function(message) sent[#sent + 1] = message end },
		}, { __index = _G })
		engine.G.FUNCS = engine.G.FUNCS or {}
		local chunk = assert((loadstring or load)(PINNED, "=pinned_timer"))
		if setfenv then
			setfenv(chunk, env)
		else
			chunk = assert(load(PINNED, "=pinned_timer", "t", env))
		end
		chunk()
		-- The executor calls callbacks through the engine's funcs table.
		engine.funcs.mp_timer_button = engine.G.FUNCS.mp_timer_button
		return engine, sent
	end

	local function offered(pipeline)
		local step = pipeline.adapter.step()
		local handle = bundle.reader.capture(step.runtime, step.ui_view)
		for _, action in ipairs(bundle.actions.generate(handle)) do
			if action.type == "START_TIMER" then
				return action
			end
		end
		return nil
	end

	test("pinned_timer_button_starts_and_sends_at_threshold", function()
		local engine, sent = pinned_engine({ timer = 180 })
		local pipeline = support.pipeline(bundle, engine, {})
		local action = offered(pipeline)
		is_true(action ~= nil, "pinned gate lights the button while readied")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.MP.GAME.timer_started, true)
		eq(#sent, 1)
		eq(sent[1].action, "startAnteTimer")
		eq(sent[1].time, 180)
		is_true(offered(pipeline) == nil, "never offered again: a second press pauses")
	end)

	test("pinned_timer_above_threshold_defers_the_send", function()
		-- timer > timer_display_threshold: start locally, send once it ticks
		-- down to the threshold (timer.lua Game:update).
		local engine, sent = pinned_engine({ timer = 200 })
		local pipeline = support.pipeline(bundle, engine, {})
		local action = offered(pipeline)
		is_true(action ~= nil)
		local valid, vcode = pipeline.executor.validate(action)
		is_true(valid == true, "validate: " .. tostring(vcode))
		local ok, code = pipeline.executor.dispatch(action)
		is_true(ok == true, "dispatch: " .. tostring(code))
		eq(engine.MP.GAME.timer_started, true)
		eq(engine.MP.GAME.timer_threshold_pending, true)
		eq(#sent, 0)
	end)

	test("pinned_gate_closes_for_every_real_reason", function()
		for _, case in ipairs({
			{ label = "opponent ready", opts = { enemy_location = "loc_ready" } },
			{ label = "being timered", opts = { nemesis_started = true } },
			{ label = "countdown", opts = { countdown = true } },
			{ label = "consumed", opts = { timer = 0 } },
			{ label = "not readied", opts = { ready_blind = false } },
		}) do
			local engine, sent = pinned_engine(case.opts)
			local pipeline = support.pipeline(bundle, engine, {})
			is_true(offered(pipeline) == nil, case.label .. ": offered")
			local ok, code = pipeline.executor.validate({ type = "START_TIMER", id = "t" })
			eq(ok, nil, case.label)
			eq(code, "exec_illegal", case.label)
			eq(#sent, 0, case.label)
		end
	end)

	test("pinned_gate_hidden_hud_or_no_lobby", function()
		for _, mutate in ipairs({
			function(MP) MP.LOBBY.config.disable_live_and_timer_hud = true end,
			function(MP) MP.LOBBY.code = nil end,
		}) do
			local engine = pinned_engine()
			mutate(engine.MP)
			local pipeline = support.pipeline(bundle, engine, {})
			is_true(offered(pipeline) == nil, "button not mounted")
		end
	end)

	test("adapter_and_executor_agree_on_timer_availability", function()
		for _, opts in ipairs({
			{}, { enemy_location = "loc_ready" }, { nemesis_started = true }, { timer = 0 },
			{ ready_blind = false }, { countdown = true }, { timer = 250 },
		}) do
			local engine = pinned_engine(opts)
			local pipeline = support.pipeline(bundle, engine, {})
			local certified = offered(pipeline) ~= nil
			local valid = pipeline.executor.validate({ type = "START_TIMER", id = "t" }) == true
			eq(certified, valid)
		end
	end)
end
