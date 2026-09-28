return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root

	local function play_action(r)
		return support.action(r.env, { type = "PLAY_CARDS", card_refs = { "hand:1" } })
	end

	test("transport_request_carries_only_sequence_and_observation", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued")
		eq(lr.transport.sent, 1)
		local payload = lr.transport.requests[1]
		eq(type(payload), "table")
		eq(type(payload.sequence), "number")
		eq(type(payload.observation), "table")
		local keys = {}
		for key in next, payload do
			keys[#keys + 1] = key
		end
		eq(#keys, 2, "payload has exactly two keys")
		eq(support.has_key(payload, "actions"), false)
		eq(support.has_key(payload, "token"), false)
		eq(support.has_key(payload, "seed"), false)
		eq(support.has_key(payload, "session"), false)
		eq(support.has_key(payload, "source"), false)
		eq(support.has_key(payload, "config"), false)
		eq(support.has_key(payload, "candidates"), false)
		eq(support.has_key(payload.observation, "secret"), false)
		eq(support.count_nonplain(payload), 0, "no functions or userdata")
		eq(r.broker.has_pending(), true, "token stays private in the broker")
	end)

	test("loop_submits_matched_response_and_logs_bounded_fields", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued")
		eq(lr.loop.update(), "waiting")
		lr.transport.push({
			sequence = 1,
			ok = true,
			action = play_action(r),
			reason = "play_best",
		})
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)
		eq(lr.loop.stats().submitted, 1)
		eq(#lr.logger.records, 1)
		local record = lr.logger.records[1]
		eq(record.phase, "PLAY_HAND")
		eq(record.candidate_count, 2)
		eq(record.selected.type, "PLAY_CARDS")
		eq(record.reason, "play_best")
		eq(type(record.checksum), "string")
		eq(record.result_code, "broker_ok")
		eq(record.issue_epoch, 5)
		eq(record.result_epoch, nil, "no injected revision reader: never relabel the pre-issue epoch as post")
	end)

	test("pacing_defers_submit_without_blocking", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { pacing = 2 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "scheduled")
		eq(r.ports.dispatch_calls, 0, "not_dispatched_yet")
		eq(lr.loop.update(), "scheduled")
		eq(r.ports.dispatch_calls, 0, "still_not_dispatched")
		lr.clock.advance(2)
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)
	end)

	test("out_of_order_response_dropped_then_exact_match", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 99, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "waiting")
		eq(lr.loop.stats().out_of_order, 1)
		eq(r.ports.dispatch_calls, 0)
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)
	end)

	test("replayed_response_never_dispatches_twice", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "issued")
		eq(lr.loop.update(), "waiting")
		eq(lr.loop.stats().out_of_order, 1)
		eq(r.ports.dispatch_calls, 1, "no_double_dispatch")
		lr.transport.push({ sequence = 2, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 2)
	end)

	test("timeout_revokes_after_bounded_errors", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { timeout = 1, max_consecutive_errors = 2 })
		eq(lr.loop.update(), "issued")
		lr.clock.advance(2)
		local first_status, first_code = lr.loop.update()
		eq(first_status, "idle")
		eq(first_code, "loop_timeout")
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.stats().timeouts, 1)
		eq(lr.loop.update(), "issued")
		lr.clock.advance(2)
		local second_status, second_code = lr.loop.update()
		eq(second_status, "stopped")
		eq(second_code, "loop_timeout")
		eq(lr.loop.is_stopped(), true)
		eq(r.broker.is_revoked(), true)
	end)

	test("policy_error_then_success_recovers", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { max_consecutive_errors = 5 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = false, code = "policy_runtime_error" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.stats().errors, 1)
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 2, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)
		eq(lr.loop.stats().errors, 1)
	end)

	test("stale_aba_rejected_and_reissued", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued")
		r.world.set_money(999)
		r.world.set_money(10)
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		local status, code = lr.loop.update()
		eq(status, "idle")
		eq(code, "loop_stale")
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.stats().stale, 1)
		eq(r.ports.dispatch_calls, 0)
		eq(lr.loop.update(), "issued")
		eq(lr.transport.sent, 2)
		lr.transport.push({ sequence = 2, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)
	end)

	test("terminal_observation_stops_loop", function()
		local r = support.rig(repo, { frame = support.terminal_frame() })
		local lr = support.loop(r, {})
		local status, code = lr.loop.update()
		eq(status, "terminal")
		eq(code, "loop_terminal")
		eq(lr.loop.is_terminal(), true)
		eq(lr.loop.is_stopped(), true)
		eq(lr.transport.sent, 0)
	end)

	test("empty_actions_backs_off_without_spin_or_abort", function()
		local r = support.rig(repo, { frame = support.blocked_frame() })
		local lr = support.loop(r, {})
		local status, code = lr.loop.update()
		eq(status, "idle")
		eq(code, "loop_empty_actions")
		eq(lr.loop.is_stopped(), false)
		eq(lr.transport.sent, 0)
		local status2, code2 = lr.loop.update()
		eq(status2, "idle")
		eq(code2, "loop_ok")
		eq(lr.transport.sent, 0)
		eq(lr.loop.stats().empty, 1)
	end)

	test("request_rate_is_capped", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { min_interval = 10 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(lr.transport.sent, 1)
		local status, code = lr.loop.update()
		eq(status, "idle")
		eq(code, "loop_ok")
		eq(lr.transport.sent, 1)
		lr.clock.advance(10)
		eq(lr.loop.update(), "issued")
		eq(lr.transport.sent, 2)
	end)

	test("cashout_control_uses_injected_advance_only", function()
		local r = support.rig(repo, {})
		local controls = support.controls()
		controls.name = "cash_out"
		local lr = support.loop(r, { controls = controls })
		local status, code = lr.loop.update()
		eq(status, "control")
		eq(code, "loop_ok")
		eq(controls.advanced, 1)
		eq(controls.advanced_name, "cash_out")
		eq(lr.transport.sent, 0)
		eq(lr.loop.update(), "issued")
	end)

	test("unknown_control_is_not_navigated", function()
		local r = support.rig(repo, {})
		local controls = support.controls()
		controls.name = "pvp_ready"
		local lr = support.loop(r, { controls = controls })
		eq(lr.loop.update(), "issued")
		eq(controls.advanced, 0)
	end)

	test("transient_capture_failures_are_bounded_waits", function()
		local r = support.rig(repo, { capture_fail_times = 5 })
		local lr = support.loop(r, { transient_backoff = 0.1, max_transient_streak = 50 })
		for _ = 1, 5 do
			local status, code = lr.loop.update()
			eq(status, "idle")
			eq(code, "loop_transient")
			lr.clock.advance(0.1)
		end
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.stats().transient, 5)
		eq(lr.loop.update(), "issued")
		eq(lr.loop.stats().transient, 5)
	end)

	test("transient_streak_is_bounded_then_aborts", function()
		local r = support.rig(repo, { capture_fail_times = 100 })
		local lr = support.loop(r, { transient_backoff = 0.1, max_transient_streak = 3 })
		for _ = 1, 3 do
			local status, code = lr.loop.update()
			eq(status, "idle")
			eq(code, "loop_transient")
			lr.clock.advance(0.1)
		end
		eq(lr.loop.is_stopped(), false)
		local status, code = lr.loop.update()
		eq(status, "stopped")
		eq(code, "broker_capture_failed")
		eq(r.broker.is_revoked(), true)
	end)

	test("control_latch_does_not_deadlock_and_refreshes_through_capture", function()
		local r = support.rig(repo, {})
		local controls = support.controls({ sticky = true })
		controls.name = "cash_out"
		local lr = support.loop(r, { controls = controls })
		eq(lr.loop.update(), "control")
		eq(controls.advanced, 1)
		-- The runtime's controls.next is only refreshed by the trusted capture,
		-- so the stale latch must fall through to broker.issue (capture) rather
		-- than returning a dead control_pending forever.
		eq(lr.loop.update(), "issued")
		eq(controls.advanced, 1, "no second deferred transition")
		eq(lr.transport.sent, 1, "capture ran and a fresh decision was issued")
		-- Once the trusted capture observes that the control cleared, the latch
		-- releases and the loop returns to polling the outstanding request.
		controls.clear()
		eq(lr.loop.update(), "waiting")
		eq(lr.loop.is_stopped(), false)
	end)

	test("control_latch_progresses_after_cashout_phase_change", function()
		local captures = 0
		local controls = support.controls({ sticky = true })
		controls.name = "cash_out"
		local r = support.rig(repo, {
			capture_impl = function(default_capture)
				return function()
					captures = captures + 1
					return default_capture()
				end
			end,
		})
		local lr = support.loop(r, { controls = controls })
		eq(lr.loop.update(), "control")
		eq(captures, 0, "no capture before the transition")
		eq(lr.loop.update(), "issued")
		is_true(captures >= 1, "latch refresh went through the trusted capture")
		eq(r.broker.has_pending(), true)
	end)

	test("failed_control_advance_is_a_bounded_wait_not_an_error", function()
		local r = support.rig(repo, {})
		local controls = support.controls()
		controls.name = "cash_out"
		controls.advance = function()
			return nil, "exec_element_missing"
		end
		local lr = support.loop(r, {
			controls = controls,
			max_consecutive_errors = 1,
			max_transient_streak = 5,
			transient_backoff = 0.1,
		})
		for _ = 1, 5 do
			local status, code = lr.loop.update()
			eq(status, "idle")
			eq(code, "loop_transient")
			lr.clock.advance(0.1)
		end
		eq(lr.loop.is_stopped(), false, "an animating control button never aborts the match")
		eq(lr.loop.stats().errors, 0)
		eq(r.ports.dispatch_calls, 0)
	end)

	test("transient_wait_is_bounded_by_wall_clock", function()
		local r = support.rig(repo, { capture_fail_times = 1000 })
		local lr = support.loop(r, {
			transient_backoff = 0.25,
			max_transient_seconds = 1,
			max_transient_streak = 1000,
		})
		local aborted = false
		for _ = 1, 20 do
			local status, code = lr.loop.update()
			if status == "stopped" then
				aborted = true
				eq(code, "broker_capture_failed")
				break
			end
			lr.clock.advance(0.25)
		end
		is_true(aborted, "an unbroken anonymous stall is still bounded")
	end)

	test("verified_wait_state_holds_the_transient_window_open", function()
		local r = support.rig(repo, { capture_fail_times = 1000 })
		local lr = support.loop(r, {
			transient_backoff = 0.25,
			max_transient_seconds = 1,
			wait_state = function()
				return "waiting_opponent"
			end,
		})
		for _ = 1, 40 do
			lr.loop.update()
			lr.clock.advance(0.25)
		end
		eq(lr.loop.is_stopped(), false, "the authoritative MP wait is never deadline-aborted")
		is_true(lr.loop.stats().transient_waiting > 0)
		eq(lr.loop.stats().errors, 0)
	end)

	test("policy_no_action_backs_off_without_counting_an_error", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { max_consecutive_errors = 1 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = false, code = "policy_no_action" })
		local status, code = lr.loop.update()
		eq(status, "idle")
		eq(code, "loop_policy_no_action")
		eq(lr.loop.stats().no_action, 1)
		eq(lr.loop.stats().errors, 0)
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.update(), "idle", "backoff, no spin")
		lr.clock.advance(0.5)
		eq(lr.loop.update(), "issued")
	end)

	test("scheduled_submit_skips_timeout_and_polling", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { timeout = 5, pacing = 2 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "scheduled")
		-- A duplicate response must not overwrite the scheduled action or reset
		-- the submit time while it is scheduled.
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "scheduled")
		eq(lr.loop.pending_sequence(), 1)
		-- The request timeout is measured from request_sent_at; with pacing <
		-- timeout a scheduled submit always resolves first, so advancing past the
		-- pacing window (but before the timeout) dispatches exactly once.
		lr.clock.advance(3)
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)
		eq(lr.loop.stats().timeouts, 0)
	end)

	test("pacing_not_below_timeout_is_rejected", function()
		local r = support.rig(repo, {})
		local clock = support.clock()
		local transport = support.transport()
		local loop, code = r.env.loop.factory({
			broker = r.broker,
			transport = transport,
			clock = clock,
			pacing = 5,
			timeout = 5,
		})
		eq(loop, nil)
		eq(code, "loop_bad_options")
	end)

	test("factory_requires_broker_revoke_port", function()
		local r = support.rig(repo, {})
		local clock = support.clock()
		local transport = support.transport()
		local broker = r.broker
		local loop, code = r.env.loop.factory({
			broker = {
				issue = broker.issue,
				submit = broker.submit,
				cancel = broker.cancel,
				is_revoked = broker.is_revoked,
			},
			transport = transport,
			clock = clock,
		})
		eq(loop, nil)
		eq(code, "loop_bad_broker")
	end)

	test("response_rejections_are_logged", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { max_consecutive_errors = 5 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = false, code = "policy_runtime_error" })
		eq(lr.loop.update(), "idle")
		eq(#lr.logger.records, 1)
		local record = lr.logger.records[1]
		eq(record.result_code, "policy_runtime_error")
		eq(record.selected, nil)
		eq(record.issue_epoch, 5)
	end)

	test("post_action_revision_is_logged_from_injected_reader", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			get_revision = function()
				return 77
			end,
		})
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		local record = lr.logger.records[1]
		eq(record.issue_epoch, 5)
		eq(record.result_epoch, 77)
	end)

	test("terminal_stop_revokes_the_broker", function()
		local r = support.rig(repo, { frame = support.terminal_frame() })
		local lr = support.loop(r, {})
		local status, code = lr.loop.update()
		eq(status, "terminal")
		eq(code, "loop_terminal")
		eq(r.broker.is_revoked(), true, "terminal closes the authority")
	end)

	test("control_does_not_repeat_deferred_transition", function()
		local r = support.rig(repo, {})
		local controls = support.controls()
		controls.name = "cash_out"
		local lr = support.loop(r, { controls = controls })
		eq(lr.loop.update(), "control")
		eq(controls.advanced, 1)
		-- A still-required control is not a second deferred transition; the loop
		-- refreshes through capture and makes progress instead.
		controls.name = "cash_out"
		eq(lr.loop.update(), "issued")
		eq(controls.advanced, 1, "no second transition")
	end)

	test("control_transition_cancels_pending_token", function()
		local r = support.rig(repo, {})
		local controls = support.controls()
		local lr = support.loop(r, { controls = controls })
		eq(lr.loop.update(), "issued")
		eq(r.broker.has_pending(), true)
		controls.name = "cash_out"
		eq(lr.loop.update(), "control")
		eq(r.broker.has_pending(), false, "pending token cleared before transition")
		eq(lr.transport.canceled, 1)
	end)

	test("transport_request_fault_aborts_after_cap", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { max_consecutive_errors = 1 })
		lr.transport.request_fault = true
		local status, code = lr.loop.update()
		eq(status, "stopped")
		eq(code, "loop_transport_error")
		eq(lr.loop.is_stopped(), true)
		eq(r.broker.is_revoked(), true)
	end)

	test("transport_poll_fault_is_bounded_and_revokes", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { max_consecutive_errors = 1 })
		eq(lr.loop.update(), "issued")
		lr.transport.poll_fault = true
		local status, code = lr.loop.update()
		eq(status, "stopped")
		eq(code, "loop_transport_error")
		eq(r.broker.is_revoked(), true)
	end)

	test("module_runs_without_engine_globals", function()
		eq(type(G), "nil")
		eq(type(MP), "nil")
		eq(type(SMODS), "nil")
		eq(type(Client), "nil")
		eq(type(love), "nil")
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued")
	end)

	test("legal_progression_through_match_termination", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})

		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 1)

		r.world.replace_frame(support.shop_frame())
		eq(lr.loop.update(), "issued")
		lr.transport.push({
			sequence = 2,
			ok = true,
			action = support.action(r.env, { type = "LEAVE_SHOP" }),
		})
		eq(lr.loop.update(), "submitted")
		eq(r.ports.dispatch_calls, 2)
		eq(r.ports.last_action.type, "LEAVE_SHOP")

		r.world.replace_frame(support.terminal_frame())
		local status, code = lr.loop.update()
		eq(status, "terminal")
		eq(code, "loop_terminal")
		eq(lr.loop.is_terminal(), true)
		eq(lr.transport.sent, 2)
	end)

	test("exec_pending_is_a_valid_bounded_wait_not_a_fault", function()
		local r = support.rig(repo, { capture_code = "exec_pending" })
		local lr = support.loop(r, { transient_backoff = 0.1, max_transient_streak = 50 })
		local status, code = lr.loop.update()
		eq(status, "idle")
		eq(code, "loop_transient")
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.stats().faults, 0, "the pending latch is not a fault")
		eq(lr.loop.stats().transient, 1)
		eq(r.broker.is_revoked(), false)
	end)

	test("exec_stall_timeout_stops_the_match_immediately", function()
		local r = support.rig(repo, { capture_code = "exec_stall_timeout" })
		local lr = support.loop(r, { max_consecutive_errors = 5 })
		local status, code = lr.loop.update()
		eq(status, "stopped")
		eq(code, "exec_stall_timeout", "the terminal fault is surfaced verbatim")
		eq(lr.loop.is_stopped(), true)
		eq(lr.loop.stats().faults, 1)
		eq(lr.loop.stats().errors, 0, "a fault is not a bounded error")
		eq(r.broker.is_revoked(), true)
	end)

	test("exec_revoked_stops_the_match_immediately", function()
		local r = support.rig(repo, { capture_code = "exec_revoked" })
		local lr = support.loop(r, { max_consecutive_errors = 5 })
		local status, code = lr.loop.update()
		eq(status, "stopped")
		eq(code, "exec_revoked")
		eq(lr.loop.stats().errors, 0)
		eq(r.broker.is_revoked(), true)
	end)

	test("exec_stall_timeout_during_submit_stops_immediately", function()
		-- The production broker re-captures immediately before dispatch, so a
		-- fault can also surface on the submit path (not just issue).
		local r = support.rig(repo, {
			capture_impl = function(default_capture)
				local calls = 0
				return function()
					calls = calls + 1
					if calls >= 2 then
						return nil, "exec_stall_timeout"
					end
					return default_capture()
				end
			end,
		})
		local lr = support.loop(r, { max_consecutive_errors = 5 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = lr.loop.pending_sequence(), ok = true, action = play_action(r) })
		local status, code = lr.loop.update()
		eq(status, "stopped")
		eq(code, "exec_stall_timeout")
		eq(lr.loop.stats().faults, 1)
		eq(lr.loop.stats().errors, 0)
		eq(r.broker.is_revoked(), true)
	end)

	test("failed_control_advance_wait_is_frame_rate_independent", function()
		local r = support.rig(repo, {})
		local controls = support.controls()
		controls.name = "cash_out"
		controls.advance = function()
			return nil, "exec_element_missing"
		end
		local lr = support.loop(r, { controls = controls, transient_backoff = 0.25 })
		-- 15s at 144 FPS. The operationally relevant bound is the wall clock, not
		-- the frame count: before N3 this retried every frame and tripped the
		-- 1200-step streak guard after about 8.3s.
		for _ = 1, 2160 do
			lr.loop.update()
			lr.clock.advance(1 / 144)
			if lr.loop.is_stopped() then
				break
			end
		end
		eq(lr.loop.is_stopped(), false, "a 15s failed-advance wait is not frame-rate aborted")
		eq(lr.loop.stats().errors, 0)
		is_true(lr.loop.stats().transient <= 62,
			"throttled attempts, got " .. tostring(lr.loop.stats().transient))
	end)

	test("policy_no_action_same_epoch_backs_off_exponentially_to_cap", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { transient_backoff = 0.25, no_action_max_backoff = 2 })
		local function round()
			eq(lr.loop.update(), "issued")
			lr.transport.push({
				sequence = lr.loop.pending_sequence(),
				ok = false,
				code = "policy_no_action",
			})
			local status, code = lr.loop.update()
			eq(status, "idle")
			eq(code, "loop_policy_no_action")
		end
		round()
		eq(lr.loop.describe().no_action_backoff, 0.25)
		lr.clock.advance(0.25)
		round()
		eq(lr.loop.describe().no_action_backoff, 0.5)
		lr.clock.advance(0.5)
		round()
		eq(lr.loop.describe().no_action_backoff, 1)
		lr.clock.advance(1)
		round()
		eq(lr.loop.describe().no_action_backoff, 2)
		lr.clock.advance(2)
		round()
		eq(lr.loop.describe().no_action_backoff, 2, "capped at the configured maximum")
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.stats().no_action, 5)
	end)

	test("policy_no_action_backoff_resets_when_epoch_changes", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { transient_backoff = 0.25, no_action_max_backoff = 2 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = lr.loop.pending_sequence(), ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		lr.clock.advance(0.25)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = lr.loop.pending_sequence(), ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.describe().no_action_backoff, 0.5)
		-- Observable progress: the trusted epoch moves, so the throttle resets.
		lr.clock.advance(0.5)
		r.world.set_money(11)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = lr.loop.pending_sequence(), ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.describe().no_action_backoff, 0.25, "a changed epoch resets the throttle")
	end)

	test("policy_no_action_backoff_resets_after_commit", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, { transient_backoff = 0.25, no_action_max_backoff = 2 })
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = lr.loop.pending_sequence(), ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		lr.clock.advance(0.25)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = lr.loop.pending_sequence(), ok = true, action = play_action(r) })
		eq(lr.loop.update(), "submitted")
		eq(lr.loop.describe().no_action_backoff, nil, "committed progress clears the throttle")
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = lr.loop.pending_sequence(), ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.describe().no_action_backoff, 0.25, "starts from the base delay again")
	end)
end
