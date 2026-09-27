return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local repo = ctx.repo_root

	local function rig(opts)
		return Support.rig(repo, opts)
	end

	local function issue_or_fail(r)
		local token, payload = r.broker.issue()
		if token == nil then
			error("issue failed: " .. tostring(payload), 2)
		end
		return token, payload
	end

	test("broker_factory_rejects_bad_inputs", function()
		local env = Support.load(repo)
		local obs = env.observation.factory(env.codec)
		local acts = env.actions.factory(obs, env.codec)
		local broker, code = env.broker.factory(obs, acts, {})
		ctx.is_true(broker == nil, "nil_ports")
		ctx.eq(code, "broker_bad_ports", "ports_code")
		broker, code = env.broker.factory(obs, {}, { capture = function() end, validate = function() end })
		ctx.eq(code, "broker_bad_actions", "actions_code")
		broker, code = env.broker.factory({}, acts, { capture = function() end, validate = function() end })
		ctx.eq(code, "broker_bad_observation", "observation_code")
		broker, code = env.broker.factory(obs, acts, {
			capture = function() end,
			validate = function() end,
			fixture = "M2_FIXTURE_ONLY",
		})
		ctx.eq(code, "broker_bad_ports", "fixture_requires_dispatch")
		broker, code = env.broker.factory(obs, acts, {
			capture = function() end,
			validate = function() end,
			fixture = true,
		})
		ctx.is_true(broker ~= nil, "boolean_fixture_not_sentinel")
		ctx.eq(code, nil, "boolean_fixture_code")
	end)

	test("broker_issue_returns_copies_without_functions", function()
		local r = rig({})
		local token, payload = issue_or_fail(r)
		ctx.is_true(type(token) == "table", "token")
		ctx.is_true(type(payload) == "table", "payload")
		ctx.is_true(type(payload.observation) == "table", "observation")
		ctx.is_true(type(payload.actions) == "table", "actions")
		ctx.is_true(type(payload.actions[1]) == "table", "action")
		ctx.is_true(type(payload.actions[1].id) == "string", "action_id")
		ctx.eq(Support.count_functions(payload), 0, "no_capabilities")
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == nil, "production_submit_fails")
		ctx.eq(code, "broker_executor_disabled", "executor_disabled")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_production_submit_executor_disabled_no_dispatch", function()
		local r = rig({ fixture = false })
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_executor_disabled", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_fixture_submit_dispatches_once", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == true, "ok")
		ctx.eq(code, "broker_ok", "code")
		ctx.eq(r.ports.dispatch_calls, 1, "dispatch_once")
		ctx.is_true(type(r.ports.last_action) == "table", "dispatched_action")
	end)

	test("broker_pending_lifecycle", function()
		local r = rig({ fixture = true })
		ctx.eq(r.broker.has_pending(), false, "initial")
		local token, payload = issue_or_fail(r)
		ctx.eq(r.broker.has_pending(), true, "after_issue")
		r.broker.submit(token, payload.actions[1])
		ctx.eq(r.broker.has_pending(), false, "after_submit")
	end)

	test("broker_replay_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.broker.submit(token, payload.actions[1])
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_token_unknown", "code")
		ctx.eq(r.ports.dispatch_calls, 1, "dispatch_once")
	end)

	test("broker_new_issue_invalidates_previous", function()
		local r = rig({ fixture = true })
		local first = r.broker.issue()
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(first, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_token_unknown", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_forged_plain_token_rejected", function()
		local r = rig({ fixture = true })
		local _, payload = issue_or_fail(r)
		local ok, code = r.broker.submit({}, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_token_invalid", "code")
	end)

	test("broker_forged_tagged_token_rejected", function()
		local r = rig({ fixture = true })
		local _, payload = issue_or_fail(r)
		local forged = setmetatable({}, { __metatable = "AISparring.ActionBroker.token" })
		local ok, code = r.broker.submit(forged, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_token_unknown", "code")
	end)

	test("broker_cross_broker_token_rejected", function()
		local a = rig({ fixture = true })
		local b = rig({ fixture = true })
		local token, payload = issue_or_fail(a)
		local ok, code = b.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_token_unknown", "code")
		ctx.eq(b.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_stale_epoch_before_submit_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.world.bump_epoch()
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_stale_epoch", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_epoch_regression_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.world.set_epoch(3)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_epoch_regression", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_negative_epoch_rejected", function()
		local r = rig({ epoch = -1 })
		local token, code = r.broker.issue()
		ctx.is_true(token == nil, "nil")
		ctx.eq(code, "broker_epoch_invalid", "code")
	end)

	test("broker_changed_money_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.world.set_money(999)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_stale_epoch", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_changed_phase_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.world.set_phase("DISCARD")
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_stale_epoch", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_constant_revision_canonical_change_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.frame.self.money = 999
		r.world.rebuild_constant_revision()
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_observation_changed", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_aba_after_failed_submit_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.world.set_money(999)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_stale_epoch", "first_code")
		ctx.eq(r.broker.has_pending(), false, "token_consumed")
		r.world.set_money(10)
		local ok2, code2 = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok2 == nil, "replay_nil")
		ctx.eq(code2, "broker_token_unknown", "replay_code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_unseen_aba_strict_revision_rejected", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		r.world.set_money(999)
		r.world.set_money(10)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_stale_epoch", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_capture_failure_rejected", function()
		local r = rig({ fixture = true, capture_throws = true })
		local token, code = r.broker.issue()
		ctx.is_true(token == nil, "nil")
		ctx.eq(code, "broker_capture_failed", "code")
	end)

	test("broker_validator_false_rejected", function()
		local r = rig({ fixture = true, validate_result = false })
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_validate_failed", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_validator_throws_rejected", function()
		local r = rig({ fixture = true, validate_throws = true })
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_validate_failed", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_validator_state_change_rejected", function()
		local r
		r = rig({
			fixture = true,
			on_validate = function()
				r.world.set_money(5)
			end,
		})
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_stale_epoch", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_validator_epoch_advance_rejected", function()
		local r
		r = rig({
			fixture = true,
			on_validate = function()
				r.world.bump_epoch()
			end,
		})
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_stale_epoch", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_validator_reentrant_submit_rejected", function()
		local r
		local nested_code
		r = rig({
			fixture = true,
			on_validate = function()
				local _, code = r.broker.submit(r.nested_token, r.nested_action)
				nested_code = code
			end,
		})
		local token, payload = issue_or_fail(r)
		r.nested_token = token
		r.nested_action = payload.actions[1]
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(nested_code, "broker_busy", "nested_busy")
		ctx.eq(code, "broker_reentrant", "outer_reentrant")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_validator_reentrant_issue_rejected", function()
		local r
		local nested_code
		r = rig({
			fixture = true,
			on_validate = function()
				local _, code = r.broker.issue()
				nested_code = code
			end,
		})
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(nested_code, "broker_busy", "nested_busy")
		ctx.eq(code, "broker_reentrant", "outer_reentrant")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_validator_mutation_does_not_alter_dispatch", function()
		local r
		r = rig({
			fixture = true,
			on_validate = function(view)
				view.type = "DISCARD_CARDS"
				view.card_refs[1] = "hand:2"
			end,
		})
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == true, "ok")
		ctx.eq(code, "broker_ok", "code")
		ctx.eq(r.ports.last_action.type, "PLAY_CARDS", "type")
		ctx.eq(r.ports.last_action.card_refs[1], "hand:1", "ref")
	end)

	test("broker_action_not_candidate_rejected", function()
		local r = rig({ fixture = true })
		local token = issue_or_fail(r)
		local ok, code = r.broker.submit(token, { type = "LEAVE_SHOP" })
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_action_not_candidate", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_action_malformed_rejected", function()
		local r = rig({ fixture = true })
		local token = issue_or_fail(r)
		local ok, code = r.broker.submit(token, setmetatable({}, {}))
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_action_malformed", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_dispatch_failure_consumes_token", function()
		local r = rig({ fixture = true, dispatch_throws = true })
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_dispatch_failed", "code")
		ctx.eq(r.ports.dispatch_calls, 1, "dispatch_attempted")
		local ok2, code2 = r.broker.submit(token, payload.actions[1])
		ctx.eq(code2, "broker_token_unknown", "replay_unknown")
	end)

	test("broker_exported_constants_do_not_affect_internals", function()
		local r = rig({ fixture = true })
		r.env.broker.CODE.OK = "hacked"
		r.env.broker.LIMITS.max_actions = 0
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == true, "ok")
		ctx.eq(code, "broker_ok", "code")
	end)

	test("broker_recovers_after_capture_failure", function()
		local r = rig({ fixture = true, capture_fail_times = 1 })
		local token, code = r.broker.issue()
		ctx.is_true(token == nil, "first_failed")
		ctx.eq(code, "broker_capture_failed", "first_code")
		local token2, payload = issue_or_fail(r)
		local ok, code2 = r.broker.submit(token2, payload.actions[1])
		ctx.is_true(ok == true, "recovered")
		ctx.eq(code2, "broker_ok", "recovered_code")
	end)

	test("broker_recovers_after_validator_failure", function()
		local attempts = 0
		local r
		r = rig({
			fixture = true,
			on_validate = function()
				attempts = attempts + 1
				if attempts == 1 then
					error("validator_failure")
				end
			end,
		})
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_validate_failed", "first_code")
		local token2, payload2 = issue_or_fail(r)
		local ok2, code2 = r.broker.submit(token2, payload2.actions[1])
		ctx.is_true(ok2 == true, "recovered")
		ctx.eq(code2, "broker_ok", "recovered_code")
	end)

	test("broker_not_busy_after_reentrant_rejection", function()
		local calls = 0
		local r
		r = rig({
			fixture = true,
			on_validate = function()
				calls = calls + 1
				if calls == 1 then
					r.broker.issue()
				end
			end,
		})
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.eq(code, "broker_reentrant", "reentrant")
		local token2, payload2 = issue_or_fail(r)
		local ok2, code2 = r.broker.submit(token2, payload2.actions[1])
		ctx.is_true(ok2 == true, "recovered")
		ctx.eq(code2, "broker_ok", "recovered_code")
	end)

	test("broker_boolean_fixture_does_not_enable_dispatch", function()
		local r = rig({ fixture_raw = true })
		local token, payload = issue_or_fail(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_executor_disabled", "code")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("broker_internal_error_on_escaping_fault_and_recovers", function()
		local r = rig({ fixture = true })
		local token, payload = issue_or_fail(r)
		Support.arm_capture_escape(r)
		local ok, code = r.broker.submit(token, payload.actions[1])
		ctx.is_true(ok == nil, "nil")
		ctx.eq(code, "broker_internal_error", "internal")
		ctx.eq(r.ports.dispatch_calls, 0, "no_dispatch")
		Support.disarm_capture_escape(r)
		local token2, payload2 = issue_or_fail(r)
		local ok2, code2 = r.broker.submit(token2, payload2.actions[1])
		ctx.is_true(ok2 == true, "recovered")
		ctx.eq(code2, "broker_ok", "recovered_code")
		ctx.eq(r.ports.dispatch_calls, 1, "dispatch_once")
	end)
end
