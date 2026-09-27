return function(ctx)
	local test, eq, Fixture, repo = ctx.test, ctx.eq, ctx.fixture, ctx.repo_root

	local function run(opts)
		opts.repo_root = repo
		local fixture = Fixture.new(opts)
		return fixture:run()
	end

	local function expect_code(opts, code)
		local ok, result = run(opts)
		eq(ok, true, "entrypoint returns")
		eq(result.state, "fail_closed", "state for " .. code)
		eq(result.code, code, "code")
		return result
	end

	test("ready scaffold when dependency matches", function()
		local ok, result = run({})
		eq(ok, true, "entrypoint ok")
		eq(result.state, "scaffold_ready", "state")
		eq(result.code, "ok", "code")
		eq(result.dependency.compatible, true, "compatible")
		eq(result.dependency.identity_verified, true, "identity verified")
		eq(result.dependency.compatibility, "structural-only", "structural only")
		eq(result.dependency.server_parity, "unproven", "parity unproven")
		eq(result.observation_extractor, false, "no extractor")
		eq(result.policy, false, "no policy")
	end)

	test("missing dependency fails closed", function()
		expect_code({ mp_present = false }, "dependency_missing")
	end)

	test("disabled dependency fails closed", function()
		expect_code({ mp_disabled = true }, "dependency_disabled")
	end)

	test("not loadable dependency fails closed", function()
		expect_code({ mp_can_load = false }, "dependency_not_loadable")
	end)

	test("nonboolean can_load is unknown", function()
		expect_code({ mp_can_load = "yes" }, "dependency_state_unknown")
	end)

	test("nil can_load is unknown", function()
		expect_code({ mp_can_load_nil = true }, "dependency_state_unknown")
	end)

	test("stale MP identity fails closed", function()
		expect_code({ mp_identity_mismatch = true }, "dependency_identity_mismatch")
	end)

	test("unsupported version fails closed with safe token", function()
		local result = expect_code({ mp_version = "0.5.4" }, "dependency_version_mismatch")
		eq(result.dependency.inspected_version, "unsupported", "unsupported token")
		eq(result.dependency.identity_verified, false, "identity not claimed")
	end)

	test("malformed version fails closed with safe token", function()
		local result = expect_code({ mp_version = {} }, "dependency_version_mismatch")
		eq(result.dependency.inspected_version, "malformed", "malformed token")
	end)

	test("missing structure fails closed", function()
		local result = expect_code({ mp_structure = { MOD_ACTIONS = false, current_ruleset = "nope" } }, "dependency_structure_incomplete")
		local seen = {}
		for i = 1, #result.missing do
			seen[result.missing[i]] = true
		end
		eq(seen.MOD_ACTIONS, true, "MOD_ACTIONS missing")
		eq(seen.current_ruleset, true, "current_ruleset missing")
	end)

	test("malformed lobby state fails closed", function()
		local result = expect_code({ mp_lobby = { connected = "yes" } }, "dependency_structure_incomplete")
		eq(result.missing[1], "LOBBY.connected", "lobby connected")
	end)

	test("missing lobby table fails closed", function()
		local result = expect_code({ mp_structure = { LOBBY = false } }, "dependency_structure_incomplete")
		eq(result.missing[1], "LOBBY", "lobby table")
	end)

	test("partial Multiplayer without lovely marker fails closed", function()
		local result = expect_code({ mp_structure = { lovely = false } }, "dependency_structure_incomplete")
		local seen = {}
		for i = 1, #result.missing do
			seen[result.missing[i]] = true
		end
		eq(seen.lovely, true, "lovely missing")
	end)

	test("partial Multiplayer without ACTIONS.connect fails closed", function()
		local result = expect_code({ mp_structure = { ACTIONS = {} } }, "dependency_structure_incomplete")
		local seen = {}
		for i = 1, #result.missing do
			seen[result.missing[i]] = true
		end
		eq(seen["ACTIONS.connect"], true, "connect missing")
	end)

	test("version token normalizes arbitrary values", function()
		local Dependency = dofile(repo .. "/AISparring/src/dependency.lua")
		eq(Dependency.version_token("0.5.5"), "0.5.5", "supported")
		eq(Dependency.version_token("9.9.9"), "unsupported", "unsupported")
		eq(Dependency.version_token(nil), "missing", "missing")
		eq(Dependency.version_token({}), "malformed", "malformed")
		eq(Dependency.version_token("9.9.9", nil, true), "malformed", "explicit malformed")
	end)
end
