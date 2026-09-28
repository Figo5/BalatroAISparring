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
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
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
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
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
		local instance, _, bctx = support.bootstrap(ctx.repo_root, { role = "ai" })
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

	test("mp_wait_state_only_trusts_grounded_mp_waits", function()
		local RuntimeBootstrap = support.mod(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		ctx.eq(RuntimeBootstrap.mp_wait_state(nil, nil), nil)
		ctx.eq(RuntimeBootstrap.mp_wait_state({ GAME = {} }, { GAME = { current_round = { hands_left = 4 } } }), nil)
		ctx.eq(
			RuntimeBootstrap.mp_wait_state({ GAME = { ready_blind = true } }, { GAME = {} }),
			"mp_ready_blind"
		)
		ctx.eq(
			RuntimeBootstrap.mp_wait_state(
				{ GAME = { pvp_reached = true } },
				{ GAME = { current_round = { hands_left = 0 } } }
			),
			"mp_pvp_no_hands"
		)
		ctx.eq(
			RuntimeBootstrap.mp_wait_state({ GAME = { pvp_countdown = 3 } }, { GAME = {} }),
			"mp_pvp_countdown"
		)
		-- A finished PvP round is not a wait, and an unknown engine fault never
		-- becomes an unbounded wait.
		ctx.eq(
			RuntimeBootstrap.mp_wait_state(
				{ GAME = { pvp_reached = true, round_ended = true } },
				{ GAME = { current_round = { hands_left = 0 } } }
			),
			nil
		)
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
