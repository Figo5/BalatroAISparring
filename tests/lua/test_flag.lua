return function(ctx)
	local test, eq, Fixture, repo = ctx.test, ctx.eq, ctx.fixture, ctx.repo_root

	local function run(opts)
		opts.repo_root = repo
		local fixture = Fixture.new(opts)
		local ok, result = fixture:run()
		return fixture, ok, result
	end

	test("AI mode defaults off", function()
		local _, ok, result = run({})
		eq(ok, true, "entrypoint ok")
		eq(result.ai.requested, false, "not requested")
		eq(result.ai.enabled, false, "disabled")
		eq(result.ai.implemented, false, "not implemented")
		eq(result.ai.status, "disabled_default_off", "status")
	end)

	test("requested AI is blocked and inert", function()
		local _, ok, result = run({ ai_enabled = true })
		eq(ok, true, "entrypoint ok")
		eq(result.state, "scaffold_ready", "state")
		eq(result.ai.requested, true, "requested")
		eq(result.ai.enabled, false, "still disabled")
		eq(result.ai.implemented, false, "still not implemented")
		eq(result.ai.status, "requested_blocked_gates_not_implemented", "blocked status")
		eq(result.capabilities.network_transport, false, "no transport")
		eq(result.capabilities.gameplay_hooks, false, "no hooks")
		eq(result.observation_extractor, false, "no extractor")
		eq(result.policy, false, "no policy")
	end)

	test("AI flag requires strictly boolean true", function()
		local _, ok, result = run({ own_config = { ai_enabled = "true" } })
		eq(ok, true, "entrypoint ok")
		eq(result.ai.requested, false, "string is not true")
		local _, ok2, result2 = run({ own_config = { ai_enabled = 1 } })
		eq(ok2, true, "entrypoint ok 2")
		eq(result2.ai.requested, false, "number is not true")
	end)

	test("published getter returns fresh copies", function()
		local fixture, ok, result = run({ ai_enabled = true })
		eq(ok, true, "entrypoint ok")
		eq(type(fixture.own.aisparring), "table", "api attached")
		local api = fixture.own.aisparring
		local first = api.get_status()
		eq(first.state, "scaffold_ready", "first state")
		first.ai.enabled = true
		first.ai.requested = false
		first.capabilities.network_transport = true
		first.gates[1] = "HACKED"
		first.dependency.compatible = false
		local second = api.get_status()
		eq(second.ai.enabled, false, "ai copy")
		eq(second.ai.requested, true, "requested copy")
		eq(second.capabilities.network_transport, false, "capability copy")
		eq(second.gates[1], "P0", "gates copy")
		eq(second.dependency.compatible, true, "dependency copy")
		eq(result.state, "scaffold_ready", "original result untouched")
	end)

	test("getter exposes no functions", function()
		local fixture = Fixture.new({ repo_root = repo })
		fixture:run()
		local status = fixture.own.aisparring.get_status()
		local function scan(value)
			for key, item in pairs(value) do
				if type(item) == "function" then
					error("function leaked at " .. tostring(key), 2)
				end
				if type(item) == "table" then
					scan(item)
				end
			end
		end
		scan(status)
		eq(type(status.ai), "table", "ai present")
	end)

	test("repeated bootstrap publish is consistent", function()
		local fixture = Fixture.new({ repo_root = repo, ai_enabled = true })
		local ok1, first = fixture:run()
		local ok2, second = fixture:run()
		eq(ok1, true, "first run")
		eq(ok2, true, "second run")
		eq(first.state, second.state, "state stable")
		eq(first.code, second.code, "code stable")
		local status_a = fixture.own.aisparring.get_status()
		local status_b = fixture.own.aisparring.get_status()
		eq(status_a.state, status_b.state, "getter state stable")
		eq(status_a.ai.requested, status_b.ai.requested, "getter flag stable")
		eq(status_a.dependency.compatible, second.dependency.compatible, "getter matches result")
	end)
end
