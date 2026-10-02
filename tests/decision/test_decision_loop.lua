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

	-- WAITING_FOR_OPPONENT (NATIVE_TEST_PROGRESS match 10: 33 `policy_no_action`
	-- polls at the PvP blind were counted as errors by the service).
	local function wait_rig(opts)
		local r = support.rig(repo, {})
		local state = { value = "mp_ready_blind" }
		local merged = {
			transient_backoff = 0.25,
			max_transient_seconds = 1,
			max_consecutive_errors = 1,
			wait_state = function()
				return state.value
			end,
		}
		for key, value in pairs(opts or {}) do
			merged[key] = value
		end
		local lr = support.loop(r, merged)
		return r, lr, state
	end

	local function wait_records(logger, event)
		local out = {}
		for _, record in ipairs(logger.records) do
			if record.event == event then
				out[#out + 1] = record
			end
		end
		return out
	end

	test("waiting_for_opponent_never_asks_the_policy_or_counts_an_error", function()
		local r, lr = wait_rig()
		for _ = 1, 50 do
			local status, code = lr.loop.update()
			is_true(status == "waiting" or status == "idle", tostring(status))
			if status == "waiting" then
				eq(code, "loop_waiting_for_opponent")
			end
			lr.clock.advance(0.3)
		end
		eq(lr.transport.sent, 0, "no policy request while waiting")
		local stats = lr.loop.stats()
		eq(stats.errors, 0)
		eq(stats.transient, 0)
		eq(stats.no_action, 0)
		eq(stats.requests, 0)
		eq(stats.waits, 1)
		is_true(stats.waiting_polls > 1)
		eq(lr.loop.is_stopped(), false, "a long opponent wait is never deadline-aborted")
		eq(r.broker.has_pending(), false, "the captured token is released")
		eq(#wait_records(lr.logger, "wait_begin"), 1, "the entry is logged once, not per poll")
		eq(wait_records(lr.logger, "wait_begin")[1].detail, "mp_ready_blind")
		eq(wait_records(lr.logger, "wait_begin")[1].code, "loop_waiting_for_opponent")
		eq(#wait_records(lr.logger, "wait_end"), 0)
	end)

	test("waiting_for_opponent_backoff_doubles_and_is_capped", function()
		local _, lr = wait_rig({ wait_max_backoff = 1.0 })
		local seen = {}
		-- Polls land at t = 0, 0.25, 0.75, 1.75: 35 steps of 0.05 s reach 1.70.
		for _ = 1, 35 do
			local status = lr.loop.update()
			if status == "waiting" then
				seen[#seen + 1] = lr.loop.describe().wait_backoff
			end
			lr.clock.advance(0.05)
		end
		eq(seen[1], 0.25)
		eq(seen[2], 0.5)
		eq(seen[3], 1.0)
		eq(#seen, 3, "the cooldown suppresses polls in between")
		for _ = 1, 100 do
			if lr.loop.update() == "waiting" then
				eq(lr.loop.describe().wait_backoff, 1.0, "capped")
			end
			lr.clock.advance(0.05)
		end
	end)

	test("waiting_for_opponent_resumes_promptly_when_the_opponent_arrives", function()
		local _, lr, state = wait_rig()
		for _ = 1, 20 do
			lr.loop.update()
			lr.clock.advance(0.25)
		end
		state.value = nil
		local issued = false
		for _ = 1, 5 do
			if lr.loop.update() == "issued" then
				issued = true
				break
			end
			lr.clock.advance(0.25)
		end
		is_true(issued, "the policy is asked within the capped backoff")
		eq(lr.transport.sent, 1)
		local ends = wait_records(lr.logger, "wait_end")
		eq(#ends, 1)
		is_true(ends[1].seconds > 4, tostring(ends[1].seconds))
		is_true(lr.loop.stats().waiting_seconds > 4)
		eq(lr.loop.describe().waiting, nil)
		eq(lr.loop.describe().wait_backoff, nil, "the next wait starts from the base delay")
	end)

	test("waiting_for_opponent_transient_capture_is_not_a_transient", function()
		-- A PvP no-hands wait keeps G.STATE at HAND_PLAYED, so capture fails.
		local r = support.rig(repo, { capture_fail_times = 1000 })
		local lr = support.loop(r, {
			transient_backoff = 0.25,
			max_transient_seconds = 1,
			wait_state = function()
				return "mp_pvp_no_hands"
			end,
		})
		local status, code = lr.loop.update()
		eq(status, "waiting")
		eq(code, "loop_waiting_for_opponent")
		for _ = 1, 40 do
			lr.loop.update()
			lr.clock.advance(0.25)
		end
		eq(lr.loop.is_stopped(), false)
		eq(lr.loop.stats().transient, 0)
		eq(lr.loop.stats().errors, 0)
		eq(lr.loop.stats().waits, 1)
	end)

	test("waiting_for_opponent_changing_wait_kind_logs_a_new_wait", function()
		local _, lr, state = wait_rig()
		lr.loop.update()
		lr.clock.advance(2)
		state.value = "mp_pvp_countdown"
		lr.loop.update()
		eq(lr.loop.stats().waits, 2)
		eq(#wait_records(lr.logger, "wait_begin"), 2)
		eq(#wait_records(lr.logger, "wait_end"), 1)
	end)

	test("terminal_match_end_takes_precedence_over_a_wait", function()
		local r = support.rig(repo, { frame = support.terminal_frame() })
		local lr = support.loop(r, {
			wait_state = function()
				return "mp_ready_blind"
			end,
		})
		local status, code = lr.loop.update()
		eq(status, "terminal")
		eq(code, "loop_terminal")
	end)

	test("stopping_while_waiting_closes_the_wait_record", function()
		local _, lr = wait_rig()
		lr.loop.update()
		lr.clock.advance(3)
		lr.loop.update()
		lr.loop.stop("closed")
		local ends = wait_records(lr.logger, "wait_end")
		eq(#ends, 1)
		eq(ends[1].seconds, 3)
	end)

	test("wait_max_backoff_option_is_validated", function()
		local r = support.rig(repo, {})
		for _, bad in ipairs({ 0, -1, "1" }) do
			local lr = support.loop(r, { wait_max_backoff = bad })
			eq(lr.loop, nil)
			eq(lr.code, "loop_bad_options")
		end
	end)

	test("waiting_does_not_reset_the_consecutive_error_streak", function()
		-- Claude review L1: capture errors alternating with successful waiting
		-- captures must still reach the error budget.
		local calls = 0
		local r = support.rig(repo, {
			capture_impl = function(default_capture)
				return function()
					calls = calls + 1
					if calls % 2 == 1 then
						return nil, "exec_unexpected_fault"
					end
					return default_capture()
				end
			end,
		})
		local lr = support.loop(r, {
			max_consecutive_errors = 2,
			-- Make the capture failure a counted error rather than a transient.
			transient_codes = { broker_capture_failed = false },
			wait_state = function()
				return "mp_ready_blind"
			end,
		})
		local stopped = false
		for _ = 1, 20 do
			local status = lr.loop.update()
			if status == "stopped" then
				stopped = true
				break
			end
			lr.clock.advance(1)
		end
		is_true(stopped, "two errors separated by a wait still stop the loop")
		eq(lr.loop.stats().errors, 2)
	end)

	test("a_decision_in_flight_when_the_wait_begins_still_completes", function()
		local r = support.rig(repo, {})
		local state = { value = nil }
		local lr = support.loop(r, {
			wait_state = function()
				return state.value
			end,
		})
		eq(lr.loop.update(), "issued")
		state.value = "mp_ready_blind"
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r), reason = "play_best" })
		eq(lr.loop.update(), "submitted", "the response to an earlier request is not dropped")
		eq(lr.loop.stats().waits, 0)
		lr.clock.advance(1)
		local status, code = lr.loop.update()
		eq(status, "waiting")
		eq(code, "loop_waiting_for_opponent")
	end)

	-- Minimal broker for the timer exemption: one BLIND_SELECTION capture whose
	-- catalogue holds a wait-compatible START_TIMER candidate.
	local function timer_broker(state)
		local broker = { issued = 0, canceled = 0, submitted = {} }
		function broker.issue()
			broker.issued = broker.issued + 1
			local token = {}
			local request = { observation = { phase = "BLIND_SELECTION" }, actions = {} }
			return token, request, {
				epoch = state.epoch,
				candidate_count = state.wait_actions + 1,
				wait_action_count = state.wait_actions,
			}
		end
		function broker.submit(token, action)
			broker.submitted[#broker.submitted + 1] = action
			state.epoch = state.epoch + 1
			state.wait_actions = 0
			return true, "broker_ok"
		end
		function broker.cancel()
			broker.canceled = broker.canceled + 1
		end
		function broker.is_revoked()
			return false
		end
		function broker.revoke() end
		return broker
	end

	local function timer_loop(state)
		local broker = timer_broker(state)
		local clock = support.clock()
		local transport = support.transport()
		local logger = support.logger()
		local loop = support.load(repo).loop.factory({
			broker = broker,
			transport = transport,
			clock = clock,
			logger = logger,
			min_interval = 0,
			wait_state = function()
				return "mp_ready_blind"
			end,
		})
		return loop, broker, transport, clock
	end

	test("wait_asks_the_policy_once_per_epoch_about_the_timer", function()
		local state = { epoch = 7, wait_actions = 1 }
		local loop, broker, transport, clock = timer_loop(state)
		eq(loop.update(), "issued", "the timer choice is asked about during the wait")
		eq(transport.sent, 1)
		transport.push({ sequence = 1, ok = false, code = "policy_no_action" })
		loop.update()
		clock.advance(5)
		local status, code = loop.update()
		eq(status, "waiting", "same epoch: never asked twice")
		eq(code, "loop_waiting_for_opponent")
		eq(transport.sent, 1)
		eq(loop.stats().wait_decisions, 1)
		eq(loop.stats().errors, 0)
	end)

	test("wait_timer_press_is_submitted_then_the_wait_resumes", function()
		local state = { epoch = 3, wait_actions = 1 }
		local loop, broker, transport, clock = timer_loop(state)
		eq(loop.update(), "issued")
		transport.push({ sequence = 1, ok = true, action = { type = "START_TIMER", id = "t1" }, reason = "timer" })
		eq(loop.update(), "submitted")
		eq(#broker.submitted, 1)
		eq(broker.submitted[1].type, "START_TIMER")
		clock.advance(1)
		eq(loop.update(), "waiting", "timer pressed: nothing left to decide")
		eq(transport.sent, 1)
	end)

	test("wait_without_wait_actions_never_asks", function()
		local state = { epoch = 1, wait_actions = 0 }
		local loop, _, transport, clock = timer_loop(state)
		for _ = 1, 10 do
			loop.update()
			clock.advance(1)
		end
		eq(transport.sent, 0)
		eq(loop.stats().wait_decisions, 0)
	end)

	test("wait_decision_send_failure_is_not_retried_on_the_same_epoch", function()
		local state = { epoch = 9, wait_actions = 1 }
		local loop, _, transport, clock = timer_loop(state)
		transport.request_fault = true
		local status = loop.update()
		is_true(status == "idle" or status == "stopped", tostring(status))
		eq(loop.stats().errors, 1)
		transport.request_fault = false
		clock.advance(5)
		eq(loop.update(), "waiting", "same epoch: hold instead of re-sending")
		eq(transport.sent, 0)
		-- A new epoch (e.g. the opponent moved) earns one new ask.
		state.epoch = 10
		clock.advance(5)
		eq(loop.update(), "issued")
	end)

	-- H2 thinking dwell. A trusted readiness probe reports a decision phase and
	-- the AI's own visible timer; the loop waits BEFORE capturing, then captures
	-- and submits immediately (post-response pacing stays 0).
	local function ready_state(phase, timer)
		return { value = { ready = true, phase = phase, timer_remaining = timer } }
	end

	test("normal_dwell_waits_before_capture_then_issues", function()
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		eq(lr.loop.update(), "dwelling", "ready: dwell before any capture")
		eq(lr.transport.sent, 0, "no policy request before the dwell elapses")
		eq(r.ports.dispatch_calls, 0)
		lr.clock.advance(3.9)
		eq(lr.loop.update(), "dwelling")
		eq(lr.transport.sent, 0)
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued")
		eq(lr.transport.sent, 1)
	end)

	test("cash_out_control_ends_the_decision_so_the_first_shop_is_eight", function()
		-- M1: a successful cash-out control is a committed logical transition.
		-- The round-eval animation time must not be charged to the next shop, and
		-- the first inspection of the new shop is the full 8 s.
		local state = ready_state("PLAY_HAND", nil)
		local controls = support.controls()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4, shop = 6, shop_first = 8 },
			controls = controls,
		})
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(4.1)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r), reason = "play" })
		eq(lr.loop.update(), "submitted")
		-- Cash-out control (ROUND_EVAL), then the button clears.
		state.value = { ready = true, phase = "ROUND_EVAL_CONTROL" }
		controls.name = "cash_out"
		eq(lr.loop.update(), "control")
		controls.clear()
		-- A long cash-out animation passes: it is NOT charged to the shop.
		lr.clock.advance(5)
		state.value = { ready = true, phase = "SHOP", timer_remaining = nil }
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(7.9)
		eq(lr.loop.update(), "dwelling", "the full 8s starts at the shop, not at cash-out")
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued")
	end)

	test("booster_commit_returns_to_the_same_shop_with_the_ordinary_six", function()
		local state = ready_state("SHOP", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4, shop = 6, shop_first = 8, booster = 4 },
		})
		-- First inspection of the shop: 8.
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(8.1)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r), reason = "buy" })
		eq(lr.loop.update(), "submitted")
		-- Open a booster (same visit): 4.
		state.value = { ready = true, phase = "BOOSTER_SELECTION" }
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(4.1)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 2, ok = true, action = play_action(r), reason = "pick" })
		eq(lr.loop.update(), "submitted")
		-- Back in the same shop visit: ordinary 6, never another 8.
		state.value = { ready = true, phase = "SHOP" }
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(5.9)
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued", "same shop visit uses 6s")
	end)

	test("own_timer_cap_shortens_the_dwell", function()
		local state = ready_state("PLAY_HAND", 10)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		-- cap = min(4, max(0, 10-2), 0.2*10) = 2.
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(1.9)
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued")
	end)

	test("terminal_during_dwell_stops_without_dispatch", function()
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		eq(lr.loop.update(), "dwelling")
		state.value = { ready = true, phase = "MATCH_COMPLETE" }
		local status, code = lr.loop.update()
		eq(status, "terminal")
		eq(code, "loop_terminal")
		eq(r.ports.dispatch_calls, 0, "terminal never dispatches")
		eq(lr.transport.sent, 0)
	end)

	test("wait_during_dwell_holds_instead_of_dispatching", function()
		local state = ready_state("PLAY_HAND", nil)
		local wait = { value = nil }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			wait_state = function() return wait.value end,
		})
		eq(lr.loop.update(), "dwelling")
		wait.value = "mp_ready_blind"
		lr.clock.advance(5)
		local status, code = lr.loop.update()
		eq(status, "waiting")
		eq(code, "loop_waiting_for_opponent")
		eq(lr.transport.sent, 0, "a wait never captures")
		eq(lr.loop.stats().waits, 1)
	end)

	test("a_stale_retry_does_not_restart_the_full_dwell", function()
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(4.1)
		eq(lr.loop.update(), "issued")
		-- The state changes before the delivery: the broker refuses the stale
		-- token instead of dispatching it.
		r.world.bump_epoch()
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r), reason = "x" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.stats().stale, 1)
		eq(r.ports.dispatch_calls, 0, "a stale action is never dispatched")
		-- The retry re-issues at once: the carried elapsed is already past target.
		eq(lr.loop.update(), "issued")
	end)

	test("a_no_action_retry_does_not_restart_the_full_dwell", function()
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(4.1)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.stats().no_action, 1)
		-- Past the no-action cooldown the retry issues at once: the carried
		-- elapsed is already past the target, so no fresh 4 s dwell is added.
		lr.clock.advance(0.3)
		eq(lr.loop.update(), "issued")
	end)

	test("a_changing_observation_does_not_restart_the_dwell", function()
		-- Ranked exposes changing opponent score/location, which moves the epoch.
		-- The dwell is wall-clock, so this churn must not restart it.
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		eq(lr.loop.update(), "dwelling")
		local issued_at = nil
		for step = 1, 60 do
			r.world.bump_epoch()
			lr.clock.advance(0.1)
			if lr.loop.update() == "issued" then
				issued_at = step * 0.1
				break
			end
		end
		is_true(issued_at ~= nil and issued_at >= 4.0, "issued after the full dwell: " .. tostring(issued_at))
		eq(lr.transport.sent, 1)
	end)

	test("a_mid_dwell_unready_transient_does_not_restart_the_clock", function()
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(2)
		-- The engine becomes non-actionable mid-dwell (lock/animation); the clock
		-- keeps running rather than restarting.
		state.value = { ready = false }
		eq(lr.loop.update(), "idle")
		lr.clock.advance(2.1) -- 4.1 s since the clock started
		state.value = { ready = true, phase = "PLAY_HAND" }
		eq(lr.loop.update(), "issued", "the carried elapsed already passed the target")
	end)

	test("the_dwell_table_is_copied_at_factory", function()
		local state = ready_state("PLAY_HAND", nil)
		local caller_dwell = { card = 4 }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = caller_dwell,
		})
		caller_dwell.card = 0
		eq(lr.loop.update(), "dwelling", "the factory copy keeps the original 4s dwell")
	end)

	test("an_unready_probe_does_not_capture_or_start_the_clock", function()
		local state = { value = { ready = false } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
		})
		for _ = 1, 10 do
			eq(lr.loop.update(), "idle")
			lr.clock.advance(1)
		end
		eq(lr.transport.sent, 0, "no capture/request while unready")
		-- Readiness arrives: the full dwell starts now, not earlier.
		state.value = { ready = true, phase = "PLAY_HAND", timer_remaining = nil }
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(3.9)
		eq(lr.loop.update(), "dwelling")
		eq(lr.transport.sent, 0)
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued")
	end)

	test("an_overlay_appearing_mid_dwell_does_not_advance_the_clock", function()
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 8,
		})
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(2)
		eq(lr.loop.update(), "dwelling", "2s of real thinking")
		-- A soft overlay/pause appears: the clock freezes immediately.
		state.value = { ready = false, block = "soft", phase = "PLAY_HAND" }
		eq(lr.loop.update(), "idle", "freeze at t=2")
		lr.clock.advance(5)
		eq(lr.loop.update(), "idle", "still frozen after 5s of overlay")
		-- It clears: only the remaining 2s of thinking are needed, so no overlay
		-- time leaked into the decision.
		state.value = { ready = true, phase = "PLAY_HAND" }
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(1.9)
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued", "the overlay time did not advance the dwell")
	end)

	test("a_persistent_soft_overlay_acts_after_the_bounded_grace", function()
		local state = { value = { ready = false, block = "soft", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 2,
		})
		eq(lr.loop.update(), "idle")
		lr.clock.advance(1.9)
		eq(lr.loop.update(), "idle")
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued", "acts under the overlay after the grace")
	end)

	test("a_persistent_soft_overlay_never_exhausts_the_fatal_window", function()
		-- Soft frames must not count toward the hard/fatal not-ready window.
		local state = { value = { ready = false, block = "soft", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			dwell_max = 1000,
			overlay_grace = 1000, -- never act within the test window
			max_transient_seconds = 1,
		})
		for _ = 1, 50 do
			lr.clock.advance(1)
			eq(lr.loop.update(), "idle")
		end
		eq(lr.loop.is_stopped(), false, "50s of soft overlay never exhausts a 1s fatal window")
		eq(lr.loop.stats().not_ready, 0)
		is_true(lr.loop.stats().overlay_idle > 0)
	end)

	test("a_soft_overlay_preserves_the_no_action_cooldown", function()
		-- Regression 1: the soft fallback must not bypass the no-action backoff.
		local state = { value = { ready = false, block = "soft", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 0,
			min_interval = 2,
		})
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		eq(lr.transport.sent, 1)
		-- The immediate next update must idle, not re-issue, and keep one request.
		eq(lr.loop.update(), "idle", "the no-action cooldown is respected under a soft overlay")
		eq(lr.transport.sent, 1, "no repeated capture/request every frame")
	end)

	test("persistent_capture_failures_under_a_soft_overlay_hit_the_capture_bound", function()
		-- Regression: a soft phase must not erase the broker CAPTURE-failure window.
		local state = { value = { ready = false, block = "soft", phase = "PLAY_HAND" } }
		local r = support.rig(repo, { capture_fail_times = 10000 })
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 0,
			max_transient_seconds = 1,
		})
		local stopped = false
		for _ = 1, 20 do
			lr.clock.advance(0.2)
			if lr.loop.update() == "stopped" then
				stopped = true
				break
			end
		end
		is_true(stopped, "persistent capture failures still hit the capture bound under a soft overlay")
	end)

	test("a_soft_overlay_does_not_clear_the_consecutive_error_budget", function()
		-- A soft phase is genuine readiness progress, but it must not clear a
		-- substantive broker error budget.
		local state = ready_state("PLAY_HAND", nil)
		local r = support.rig(repo, { dispatch_result = false })
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 0,
			max_consecutive_errors = 2,
		})
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(4.1)
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = true, action = play_action(r), reason = "x" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.stats().errors, 1)
		state.value = { ready = false, block = "soft", phase = "PLAY_HAND" }
		eq(lr.loop.update(), "issued", "acts under the overlay")
		lr.transport.push({ sequence = 2, ok = true, action = play_action(r), reason = "x" })
		eq(lr.loop.update(), "stopped", "the prior substantive error is not cleared by the soft phase")
		eq(lr.loop.stats().errors, 2)
	end)

	test("a_soft_overlay_respects_the_min_interval", function()
		local state = { value = { ready = false, block = "soft", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 0,
			min_interval = 2,
		})
		eq(lr.loop.update(), "issued")
		lr.transport.push({ sequence = 1, ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		eq(lr.transport.sent, 1)
		lr.clock.advance(1.9)
		eq(lr.loop.update(), "idle", "still inside the min interval / backoff")
		eq(lr.transport.sent, 1)
		lr.clock.advance(0.2)
		eq(lr.loop.update(), "issued")
	end)

	test("a_soft_overlay_keeps_the_verified_wait_backoff", function()
		local state = { value = { ready = false, block = "soft", phase = "PLAY_HAND" } }
		local wait = { value = "mp_ready_blind" }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 0,
			wait_state = function() return wait.value end,
		})
		local status, code = lr.loop.update()
		eq(status, "waiting")
		eq(code, "loop_waiting_for_opponent")
		eq(lr.loop.stats().waits, 1)
		-- The wait cooldown suppresses the next frame (the wait is not re-held).
		eq(lr.loop.update(), "idle")
		eq(lr.loop.stats().waiting_polls, 1)
	end)

	test("soft_time_is_excluded_from_the_hard_deadline", function()
		-- Regression 2: hard -> soft -> hard must not count the soft time toward
		-- the hard fatal wall-clock deadline.
		local state = { value = { ready = false, block = "hard", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 8,
			max_transient_seconds = 1,
		})
		eq(lr.loop.update(), "idle") -- t0 hard
		lr.clock.advance(0.2)
		state.value = { ready = false, block = "soft", phase = "PLAY_HAND" }
		eq(lr.loop.update(), "idle") -- t0.2 soft resets the hard window
		lr.clock.advance(2)
		eq(lr.loop.update(), "idle") -- t2.2 soft, under grace
		state.value = { ready = false, block = "hard", phase = "PLAY_HAND" }
		lr.clock.advance(0.1)
		eq(lr.loop.update(), "idle", "soft time is excluded from the hard deadline") -- t2.3 hard, 0.1s
		eq(lr.loop.is_stopped(), false)
	end)

	test("repeated_soft_episodes_do_not_accumulate_the_hard_deadline", function()
		local state = { value = { ready = false, block = "hard", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 100,
			max_transient_seconds = 1,
		})
		for i = 1, 6 do
			state.value = { ready = false, block = "hard", phase = "PLAY_HAND" }
			lr.clock.advance(0.5)
			is_true(lr.loop.update() ~= "stopped", "hard episode " .. i .. " is bounded")
			state.value = { ready = false, block = "soft", phase = "PLAY_HAND" }
			lr.clock.advance(0.5)
			lr.loop.update()
		end
		is_true(lr.loop.is_stopped() == false, "3s of alternating soft/hard never accumulates past the 1s window")
	end)

	test("a_continuous_hard_overlay_probe_still_stops", function()
		-- A combined lock+overlay (or a persistent hard state) must still stop.
		local state = { value = { ready = false, block = "hard", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			max_transient_seconds = 1,
		})
		local stopped = false
		for _ = 1, 10 do
			lr.clock.advance(0.5)
			if lr.loop.update() == "stopped" then
				stopped = true
				break
			end
		end
		is_true(stopped, "a persistent hard/combined state still stops within the window")
	end)

	test("a_zero_overlay_grace_acts_immediately", function()
		local state = { value = { ready = false, block = "soft", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			overlay_grace = 0,
		})
		eq(lr.loop.update(), "issued", "a zero grace acts under the overlay at once")
	end)

	test("soft_overlay_churn_never_consumes_the_fatal_window", function()
		local state = { value = { ready = true, phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			dwell_max = 1000,
			overlay_grace = 1000,
			max_transient_seconds = 1,
		})
		for i = 1, 40 do
			-- Toggle overlay/pause on and off: the grace resets, and none of it
			-- may count toward the fatal window.
			if i % 2 == 0 then
				state.value = { ready = false, block = "soft", phase = "PLAY_HAND" }
			else
				state.value = { ready = true, phase = "PLAY_HAND" }
			end
			lr.clock.advance(0.5)
			lr.loop.update()
		end
		eq(lr.loop.stats().not_ready, 0, "soft churn never consumes the fatal window")
	end)

	test("a_persistent_hard_lock_still_stops_in_the_bounded_window", function()
		local state = { value = { ready = false, block = "hard", phase = "PLAY_HAND" } }
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { card = 4 },
			max_transient_seconds = 1,
		})
		local stopped = false
		for _ = 1, 10 do
			lr.clock.advance(0.5)
			if lr.loop.update() == "stopped" then
				stopped = true
				break
			end
		end
		is_true(stopped, "a persistent hard lock still stops within the bounded window")
	end)

	test("first_shop_inspection_uses_the_longer_dwell", function()
		local state = ready_state("SHOP", nil)
		local r = support.rig(repo, {})
		local lr = support.loop(r, {
			readiness = function() return state.value end,
			dwell = { shop = 6, shop_first = 8 },
		})
		eq(lr.loop.update(), "dwelling")
		lr.clock.advance(6.1)
		eq(lr.loop.update(), "dwelling", "first inspection still needs 8s total")
		lr.clock.advance(2)
		eq(lr.loop.update(), "issued")
	end)

	test("instant_has_no_dwell", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued", "no readiness probe: legacy immediate path")
		eq(lr.loop.describe().has_readiness, false)
	end)

	test("cooldown_idle_frames_are_counted_as_idle_not_rejections", function()
		local r = support.rig(repo, {})
		local lr = support.loop(r, {})
		eq(lr.loop.update(), "issued")
		-- A legitimate no-action answer backs off; the following cooldown frames
		-- are plain idle ticks, counted separately and never as rejections.
		lr.transport.push({ sequence = 1, ok = false, code = "policy_no_action" })
		eq(lr.loop.update(), "idle")
		eq(lr.loop.stats().no_action, 1)
		local before = lr.loop.stats().rejected
		eq(lr.loop.update(), "idle", "inside the no-action cooldown")
		eq(lr.loop.stats().idle, 1, "idle ticks are their own metric")
		eq(lr.loop.stats().rejected, before, "a cooldown idle tick never adds a rejection")
	end)

	test("dwell_options_are_validated", function()
		local r = support.rig(repo, {})
		local bad = support.loop(r, { dwell = { card = -1 } })
		eq(bad.loop, nil)
		eq(bad.code, "loop_bad_options")
		local bad2 = support.loop(r, { dwell = "x" })
		eq(bad2.loop, nil)
		eq(bad2.code, "loop_bad_options")
		local bad3 = support.loop(r, { readiness = "x" })
		eq(bad3.loop, nil)
		eq(bad3.code, "loop_bad_options")
	end)
end

