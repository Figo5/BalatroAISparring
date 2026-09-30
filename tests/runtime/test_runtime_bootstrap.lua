return function(ctx)
	local support = ctx.support
	local test = ctx.test

	local function drain_envelopes(bctx)
		local messages = support.drain_outbound(bctx)
		local by_op = {}
		for _, message in ipairs(messages) do
			if type(message) == "table" and type(message.op) == "string" then
				by_op[message.op] = message
			end
		end
		return messages, by_op
	end

	test("non_staged_role_is_inert_and_touches_nothing", function()
		local instance, code, bctx = support.bootstrap(ctx.repo_root, { role = "live" })
		ctx.eq(code, nil)
		local allowed, refused = instance.validate()
		ctx.eq(allowed, nil)
		ctx.eq(refused, "boot_not_staged")
		local installed, install_code = instance.install()
		ctx.eq(installed, nil)
		ctx.eq(install_code, "boot_not_staged")
		ctx.is_true(instance.is_inert())
		ctx.eq(bctx.channels.to_worker:size(), 0)
	end)

	test("env_path_mismatch_is_refused", function()
		local instance = support.bootstrap(ctx.repo_root, {
			env = {
				save_dir = function() return "/somewhere/else" end,
				mods_root = function() return "/stage/Mods" end,
				mod_root = function() return "/stage/Mods/AISparring" end,
			},
		})
		local allowed, code = instance.validate()
		ctx.eq(allowed, nil)
		ctx.eq(code, "boot_env_mismatch")
	end)

	test("unverified_launcher_is_refused", function()
		local instance = support.bootstrap(ctx.repo_root, {
			launcher = { verify = function() return { ok = false } end },
		})
		local allowed, code = instance.validate()
		ctx.eq(allowed, nil)
		ctx.eq(code, "boot_launcher_unverified")
	end)

	-- Advance the fake clock so the bounded coordinator retry is not throttled,
	-- then run one update.
	local function step(instance, bctx, delta)
		bctx.clock.advance(delta or 1)
		return instance.update(0.016)
	end

	local function unlock_element(button)
		return { config = { id = "overlay_menu_back_button", button = button or "continue_unlock" } }
	end

	local function metatable_overlay(element)
		return setmetatable({}, {
			__index = {
				get_UIE_by_ID = function(_, id)
					if id == "overlay_menu_back_button" then
						return element
					end
					return nil
				end,
			},
		})
	end

	local function mounted_menu(engine)
		return {
			get_UIE_by_ID = function(_, id)
				if id == "lobby_menu_start" then
					return engine.ready_element
				end
				return nil
			end,
		}
	end

	-- A match-9-shaped unlock popup: while it is up the main menu UI has not
	-- mounted; the real continue_unlock clears the overlay and (I1) unpauses like
	-- exit_overlay_menu, and the deferred main-menu event then mounts the menu.
	-- `chain` opens the next popup instead (the chained E_MANAGER update),
	-- `chain_count` more times when set;
	-- `leave` never clears it (a callback that is not really dismissing);
	-- `menu_ready` keeps the menu mounted under the popup.
	local function install_unlock_overlay(bctx, opts)
		opts = opts or {}
		local engine = bctx.engine
		local G = engine.G
		local state = { dismissed = 0 }
		local function build()
			G.SETTINGS.paused = true
			return metatable_overlay(unlock_element(opts.button))
		end
		G.OVERLAY_MENU = build()
		G.MAIN_MENU_UI = opts.menu_ready and mounted_menu(engine) or nil
		G.FUNCS.continue_unlock = function()
			state.dismissed = state.dismissed + 1
			if opts.leave then
				return
			end
			if opts.chain and (opts.chain_count == nil or state.dismissed <= opts.chain_count) then
				G.OVERLAY_MENU = build()
			else
				G.OVERLAY_MENU = nil
				G.SETTINGS.paused = false
				G.MAIN_MENU_UI = mounted_menu(engine)
			end
		end
		return state
	end

	local function setup_ok(bctx, setup_role)
		support.inbound(bctx, {
			ok = true,
			code = "practice_ok",
			role = setup_role,
			ruleset_id = "ruleset_mp_majorleague",
			gamemode = "gamemode_mp_attrition",
			-- The real service returns the full forced ruleset keyset; the host
			-- verifies its locally recorded create keyset against it.
			forced_options = {
				"timer_base_seconds",
				"timer_forgiveness",
				"the_order",
				"preview_disabled",
				"enemy_location_disabled",
				"timer_display_threshold",
			},
			difficulty = "competitive",
			mode = "normal",
			pacing = "normal",
		})
	end

	test("human_prestart_unlock_overlay_is_dismissed_so_the_lobby_can_start", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		setup_ok(bctx, "human")
		-- The unlock popup is up and the main menu UI has not mounted: exactly
		-- match 9's frozen pre-start.
		local state = install_unlock_overlay(bctx)
		ctx.eq(bctx.engine.start_lobby_calls, 0)
		-- L2: the human's own pre-start popup is shown for its grace window; the
		-- gated coordinator never creates the lobby under it.
		for _ = 1, 7 do
			step(instance, bctx)
		end
		ctx.eq(state.dismissed, 0, "not dismissed inside the human grace window")
		ctx.eq(bctx.engine.start_lobby_calls, 0)
		for _ = 1, 2 do
			step(instance, bctx)
		end
		ctx.eq(state.dismissed, 1, "the popup is dismissed once the grace passes")
		ctx.eq(bctx.engine.start_lobby_calls, 1, "the host creates the lobby once the overlay is gone")
		ctx.eq(bctx.engine.G.OVERLAY_MENU, nil)
		instance.shutdown("test")
	end)

	test("human_in_match_unlock_overlay_is_left_to_the_human", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", lobby_code = "ABC12" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		-- The human's match has started: its popups belong to the human.
		local state = install_unlock_overlay(bctx)
		for _ = 1, 4 do
			step(instance, bctx)
		end
		ctx.eq(state.dismissed, 0)
		ctx.is_true(bctx.engine.G.OVERLAY_MENU ~= nil)
		instance.shutdown("test")
	end)

	test("ai_in_match_unlock_overlay_holds_the_loop_until_it_is_gone", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		local state = install_unlock_overlay(bctx, { chain = true })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		local _, blocked = drain_envelopes(bctx)
		ctx.eq(blocked.decide_begin, nil, "no decision is consumed while the popup is up")
		ctx.is_true(state.dismissed >= 1)
		-- The popup finally clears: the loop resumes on the next tick.
		bctx.engine.G.OVERLAY_MENU = nil
		step(instance, bctx)
		local _, resumed = drain_envelopes(bctx)
		ctx.is_true(resumed.decide_begin ~= nil, "the loop resumes once the overlay is gone")
		instance.shutdown("test")
	end)

	test("non_unlock_overlays_are_never_touched_for_either_role", function()
		-- The human case runs PRE-START (no match yet, frozen menu) so the policy
		-- gate allows dismissal and only the identity check refuses: a broken
		-- identity check would now actually dismiss it.
		local human, _, human_ctx = support.bootstrap(ctx.repo_root, { role = "human", started = false })
		local human_state = install_unlock_overlay(human_ctx, { button = "exit_overlay_menu" })
		local human_overlay = human_ctx.engine.G.OVERLAY_MENU
		human.install()
		drain_envelopes(human_ctx)
		support.inbound(human_ctx, { ok = true, code = "practice_ok" })
		for _ = 1, 10 do
			step(human, human_ctx)
		end
		ctx.eq(human_state.dismissed, 0, "the human must not dismiss a foreign overlay")
		ctx.is_true(rawequal(human_ctx.engine.G.OVERLAY_MENU, human_overlay))
		ctx.eq(human_ctx.engine.start_lobby_calls, 0, "the frozen menu never creates a lobby")
		human.shutdown("test")

		-- The AI keeps a joined match; its foreign overlay is refused by identity.
		local ai, _, ai_ctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		local ai_state = install_unlock_overlay(ai_ctx, { button = "exit_overlay_menu" })
		local ai_overlay = ai_ctx.engine.G.OVERLAY_MENU
		ai.install()
		drain_envelopes(ai_ctx)
		support.inbound(ai_ctx, { ok = true, code = "practice_ok" })
		for _ = 1, 3 do
			step(ai, ai_ctx)
		end
		ctx.eq(ai_state.dismissed, 0, "the ai must not dismiss a foreign overlay")
		ctx.is_true(rawequal(ai_ctx.engine.G.OVERLAY_MENU, ai_overlay))
		ai.shutdown("test")
	end)

	test("unlock_dismissal_is_rate_limited_and_capped", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local records = {}
		local logger = { record = function(fields)
			records[#records + 1] = fields
		end }
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12", logger = logger })
		local state = install_unlock_overlay(bctx, { chain = true })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		-- Within the interval the same popup is not re-attempted.
		bctx.clock.advance(0.25)
		instance.update(0.016)
		ctx.eq(state.dismissed, 1, "at most one attempt per interval")
		bctx.clock.advance(0.25)
		instance.update(0.016)
		ctx.eq(state.dismissed, 2)
		-- Keep chaining at the minimum interval: the fixed success cap is reached
		-- before the continuous-block bound (M1) would stop the runtime.
		for _ = 1, 30 do
			step(instance, bctx, 0.5)
		end
		ctx.eq(state.dismissed, RuntimeBootstrap.LIMITS.max_unlock_dismissals)
		-- One more refused tick logs the cap exactly once.
		step(instance, bctx, 0.5)
		local caps = 0
		for _, record in ipairs(records) do
			if record.event == "unlock_dismiss_cap" then
				caps = caps + 1
			end
		end
		ctx.eq(caps, 1, "the cap is logged exactly once")
		ctx.is_true(instance.state() ~= "stopped", "the cap alone never aborts the runtime")
		instance.shutdown("test")
	end)

	test("human_unlock_grace_shows_the_popup_then_dismisses_it", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", started = false })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		local state = install_unlock_overlay(bctx)
		-- The grace is counted from the first tick that observed this overlay.
		step(instance, bctx)
		bctx.clock.advance(7)
		instance.update(0.016)
		ctx.eq(state.dismissed, 0, "the human sees the popup for the grace window")
		ctx.eq(bctx.engine.G.SETTINGS.paused, true)
		-- A replacement overlay object restarts the grace.
		bctx.engine.G.OVERLAY_MENU = metatable_overlay(unlock_element())
		bctx.engine.G.SETTINGS.paused = true
		local replaced = bctx.engine.G.OVERLAY_MENU
		step(instance, bctx)
		bctx.clock.advance(7)
		instance.update(0.016)
		ctx.eq(state.dismissed, 0, "a replaced overlay object restarts the grace")
		ctx.is_true(rawequal(bctx.engine.G.OVERLAY_MENU, replaced))
		-- Once the grace passes the popup is dismissed and the menu unpauses.
		bctx.clock.advance(1)
		instance.update(0.016)
		ctx.eq(state.dismissed, 1)
		ctx.eq(bctx.engine.G.OVERLAY_MENU, nil)
		ctx.eq(bctx.engine.G.SETTINGS.paused, false)
		instance.shutdown("test")
	end)

	test("ai_unlock_popup_is_dismissed_on_the_first_tick", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
		local state = install_unlock_overlay(bctx)
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		ctx.eq(state.dismissed, 1, "the ai is immediate, never graced")
		ctx.eq(bctx.engine.G.OVERLAY_MENU, nil)
		instance.shutdown("test")
	end)

	test("unlock_popup_gates_the_coordinator_but_not_the_prestart_deadline", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", started = false })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		setup_ok(bctx, "human")
		-- A popup replaced every tick keeps restarting the human grace, so no
		-- dismissal is ever permitted (and M1's clock never starts) while the
		-- menu is already mounted: the coordinator must not step.
		local function install_fresh()
			bctx.engine.G.OVERLAY_MENU = metatable_overlay(unlock_element())
			bctx.engine.G.MAIN_MENU_UI = mounted_menu(bctx.engine)
			bctx.engine.G.SETTINGS.paused = true
		end
		install_fresh()
		for _ = 1, 5 do
			step(instance, bctx)
			install_fresh()
		end
		ctx.eq(bctx.engine.start_lobby_calls, 0, "no coordinator step under the popup")
		-- The deadline check stays outside the gate and still ends the boot.
		bctx.clock.advance(RuntimeBootstrap.LIMITS.prestart_timeout)
		local status, code = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(code, "boot_coord_timeout")
		ctx.eq(instance.status().last_error, "boot_coord_timeout")
	end)

	test("unlock_overlay_that_never_clears_is_a_clean_stuck_stop", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
		local state = install_unlock_overlay(bctx, { leave = true })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		ctx.eq(state.dismissed, 1, "the first attempt is made immediately")
		-- Just inside the bound the runtime is still alive.
		bctx.clock.advance(19)
		instance.update(0.016)
		ctx.is_true(instance.state() ~= "stopped", "no stop before the bound")
		ctx.is_true(bctx.engine.G.OVERLAY_MENU ~= nil)
		-- Past the bound it is a clean stop, exactly like a coord timeout.
		bctx.clock.advance(2)
		local status, code = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(code, "unlock_overlay_stuck")
		ctx.eq(instance.status().last_error, "unlock_overlay_stuck")
		ctx.eq(instance.status().state, "stopped")
	end)

	test("unlock_success_cap_then_a_still_present_chain_is_a_clean_stop", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local records = {}
		local logger = { record = function(fields)
			records[#records + 1] = fields
		end }
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", logger = logger })
		local state = install_unlock_overlay(bctx, { chain = true })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		for _ = 1, 31 do
			step(instance, bctx, 0.5)
		end
		ctx.eq(state.dismissed, RuntimeBootstrap.LIMITS.max_unlock_dismissals)
		-- One more refused tick logs the success cap while the chain is still up.
		step(instance, bctx, 0.5)
		ctx.is_true(instance.state() ~= "stopped", "the cap alone does not stop the runtime")
		-- The chained popup is still up: the continuous-block bound ends it.
		bctx.clock.advance(RuntimeBootstrap.LIMITS.unlock_block_timeout)
		local status, code = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(code, "unlock_overlay_stuck")
		local caps = 0
		for _, record in ipairs(records) do
			if record.event == "unlock_dismiss_cap" then
				caps = caps + 1
			end
		end
		ctx.eq(caps, 1, "the success cap is logged exactly once")
	end)

	test("unlock_attempt_cap_bounds_failed_attempts_once", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local records = {}
		local logger = { record = function(fields)
			records[#records + 1] = fields
		end }
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", logger = logger })
		local G = bctx.engine.G
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		-- Each episode is a failed dismissal followed by a clear, so the
		-- continuous-block clock resets every episode and never reaches its bound;
		-- only the attempt cap limits the attempts.
		local attempts = 0
		G.FUNCS.continue_unlock = function()
			attempts = attempts + 1
		end
		for _ = 1, 64 do
			G.SETTINGS.paused = true
			G.OVERLAY_MENU = metatable_overlay(unlock_element())
			step(instance, bctx, 0.5)
			G.OVERLAY_MENU = nil
			step(instance, bctx, 0.5)
		end
		ctx.eq(attempts, RuntimeBootstrap.LIMITS.max_unlock_attempts)
		-- The overlay is still up: the attempt cap is logged exactly once.
		G.SETTINGS.paused = true
		G.OVERLAY_MENU = metatable_overlay(unlock_element())
		step(instance, bctx, 0.5)
		local caps = 0
		for _, record in ipairs(records) do
			if record.event == "unlock_attempt_cap" then
				caps = caps + 1
			end
		end
		ctx.eq(caps, 1, "the attempt cap is logged exactly once")
		ctx.is_true(instance.state() ~= "stopped", "the attempt cap never aborts the runtime")
		instance.shutdown("test")
	end)

	-- R1: once a cap is reached no further attempt is made, yet an in-match AI
	-- must still end in the clean stuck stop rather than a loop gated forever.
	test("in_match_ai_after_the_attempt_cap_still_ends_in_a_stuck_stop", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		-- The cap is reached pre-start (the fixture service never answers
		-- decisions, so a minute of in-match ticks would stop the loop itself);
		-- the AI is then moved into the match before the final popup.
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
		local G = bctx.engine.G
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		local attempts = 0
		G.FUNCS.continue_unlock = function()
			attempts = attempts + 1
		end
		for _ = 1, RuntimeBootstrap.LIMITS.max_unlock_attempts do
			G.OVERLAY_MENU = metatable_overlay(unlock_element())
			step(instance, bctx, 0.5)
			G.OVERLAY_MENU = nil
			step(instance, bctx, 0.5)
		end
		ctx.eq(attempts, RuntimeBootstrap.LIMITS.max_unlock_attempts)
		bctx.engine.set_match_code("ABC12")
		bctx.engine.set_run()
		-- A new popup after the cap: no attempt, but the bound still applies.
		G.OVERLAY_MENU = metatable_overlay(unlock_element())
		step(instance, bctx, 0.5)
		ctx.eq(attempts, RuntimeBootstrap.LIMITS.max_unlock_attempts, "no attempt past the cap")
		ctx.is_true(instance.state() ~= "stopped")
		bctx.clock.advance(RuntimeBootstrap.LIMITS.unlock_block_timeout + 1)
		local status, code = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(code, "unlock_overlay_stuck")
	end)

	test("in_match_ai_after_the_success_cap_and_a_clear_still_ends_in_a_stuck_stop", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		local G = bctx.engine.G
		local state = install_unlock_overlay(bctx, { chain = true })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		for _ = 1, RuntimeBootstrap.LIMITS.max_unlock_dismissals - 1 do
			step(instance, bctx, 0.5)
		end
		ctx.eq(state.dismissed, RuntimeBootstrap.LIMITS.max_unlock_dismissals)
		-- The chain clears for one tick (the stuck clock resets), then a new popup.
		G.OVERLAY_MENU = nil
		step(instance, bctx, 0.5)
		G.OVERLAY_MENU = metatable_overlay(unlock_element())
		step(instance, bctx, 0.5)
		ctx.eq(state.dismissed, RuntimeBootstrap.LIMITS.max_unlock_dismissals, "no dismissal past the cap")
		ctx.is_true(instance.state() ~= "stopped")
		bctx.clock.advance(RuntimeBootstrap.LIMITS.unlock_block_timeout + 1)
		local status, code = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(code, "unlock_overlay_stuck")
	end)

	-- N1: a chain of pre-start unlock popups on the human is shown once (first
	-- popup's grace) and the rest are dismissed promptly; a healthy chain never
	-- trips the stuck bound and the lobby is created.
	test("human_prestart_unlock_chain_is_dismissed_without_a_stuck_stop", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		setup_ok(bctx, "human")
		local state = install_unlock_overlay(bctx, { chain = true, chain_count = 5 })
		for _ = 1, 30 do
			step(instance, bctx)
		end
		ctx.is_true(instance.state() ~= "stopped", "a healthy chain is never a stuck stop")
		ctx.eq(state.dismissed, 6, "all six chained popups are dismissed")
		ctx.eq(bctx.engine.G.OVERLAY_MENU, nil)
		ctx.eq(bctx.engine.start_lobby_calls, 1, "the host creates the lobby after the chain")
		instance.shutdown("test")
	end)

	test("human_start_committed_but_not_yet_running_keeps_its_popup", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", deferred_code = true })
		-- Defence in depth, not an observed engine window: the real
		-- host_start_game latches is_started() in the same call that commits the
		-- start. Pin is_started() false so the `not start_committed` clause is
		-- still exercised on its own and dropping it is caught here.
		local real_driver = bctx.modules.MPDriver
		bctx.modules.MPDriver = {
			factory = function(ports)
				local driver = real_driver.factory(ports)
				driver.is_started = function()
					return false
				end
				return driver
			end,
		}
		bctx.engine.MP.LOBBY.ready_to_start = true
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		setup_ok(bctx, "human")
		step(instance, bctx)
		-- The real create is asynchronous: the code arrives later.
		ctx.eq(bctx.engine.start_lobby_calls, 1)
		bctx.engine.complete_lobby("ABC12")
		for _ = 1, 12 do
			step(instance, bctx)
			for _, message in ipairs(support.drain_outbound(bctx)) do
				if message.op == "start" then
					support.inbound(bctx, { ok = true, code = "practice_ok", started = true })
				else
					support.inbound(bctx, { ok = true, code = "practice_ok" })
				end
			end
			if instance.describe().lobby_ready then
				break
			end
		end
		ctx.is_true(instance.describe().lobby_ready, "the human start is committed")
		local state = install_unlock_overlay(bctx)
		for _ = 1, 10 do
			step(instance, bctx)
		end
		ctx.eq(state.dismissed, 0, "a committed-but-not-running human keeps its popup")
		ctx.is_true(bctx.engine.G.OVERLAY_MENU ~= nil)
		instance.shutdown("test")
	end)

	test("ai_prestart_popup_blocks_ai_join_until_it_is_dismissed", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", started = false })
		local state = install_unlock_overlay(bctx)
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		-- The AI's own popup is dismissed immediately and the deferred main-menu
		-- UI mounts, so the coordinator can join on later ticks.
		ctx.eq(state.dismissed, 1)
		ctx.is_true(bctx.engine.G.MAIN_MENU_UI ~= nil)
		for _ = 1, 6 do
			step(instance, bctx)
			for _, message in ipairs(support.drain_outbound(bctx)) do
				if message.op == "setup" then
					setup_ok(bctx, "ai")
				elseif message.op == "join_code" then
					support.inbound(bctx, { ok = true, code = "practice_ok", lobby_code = "ABC12" })
				else
					support.inbound(bctx, { ok = true, code = "practice_ok" })
				end
			end
		end
		ctx.eq(instance.lobby_code(), "ABC12", "ai_join runs once the popup is gone")
		instance.shutdown("test")
	end)

	test("unlock_dismissal_logs_allowlisted_fields_only", function()
		local Logger = support.mod(ctx.repo_root, "AISparring/src/logger.lua")
		local records = {}
		local logger = { record = function(fields)
			records[#records + 1] = fields
		end }
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12", logger = logger })
		install_unlock_overlay(bctx)
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		-- A fresh popup with the callback gone: the refusal is logged once.
		bctx.engine.G.OVERLAY_MENU = metatable_overlay(unlock_element())
		bctx.engine.G.FUNCS.continue_unlock = nil
		step(instance, bctx)
		step(instance, bctx)
		local dismissals, refusals = 0, 0
		for _, record in ipairs(records) do
			if record.event == "unlock_overlay_dismissed"
				or record.event == "unlock_overlay_refused"
				or record.event == "unlock_dismiss_cap" then
				for key in pairs(record) do
					ctx.is_true(Logger.is_allowed_field(key), "non-allowlisted log field: " .. tostring(key))
				end
				if record.event == "unlock_overlay_dismissed" then
					dismissals = dismissals + 1
				end
				if record.event == "unlock_overlay_refused" then
					refusals = refusals + 1
				end
			end
		end
		ctx.is_true(dismissals >= 1)
		ctx.eq(refusals, 1, "a refusal is logged once per distinct code")
		instance.shutdown("test")
	end)

	test("human_install_sends_hello_and_never_activates", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human" })
		local installed = instance.install()
		ctx.is_true(installed)
		local messages, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.hello ~= nil)
		ctx.eq(by_op.hello.role, "human")
		ctx.eq(by_op.hello.observation.content_digest, "content-1")
		ctx.eq(by_op.hello.sequence, 1)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		ctx.eq(instance.status().handshake, "acked")
		ctx.eq(instance.status().activated, false)
		-- SETUP is the first coordination op after the hello ack.
		local _, first = drain_envelopes(bctx)
		ctx.is_true(first.setup ~= nil)
		support.inbound(bctx, {
			ok = true,
			code = "practice_ok",
			role = "human",
			ruleset_id = "ruleset_mp_majorleague",
			gamemode = "gamemode_mp_attrition",
			forced_options = { "timer_base_seconds" },
			difficulty = "competitive",
			mode = "normal",
			pacing = "normal",
		})
		step(instance, bctx)
		ctx.is_true(instance.describe().setup_acked)
		-- The host creates the real lobby only after SETUP, then reports the
		-- exact code to the service.
		step(instance, bctx)
		step(instance, bctx)
		local sent, coord = drain_envelopes(bctx)
		ctx.is_true(coord.lobby_code ~= nil)
		ctx.eq(coord.lobby_code.observation.lobby_code, "ABC12")
		ctx.is_true(instance.state() ~= "stopped")
		instance.shutdown("test")
		ctx.eq(instance.state(), "stopped")
	end)

	test("bootstrap_default_get_channel_supports_love_channel_userdata", function()
		-- Real `love.thread.getChannel` returns userdata whose push/pop live on
		-- the metatable. No explicit `channels` is injected here, so the default
		-- `get_channel` route must accept the userdata objects (Astra root:
		-- control_channels_accept_userdata_methods).
		local sent = {}
		local function love_channel(methods)
			local value = newproxy(true)
			getmetatable(value).__index = methods
			return value
		end
		local to_worker = love_channel({ push = function(_, line) sent[#sent + 1] = line end })
		local from_worker = love_channel({ pop = function() return nil end })
		local looked_up = {}
		local instance, code = support.bootstrap(ctx.repo_root, {
			get_channel = function(name)
				looked_up[#looked_up + 1] = name
				if string.match(name, "_tw$") ~= nil then
					return to_worker
				end
				return from_worker
			end,
		})
		ctx.eq(code, nil)
		ctx.is_true(instance ~= nil)
		ctx.eq(instance.install(), true)
		ctx.is_true(#sent >= 1, "hello pushed through the userdata channel")
		ctx.is_true(string.find(sent[1], '"op":"hello"', 1, true) ~= nil)
		ctx.eq(#looked_up, 2, "both named channels resolved exactly once")
		instance.shutdown("test")
	end)

	test("bootstrap_accepts_injected_love_channel_userdata", function()
		-- The injected `{ to_worker, from_worker }` port must accept real LÖVE
		-- Channel userdata members exactly like table fixtures.
		local sent = {}
		local function love_channel(methods)
			local value = newproxy(true)
			getmetatable(value).__index = methods
			return value
		end
		local instance, code = support.bootstrap(ctx.repo_root, {
			channels = {
				to_worker = love_channel({ push = function(_, line) sent[#sent + 1] = line end }),
				from_worker = love_channel({ pop = function() return nil end }),
			},
		})
		ctx.eq(code, nil)
		ctx.eq(instance.install(), true)
		ctx.is_true(#sent >= 1, "hello pushed through the injected userdata pair")
		instance.shutdown("test")
	end)

	test("ai_activates_after_hello_and_issues_a_decision", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		local status = instance.update(0.016)
		ctx.eq(status, "active")
		ctx.is_true(instance.status().activated)
		local messages, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.decide_begin ~= nil)
		-- The wire sequence is globally monotonic across coordination and
		-- decisions; the decision loop's own sequence stays private.
		local previous = 0
		for _, message in ipairs(messages) do
			if type(message.sequence) == "number" then
				ctx.is_true(message.sequence > previous, "wire sequence strictly increases")
				previous = message.sequence
			end
		end
		ctx.eq(by_op.decide_begin.observation.sequence, nil)
		ctx.eq(by_op.decide_begin.observation.seed, nil)
		ctx.eq(by_op.decide_begin.observation.credential, nil)
		ctx.eq(by_op.decide_begin.observation.actions, nil)
		-- The guest never reports a trusted seed; the human-only SETUP seed is
		-- the sole seed source.
		ctx.eq(by_op.status, nil)
		ctx.eq(instance.status().decisions, 0)
	end)

	test("ai_activation_wires_wait_state_and_revision_and_a_15s_loop_timeout", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		local description = instance.describe()
		ctx.is_true(description.loop_has_wait_state)
		ctx.is_true(description.loop_has_revision)
		ctx.eq(description.loop_timeout, 15.25, "service 10s + poll margin")
		instance.shutdown("test")
	end)

	test("missing_client_guard_aborts_ai_boot_before_lobby", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", no_client = true })
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		local status = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(instance.status().activated, false)
		ctx.eq(instance.status().last_error, "boot_guard_failed")
	end)

	test("decision_issue_is_bounded_and_matches_pacing", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.decide_begin ~= nil)
		instance.update(0.016)
		local _, second = drain_envelopes(bctx)
		ctx.eq(second.decide_begin, nil, "no second issue while one is outstanding")
		ctx.eq(instance.status().has_pending, true)
		instance.shutdown("test")
	end)

	test("hello_timeout_stops_without_activation", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
		instance.install()
		drain_envelopes(bctx)
		-- The attestation/probe window is bounded at coord_timeout, not a frame
		-- budget; the hello itself is retried inside it.
		bctx.clock.advance(61)
		local status = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(instance.status().activated, false)
		ctx.eq(instance.status().last_error, "boot_hello_failed")
	end)

	test("hello_is_retried_until_the_attestation_gate_opens", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
		instance.install()
		drain_envelopes(bctx)
		-- The service refuses hello until the host attests.
		support.inbound(bctx, { ok = false, code = "practice_not_attested" })
		step(instance, bctx)
		ctx.eq(instance.status().handshake, "sent")
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.hello ~= nil, "hello re-sent")
		-- Attested: the next hello is acked and the boot arms.
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		ctx.eq(instance.status().handshake, "acked")
	end)

	test("loop_timeout_issues_a_wire_cancel_then_reissues", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		local _, first = drain_envelopes(bctx)
		local begin1 = first.decide_begin
		ctx.is_true(begin1 ~= nil)
		-- A 3s human-window stall is inside the loop budget.
		bctx.clock.advance(3)
		instance.update(0.016)
		ctx.eq(instance.state(), "active")
		ctx.eq(instance.status().has_pending, true)
		-- Past the loop deadline the loop cancels on the wire and reissues.
		bctx.clock.advance(14)
		instance.update(0.016)
		instance.update(0.016)
		local messages = support.drain_outbound(bctx)
		local cancel, begin2 = nil, nil
		for _, message in ipairs(messages) do
			if message.op == "decide_cancel" then
				cancel = message
			end
			if message.op == "decide_begin" then
				begin2 = message
			end
		end
		ctx.is_true(cancel ~= nil, "timeout sends a wire cancel")
		ctx.eq(cancel.observation.decision_sequence, begin1.sequence)
		ctx.is_true(begin2 ~= nil, "a fresh decision is reissued")
		ctx.is_true(cancel.sequence > begin1.sequence)
		ctx.is_true(begin2.sequence > cancel.sequence)
		instance.shutdown("test")
	end)

	test("terminal_probe_stops_the_policy", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			terminal_probe = function() return "win" end,
		})
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		local status = instance.update(0.016)
		ctx.eq(status, "terminal")
		ctx.eq(instance.status().state, "terminal")
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op["end"] ~= nil)
		ctx.eq(by_op["end"].observation.result, "ai_win")
	end)

	test("terminal_loss_is_reported", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			terminal_probe = function() return "loss" end,
		})
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		local status = instance.update(0.016)
		ctx.eq(status, "terminal")
		local _, by_op = drain_envelopes(bctx)
		ctx.eq(by_op["end"].observation.result, "human_win")
	end)

	test("terminal_mapping_is_role_aware_for_ai_and_human", function()
		local function terminal_for(role, result)
			local engine = support.engine(ctx.repo_root, {
				state = support.engine_support(ctx.repo_root).STATES.BLIND_SELECT,
				blind_on_deck = "Small",
				blind_states = { Small = "Select", Big = "Select", Boss = "Upcoming" },
				lives = 4,
				enemy_lives = 2,
			})
			local instance, _, bctx = support.bootstrap(ctx.repo_root, {
				role = role,
				engine = engine,
				terminal_probe = function() return result end,
			})
			instance.install()
			drain_envelopes(bctx)
			support.inbound(bctx, { ok = true, code = "practice_ok" })
			instance.update(0.016)
			local _, by_op = drain_envelopes(bctx)
			return by_op["end"].observation
		end

		-- The AI's local win is the AI's win; its local lives are ai_lives.
		local ai_win = terminal_for("ai", "win")
		ctx.eq(ai_win.result, "ai_win")
		ctx.eq(ai_win.ai_lives, 4)
		ctx.eq(ai_win.human_lives, 2)
		local ai_loss = terminal_for("ai", "loss")
		ctx.eq(ai_loss.result, "human_win")
		ctx.eq(ai_loss.ai_lives, 4)
		ctx.eq(ai_loss.human_lives, 2)
		-- The human runtime is the mirror image: local win -> human_win and the
		-- human's local lives are human_lives (the service trusts the human END).
		local human_win = terminal_for("human", "win")
		ctx.eq(human_win.result, "human_win")
		ctx.eq(human_win.human_lives, 4)
		ctx.eq(human_win.ai_lives, 2)
		local human_loss = terminal_for("human", "loss")
		ctx.eq(human_loss.result, "ai_win")
		ctx.eq(human_loss.human_lives, 4)
		ctx.eq(human_loss.ai_lives, 2)
	end)

	test("terminal_end_is_drained_and_bounded", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			terminal_probe = function() return "win" end,
		})
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op["end"] ~= nil)
		-- The owned END reply is consumed on a later update without re-sending
		-- or generating decisions.
		support.inbound(bctx, { ok = true, code = "practice_ok", role = "ai", recorded = true })
		bctx.clock.advance(1)
		ctx.eq(instance.update(0.016), "terminal")
		ctx.eq(#support.drain_outbound(bctx), 0, "no further frames after terminal")
		ctx.eq(instance.status().decisions, 0)
	end)

	test("human_host_start_is_not_resent_while_the_lobby_code_is_async", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", deferred_code = true })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		support.inbound(bctx, {
			ok = true,
			code = "practice_ok",
			role = "human",
			ruleset_id = "ruleset_mp_majorleague",
			gamemode = "gamemode_mp_attrition",
			forced_options = { "timer_base_seconds" },
			difficulty = "competitive",
			mode = "normal",
			pacing = "normal",
		})
		step(instance, bctx)
		-- The create is asynchronous: the code has not arrived yet.
		for _ = 1, 4 do
			step(instance, bctx)
		end
		ctx.eq(bctx.engine.start_lobby_calls, 1, "create_lobby is not resent every retry")
		ctx.eq(instance.lobby_code(), nil)
		-- The server finally answers with the real code.
		bctx.engine.complete_lobby("ABC12")
		step(instance, bctx)
		step(instance, bctx)
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.lobby_code ~= nil)
		ctx.eq(by_op.lobby_code.observation.lobby_code, "ABC12")
		ctx.eq(bctx.engine.start_lobby_calls, 1)
		instance.shutdown("test")
	end)

	test("coordinator_logs_why_the_host_is_waiting_once_per_change", function()
		local records = {}
		local logger = { record = function(fields)
			records[#records + 1] = fields
		end }
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", deferred_code = true, logger = logger })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		support.inbound(bctx, {
			ok = true,
			code = "practice_ok",
			role = "human",
			ruleset_id = "ruleset_mp_majorleague",
			gamemode = "gamemode_mp_attrition",
			forced_options = { "timer_base_seconds" },
			difficulty = "competitive",
			mode = "normal",
			pacing = "normal",
		})
		-- Not on the real main menu yet: the wait reason and engine enums are logged.
		bctx.engine.set_run()
		for _ = 1, 3 do
			step(instance, bctx)
		end
		local function waits(code)
			local found = {}
			for i = 1, #records do
				if records[i].event == "coordinator_wait" and records[i].code == code then
					found[#found + 1] = records[i]
				end
			end
			return found
		end
		local menu = waits("menu_not_ready")
		ctx.eq(#menu, 1, "logged once per change, not every tick")
		ctx.is_true(type(menu[1].detail) == "string" and menu[1].detail:find("st=", 1, true) ~= nil)
		ctx.eq(bctx.engine.start_lobby_calls, 0)
		-- The menu becomes ready: the host creates and then waits for the server code.
		bctx.engine.set_main_menu()
		for _ = 1, 3 do
			step(instance, bctx)
		end
		ctx.eq(bctx.engine.start_lobby_calls, 1)
		ctx.eq(#waits("lobby_code_awaiting_server"), 1)
		for i = 1, #records do
			if records[i].event == "coordinator_wait" then
				for key in pairs(records[i]) do
					ctx.is_true(key == "event" or key == "code" or key == "detail", "bounded fields only: " .. tostring(key))
				end
			end
		end
		instance.shutdown("test")
	end)

	test("describe_exposes_no_private_objects_or_secrets", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		local description = instance.describe()
		ctx.eq(rawget(description, "capability"), nil)
		ctx.eq(rawget(description, "broker"), nil)
		ctx.eq(rawget(description, "executor"), nil)
		ctx.eq(rawget(description, "credential"), nil)
		ctx.eq(rawget(description, "session"), nil)
		instance.shutdown("test")
	end)

	test("missing_guard_aborts_the_human_boot_before_lobby", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", no_client = true })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		ctx.eq(instance.state(), "stopped")
		ctx.eq(instance.status().last_error, "boot_guard_failed")
	end)

	local HAND_STATES = {
		SELECTING_HAND = 1, HAND_PLAYED = 2, DRAW_TO_HAND = 3, SHOP = 5, ROUND_EVAL = 8, BLIND_SELECT = 7,
	}

	test("mp_wait_state_only_trusts_grounded_mp_waits", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		ctx.eq(RuntimeBootstrap.mp_wait_state(nil, nil), nil)
		ctx.eq(RuntimeBootstrap.mp_wait_state({ GAME = {} }, { GAME = { current_round = { hands_left = 4 } } }), nil)
		ctx.eq(
			RuntimeBootstrap.mp_wait_state({ GAME = { ready_blind = true } }, { GAME = {} }),
			"mp_ready_blind"
		)
		-- Engine HIGH C: the real PvP no-hands wait is driven by the *current*
		-- blind and the hands counter, not by `pvp_reached` (which Multiplayer
		-- resets to false when the PvP blind starts). The source-visible PvP
		-- blind is `blind.pvp` (any non-nil/non-false value) or the pinned
		-- nemesis key.
		ctx.eq(
			RuntimeBootstrap.mp_wait_state(
				{ GAME = { pvp_reached = false } },
				{
					STATES = HAND_STATES,
					STATE = HAND_STATES.SELECTING_HAND,
					GAME = { current_round = { hands_left = 0 }, blind = { pvp = true } },
				}
			),
			"mp_pvp_no_hands"
		)
		ctx.eq(
			RuntimeBootstrap.mp_wait_state(
				{ GAME = { pvp_reached = false } },
				{
					STATES = HAND_STATES,
					STATE = HAND_STATES.HAND_PLAYED,
					GAME = {
						current_round = { hands_left = -1 },
						blind = { config = { blind = { key = "bl_mp_nemesis" } } },
					},
				}
			),
			"mp_pvp_no_hands"
		)
		ctx.eq(
			RuntimeBootstrap.mp_wait_state({ GAME = { pvp_countdown = 3 } }, { GAME = {} }),
			"mp_pvp_countdown"
		)
		-- A finished PvP round is not a wait, and a non-PvP blind with no hands is
		-- never a PvP wait even when pvp_reached is stale-true.
		ctx.eq(
			RuntimeBootstrap.mp_wait_state(
				{ GAME = { pvp_reached = true, round_ended = true } },
				{ GAME = { current_round = { hands_left = 0 }, blind = { pvp = true } } }
			),
			nil
		)
		ctx.eq(
			RuntimeBootstrap.mp_wait_state(
				{ GAME = { pvp_reached = true } },
				{ GAME = { current_round = { hands_left = 0 }, blind = { config = { blind = { key = "bl_small" } } } } }
			),
			nil
		)
	end)

	test("mp_pvp_no_hands_wait_ends_with_the_pvp_hand_loop", function()
		-- Claude review M1: after PvP, Multiplayer keeps the blind PvP through
		-- round evaluation and clears `end_pvp`; the wait must not hold there or in
		-- the shop, or the AI would never cash out or shop.
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local function probe(state_name, states)
			return RuntimeBootstrap.mp_wait_state(
				{ GAME = { end_pvp = false } },
				{
					STATES = states or HAND_STATES,
					STATE = (states or HAND_STATES)[state_name],
					GAME = { current_round = { hands_left = 0 }, blind = { pvp = true } },
				}
			)
		end
		for _, name in ipairs({ "SELECTING_HAND", "HAND_PLAYED", "DRAW_TO_HAND" }) do
			ctx.eq(probe(name), "mp_pvp_no_hands", name)
		end
		for _, name in ipairs({ "ROUND_EVAL", "SHOP", "BLIND_SELECT" }) do
			ctx.eq(probe(name), nil, name)
		end
		-- No readable engine state: never a wait (the policy is asked instead).
		ctx.eq(
			RuntimeBootstrap.mp_wait_state(
				{ GAME = {} },
				{ GAME = { current_round = { hands_left = 0 }, blind = { pvp = true } } }
			),
			nil
		)
	end)

	test("host_create_failure_is_fatal_and_never_recreated", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human" })
		-- Break the real forcing *before* the driver snapshots the callbacks:
		-- the lobby is created but no config keys are recorded. Once the create
		-- callback ran, this must be fatal, never a re-armed second createLobby.
		local creates = 0
		bctx.engine.G.FUNCS.start_lobby = function()
			creates = creates + 1
			bctx.engine.MP.LOBBY.code = "ABC12"
		end
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		support.inbound(bctx, {
			ok = true,
			code = "practice_ok",
			role = "human",
			ruleset_id = "ruleset_mp_majorleague",
			gamemode = "gamemode_mp_attrition",
			forced_options = { "timer_base_seconds" },
			difficulty = "competitive",
			mode = "normal",
			pacing = "normal",
		})
		step(instance, bctx)
		step(instance, bctx)
		step(instance, bctx)
		ctx.eq(instance.state(), "stopped")
		ctx.eq(instance.status().last_error, "driver_force_failed")
		ctx.eq(creates, 1, "createLobby is never re-sent after the real call")
	end)

	test("service_aborted_reply_stops_the_coordinator", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human" })
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		-- The SETUP reply carries the service's fatal abort.
		support.inbound(bctx, { ok = false, code = "practice_aborted" })
		step(instance, bctx)
		ctx.eq(instance.state(), "stopped")
		ctx.eq(instance.status().last_error, "practice_aborted")
	end)

	test("heartbeat_aborted_stops_the_runtime", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "human",
			auto_coordinate = false,
		})
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		-- With auto coordination off, the heartbeat is the only outstanding
		-- frame, so its aborted reply routes straight back to it.
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.heartbeat ~= nil)
		support.inbound(bctx, {
			ok = true,
			code = "practice_ok",
			role = "human",
			started = false,
			aborted = true,
		})
		step(instance, bctx)
		ctx.eq(instance.state(), "stopped")
		ctx.eq(instance.status().last_error, "practice_aborted")
	end)

	test("prestart_deadline_stops_an_uncompletable_coordination", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "human",
			auto_coordinate = false,
		})
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		bctx.clock.advance(RuntimeBootstrap.LIMITS.prestart_timeout + 1)
		local status, code = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(code, "boot_coord_timeout")
		ctx.eq(instance.status().last_error, "boot_coord_timeout")
	end)

	test("pvp_no_hands_wait_holds_the_loop_beyond_120s", function()
		local engine_support = support.engine_support(ctx.repo_root)

		local function build(pvp)
			local engine = support.engine(ctx.repo_root, {
				state = engine_support.STATES.HAND_PLAYED,
				blind_on_deck = "Boss",
				hands_left = 0,
				blind_pvp = pvp or nil,
				blind_key = pvp and "bl_mp_nemesis" or "bl_small",
			})
			support.shape_mp(engine, { code = "ABC12" })
			-- The guest applies the host's lobby configuration locally; the AI's
			-- source-derived digest reads these live values.
			engine.MP.LOBBY.config.timer_base_seconds = 180
			return support.bootstrap(ctx.repo_root, { role = "ai", engine = engine })
		end

		-- Ordered mini-responder: every pushed frame gets exactly one reply so
		-- the real service ordering invariant holds.
		local function respond_all(bctx)
			local messages = support.drain_outbound(bctx)
			for _, message in ipairs(messages) do
				local op = message.op
				if op == "hello" then
					support.inbound(bctx, { ok = true, code = "practice_ok" })
				elseif op == "setup" then
					support.inbound(bctx, {
						ok = true,
						code = "practice_ok",
						role = "ai",
						ruleset_id = "ruleset_mp_majorleague",
						gamemode = "gamemode_mp_attrition",
						forced_options = { "timer_base_seconds" },
						difficulty = "competitive",
						mode = "normal",
						pacing = "normal",
					})
				elseif op == "join_code" then
					support.inbound(bctx, { ok = true, code = "practice_ok", lobby_code = "ABC12" })
				elseif op == "ready" then
					support.inbound(bctx, { ok = true, code = "practice_ok", role = "ai" })
				elseif op == "start" then
					support.inbound(bctx, { ok = true, code = "practice_ok", started = true })
				else
					support.inbound(bctx, { ok = true, code = "practice_ok" })
				end
			end
		end

		local function coordinated(pvp)
			local instance, _, bctx = build(pvp)
			instance.install()
			step(instance, bctx)
			respond_all(bctx)
			for _ = 1, 40 do
				step(instance, bctx)
				respond_all(bctx)
				if instance.describe().coordinated then
					break
				end
			end
			return instance, bctx
		end

		-- Control: a non-PvP blind with no hands is not a trusted wait, so the
		-- loop's own 120 s transient window ends the AI.
		local control, control_ctx = coordinated(false)
		ctx.is_true(control.describe().coordinated, "control coordinated")
		for _ = 1, 140 do
			step(control, control_ctx)
			respond_all(control_ctx)
		end
		ctx.eq(control.state(), "stopped", "unverified no-hands stall still aborts")

		-- PvP: the current blind really is the PvP blind and the AI is waiting for
		-- the human's turn (`pvp_reached` is false post-start). The trusted wait
		-- keeps the loop alive well beyond its 120 s transient budget.
		local pvp, pvp_ctx = coordinated(true)
		ctx.is_true(pvp.describe().coordinated, "pvp coordinated")
		for _ = 1, 200 do
			step(pvp, pvp_ctx)
			respond_all(pvp_ctx)
		end
		ctx.eq(pvp.state(), "active", "PvP no-hands wait does not end the AI")
	end)

	test("install_hooks_preserves_returns_and_exceptions", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local bumps = 0
		local revision = {
			bump = function()
				bumps = bumps + 1
			end,
		}
		local owner = {
			combine = function(a, b)
				return a + b, "extra"
			end,
			fail = function()
				error("boom")
			end,
		}
		local restore = RuntimeBootstrap.install_hooks({
			{ table = owner, name = "combine", reason = "card_change" },
			{ table = owner, name = "fail", reason = "card_change" },
		}, revision)
		local first, second = owner.combine(2, 3)
		ctx.eq(first, 5)
		ctx.eq(second, "extra")
		ctx.eq(bumps, 1)
		local ok = pcall(owner.fail)
		ctx.eq(ok, false)
		ctx.eq(bumps, 1, "failed callback never bumps")
		restore()
		owner.combine(1, 1)
		ctx.eq(bumps, 1, "restored original no longer bumps")
	end)
end
