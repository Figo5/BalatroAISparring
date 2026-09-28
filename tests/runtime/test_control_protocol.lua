return function(ctx)
	local protocol = ctx.support.protocol(ctx.repo_root)
	local test = ctx.test

	test("envelope_has_exact_six_keys", function()
		local envelope = protocol.envelope("sess", "cred", "ai", "hello", 1, nil)
		local count = 0
		for _ in next, envelope do
			count = count + 1
		end
		ctx.eq(count, 6, "key count")
		ctx.eq(envelope.session, "sess")
		ctx.eq(envelope.credential, "cred")
		ctx.eq(envelope.role, "ai")
		ctx.eq(envelope.op, "hello")
		ctx.eq(envelope.sequence, 1)
		-- A nil payload becomes an empty table so the sixth key survives JSON
		-- encoders that drop nil fields; the service accepts {} for these ops.
		ctx.eq(type(envelope.observation), "table")
		local observation_keys = 0
		for _ in next, envelope.observation do
			observation_keys = observation_keys + 1
		end
		ctx.eq(observation_keys, 0)
	end)

	test("gauntlet_seeds_are_stable", function()
		ctx.eq(protocol.gauntlet_seed("Test1"), "AISP0001")
		ctx.eq(protocol.gauntlet_seed("Test2"), "AISP0002")
		ctx.eq(protocol.gauntlet_seed("Test3"), "AISP0003")
		ctx.eq(protocol.gauntlet_seed("Test4"), "AISP0004")
		ctx.eq(protocol.gauntlet_seed("Test5"), "AISP0005")
		ctx.eq(protocol.gauntlet_seed("unknown"), nil)
	end)

	test("ops_cover_coordination_and_decisions", function()
		ctx.eq(protocol.OPS.HELLO, "hello")
		ctx.eq(protocol.OPS.LOBBY_CODE, "lobby_code")
		ctx.eq(protocol.OPS.JOIN_CODE, "join_code")
		ctx.eq(protocol.OPS.READY, "ready")
		ctx.eq(protocol.OPS.START, "start")
		ctx.eq(protocol.OPS.DECIDE_BEGIN, "decide_begin")
		ctx.eq(protocol.OPS.DECIDE_POLL, "decide_poll")
	end)

	test("response_classification", function()
		ctx.is_true(protocol.is_success({ ok = true }))
		ctx.is_true(protocol.is_pending({ code = protocol.CODES.DECISION_PENDING }))
		ctx.is_true(protocol.is_ready({ code = protocol.CODES.DECISION_READY, action = { type = "SELECT_BLIND" } }))
		ctx.is_true(protocol.is_failure({ ok = false, code = "practice_bad_role" }))
	end)

	test("next_sequence_is_strictly_increasing", function()
		local state = {}
		ctx.eq(protocol.next_sequence(state), 1)
		ctx.eq(protocol.next_sequence(state), 2)
		ctx.eq(protocol.next_sequence(state), 3)
	end)
end
