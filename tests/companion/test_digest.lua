-- Production `core.lua` + human staged boot fixture.
--
-- The runtime driver computes the actual source-derived Major League config
-- digest with `Codec.hash_string`, so the pure codec must be part of the COMMON
-- staged module set for BOTH roles. A human host therefore has to receive the
-- real codec (or it can never send READY) while still never loading the
-- policy/executor/broker/loop set. The fixture intercepts the real modules the
-- entrypoint loads and asserts the hash the driver receives agrees with the
-- actual shipped codec. No game, Mods write, process, socket or thread is used.
return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root
	local json = support.json(repo)
	local Codec = support.load(repo, "AISparring/ai/codec.lua")
	local ControlThread = support.load(repo, "AISparring/integration/control_thread.lua")

	-- The AI-only automation/policy set that the human role must never load.
	local POLICY_PATHS = {
		"integration/state_reader.lua",
		"integration/engine_adapter.lua",
		"integration/production_executor.lua",
		"integration/action_broker.lua",
		"integration/decision_loop.lua",
		"ai/observation.lua",
		"ai/actions.lua",
	}

	local function has_load(record, path)
		for i = 1, #record.loads do
			if record.loads[i] == path then
				return true
			end
		end
		return false
	end

	-- Boot the real production entrypoint for a human staged role with a valid
	-- session-bound attestation, intercepting the exact modules it loads.
	local function staged_fixture(staged_role)
		local save = "/stage/AppData/Balatro"
		local mods = "/stage/Mods"
		local mod = mods .. "/AISparring"
		local attestation_path = save .. "/aisparring-launcher-attestation.json"
		local values = support.env_values({ role = staged_role, save_root = save, mods_root = mods })
		local descriptors = support.descriptors({ role = staged_role, save_root = save, mods_root = mods })
		local attestation = support.attestation_blob(descriptors)
		local captured = { codec = nil, ranked_config = nil, driver_ports = nil, bootstrap_ports = nil }
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			env_values = values,
			save_dir = save,
			mods_root = mods,
			mod_root = mod,
			companion = { role = "staged" },
			files = { [attestation_path] = json.encode(attestation) },
			intercept = function(path, module)
				if type(module) ~= "table" then
					return module
				end
				if path == "ai/codec.lua" then
					captured.codec = module
				elseif path == "integration/ranked_config.lua" then
					captured.ranked_config = module
				elseif path == "integration/mp_driver.lua" and type(module.factory) == "function" then
					local factory = module.factory
					module.factory = function(ports)
						captured.driver_ports = ports
						return factory(ports)
					end
				elseif path == "integration/runtime_bootstrap.lua" and type(module.factory) == "function" then
					local factory = module.factory
					module.factory = function(ports)
						captured.bootstrap_ports = ports
						return factory(ports)
					end
				end
				return module
			end,
		})
		return fixture, captured, descriptors
	end

	local function assert_common_modules(captured, staged_role)
		local modules = captured.bootstrap_ports and captured.bootstrap_ports.modules
		is_true(type(modules) == "table", "bootstrap modules")
		eq(modules.codec, captured.codec, "common codec supplied to the bootstrap")
		is_true(modules.MPDriver ~= nil, "driver module supplied")
		is_true(modules.ranked_config ~= nil, "ranked parity module supplied to " .. staged_role)
		eq(modules.ranked_config, captured.ranked_config, "ranked parity module identity")
		is_true(type(modules.ranked_config.canonical_bytes) == "function", "ranked canonical_bytes")
		is_true(type(modules.ranked_config.digest) == "function", "ranked digest")
		is_true(type(modules.ranked_config.NIL) == "table", "ranked NIL sentinel")
		is_true(type(modules.ranked_config.LOBBY_ORDER) == "table", "ranked field order")
	end

	test("core human staged boot loads the common codec and ranked parity but no policy set", function()
		local fixture, captured = staged_fixture("human")
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "companion_ready", "state")
		eq(result.companion.role, "staged", "role")
		eq(result.companion.staged_role, "human", "staged role")

		is_true(has_load(fixture.record, "ai/codec.lua"), "pure codec loaded for human")
		is_true(has_load(fixture.record, "integration/ranked_config.lua"), "ranked parity loaded for human")
		is_true(captured.codec ~= nil, "codec module captured")
		is_true(captured.ranked_config ~= nil, "ranked parity module captured")
		for _, path in ipairs(POLICY_PATHS) do
			eq(has_load(fixture.record, path), false, "not loaded: " .. path)
		end
		assert_common_modules(captured, "human")
		eq(captured.bootstrap_ports.modules.StateReader, nil, "no StateReader")
		eq(captured.bootstrap_ports.modules.EngineAdapter, nil, "no EngineAdapter")
		eq(captured.bootstrap_ports.modules.ProductionExecutor, nil, "no ProductionExecutor")
		eq(captured.bootstrap_ports.modules.StateRevision, nil, "no StateRevision")
		eq(captured.bootstrap_ports.modules.ActionBroker, nil, "no ActionBroker")
		eq(captured.bootstrap_ports.modules.DecisionLoop, nil, "no DecisionLoop")
		eq(captured.bootstrap_ports.modules.observation, nil, "no observation")
		eq(captured.bootstrap_ports.modules.actions, nil, "no actions")
	end)

	test("core ai staged boot loads the common ranked parity module", function()
		local fixture, captured = staged_fixture("ai")
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "companion_ready", "state")
		eq(result.companion.staged_role, "ai", "staged role")
		is_true(has_load(fixture.record, "ai/codec.lua"), "pure codec loaded for ai")
		is_true(has_load(fixture.record, "integration/ranked_config.lua"), "ranked parity loaded for ai")
		assert_common_modules(captured, "ai")
		is_true(captured.bootstrap_ports.modules.StateReader ~= nil, "AI policy set loaded")
		is_true(captured.bootstrap_ports.modules.DecisionLoop ~= nil, "AI loop loaded")
	end)

	test("core human staged boot supplies a driver hash that agrees with the real codec", function()
		local fixture, captured = staged_fixture("human")
		fixture:run()
		-- The authenticated hello ack is what constructs the human coordination
		-- driver, which is the only consumer of the supplied hash_string.
		local channels = ControlThread.channel_names("nonce1", "human")
		fixture.env.love.thread.getChannel(channels.from_worker):push(json.encode({ ok = true, code = "practice_ok" }))
		fixture.env.Game.update(fixture.env.Game, 0.1)

		local ports = captured.driver_ports
		is_true(type(ports) == "table", "driver factory received its ports")
		eq(ports.role, "human", "driver role")
		is_true(type(ports.hash_string) == "function", "hash_string supplied to the driver")

		local canonical = "ruleset_mp_majorleague|gamemode_mp_attrition|timer_base_seconds=60"
		local expected = Codec.hash_string(canonical)
		is_true(type(expected) == "string" and #expected == 8, "codec digest")
		eq(ports.hash_string(canonical), expected, "driver hash agrees with the shipped codec")
		eq(ports.hash_string(canonical), captured.codec.hash_string(canonical), "driver hash agrees with the loaded codec")
	end)
end
