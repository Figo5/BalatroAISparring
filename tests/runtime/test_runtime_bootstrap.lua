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

	-- Generic fixtures explicitly choose the legacy Major League registry; the
	-- production default Standard Ranked driver is exercised by the ranked tests
	-- and the actual core boot fixture.
	local LEGACY_RULESET = { ruleset_key = "ruleset_mp_majorleague", ruleset_short = "majorleague" }

	local function legacy_bootstrap(overrides)
		local merged = {}
		for key, value in pairs(LEGACY_RULESET) do
			merged[key] = value
		end
		for key, value in pairs(overrides or {}) do
			merged[key] = value
		end
		return support.bootstrap(ctx.repo_root, merged)
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
		local instance, _, bctx = legacy_bootstrap({ role = "human" })
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
		local instance, _, bctx = legacy_bootstrap({ role = "human", started = false })
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
		local instance, _, bctx = legacy_bootstrap({ role = "human" })
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
		local instance, _, bctx = legacy_bootstrap({ role = "human", deferred_code = true })
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
		local instance, _, bctx = legacy_bootstrap({ role = "ai", started = false })
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
		local instance, _, bctx = legacy_bootstrap({ role = "human" })
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
		ctx.eq(bctx.engine.G.SETTINGS.GAMESPEED, nil, "human speed preference untouched")
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
		ctx.eq(bctx.engine.G.SETTINGS.GAMESPEED, 4, "authenticated staged AI uses legal 4x")
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

	test("idle_cooldown_frames_do_not_inflate_rejected_receipts", function()
		-- H3 regression: the runtime no longer counts every idle loop frame as a
		-- rejection. A legitimate policy no-action backs the loop off; the
		-- following cooldown frames are idle and must leave `rejected` at 0.
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		ctx.eq(instance.update(0.016), "active")
		drain_envelopes(bctx)
		-- A delivered, non-refusal answer (no-action) is not a rejected decision.
		support.inbound(bctx, { ok = false, code = "policy_no_action" })
		instance.update(0.016)
		ctx.eq(instance.status().rejected, 0, "a no-action is not a refused decision")
		for _ = 1, 30 do
			instance.update(0.016)
		end
		ctx.eq(instance.status().rejected, 0, "idle cooldown frames are not rejections")
		ctx.eq(instance.status().counter_version, 2, "versioned receipt-counter semantics")
		instance.shutdown("test")
	end)

	-- Deliver a service decision reply on the fake worker channel. The transport
	-- routes it to the owned decision by its ordered inflight slot.
	local function decision_reply(fields)
		local reply = { ok = true, code = "practice_decision_ready" }
		for key, value in next, fields do
			reply[key] = value
		end
		return reply
	end

	local function count_receipts(bctx)
		local messages = support.drain_outbound(bctx)
		local total, rejected = 0, 0
		for _, message in ipairs(messages) do
			if type(message) == "table" and message.op == "decision_result" then
				total = total + 1
				local observation = message.observation
				if type(observation) == "table" and observation.accepted == false then
					rejected = rejected + 1
				end
			end
		end
		return total, rejected
	end

	local function activate_ai(opts)
		opts = opts or {}
		local instance, _, bctx = legacy_bootstrap({
			role = "ai",
			lobby_code = "ABC12",
			dwell = opts.dwell,
			pacing = opts.pacing,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		ctx.eq(instance.update(0.016), "active")
		drain_envelopes(bctx)
		-- Confirm SETUP so the owned decision is the oldest inflight frame; a
		-- delivered decision reply then routes to that decision rather than to a
		-- preceding coordination op.
		if (opts.pacing or "normal") == "normal" then
			setup_ok(bctx, "ai")
			instance.update(0.016)
			drain_envelopes(bctx)
		end
		return instance, bctx
	end

	test("a_delivered_stale_decision_counts_once_despite_many_updates", function()
		local instance, bctx = activate_ai()
		-- The loop issued a decision and captured at the current epoch; move the
		-- engine state so the delivered action can no longer be valid.
		bctx.engine.G.GAME.dollars = 999
		support.inbound(bctx, decision_reply({ action = { type = "SELECT_BLIND", id = "b1" }, reason = "r" }))
		instance.update(0.016)
		ctx.eq(instance.status().rejected, 1, "the delivered stale is counted once")
		local total, rejected = count_receipts(bctx)
		ctx.eq(rejected, 1, "exactly one rejection receipt")
		-- A hundred-plus further idle/dwell/transient updates must not re-count it.
		for _ = 1, 120 do
			instance.update(0.016)
		end
		ctx.eq(instance.status().rejected, 1, "no re-count through repeated updates")
		local _, more_rejected = count_receipts(bctx)
		ctx.eq(more_rejected, 0, "no further rejection receipt")
		instance.shutdown("test")
	end)

	test("a_dispatch_failed_decision_counts_once", function()
		local instance, bctx = activate_ai()
		-- A delivered action that is not a current candidate fails validation.
		support.inbound(bctx, decision_reply({ action = { type = "SELECT_BLIND", id = "bogus" }, reason = "r" }))
		instance.update(0.016)
		ctx.eq(instance.status().rejected, 1, "dispatch failure counted once")
		local total, rejected = count_receipts(bctx)
		ctx.eq(rejected, 1)
		instance.shutdown("test")
	end)

	test("a_response_rejected_decision_counts_once", function()
		local instance, bctx = activate_ai()
		support.inbound(bctx, { ok = false, code = "practice_bad_payload" })
		instance.update(0.016)
		ctx.eq(instance.status().rejected, 1, "response rejection counted once")
		local total, rejected = count_receipts(bctx)
		ctx.eq(rejected, 1)
		instance.shutdown("test")
	end)

	test("an_out_of_order_decision_code_is_not_counted", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		-- Unsolicited decision reply with no owned inflight slot.
		support.inbound(bctx, { ok = true, code = "practice_decision_ready", action = { type = "SELECT_BLIND", id = "b1" } })
		instance.update(0.016)
		for _ = 1, 20 do
			instance.update(0.016)
		end
		ctx.eq(instance.status().rejected, 0, "an out-of-order reply is never a counted refusal")
		instance.shutdown("test")
	end)

	test("the_final_refusal_before_a_stop_is_still_counted_once", function()
		-- Default max_consecutive_errors is 3: three delivered dispatch failures
		-- reach the stop. The third still counts and is receipted (L3), even
		-- though the loop returns "stopped" rather than "idle". Auto-coordination
		-- is off so the only coordination frame is the single startup heartbeat and
		-- the owned decision is the oldest inflight frame at each delivery.
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			lobby_code = "ABC12",
			auto_coordinate = false,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		ctx.eq(instance.update(0.016), "active")
		drain_envelopes(bctx)
		local reply = decision_reply({ action = { type = "SELECT_BLIND", id = "bogus" }, reason = "r" })
		support.inbound(bctx, reply)
		instance.update(0.016)
		ctx.eq(instance.status().rejected, 1)
		-- Re-issue, then clear the heartbeat and the previous receipt's inflight
		-- slot ahead of the next decision (with auto-coordination off these are
		-- the only coordination/result frames).
		instance.update(0.016)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		support.inbound(bctx, reply)
		instance.update(0.016)
		ctx.eq(instance.status().rejected, 2)
		-- Re-issue and deliver the refusal that exhausts the error budget.
		instance.update(0.016)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		support.inbound(bctx, reply)
		ctx.eq(instance.update(0.016), "stopped", "the third refusal stops the loop")
		ctx.eq(instance.status().rejected, 3, "the final refusal is counted once")
		local _, rejected = count_receipts(bctx)
		ctx.eq(rejected, 3, "three rejection receipts")
		instance.shutdown("test")
	end)

	test("bootstrap_wires_the_readiness_probe_only_with_dwell", function()
		local dwell = { blind = 2, card = 4, pvp = 4, shop = 6, shop_first = 8, booster = 4, control = 0 }
		local normal, _ = activate_ai({ dwell = dwell })
		ctx.eq(normal.describe().loop_has_readiness, true, "Normal + dwell wires the probe")
		normal.shutdown("test")
		local instant, _ = activate_ai({ dwell = dwell, pacing = "instant" })
		ctx.eq(instant.describe().loop_has_readiness, false, "Instant never wires the probe")
		instant.shutdown("test")
		local legacy, _ = activate_ai({})
		ctx.eq(legacy.describe().loop_has_readiness, false, "no dwell port keeps the legacy path")
		legacy.shutdown("test")
	end)

	test("a_locked_decision_gives_full_thinking_time_after_readiness", function()
		local dwell = { blind = 2, card = 4, pvp = 4, shop = 6, shop_first = 8, booster = 4, control = 0 }
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12", dwell = dwell })
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		-- The decision is live (BLIND_SELECTION) but the engine is mid-animation:
		-- the controller is locked from before activation. No capture and no
		-- decision may be issued, and the thinking clock must not run.
		bctx.engine.G.CONTROLLER.locked = true
		ctx.eq(instance.update(0.016), "active")
		drain_envelopes(bctx)
		for _ = 1, 20 do
			instance.update(0.016)
			bctx.clock.advance(0.25) -- five seconds of animation
		end
		local _, locked_ops = drain_envelopes(bctx)
		ctx.eq(locked_ops.decide_begin, nil, "no decision while locked")
		ctx.eq(instance.status().decisions, 0)
		-- Readiness arrives: the full 2 s blind dwell starts now, not earlier.
		bctx.engine.G.CONTROLLER.locked = false
		instance.update(0.016)
		local _, first = drain_envelopes(bctx)
		ctx.eq(first.decide_begin, nil, "the dwell starts at readiness, not an immediate issue")
		bctx.clock.advance(1.9)
		instance.update(0.016)
		local _, mid = drain_envelopes(bctx)
		ctx.eq(mid.decide_begin, nil, "still inside the 2s dwell")
		bctx.clock.advance(0.2)
		instance.update(0.016)
		local _, ready_ops = drain_envelopes(bctx)
		ctx.is_true(ready_ops.decide_begin ~= nil, "issues only after the full dwell from readiness")
		instance.shutdown("test")
	end)

	test("a_persistent_overlay_never_stops_or_leaves_the_lobby", function()
		-- A1: an informational Multiplayer overlay (e.g. "Reconnected!") the AI
		-- cannot dismiss must gate the thinking clock only. It must never end the
		-- match, even after 120 s. A decision phase with no legal candidate (an
		-- empty hand) isolates the overlay hold from request timeouts, and the
		-- ordered responder completes the pre-start coordination so the only
		-- deadline in play is the overlay hold itself.
		local dwell = { blind = 2, card = 4, pvp = 4, shop = 6, shop_first = 8, booster = 4, control = 0 }
		local engine_support = support.engine_support(ctx.repo_root)
		local engine = support.engine(ctx.repo_root, { state = engine_support.STATES.SELECTING_HAND })
		support.shape_mp(engine, { code = "ABC12", ruleset_key = "ruleset_mp_majorleague", ruleset_short = "majorleague" })
		engine.MP.LOBBY.config.timer_base_seconds = 180
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", engine = engine, dwell = dwell,
			ruleset_key = "ruleset_mp_majorleague", ruleset_short = "majorleague",
		})
		local function respond_all()
			for _, message in ipairs(support.drain_outbound(bctx)) do
				local op = message.op
				if op == "setup" then
					support.inbound(bctx, {
						ok = true, code = "practice_ok", role = "ai",
						ruleset_id = "ruleset_mp_majorleague", gamemode = "gamemode_mp_attrition",
						forced_options = { "timer_base_seconds" }, difficulty = "competitive",
						mode = "normal", pacing = "normal",
					})
				elseif op == "join_code" then
					support.inbound(bctx, { ok = true, code = "practice_ok", lobby_code = "ABC12" })
				else
					support.inbound(bctx, { ok = true, code = "practice_ok", role = "ai", started = true })
				end
			end
		end
		ctx.is_true(instance.install())
		step(instance, bctx)
		respond_all()
		for _ = 1, 60 do
			step(instance, bctx)
			respond_all()
			if instance.describe().coordinated then
				break
			end
		end
		ctx.is_true(instance.describe().coordinated, "pre-start coordination completed")
		bctx.engine.G.OVERLAY_MENU = { id = "mp_info" }
		for _ = 1, 130 do
			bctx.clock.advance(1)
			instance.update(0.016)
		end
		ctx.eq(instance.state(), "active", "a persistent overlay must not stop the runtime")
		ctx.eq(instance.status().last_error, nil, "no loop_not_ready under an overlay")
		local stats = instance.describe().loop_stats
		ctx.is_true(stats ~= nil and stats.not_ready == 0, "soft frames never count toward the fatal window")
		ctx.is_true(stats ~= nil and stats.overlay_idle > 0, "the overlay gated the thinking clock")
		ctx.is_true(stats ~= nil and stats.empty > 0, "the AI acted under the overlay after the grace")
		instance.shutdown("test")
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

	test("terminal_late_success_replies_never_rearm_or_teardown", function()
		local original_send = function()
			return true
		end
		local client = { send = original_send }
		local leave_calls = 0
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			client = client,
			terminal_probe = function()
				return "win"
			end,
		})
		bctx.engine.MP.LOBBY.code = "ABC12"
		bctx.engine.MP.ACTIONS.leave_lobby = function()
			leave_calls = leave_calls + 1
		end
		instance.install()
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		ctx.eq(instance.update(0.016), "terminal")
		drain_envelopes(bctx)
		ctx.is_true(client.send ~= original_send, "send guard installed for the terminal run")
		local guard = client.send

		local late = {
			{ op = "hello", ok = true, code = "practice_ok" },
			{
				op = "setup", ok = true, code = "practice_ok",
				ruleset_id = "ruleset_mp_standard_ranked", gamemode = "gamemode_mp_attrition",
				forced_options = { "timer_base_seconds" }, role = "ai",
				difficulty = "competitive", mode = "normal", pacing = "normal",
			},
			{ op = "ready", ok = true, code = "practice_ok" },
			{ op = "start", ok = true, code = "practice_ok" },
			{ op = "join_code", ok = true, code = "practice_ok", lobby_code = "ABC12" },
			{ op = "lobby_code", ok = false, code = "practice_bad_payload" },
			{ op = "heartbeat", ok = true, code = "practice_ok", aborted = true },
		}
		for _, reply in ipairs(late) do
			-- CLOSED then a successful reply in the same batch, then across updates.
			support.inbound(bctx, { op = "status", ok = false, code = "practice_closed" })
			support.inbound(bctx, reply)
			bctx.clock.advance(1)
			ctx.eq(instance.update(0.016), "terminal")
		end
		for _, code in ipairs({ "practice_closed", "practice_ended", "practice_aborted" }) do
			support.inbound(bctx, { op = "status", ok = false, code = code })
			bctx.clock.advance(1)
			ctx.eq(instance.update(0.016), "terminal")
		end
		ctx.eq(instance.state(), "terminal", "terminal state remains sticky")
		ctx.eq(instance.status().decisions, 0, "no decisions after terminal")
		ctx.eq(#support.drain_outbound(bctx), 0, "no frames after terminal")
		ctx.eq(client.send, guard, "send guard retained")
		ctx.eq(leave_calls, 0, "leave_local/host teardown never called")
		ctx.eq(bctx.engine.MP.LOBBY.code, "ABC12", "lobby left untouched")
		ctx.eq(instance.status().errors, 0, "dropped terminal replies are not failures")
		instance.shutdown("test")
	end)

	test("terminal_owned_late_hello_ack_never_rearms", function()
		-- Terminal can precede the original owned HELLO ack. The real in-memory
		-- worker channel then delivers it through the genuine inflight routing.
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			terminal_probe = function()
				return "win"
			end,
		})
		instance.install()
		local requests = support.drain_outbound(bctx)
		ctx.eq(requests[1].op, "hello")
		ctx.eq(instance.update(0.016), "terminal")
		support.drain_outbound(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		bctx.clock.advance(1)
		ctx.eq(instance.update(0.016), "terminal")
		ctx.eq(instance.state(), "terminal", "owned late HELLO ack never re-arms")
		ctx.eq(instance.status().decisions, 0)
		instance.shutdown("test")
	end)

	test("terminal_end_ack_consumed_and_timeout_recorded_once", function()
		local acked, _, acked_ctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			terminal_probe = function()
				return "win"
			end,
		})
		acked.install()
		drain_envelopes(acked_ctx)
		support.inbound(acked_ctx, { ok = true, code = "practice_ok" })
		ctx.eq(acked.update(0.016), "terminal")
		drain_envelopes(acked_ctx)
		support.inbound(acked_ctx, { op = "end", ok = true, code = "practice_ok" })
		acked_ctx.clock.advance(121)
		ctx.eq(acked.update(0.016), "terminal")
		ctx.eq(acked.status().errors, 0, "an acked END records no timeout")
		acked.shutdown("test")

		local silent, _, silent_ctx = support.bootstrap(ctx.repo_root, {
			role = "ai",
			terminal_probe = function()
				return "win"
			end,
		})
		silent.install()
		drain_envelopes(silent_ctx)
		support.inbound(silent_ctx, { ok = true, code = "practice_ok" })
		ctx.eq(silent.update(0.016), "terminal")
		drain_envelopes(silent_ctx)
		silent_ctx.clock.advance(121)
		ctx.eq(silent.update(0.016), "terminal")
		ctx.eq(silent.status().errors, 1, "a missing END ack records exactly one timeout")
		silent_ctx.clock.advance(121)
		ctx.eq(silent.update(0.016), "terminal")
		ctx.eq(silent.status().errors, 1, "the timeout is never re-recorded")
		silent.shutdown("test")
	end)

	test("human_host_start_is_not_resent_while_the_lobby_code_is_async", function()
		local instance, _, bctx = legacy_bootstrap({ role = "human", deferred_code = true })
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
		local instance, _, bctx = legacy_bootstrap({ role = "human", deferred_code = true, logger = logger })
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
		local instance, _, bctx = legacy_bootstrap({ role = "human" })
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
			support.shape_mp(engine, { code = "ABC12", ruleset_key = "ruleset_mp_majorleague", ruleset_short = "majorleague" })
			-- The guest applies the host's lobby configuration locally; the AI's
			-- source-derived digest reads these live values.
			engine.MP.LOBBY.config.timer_base_seconds = 180
			return support.bootstrap(ctx.repo_root, {
				role = "ai", engine = engine,
				ruleset_key = "ruleset_mp_majorleague", ruleset_short = "majorleague",
			})
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

	test("state_edge_observer_is_honest_sampled_diagnostic", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local stages = { MAIN_MENU = 1, RUN = 2 }
		local observed = nil
		local function observe(connected, enemy_countdown, self_countdown, stage, started)
			local mp = {
				LOBBY = { connected = connected, code = "ABC12" },
				enemy_disconnect_countdown = enemy_countdown,
				self_reconnect_countdown = self_countdown,
			}
			local g = { STAGES = stages, STAGE = stage }
			local next_state = RuntimeBootstrap.observe_state_edges(observed, mp, g, started)
			local delta = {
				enemy = next_state.enemy_edge,
				reconnect = next_state.reconnect_edge,
				stop = next_state.stop_edge,
			}
			observed = next_state
			return delta
		end

		local delta = observe(true, nil, nil, stages.RUN, true)
		ctx.eq(delta.enemy, 0)
		ctx.eq(delta.reconnect, 0)
		ctx.eq(delta.stop, 0)

		delta = observe(true, { end_time = 5 }, nil, stages.RUN, true)
		ctx.eq(delta.enemy, 1)
		delta = observe(true, { end_time = 5 }, nil, stages.RUN, true)
		ctx.eq(delta.enemy, 0)
		delta = observe(true, nil, nil, stages.RUN, true)
		ctx.eq(delta.enemy, 0)

		delta = observe(false, nil, { end_time = 6 }, stages.RUN, true)
		ctx.eq(delta.reconnect, 1)
		delta = observe(false, nil, { end_time = 6 }, stages.RUN, true)
		ctx.eq(delta.reconnect, 0)
		delta = observe(true, nil, nil, stages.RUN, true)
		ctx.eq(delta.reconnect, 0)

		delta = observe(true, nil, nil, stages.MAIN_MENU, true)
		ctx.eq(delta.stop, 1)
		delta = observe(true, nil, nil, stages.MAIN_MENU, true)
		ctx.eq(delta.stop, 0)

		-- A manual start/normal terminal (RUN stage retained) never produces an edge.
		local state = RuntimeBootstrap.observe_state_edges(nil, { LOBBY = { connected = true, code = "ABC12" } }, { STAGES = stages, STAGE = stages.RUN }, true)
		ctx.eq(state.match, true)
		local next_state = RuntimeBootstrap.observe_state_edges(state, { LOBBY = { connected = true, code = "ABC12" } }, { STAGES = stages, STAGE = stages.RUN }, true)
		ctx.eq(next_state.stop_edge, 0)
		local idle = RuntimeBootstrap.observe_state_edges(nil, { LOBBY = { connected = true, code = "ABC12" } }, { STAGES = stages, STAGE = stages.RUN }, false)
		ctx.eq(idle.match, false)
		ctx.eq(idle.stop_edge, 0)
		local nomp = RuntimeBootstrap.observe_state_edges(nil, nil, { STAGES = stages, STAGE = stages.RUN }, true)
		ctx.eq(nomp.enemy_edge, 0)
		ctx.eq(nomp.reconnect_edge, 0)
		ctx.eq(nomp.stop_edge, 0)
	end)

	test("inbound_tap_counts_actual_parsed_actions_and_is_human_only", function()
		-- The unattended AI runtime never installs the observer tap.
		local ai = support.bootstrap(ctx.repo_root, { role = "ai" })
		ai.install()
		ctx.eq(AISP_INBOUND_TAP, nil, "AI runtime leaves the tap nil")
		ai.shutdown("test")

		local human = support.bootstrap(ctx.repo_root, { role = "human" })
		human.install()
		ctx.is_true(type(AISP_INBOUND_TAP) == "function", "human runtime installs the observer tap")
		-- The tap receives only an action name, returns nothing, counts each
		-- occurrence of exactly the three known real actions, and keeps a bounded
		-- total of every parsed action string (liveness, incl. innocuous traffic).
		ctx.eq(AISP_INBOUND_TAP("enemyDisconnected"), nil)
		AISP_INBOUND_TAP("enemyDisconnected")
		AISP_INBOUND_TAP("stopGame")
		AISP_INBOUND_TAP("reconnecting")
		AISP_INBOUND_TAP("keepAlive")
		AISP_INBOUND_TAP("enemyInfo")
		AISP_INBOUND_TAP("somethingElse")
		AISP_INBOUND_TAP(nil)
		local status = human.status()
		local events = status.inbound_events
		ctx.eq(events.enemyDisconnected, 2)
		ctx.eq(events.stopGame, 1)
		ctx.eq(events.reconnecting, 1)
		ctx.eq(events.somethingElse, nil)
		ctx.eq(status.inbound_seen, 7, "total observed strings (nil and empty never count)")
		ctx.eq(status.inbound_tap, true)
		local described = human.describe()
		ctx.eq(described.inbound_events.enemyDisconnected, 2)
		ctx.eq(described.inbound_seen, 7)
		ctx.eq(described.inbound_tap, true)
		ctx.is_true(described.state_edges ~= nil and described.state_edges.enemy_disconnected == 0)
		human.shutdown("test")
		ctx.eq(AISP_INBOUND_TAP, nil, "tap is cleared on shutdown")
	end)

	test("inbound_tap_shutdown_preserves_a_foreign_replacement", function()
		local human = support.bootstrap(ctx.repo_root, { role = "human" })
		human.install()
		local foreign = function()
			return "not ours"
		end
		AISP_INBOUND_TAP = foreign
		human.shutdown("test")
		ctx.eq(AISP_INBOUND_TAP, foreign, "a foreign replacement is never deleted by our shutdown")
		AISP_INBOUND_TAP = nil
	end)

	test("inbound_snapshot_survives_real_logger_and_brackets_retention", function()
		local Logger = support.mod(ctx.repo_root, "AISparring/src/logger.lua")
		local lines = {}
		local real = Logger.new(function(_, line)
			lines[#lines + 1] = line
		end)
		-- The production core-shaped bridge: record -> inner:log(level, event, fields).
		local bridge = {
			record = function(fields)
				return real:log("info", fields.event or "companion", fields)
			end,
		}
		-- A directly controllable monotonic clock so nonfinite times can be driven.
		local clock_state = { t = 1000 }
		local clock = {
			now = function()
				return clock_state.t
			end,
		}
		local terminal = false
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "human",
			logger = bridge,
			clock = clock,
			terminal_probe = function()
				if terminal then
					return "win"
				end
			end,
		})
		instance.install()
		ctx.is_true(type(AISP_INBOUND_TAP) == "function")

		local function snapshot_lines(from)
			local found = {}
			for i = from or 1, #lines do
				if lines[i]:find('event="mp_inbound_snapshot"', 1, true) then
					found[#found + 1] = lines[i]
				end
			end
			return found
		end
		local function value_for(group, action)
			for _, line in ipairs(group) do
				if line:find('action="' .. action .. '"', 1, true) then
					return line
				end
			end
			return nil
		end

		-- (a) installed before any dispatch: owned + unseen.
		local installed = snapshot_lines(1)
		local installed_observer = value_for(installed, "observer")
		ctx.is_true(
			installed_observer ~= nil
				and installed_observer:find('status="installed"', 1, true) ~= nil
				and installed_observer:find('count="0"', 1, true) ~= nil,
			"installed snapshot is owned+unseen"
		)

		-- (b) alive after actual observed traffic.
		AISP_INBOUND_TAP("keepAlive")
		AISP_INBOUND_TAP("enemyInfo")
		AISP_INBOUND_TAP("enemyDisconnected")
		support.drain_outbound(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		terminal = true
		ctx.eq(instance.update(0.016), "terminal")
		local open = {}
		for _, line in ipairs(snapshot_lines(1)) do
			if line:find('phase="open"', 1, true) then
				open[#open + 1] = line
			end
		end
		local enemy = value_for(open, "enemyDisconnected")
		ctx.is_true(enemy ~= nil and enemy:find('count="1"', 1, true) ~= nil, "enemyDisconnected=1 survived")
		local stop = value_for(open, "stopGame")
		ctx.is_true(stop ~= nil and stop:find('count="0"', 1, true) ~= nil, "zero counts survive serialization")
		local observer = value_for(open, "observer")
		ctx.is_true(
			observer ~= nil
				and observer:find('status="alive"', 1, true) ~= nil
				and observer:find('count="3"', 1, true) ~= nil
				and observer:find('seconds="1000"', 1, true) ~= nil,
			"observer alive + finite total seen"
		)

		-- (c) nonfinite clocks are never serialized and never poison the cadence.
		local anchor = #lines
		clock_state.t = math.huge
		ctx.eq(instance.update(0.016), "terminal")
		clock_state.t = -math.huge
		ctx.eq(instance.update(0.016), "terminal")
		for i = anchor + 1, #lines do
			ctx.is_true(lines[i]:find('seconds="inf"', 1, true) == nil, "no +inf seconds")
			ctx.is_true(lines[i]:find('seconds="-inf"', 1, true) == nil, "no -inf seconds")
			ctx.is_true(lines[i]:find('seconds="nan"', 1, true) == nil, "no nan seconds")
		end
		-- back to finite time: honest cadence resumes from the finite anchor.
		clock_state.t = 1030
		ctx.eq(instance.update(0.016), "terminal")
		local resumed = false
		for i = anchor + 1, #lines do
			if lines[i]:find('phase="retained"', 1, true) and lines[i]:find('seconds="1030"', 1, true) then
				resumed = true
			end
		end
		ctx.is_true(resumed, "finite clock resumes periodic snapshots")
		local quiet = #lines
		instance.update(0.016)
		ctx.eq(#lines, quiet, "no per-frame snapshot flood")

		-- (d) a displaced tap freezes counters and is reported displaced.
		local foreign = function()
			return "not ours"
		end
		AISP_INBOUND_TAP = foreign
		ctx.eq(instance.status().inbound_tap, false, "status reflects actual owned identity")
		ctx.eq(instance.describe().inbound_tap, false, "describe reflects actual owned identity")
		clock_state.t = 1061
		ctx.eq(instance.update(0.016), "terminal")
		local displaced = false
		for i = quiet + 1, #lines do
			if lines[i]:find('phase="retained"', 1, true) and lines[i]:find('status="displaced"', 1, true) then
				displaced = true
			end
		end
		ctx.is_true(displaced, "displaced tap reported, not alive")

		-- (e) shutdown preserves the foreign tap and serializes absent + final.
		instance.shutdown("test")
		ctx.eq(AISP_INBOUND_TAP, foreign, "foreign replacement preserved on shutdown")
		local final, closed = false, false
		for _, line in ipairs(lines) do
			if line:find('event="mp_inbound_snapshot"', 1, true) then
				if line:find('phase="final"', 1, true) then
					final = true
				end
				if line:find('phase="closed"', 1, true) and line:find('status="absent"', 1, true) then
					closed = true
				end
			end
		end
		ctx.is_true(final, "final snapshot survives shutdown")
		ctx.is_true(closed, "absent status serialized after shutdown")
		AISP_INBOUND_TAP = nil
	end)

	-- Ranked effective-config contract carried through Setup/Ready.

	local RANKED_SCHEMA = "aisparring.ranked_effective_config.v1"
	local RANKED_SELECTION = {
		schema = "aisparring.ranked_selection.v1",
		deck_key = "red", back_key = "b_red", back_name = "Red Deck",
		stake_key = "white", stake_index = 1,
	}
	-- A fixture readiness port simulating later verified facts (unavailable to a
	-- menu/service actor). The real readers are covered by the driver tests.
	local READINESS_OK = {}
	for _, key in ipairs({
		"unlock_check", "all_unlocked", "advertised_unlocked", "advertised_preview",
		"advertised_preview_valid", "live_preview", "preview_consistent",
		"peer_unlocked", "peer_cached", "banned_mods_empty", "mods_approved",
		"release_mode", "game_speed_ok", "debug_disabled", "animations_normal", "handy_ranked_safe",
	}) do
		READINESS_OK[key] = true
	end

	-- The dedicated completed-draft commitment, matching RANKED_SELECTION's
	-- final option ("red~white" -> Red Deck / White Stake). It is mandatory
	-- under the Ranked schema.
	local RANKED_DRAFT = {
		schema = "aisparring.ranked_draft.v1",
		profile_id = "aisparring.ranked_draft_profile.standard_1_2_2.v1",
		first_actor = "human",
		pool = {
			"blue~green", "blue~black", "green~green", "green~black", "yellow~green",
			"red~white", "black~green", "black~black", "yellow~black",
		},
		transcript = {
			{ actor = "human", operation = "ban", option_ids = { "blue~green" } },
			{ actor = "ai", operation = "ban", option_ids = { "blue~black", "green~green" } },
			{ actor = "human", operation = "ban", option_ids = { "green~black", "yellow~green" } },
			{ actor = "ai", operation = "select", option_ids = { "red~white" } },
		},
		final = "red~white",
	}

	local function ranked_setup(bctx, extra)
		local response = {
			op = "setup", ok = true, code = "practice_ok", role = "ai",
			ruleset_id = "ruleset_mp_standard_ranked", gamemode = "gamemode_mp_attrition",
			config_schema = RANKED_SCHEMA,
			-- The Ranked path carries no forced-keyset; the runtime reads the
			-- actual layered configuration itself.
			forced_options = {},
			-- The validated host-owned selection and its completed draft
			-- commitment are both mandatory under Ranked.
			selection = RANKED_SELECTION,
			draft = RANKED_DRAFT,
			-- A deliberately wrong service expected digest: the runtime must
			-- never echo it as its own binding.
			expected_config_digest = "deadbeef",
			difficulty = "competitive", mode = "normal", pacing = "normal",
		}
		for key, value in pairs(extra or {}) do
			response[key] = value
		end
		support.inbound(bctx, response)
	end

	test("ranked_async_host_start_never_checks_old_menu_selection_or_seed", function()
		local notes = {}
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "human", readiness_override = READINESS_OK,
			logger = { record = function(fields) notes[#notes + 1] = tostring(fields.code or fields.event) end } })
		local G = bctx.engine.G
		local start_requests = 0
		G.FUNCS.lobby_start_game = function() start_requests = start_requests + 1 end
		G.GAME.selected_back = { effect = { center = { key = "b_blue" } } }
		G.GAME.stake = 3
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		for _ = 1, 24 do
			step(instance, bctx)
			bctx.engine.MP.LOBBY.ready_to_start = true
			for _, message in ipairs(support.drain_outbound(bctx)) do
				if message.op == "setup" then
					ranked_setup(bctx, { role = "human" })
				else
					support.inbound(bctx, { ok = true, code = "practice_ok", started = message.op == "start" })
				end
				ctx.eq(message.observation and message.observation.seed, nil, "old menu seed never reported")
			end
		end
		ctx.eq(start_requests, 1, "start request sent exactly once: " .. table.concat(notes, ","))
		ctx.is_true(instance.state() ~= "stopped", "old Blue/Green menu selection must not abort Red/White draft")
		ctx.eq(bctx.engine.MP.LOBBY.code, "ABC12", "lobby remains joined")
		G.GAME.selected_back = { effect = { center = { key = "b_red" } } }
		G.GAME.stake = 1
		bctx.engine.set_run()
		for _ = 1, 3 do step(instance, bctx) end
		ctx.is_true(instance.state() ~= "stopped", "initialized matching run passes")
		instance.shutdown("test")
	end)

	test("ranked_ready_carries_schema_and_independent_digest", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		-- The guest receives the forced config on join; this is the actual live
		-- configuration the runtime must bind.
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		ranked_setup(bctx)
		step(instance, bctx)
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.ready ~= nil, "READY is sent under the ranked contract")
		local ready_payload = by_op.ready.observation
		ctx.eq(ready_payload.config_schema, RANKED_SCHEMA)
		ctx.is_true(type(ready_payload.config_digest) == "string" and #ready_payload.config_digest == 8,
			tostring(ready_payload.config_digest))
		ctx.is_true(ready_payload.config_digest ~= "deadbeef",
			"the runtime never echoes the service expected digest")
		ctx.is_true(type(ready_payload.readiness) == "table", "the readiness record is carried")
		ctx.eq(ready_payload.readiness.unlock_check, true)
		instance.shutdown("test")
	end)

	test("ranked_ready_is_withheld_when_a_readiness_fact_is_not_true", function()
		local not_ready = {}
		for key, value in pairs(READINESS_OK) do
			not_ready[key] = value
		end
		not_ready.debug_disabled = "unknown"
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = not_ready,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		ranked_setup(bctx)
		step(instance, bctx)
		local _, by_op = drain_envelopes(bctx)
		ctx.eq(by_op.ready, nil, "READY is withheld while a fact is not true")
		instance.shutdown("test")
	end)

	test("ranked_setup_without_ranked_config_fails_immediately", function()
		local codec = support.mod(ctx.repo_root, "AISparring/ai/codec.lua")
		local MPDriver = support.mod(ctx.repo_root, "AISparring/integration/mp_driver.lua")
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "human",
			modules = { codec = codec, MPDriver = MPDriver },
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		step(instance, bctx)
		drain_envelopes(bctx)
		-- Ranked SETUP arrives, but the shared parity module was never supplied.
		support.inbound(bctx, {
			op = "setup", ok = true, code = "practice_ok", role = "human",
			ruleset_id = "ruleset_mp_standard_ranked", gamemode = "gamemode_mp_attrition",
			config_schema = "aisparring.ranked_effective_config.v1", forced_options = {},
			difficulty = "competitive", mode = "normal", pacing = "normal",
		})
		ctx.eq(instance.update(0.016), "stopped")
		ctx.eq(instance.status().last_error, "boot_bad_modules")
		instance.shutdown("test")
	end)

	test("ranked_ready_then_mutation_fails_before_actuation", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		ranked_setup(bctx)
		step(instance, bctx)
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.ready ~= nil, "READY was sent")
		-- Mutate the actual config after READY, before the readiness commit.
		bctx.engine.MP.LOBBY.config.timer_base_seconds = 151
		for _ = 1, 8 do
			if instance.state() == "stopped" then
				break
			end
			-- Ack every coordination frame so the READY ack reaches the recheck
			-- regardless of heartbeat interleaving.
			for _, message in ipairs(support.drain_outbound(bctx)) do
				if type(message.op) == "string" then
					support.inbound(bctx, { ok = true, code = "practice_ok" })
				end
			end
			step(instance, bctx)
		end
		ctx.eq(instance.state(), "stopped", "the post-READY mutation is refused")
		ctx.eq(instance.status().last_error, "boot_config_mismatch")
		-- No actuator ran: the guest ready callback never toggled the lobby.
		ctx.eq(bctx.engine.MP.LOBBY.ready_to_start, false, "no actuator mutation on refusal")
		instance.shutdown("test")
	end)

	test("ranked_setup_wrong_ruleset_id_fails_closed", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		-- A legacy ruleset id cannot be carried under the Ranked schema.
		ranked_setup(bctx, { ruleset_id = "ruleset_mp_majorleague" })
		ctx.eq(instance.update(0.016), "stopped")
		ctx.eq(instance.status().last_error, "boot_config_mismatch")
		instance.shutdown("test")
	end)

	test("ranked_unknown_schema_fails_closed_before_ready", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai", lobby_code = "ABC12" })
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		ranked_setup(bctx, { config_schema = "aisparring.ranked_effective_config.v2" })
		local status = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(instance.status().last_error, "boot_config_mismatch")
		instance.shutdown("test")
	end)

	test("ranked_post_start_wrong_deck_aborts_before_policy", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		-- The actual initialized run selected a different Back than the draft.
		bctx.engine.G.GAME.selected_back = { effect = { center = { key = "b_blue" } } }
		bctx.engine.G.GAME.stake = 1
		ranked_setup(bctx, { selection = RANKED_SELECTION })
		for _ = 1, 8 do
			if instance.state() == "stopped" then
				break
			end
			step(instance, bctx)
		end
		ctx.eq(instance.state(), "stopped", "a real deck mismatch aborts")
		ctx.eq(instance.status().last_error, "boot_selection_mismatch")
		instance.shutdown("test")
	end)

	test("ranked_post_start_matching_deck_does_not_abort", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		bctx.engine.G.GAME.selected_back = { effect = { center = { key = "b_red" } } }
		bctx.engine.G.GAME.stake = 1
		ranked_setup(bctx, { selection = RANKED_SELECTION })
		for _ = 1, 6 do
			step(instance, bctx)
		end
		ctx.is_true(instance.state() ~= "stopped", "a matching selection does not abort")
		instance.shutdown("test")
	end)

	test("ranked_ready_carries_the_draft_commitment_digest", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		ranked_setup(bctx, { draft = RANKED_DRAFT })
		step(instance, bctx)
		local _, by_op = drain_envelopes(bctx)
		ctx.is_true(by_op.ready ~= nil, "READY is sent with a bound draft")
		local ready_payload = by_op.ready.observation
		ctx.is_true(type(ready_payload.draft_digest) == "string" and #ready_payload.draft_digest == 8,
			tostring(ready_payload.draft_digest))
		-- The runtime derives the digest itself; it is not supplied by SETUP.
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local expected = ranked_config.draft_commitment_digest(
			RANKED_DRAFT.profile_id, RANKED_DRAFT.first_actor,
			RANKED_DRAFT.pool, RANKED_DRAFT.transcript, RANKED_DRAFT.final
		)
		ctx.eq(ready_payload.draft_digest, expected, "independently derived draft digest")
		instance.shutdown("test")
	end)

	test("ranked_setup_tampered_draft_fails_closed", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		local tampered = {}
		for key, value in pairs(RANKED_DRAFT) do
			tampered[key] = value
		end
		tampered.transcript = {
			{ actor = "ai", operation = "ban", option_ids = { "blue~green" } },
			RANKED_DRAFT.transcript[2],
			RANKED_DRAFT.transcript[3],
			RANKED_DRAFT.transcript[4],
		}
		ranked_setup(bctx, { draft = tampered })
		ctx.eq(instance.update(0.016), "stopped")
		ctx.eq(instance.status().last_error, "boot_setup_failed")
		instance.shutdown("test")
	end)

	test("ranked_setup_without_draft_fails_closed", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		-- Ranked SETUP with a valid schema + selection but NO completed draft
		-- commitment: fail closed. There is no selection-only Ranked launch.
		support.inbound(bctx, {
			op = "setup", ok = true, code = "practice_ok", role = "ai",
			ruleset_id = "ruleset_mp_standard_ranked", gamemode = "gamemode_mp_attrition",
			config_schema = RANKED_SCHEMA, forced_options = {},
			selection = RANKED_SELECTION,
			difficulty = "competitive", mode = "normal", pacing = "normal",
		})
		ctx.eq(instance.update(0.016), "stopped")
		ctx.eq(instance.status().last_error, "boot_setup_failed")
		instance.shutdown("test")
	end)

	test("ranked_setup_final_selection_mismatch_fails_closed", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		-- A legal transcript whose final option is "blue~white" while the
		-- mandatory selection is Red Deck / White Stake.
		local mismatched = {
			schema = "aisparring.ranked_draft.v1",
			profile_id = "aisparring.ranked_draft_profile.standard_1_2_2.v1",
			first_actor = "human",
			pool = {
				"green~green", "green~black", "yellow~green", "yellow~black", "black~green",
				"blue~white", "black~black", "red~black", "red~white",
			},
			transcript = {
				{ actor = "human", operation = "ban", option_ids = { "green~green" } },
				{ actor = "ai", operation = "ban", option_ids = { "green~black", "yellow~green" } },
				{ actor = "human", operation = "ban", option_ids = { "yellow~black", "black~green" } },
				{ actor = "ai", operation = "select", option_ids = { "blue~white" } },
			},
			final = "blue~white",
		}
		ranked_setup(bctx, { draft = mismatched })
		ctx.eq(instance.update(0.016), "stopped")
		ctx.eq(instance.status().last_error, "boot_config_mismatch")
		instance.shutdown("test")
	end)

	test("ranked_setup_underscore_deck_key_binds_final_option", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		-- A deck key that contains an underscore must parse identically in Lua
		-- (`%w` alone excludes `_`) and bind to the selection.
		local underscore_selection = {
			schema = "aisparring.ranked_selection.v1",
			deck_key = "fixture_deck", back_key = "b_fixture_deck", back_name = "Fixture Deck",
			stake_key = "white", stake_index = 1,
		}
		local underscore_draft = {
			schema = "aisparring.ranked_draft.v1",
			profile_id = "aisparring.ranked_draft_profile.standard_1_2_2.v1",
			first_actor = "human",
			pool = {
				"fixture_deck~white", "fixture_deck~green", "blue~white", "blue~green", "yellow~white",
				"yellow~green", "green~white", "black~white", "black~green",
			},
			transcript = {
				{ actor = "human", operation = "ban", option_ids = { "black~green" } },
				{ actor = "ai", operation = "ban", option_ids = { "green~white", "black~white" } },
				{ actor = "human", operation = "ban", option_ids = { "yellow~white", "yellow~green" } },
				{ actor = "ai", operation = "select", option_ids = { "fixture_deck~white" } },
			},
			final = "fixture_deck~white",
		}
		ranked_setup(bctx, { selection = underscore_selection, draft = underscore_draft })
		for _ = 1, 4 do
			step(instance, bctx)
		end
		ctx.is_true(instance.state() ~= "stopped", "an underscore deck key must not abort SETUP")
		instance.shutdown("test")
	end)

	test("ranked_setup_without_selection_fails_closed", function()
		local instance, _, bctx = support.bootstrap(ctx.repo_root, {
			role = "ai", lobby_code = "ABC12", readiness_override = READINESS_OK,
		})
		ctx.is_true(instance.install())
		drain_envelopes(bctx)
		support.inbound(bctx, { ok = true, code = "practice_ok" })
		instance.update(0.016)
		drain_envelopes(bctx)
		bctx.engine.MP.ACTIONS.join_lobby("ABC12")
		-- Ranked SETUP with no validated selection: fail closed, no fallback deck.
		support.inbound(bctx, {
			op = "setup", ok = true, code = "practice_ok", role = "ai",
			ruleset_id = "ruleset_mp_standard_ranked", gamemode = "gamemode_mp_attrition",
			config_schema = RANKED_SCHEMA, forced_options = {},
			difficulty = "competitive", mode = "normal", pacing = "normal",
		})
		local status = instance.update(0.016)
		ctx.eq(status, "stopped")
		ctx.eq(instance.status().last_error, "boot_setup_failed")
		instance.shutdown("test")
	end)
end
