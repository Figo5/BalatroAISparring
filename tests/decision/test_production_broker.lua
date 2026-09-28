return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root

	local function find_action(request, action_type)
		for i = 1, #request.actions do
			if request.actions[i].type == action_type then
				return request.actions[i]
			end
		end
		return nil
	end

	test("default_factory_stays_production_disabled", function()
		local r = support.rig(repo, {
			legacy = true,
			mode = "M3_PRODUCTION",
			production_flag = true,
		})
		is_true(r.broker ~= nil, "legacy factory: " .. tostring(r.broker_code))
		eq(r.broker.fixture_only(), false)
		local token, request = r.broker.issue()
		is_true(token ~= nil, "issue")
		local candidate = find_action(request, "PLAY_CARDS")
		is_true(candidate ~= nil, "candidate")
		local ok, code = r.broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_executor_disabled")
		eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("fixture_sentinel_still_dispatches_via_default_factory", function()
		local r = support.rig(repo, {
			legacy = true,
			fixture = "M2_FIXTURE_ONLY",
		})
		is_true(r.broker ~= nil, "legacy fixture factory: " .. tostring(r.broker_code))
		eq(r.broker.fixture_only(), true)
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local ok, code = r.broker.submit(token, candidate)
		is_true(ok == true, "ok")
		eq(code, "broker_ok")
		eq(r.ports.dispatch_calls, 1, "dispatch_once")
	end)

	test("production_authority_dispatches_on_explicit_true", function()
		local r = support.rig(repo, {})
		is_true(r.broker ~= nil, "authorize: " .. tostring(r.broker_code))
		eq(r.broker.describe().mode, "production")
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local ok, code = r.broker.submit(token, candidate)
		is_true(ok == true, "ok")
		eq(code, "broker_ok")
		eq(r.ports.dispatch_calls, 1, "dispatch_once")
		eq(r.ports.last_action.type, "PLAY_CARDS")
	end)

	test("production_dispatch_explicit_false_is_failure", function()
		local r = support.rig(repo, { dispatch_result = false })
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local ok, code = r.broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_dispatch_failed")
		eq(r.ports.dispatch_calls, 1, "dispatch_attempted")
		local ok2, code2 = r.broker.submit(token, candidate)
		eq(ok2, nil)
		eq(code2, "broker_token_unknown")
	end)

	test("production_token_single_use", function()
		local r = support.rig(repo, {})
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local ok = r.broker.submit(token, candidate)
		is_true(ok == true, "first")
		local replay, code = r.broker.submit(token, candidate)
		eq(replay, nil)
		eq(code, "broker_token_unknown")
		eq(r.ports.dispatch_calls, 1, "dispatch_once")
	end)

	test("production_stale_epoch_rejected_before_dispatch", function()
		local r = support.rig(repo, {})
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		r.world.bump_epoch()
		local ok, code = r.broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_stale_epoch")
		eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("production_validator_false_rejected", function()
		local r = support.rig(repo, { validate_result = false })
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local ok, code = r.broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_validate_failed")
		eq(r.ports.dispatch_calls, 0, "no_dispatch")
	end)

	test("forged_capability_rejected", function()
		local env = support.load(repo)
		local obs = env.observation.factory(env.codec)
		local acts = env.actions.factory(obs, env.codec)
		local authority = env.broker.production_factory(function()
			return true
		end)
		local broker, code = authority.authorize(obs, acts, support.ports(), {})
		eq(broker, nil)
		eq(code, "broker_bad_capability")
		local forged = setmetatable({}, { __metatable = "AISparring.ActionBroker.capability" })
		broker, code = authority.authorize(obs, acts, support.ports(), forged)
		eq(broker, nil)
		eq(code, "broker_bad_capability")
	end)

	test("cross_instance_capability_rejected", function()
		local env = support.load(repo)
		local obs = env.observation.factory(env.codec)
		local acts = env.actions.factory(obs, env.codec)
		local first = env.broker.production_factory(function()
			return true
		end)
		local second = env.broker.production_factory(function()
			return true
		end)
		local capability = first.mint()
		local broker, code = second.authorize(obs, acts, support.ports(), capability)
		eq(broker, nil)
		eq(code, "broker_bad_capability")
		local revoked, revoke_code = second.revoke(capability)
		eq(revoked, false)
		eq(revoke_code, "broker_bad_capability")
	end)

	test("verifier_callback_rejection", function()
		local env = support.load(repo)
		local obs = env.observation.factory(env.codec)
		local acts = env.actions.factory(obs, env.codec)
		local authority = env.broker.production_factory(function()
			return false
		end)
		local capability = authority.mint()
		local broker, code = authority.authorize(obs, acts, support.ports(), capability)
		eq(broker, nil)
		eq(code, "broker_verifier_rejected")
		local throwing = env.broker.production_factory(function()
			error("verifier_fault")
		end)
		local capability2 = throwing.mint()
		local broker2, code2 = throwing.authorize(obs, acts, support.ports(), capability2)
		eq(broker2, nil)
		eq(code2, "broker_verifier_rejected")
	end)

	test("non_function_verifier_rejected", function()
		local env = support.load(repo)
		local authority, code = env.broker.production_factory(nil)
		eq(authority, nil)
		eq(code, "broker_bad_verifier")
		local authority2, code2 = env.broker.production_factory("ai_staged")
		eq(authority2, nil)
		eq(code2, "broker_bad_verifier")
	end)

	test("capability_is_not_serializable_and_opaque", function()
		local env = support.load(repo)
		local authority = env.broker.production_factory(function()
			return true
		end)
		local capability = authority.mint()
		eq(type(capability), "table")
		eq(env.codec.encode(capability), nil)
		local described = authority.describe()
		eq(described.capabilities, 1)
		eq(described.revoked, 0)
	end)

	test("authorize_rejects_fixture_sentinel_ports", function()
		local env = support.load(repo)
		local obs = env.observation.factory(env.codec)
		local acts = env.actions.factory(obs, env.codec)
		local authority = env.broker.production_factory(function()
			return true
		end)
		local capability = authority.mint()
		local ports = support.ports({ fixture = "M2_FIXTURE_ONLY" })
		local broker, code = authority.authorize(obs, acts, ports, capability)
		eq(broker, nil)
		eq(code, "broker_bad_ports")
	end)

	test("authorize_requires_dispatch_port", function()
		local env = support.load(repo)
		local obs = env.observation.factory(env.codec)
		local acts = env.actions.factory(obs, env.codec)
		local authority = env.broker.production_factory(function()
			return true
		end)
		local capability = authority.mint()
		local broker, code = authority.authorize(obs, acts, {
			capture = function()
				return nil
			end,
			validate = function()
				return true
			end,
		}, capability)
		eq(broker, nil)
		eq(code, "broker_bad_ports")
	end)

	test("authority_revoke_before_submit_is_honored", function()
		local r = support.rig(repo, {})
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local revoked, revoke_code = r.authority.revoke(r.capability)
		is_true(revoked == true, "revoke")
		eq(revoke_code, "broker_revoked")
		eq(r.broker.is_revoked(), true)
		eq(r.broker.has_pending(), false, "pending_cleared")
		local ok, code = r.broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_revoked")
		eq(r.ports.dispatch_calls, 0, "no_dispatch")
		local token2, code2 = r.broker.issue()
		eq(token2, nil)
		eq(code2, "broker_revoked")
	end)

	test("broker_cancel_invalidates_pending_token", function()
		local r = support.rig(repo, {})
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local canceled, cancel_code = r.broker.cancel()
		is_true(canceled == true, "cancel")
		eq(cancel_code, "broker_canceled")
		eq(r.broker.has_pending(), false)
		local ok, code = r.broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_token_unknown")
		eq(r.ports.dispatch_calls, 0, "no_dispatch")
		local again, again_code = r.broker.cancel()
		eq(again, false)
		eq(again_code, "broker_no_pending")
	end)

	test("authority_revoke_all_revokes_every_broker", function()
		local env = support.load(repo)
		local obs = env.observation.factory(env.codec)
		local acts = env.actions.factory(obs, env.codec)
		local authority = env.broker.production_factory(function()
			return true
		end)
		local first = authority.authorize(obs, acts, support.ports(), authority.mint())
		local second = authority.authorize(obs, acts, support.ports(), authority.mint())
		is_true(first ~= nil and second ~= nil, "both authorized")
		eq(authority.revoke_all(), 2)
		eq(first.is_revoked(), true)
		eq(second.is_revoked(), true)
		eq(authority.describe().revoked, 2)
	end)

	test("authority_revoke_all_closes_against_new_mint", function()
		local env = support.load(repo)
		local authority = env.broker.production_factory(function()
			return true
		end)
		authority.mint()
		eq(authority.revoke_all(), 1)
		local capability, code = authority.mint()
		eq(capability, nil)
		eq(code, "broker_revoked")
	end)

	test("production_snapshots_trusted_ports_at_authorize", function()
		local r = support.rig(repo, {})
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local swapped_captures = 0
		local swapped_dispatches = 0
		r.ports.capture = function()
			swapped_captures = swapped_captures + 1
			return nil
		end
		r.ports.dispatch = function()
			swapped_dispatches = swapped_dispatches + 1
			return false
		end
		local ok, code = r.broker.submit(token, candidate)
		is_true(ok == true, "snapshot used for submit: " .. tostring(code))
		eq(code, "broker_ok")
		eq(swapped_captures, 0, "a swapped capture port cannot redirect the broker")
		eq(swapped_dispatches, 0, "a swapped dispatch port cannot redirect the broker")
		eq(r.ports.dispatch_calls, 1, "the original dispatch port ran")
	end)

	test("broker_passes_through_exec_pending", function()
		local r = support.rig(repo, { capture_code = "exec_pending" })
		local token, code = r.broker.issue()
		eq(token, nil)
		eq(code, "exec_pending", "the loop can treat the executor pending latch as transient")
	end)

	test("unlisted_port_code_still_collapses_to_capture_failed", function()
		local r = support.rig(repo, { capture_code = "exec_element_missing" })
		local token, code = r.broker.issue()
		eq(token, nil)
		eq(code, "broker_capture_failed")
	end)

	test("broker_passes_through_exec_stall_timeout_as_fatal", function()
		local r = support.rig(repo, { capture_code = "exec_stall_timeout" })
		local token, code = r.broker.issue()
		eq(token, nil)
		eq(code, "exec_stall_timeout",
			"the loop must see the terminal fault verbatim, not broker_capture_failed")
	end)

	test("broker_passes_through_exec_revoked_as_fatal", function()
		local r = support.rig(repo, { capture_code = "exec_revoked" })
		local token, code = r.broker.issue()
		eq(token, nil)
		eq(code, "exec_revoked")
	end)

	test("committed_dispatch_reports_success_on_reentry", function()
		local r
		local nested_code
		r = support.rig(repo, {
			on_dispatch = function()
				local _, code = r.broker.issue()
				nested_code = code
			end,
		})
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		local ok, code = r.broker.submit(token, candidate)
		is_true(ok == true, "committed action is reported committed")
		eq(code, "broker_ok")
		eq(nested_code, "broker_busy", "the nested call is still refused")
		eq(r.ports.dispatch_calls, 1, "never retried")
	end)

	test("precommit_reentry_still_rejected", function()
		local r
		local nested_code
		r = support.rig(repo, {
			on_validate = function()
				local _, code = r.broker.submit(r.token, r.action)
				nested_code = code
			end,
		})
		local token, request = r.broker.issue()
		local candidate = find_action(request, "PLAY_CARDS")
		r.token = token
		r.action = candidate
		local ok, code = r.broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_reentrant")
		eq(nested_code, "broker_busy")
		eq(r.ports.dispatch_calls, 0, "no dispatch from a pre-commit reentry")
	end)
end
