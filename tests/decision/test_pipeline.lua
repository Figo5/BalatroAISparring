-- Full real-module pipeline fixtures.
--
-- Builds the real StateReader / EngineAdapter / ProductionExecutor over the
-- synthetic engine fixture, authorizes a real production broker against the
-- executor's real ports, and drives the real decision loop. Only the transport
-- is fake; the broker, loop, adapter, reader and executor are the real modules.
-- This is the integration shape the hand-picked status-response fixtures cannot
-- exercise (a stale control latch, a real cash-out phase transition, and a real
-- PLAY_CARDS commit).

return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local repo = ctx.repo_root

	local engine_support = dofile(repo .. "/tests/engine/support.lua")
	local ActionBroker = dofile(repo .. "/AISparring/integration/action_broker.lua")
	local DecisionLoop = dofile(repo .. "/AISparring/integration/decision_loop.lua")

	local function transport()
		local instance = { sent = 0, requests = {}, outbox = {}, canceled = 0 }
		function instance.request(payload)
			instance.sent = instance.sent + 1
			instance.requests[#instance.requests + 1] = payload
			return instance.sent
		end
		function instance.poll()
			if #instance.outbox > 0 then
				return table.remove(instance.outbox, 1)
			end
			return nil
		end
		function instance.cancel()
			instance.canceled = instance.canceled + 1
		end
		return instance
	end

	local function build(opts)
		opts = opts or {}
		local bundle = engine_support.bundle(repo)
		local engine = engine_support.engine(opts.engine or {})
		local clock = engine_support.clock()
		local pipeline = engine_support.pipeline(bundle, engine, {
			element_for = function(name)
				if name == "cash_out" then
					return { config = { button = "cash_out" } }
				end
				return nil
			end,
			clock = clock,
			stall_timeout = opts.stall_timeout or 2.0,
		})
		local authority = ActionBroker.production_factory(function()
			return true
		end)
		local capability = authority.mint()
		local broker = authority.authorize(bundle.obs, bundle.actions, pipeline.executor.broker_ports(), capability)
		local transport_port = transport()
		local controls = {
			next = function()
				return pipeline.executor.last_control_state()
			end,
			advance = function()
				local ok, code = pipeline.executor.advance_ui()
				if ok == true then
					return true
				end
				return nil, code
			end,
		}
		local loop, loop_code = DecisionLoop.factory({
			broker = broker,
			transport = transport_port,
			clock = clock,
			controls = controls,
			timeout = 10,
			get_revision = function()
				return pipeline.revision.current()
			end,
		})
		return {
			bundle = bundle,
			engine = engine,
			clock = clock,
			pipeline = pipeline,
			broker = broker,
			transport = transport_port,
			loop = loop,
			loop_code = loop_code,
		}
	end

	test("real_pipeline_cashout_latch_refreshes_and_progresses", function()
		local r = build({
			engine = {
				state = engine_support.STATES.ROUND_EVAL,
				round_eval = {},
			},
		})
		is_true(r.loop ~= nil, "loop factory: " .. tostring(r.loop_code))
		is_true(r.pipeline.executor ~= nil, "executor factory: " .. tostring(r.pipeline.executor_code))

		-- The trusted capture reports the cash-out control as a transient state.
		local status1, code1 = r.loop.update()
		eq(status1, "idle")
		eq(code1, "loop_transient")
		eq(r.pipeline.executor.last_control_state(), "cash_out")

		-- N3: the transient capture armed a short backoff, so the loop engages
		-- the trusted control on the next eligible step, not the same frame.
		r.clock.advance(0.25)

		-- The loop engages the trusted control exactly once.
		eq(r.loop.update(), "control")
		eq(r.pipeline.executor.last_control_state(), "cash_out")
		eq(r.engine.calls[1].name, "cash_out")

		-- The runtime's last_control_state stays stale until a capture observes the
		-- finished animation. Without the H1 refresh this second call would deadlock
		-- in control_pending forever.
		r.engine.G.STATE = engine_support.STATES.SHOP
		r.engine.G.round_eval = nil
		r.clock.advance(0.25)
		local status3, code3 = r.loop.update()
		eq(status3, "issued")
		eq(code3, "loop_ok")
		eq(r.pipeline.executor.last_control_state(), nil, "capture refreshed the control state")
		eq(r.transport.sent, 1, "the loop made progress after cash-out")
		eq(r.broker.is_revoked(), false)
	end)

	test("real_pipeline_executor_stall_fault_stops_the_match", function()
		local r = build({
			engine = {
				state = engine_support.STATES.ROUND_EVAL,
				round_eval = {},
			},
		})
		is_true(r.loop ~= nil, tostring(r.loop_code))
		local status1, code1 = r.loop.update()
		eq(status1, "idle")
		eq(code1, "loop_transient")
		r.clock.advance(0.25)
		eq(r.loop.update(), "control")

		-- The engine never leaves ROUND_EVAL, so the committed CASH_OUT latch
		-- never completes. `production_executor.lua:691-701` latches that as the
		-- terminal fault `exec_stall_timeout` (not a release). The broker passes
		-- the fault through (N4) and the loop must stop and revoke immediately:
		-- it must not wait out the 120s transient window nor run past the fault
		-- as the previous version of this test asserted.
		local stopped = false
		local fault_code = nil
		for _ = 1, 20 do
			local status, code = r.loop.update()
			if status == "stopped" then
				stopped = true
				fault_code = code
				break
			end
			r.clock.advance(0.25)
		end
		is_true(stopped, "the executor stall fault stops the match")
		eq(fault_code, "exec_stall_timeout")
		eq(r.loop.stats().faults, 1)
		eq(r.broker.is_revoked(), true, "a terminal fault revokes the authority")
		eq(r.transport.sent, 0, "no decision request was issued")
	end)

	test("real_pipeline_pending_commit_wait_is_frame_rate_independent", function()
		-- The executor's stall window is 10s: a committed action whose visible
		-- effect is still animating is a *valid* bounded wait (`exec_pending`),
		-- not a fault. At 144 FPS the loop must not trip its transient streak
		-- guard by re-capturing every frame; 8s of frames is still well inside
		-- the executor window and must not stop the match.
		local r = build({
			stall_timeout = 10.0,
			engine = {
				hand = {
					engine_support.card({ rank = "Ace", suit = "Spades" }),
					engine_support.card({ rank = "King", suit = "Hearts" }),
				},
			},
		})
		is_true(r.loop ~= nil, tostring(r.loop_code))
		eq(r.loop.update(), "issued")

		local handle, capture_code = r.pipeline.executor.capture()
		is_true(handle ~= nil, "capture: " .. tostring(capture_code))
		local list = r.bundle.actions.generate(handle)
		local play
		for i = 1, #list do
			if list[i].type == "PLAY_CARDS" then
				play = list[i]
				break
			end
		end
		is_true(play ~= nil, "no PLAY_CARDS candidate")
		r.transport.outbox[#r.transport.outbox + 1] = { sequence = 1, ok = true, action = play }
		eq(r.loop.update(), "submitted")
		eq(r.engine.calls[1].name, "play_cards_from_highlighted")

		-- The recorder callbacks never mutate `G.hand`, so the committed latch
		-- stays pending. Drive 1152 frames (8s at 144 FPS) and require the loop
		-- to keep holding a transient wait.
		for _ = 1, 1152 do
			r.loop.update()
			r.clock.advance(1 / 144)
			if r.loop.is_stopped() then
				break
			end
		end
		eq(r.loop.is_stopped(), false, "a valid pending commit is not frame-rate bounded")
		eq(r.broker.is_revoked(), false)
		eq(r.loop.stats().faults, 0)
		is_true(r.loop.stats().transient > 0)
	end)

	test("real_pipeline_play_hand_dispatches_through_the_broker", function()
		local r = build({
			engine = {
				hand = {
					engine_support.card({ rank = "Ace", suit = "Spades" }),
					engine_support.card({ rank = "King", suit = "Hearts" }),
				},
			},
		})
		is_true(r.loop ~= nil, "loop factory: " .. tostring(r.loop_code))
		is_true(r.pipeline.executor ~= nil, "executor factory: " .. tostring(r.pipeline.executor_code))
		eq(r.loop.update(), "issued")
		eq(r.transport.sent, 1)

		-- Generate a legal candidate from the same trusted pipeline and answer the
		-- real broker's decision request with it.
		local handle, capture_code = r.pipeline.executor.capture()
		is_true(handle ~= nil, "capture: " .. tostring(capture_code))
		local list = r.bundle.actions.generate(handle)
		local play
		for i = 1, #list do
			if list[i].type == "PLAY_CARDS" then
				play = list[i]
				break
			end
		end
		is_true(play ~= nil, "no PLAY_CARDS candidate")
		r.transport.outbox[#r.transport.outbox + 1] = { sequence = 1, ok = true, action = play }
		eq(r.loop.update(), "submitted")
		eq(r.engine.calls[1].name, "play_cards_from_highlighted")
		eq(r.broker.is_revoked(), false)
	end)
end
