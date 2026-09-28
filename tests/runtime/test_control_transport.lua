return function(ctx)
	local support = ctx.support
	local protocol = support.protocol(ctx.repo_root)
	local test = ctx.test

	test("channel_fifo_is_gap_free_across_interleaved_push_pop", function()
		local channel = support.channel()
		channel:push("a")
		channel:push("b")
		ctx.eq(channel:size(), 2)
		ctx.eq(channel:pop(), "a")
		channel:push("c")
		ctx.eq(channel:size(), 2)
		ctx.eq(channel:pop(), "b")
		ctx.eq(channel:pop(), "c")
		ctx.eq(channel:pop(), nil)
		ctx.eq(channel:size(), 0)
	end)

	test("factory_rejects_bad_role", function()
		local transport, code = support.transport(ctx.repo_root, { role = "live" })
		ctx.eq(transport, nil)
		ctx.eq(code, "transport_bad_role")
	end)

	test("factory_rejects_missing_channels", function()
		local transport, code = support.transport(ctx.repo_root, { channels = { to_worker = {} } })
		ctx.eq(transport, nil)
		ctx.eq(code, "transport_bad_channels")
	end)

	test("factory_accepts_love_channel_userdata_methods", function()
		-- Real `love.thread.getChannel` channels are userdata whose push/pop live
		-- on the metatable, so the factory must resolve them via normal protected
		-- indexing, not rawget.
		local sent = {}
		local function love_channel(methods)
			local value = newproxy(true)
			getmetatable(value).__index = methods
			return value
		end
		local transport, code = support.transport(ctx.repo_root, {
			channels = {
				to_worker = love_channel({ push = function(_, line) sent[#sent + 1] = line end }),
				from_worker = love_channel({ pop = function() return nil end }),
			},
		})
		ctx.eq(code, nil)
		ctx.is_true(transport ~= nil)
		ctx.is_true(transport.start())
		ctx.is_true(transport.send("status", {}) ~= nil)
		ctx.eq(#sent, 1)
	end)

	test("factory_rejects_a_userdata_channel_without_the_method", function()
		local value = newproxy(true)
		getmetatable(value).__index = {}
		local transport, code = support.transport(ctx.repo_root, {
			channels = { to_worker = value, from_worker = value },
		})
		ctx.eq(transport, nil)
		ctx.eq(code, "transport_bad_channels")
	end)

	test("coordination_and_decision_wire_sequence_is_globally_monotonic", function()
		local transport, code, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		ctx.eq(code, nil)
		ctx.is_true(transport.start())
		local coordination_id = transport.send(protocol.OPS.HELLO, { content_digest = "c" })
		ctx.eq(coordination_id, "c1")
		local request_id = transport.request({ sequence = 10, observation = { phase = "BLIND_SELECTION" } })
		ctx.eq(request_id, "d10")
		-- The private local decision sequence is mapped from the wire sequence.
		ctx.eq(transport.pending_sequence(), 10)
		ctx.eq(transport.pending_wire_sequence(), 2)
		ctx.eq(transport.wire_sequence(), 2)
		local messages = support.drain_outbound(tctx)
		ctx.eq(#messages, 2, "two outbound envelopes")
		ctx.eq(messages[1].op, "hello")
		ctx.eq(messages[1].sequence, 1)
		ctx.eq(messages[2].op, "decide_begin")
		ctx.eq(messages[2].sequence, 2, "decision wire sequence is global")
		ctx.eq(messages[2].observation.phase, "BLIND_SELECTION")
	end)

	test("decision_request_is_single_slot_and_monotonic", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		ctx.eq(transport.request({ sequence = 10 }), "d10")
		ctx.eq(transport.request({ sequence = 11 }), nil)
		transport.send(protocol.OPS.STATUS, {})
		local cancelled, cancel_code = transport.cancel("d10")
		ctx.is_true(cancelled)
		ctx.eq(cancel_code, "transport_ok")
		local replay, replay_code = transport.request({ sequence = 10 })
		ctx.eq(replay, nil)
		ctx.eq(replay_code, "transport_replay")
		local low, low_code = transport.request({ sequence = 9 })
		ctx.eq(low, nil)
		ctx.eq(low_code, "transport_bad_sequence")
		local messages = support.drain_outbound(tctx)
		ctx.eq(#messages, 3, "hello-less sends: request + status + cancel")
		ctx.eq(messages[3].op, "decide_cancel")
		ctx.eq(messages[3].observation.decision_sequence, 1, "cancel names the owned decision")
		ctx.is_true(messages[3].sequence > messages[2].sequence, "cancel takes a fresh wire sequence")
	end)

	test("cancel_sends_the_wire_frame_before_clearing_the_slot", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		local wire = transport.pending_wire_sequence()
		ctx.eq(transport.pending_sequence(), 10)
		transport.cancel("d10")
		ctx.eq(transport.pending_sequence(), nil)
		-- The mapping survives the cancel so a receipt can still name it.
		local result_id, result_code = transport.decision_result(10, { accepted = false, code = "loop_timeout" })
		ctx.eq(result_code, "transport_ok")
		ctx.is_true(result_id ~= nil)
		local messages = support.drain_outbound(tctx)
		ctx.eq(messages[1].op, "decide_begin")
		ctx.eq(messages[2].op, "decide_cancel")
		ctx.eq(messages[2].observation.decision_sequence, wire)
		ctx.eq(messages[3].op, "decision_result")
		ctx.eq(messages[3].observation.sequence, wire)
		ctx.is_true(messages[3].sequence > messages[2].sequence)
	end)

	test("cancel_never_targets_an_arbitrary_old_job", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		ctx.eq(select(1, transport.cancel("d999")), false)
		ctx.eq(select(2, transport.cancel("d999")), "transport_no_pending")
		ctx.eq(transport.pending_sequence(), 10)
		local messages = support.drain_outbound(tctx)
		ctx.eq(#messages, 1, "no cancel frame for an unknown request id")
		transport.cancel("d10")
		-- A second cancel for the same already-cleared job is a no-op.
		ctx.eq(select(2, transport.cancel("d10")), "transport_no_pending")
	end)

	test("cancel_ack_is_consumed_not_delivered_as_a_decision", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		local wire = transport.pending_wire_sequence()
		transport.cancel("d10")
		support.inbound(tctx, {
			sequence = wire,
			ok = true,
			code = protocol.CODES.DECISION_CANCELLED,
		})
		ctx.eq(transport.poll_decision(), nil)
		ctx.eq(transport.stats().cancel_acks, 1)
		ctx.eq(transport.stats().out_of_order, 0)
	end)

	test("transport_timeout_cancels_its_owned_decision_on_the_wire", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10, request_timeout = 1 })
		transport.start()
		transport.request({ sequence = 10 })
		local wire = transport.pending_wire_sequence()
		tctx.clock.advance(2)
		local response = transport.poll_decision()
		ctx.eq(response.code, "transport_timeout")
		local messages = support.drain_outbound(tctx)
		ctx.eq(messages[1].op, "decide_begin")
		ctx.eq(messages[2].op, "decide_cancel")
		ctx.eq(messages[2].observation.decision_sequence, wire)
	end)

	test("pending_response_does_not_complete_the_slot", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		support.inbound(tctx, {
			sequence = transport.pending_wire_sequence(),
			ok = true,
			code = protocol.CODES.DECISION_PENDING,
		})
		ctx.eq(transport.poll_decision(), nil)
		ctx.eq(transport.pending_sequence(), 10)
	end)

	test("ready_response_completes_the_slot_and_maps_local_sequence", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		support.inbound(tctx, {
			sequence = transport.pending_wire_sequence(),
			ok = true,
			code = protocol.CODES.DECISION_READY,
			action = { type = "SELECT_BLIND", id = "a1" },
		})
		local response = transport.poll_decision()
		ctx.eq(response.sequence, 10)
		ctx.eq(response.action.type, "SELECT_BLIND")
		ctx.eq(transport.pending_sequence(), nil)
		ctx.eq(transport.last_delivered_sequence(), 10)
	end)

	test("failure_response_completes_the_slot", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		support.inbound(tctx, {
			sequence = transport.pending_wire_sequence(),
			ok = false,
			code = protocol.CODES.DECISION_TIMEOUT,
		})
		local response = transport.poll_decision()
		ctx.eq(response.ok, false)
		ctx.eq(response.code, "practice_decision_timeout")
		ctx.eq(response.sequence, 10)
		ctx.eq(transport.pending_sequence(), nil)
	end)

	test("stale_decision_sequence_is_dropped", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		support.inbound(tctx, {
			sequence = transport.pending_wire_sequence() + 100,
			ok = true,
			code = protocol.CODES.DECISION_READY,
			action = {},
		})
		ctx.eq(transport.poll_decision(), nil)
		ctx.eq(transport.stats().out_of_order, 1)
	end)

	test("request_timeout_is_terminal", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10, request_timeout = 1 })
		transport.start()
		transport.request({ sequence = 10 })
		tctx.clock.advance(2)
		local response = transport.poll_decision()
		ctx.eq(response.ok, false)
		ctx.eq(response.code, "transport_timeout")
		ctx.eq(response.sequence, 10)
	end)

	test("decision_result_uses_the_original_wire_sequence_in_payload", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { decision_base = 10 })
		transport.start()
		transport.request({ sequence = 10 })
		local wire = transport.pending_wire_sequence()
		support.inbound(tctx, {
			sequence = wire,
			ok = true,
			code = protocol.CODES.DECISION_READY,
			action = { type = "SELECT_BLIND" },
		})
		transport.poll_decision()
		support.drain_outbound(tctx)
		local id, code = transport.decision_result(10, { accepted = true, code = "broker_ok" })
		ctx.eq(code, "transport_ok")
		ctx.is_true(id ~= nil)
		local messages = support.drain_outbound(tctx)
		ctx.eq(messages[1].op, "decision_result")
		ctx.eq(messages[1].observation.sequence, wire)
		ctx.eq(messages[1].observation.accepted, true)
		ctx.is_true(messages[1].sequence > wire, "result request gets a fresh wire sequence")
		local unknown, unknown_code = transport.decision_result(11, { accepted = true, code = "broker_ok" })
		ctx.eq(unknown, nil)
		ctx.eq(unknown_code, "transport_no_pending")
	end)

	test("send_size_is_bounded", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { max_send = 5 })
		transport.start()
		local id, code = transport.send(protocol.OPS.HELLO, { content_digest = "content" })
		ctx.eq(id, nil)
		ctx.eq(code, "transport_send_too_large")
		ctx.eq(tctx.channels.to_worker:size(), 0)
	end)

	test("receive_size_is_bounded", function()
		local transport, _, tctx = support.transport(ctx.repo_root, { max_receive = 40 })
		transport.start()
		tctx.channels.from_worker:push(string.rep("x", 64))
		support.inbound(tctx, { ok = true, code = protocol.CODES.OK })
		local response = transport.poll_coordination()
		ctx.eq(response.code, protocol.CODES.OK)
		ctx.eq(transport.last_error(), "transport_receive_too_large")
	end)

	test("describe_never_leaks_secrets", function()
		local transport = support.transport(ctx.repo_root)
		local description = transport.describe()
		ctx.eq(rawget(description, "session"), nil)
		ctx.eq(rawget(description, "credential"), nil)
		ctx.is_true(description.session_configured)
		ctx.is_true(description.credential_configured)
	end)

	test("stop_pushes_stop_frame_and_marks_stopped", function()
		local transport, _, tctx = support.transport(ctx.repo_root)
		transport.start()
		transport.stop()
		local messages = support.drain_outbound(tctx)
		ctx.eq(messages[1].t, "stop")
		ctx.is_true(transport.is_stopped())
		ctx.eq(transport.send(protocol.OPS.STATUS, {}), nil)
	end)
end
