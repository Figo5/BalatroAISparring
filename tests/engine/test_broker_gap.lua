return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local ActionBroker = dofile(ctx.repo_root .. "/AISparring/integration/action_broker.lua")

	local function setup(engine_opts, pipeline_opts)
		local engine = support.engine(engine_opts or {})
		local pipeline = support.pipeline(bundle, engine, pipeline_opts or {})
		local broker, code = ActionBroker.factory(bundle.obs, bundle.actions, pipeline.executor.broker_ports())
		is_true(broker ~= nil, "broker factory: " .. tostring(code))
		return engine, pipeline, broker
	end

	test("production_broker_does_not_dispatch_and_asks_for_extension", function()
		local engine, _, broker = setup({ hand = { support.card({}), support.card({}) } })
		local token, request = broker.issue()
		is_true(token ~= nil, "issue")
		is_true(type(request) == "table")
		local candidate
		for i = 1, #request.actions do
			if request.actions[i].type == "PLAY_CARDS" then
				candidate = request.actions[i]
				break
			end
		end
		is_true(candidate ~= nil, "no PLAY_CARDS candidate")
		local ok, code = broker.submit(token, candidate)
		eq(ok, nil)
		eq(code, "broker_executor_disabled")
		eq(#engine.calls, 0, "broker dispatched in production mode")
		eq(broker.fixture_only(), false)
	end)

	test("production_broker_rejects_non_candidate", function()
		local _, _, broker = setup({ hand = { support.card({}) } })
		local token = broker.issue()
		local ok, code = broker.submit(token, { type = "LEAVE_SHOP", id = "forged" })
		eq(ok, nil)
		eq(code, "broker_action_not_candidate")
	end)

	test("production_broker_consumes_token", function()
		local _, _, broker = setup({ hand = { support.card({}) } })
		local token = broker.issue()
		local first = broker.submit(token, { type = "LEAVE_SHOP", id = "x" })
		eq(first, nil)
		local second, second_code = broker.submit(token, { type = "LEAVE_SHOP", id = "x" })
		eq(second, nil)
		eq(second_code, "broker_token_unknown")
	end)
end
