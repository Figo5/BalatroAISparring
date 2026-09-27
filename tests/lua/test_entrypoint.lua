return function(ctx)
	local test, eq, Fixture, repo = ctx.test, ctx.eq, ctx.fixture, ctx.repo_root

	local DECLARED = {
		"src/status.lua",
		"src/logger.lua",
		"src/ai_mode.lua",
		"src/dependency.lua",
		"src/host.lua",
	}

	local function raw_key_count(target)
		local count = 0
		for _ in pairs(target) do
			count = count + 1
		end
		return count
	end

	local function run(opts)
		opts.repo_root = repo
		local fixture = Fixture.new(opts)
		local ok, result = fixture:run()
		return fixture, ok, result
	end

	test("ready path has no forbidden side effects", function()
		local fixture, ok, result = run({})
		eq(ok, true, "entrypoint ok")
		eq(result.state, "scaffold_ready", "state")
		eq(#fixture.record.calls, 0, "no forbidden calls")
		eq(#fixture.record.g_reads, 0, "no G reads")
		eq(#fixture.record.g_writes, 0, "no G writes")
		eq(#fixture.record.mp_writes, 0, "no MP writes")
	end)

	test("no new environment globals are created", function()
		local fixture = Fixture.new({ repo_root = repo })
		local before = raw_key_count(fixture.env)
		fixture:run()
		local after = raw_key_count(fixture.env)
		eq(after, before, "env keys unchanged")
	end)

	test("loads only declared scaffold modules", function()
		local fixture = run({})
		eq(#fixture.record.loads, #DECLARED, "module count")
		for i = 1, #DECLARED do
			eq(fixture.record.loads[i], DECLARED[i], "module " .. DECLARED[i])
		end
	end)

	local ALLOWED_KEYS = {
		event = true, code = true, status = true, dependency = true, version = true,
		required_version = true, detail = true, module = true, mod = true,
		count = true, phase = true,
	}

	test("logs stay within safe allowlisted fields", function()
		local fixture, ok = run({})
		eq(ok, true, "entrypoint ok")
		eq(#fixture.record.logs > 0, true, "logs emitted")
		for i = 1, #fixture.record.logs do
			local line = fixture.record.logs[i]
			eq(line:find("seed", 1, true), nil, "no seed field")
			for key in line:gmatch("([%a_]+)=") do
				eq(ALLOWED_KEYS[key], true, "unexpected log field: " .. tostring(key))
			end
		end
	end)

	test("absent SMODS fails closed without publishing", function()
		local fixture, ok, result = run({ smods_present = false })
		eq(ok, true, "entrypoint returns")
		eq(result.state, "fail_closed", "state")
		eq(result.code, "module_load_failed", "code")
		eq(result.module, "status", "first module")
		eq(fixture.own.aisparring, nil, "no api published")
	end)

	test("absent current_mod still reports ready", function()
		local fixture, ok, result = run({ current_mod_present = false })
		eq(ok, true, "entrypoint returns")
		eq(result.state, "scaffold_ready", "state")
		eq(fixture.own.aisparring, nil, "no api published")
	end)

	test("missing module fails closed", function()
		local _, ok, result = run({ fail_module = "src/host.lua" })
		eq(ok, true, "entrypoint returns")
		eq(result.code, "module_load_failed", "code")
		eq(result.module, "host", "module key")
		eq(result.detail, "module_unreadable", "detail")
	end)

	test("throwing module fails closed", function()
		local _, ok, result = run({ throw_module = "src/dependency.lua" })
		eq(ok, true, "entrypoint returns")
		eq(result.code, "module_load_failed", "code")
		eq(result.module, "dependency", "module key")
		eq(result.detail, "module_exec_error", "detail")
	end)

	test("non table module return fails closed", function()
		local _, ok, result = run({ override_module = { ["src/ai_mode.lua"] = "return 42" } })
		eq(ok, true, "entrypoint returns")
		eq(result.code, "module_load_failed", "code")
		eq(result.module, "ai_mode", "module key")
		eq(result.detail, "module_bad_return", "detail")
	end)

	test("module with bad method is contained by outer pcall", function()
		local fixture, ok, result = run({ override_module = { ["src/host.lua"] = "return {}" } })
		eq(ok, true, "entrypoint returns")
		eq(result.code, "bootstrap_failed", "code")
		eq(result.detail, "unhandled_error", "detail")
		eq(fixture.own.aisparring ~= nil, true, "closed status still published")
		eq(fixture.own.aisparring.get_status().code, "bootstrap_failed", "getter reports closed")
	end)

	test("never mutates unrelated global sentinels", function()
		local fixture = Fixture.new({ repo_root = repo })
		local sentinel = { untouched = true }
		rawset(fixture.env, "SENTINEL", sentinel)
		fixture:run()
		eq(rawget(fixture.env, "SENTINEL"), sentinel, "sentinel identity")
		eq(sentinel.untouched, true, "sentinel untouched")
		eq(#fixture.record.mp_writes, 0, "no MP writes")
	end)

	test("throwing logging sinks do not escape", function()
		local fixture, ok, result = run({ throw_logs = true })
		eq(ok, true, "entrypoint returns")
		eq(result.state, "scaffold_ready", "state")
		eq(#fixture.record.logs > 0, true, "log attempts recorded")
	end)

	test("human lobby state and blocked AI flag cause no side effects", function()
		local fixture, ok, result = run({
			mp_lobby = { connected = true, code = "ROOM1" },
			ai_enabled = true,
		})
		eq(ok, true, "entrypoint returns")
		eq(result.state, "scaffold_ready", "state")
		eq(result.ai.requested, true, "requested")
		eq(result.ai.enabled, false, "still disabled")
		eq(#fixture.record.mp_writes, 0, "no MP writes")
		eq(#fixture.record.calls, 0, "no forbidden calls")
		eq(fixture.mp_storage.LOBBY.connected, true, "lobby connected unchanged")
		eq(fixture.mp_storage.LOBBY.code, "ROOM1", "lobby code unchanged")
		eq(fixture.mp_storage.version, "0.5.5", "version unchanged")
	end)

	test("unrelated current_mod gets no attach or mutation", function()
		local fixture, ok, result = run({ current_mod_unrelated = true })
		eq(ok, true, "entrypoint returns")
		eq(result.state, "scaffold_ready", "state")
		eq(fixture.own.aisparring, nil, "own entry untouched")
		eq(rawget(fixture.smods.current_mod, "aisparring"), nil, "unrelated untouched")
	end)

	test("read-only own entry publication failure is contained", function()
		local fixture, ok, result = run({ own_readonly = true })
		eq(ok, true, "entrypoint returns")
		eq(result.state, "scaffold_ready", "state")
		eq(fixture.own.aisparring, nil, "no api published")
		eq(fixture.record.publish_writes > 0, true, "publication was attempted")
	end)

	test("mutating the returned status does not change getter", function()
		local fixture, ok, result = run({})
		eq(ok, true, "entrypoint returns")
		result.state = "HACKED"
		result.ai.enabled = true
		result.capabilities.network_transport = true
		result.dependency.compatible = false
		local status = fixture.own.aisparring.get_status()
		eq(status.state, "scaffold_ready", "state stable")
		eq(status.ai.enabled, false, "ai stable")
		eq(status.capabilities.network_transport, false, "capabilities stable")
		eq(status.dependency.compatible, true, "dependency stable")
	end)

	local function key_list(target)
		local out = {}
		for key in pairs(target) do
			local kind = type(key)
			if kind == "string" or kind == "number" then
				out[#out + 1] = tostring(key)
			end
		end
		table.sort(out, function(a, b)
			return a < b
		end)
		return out
	end

	local function same_keys(a, b)
		if #a ~= #b then
			return false
		end
		for i = 1, #a do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end

	local function has_key(list, key)
		for i = 1, #list do
			if list[i] == key then
				return true
			end
		end
		return false
	end

	test("mod registry identities are preserved", function()
		local flags = { false, true }
		for index = 1, #flags do
			local flag = flags[index]
			local fixture = Fixture.new({ repo_root = repo, ai_enabled = flag })
			local smods_before = key_list(fixture.smods)
			local mods_before = key_list(fixture.smods.Mods)
			local own_before = key_list(fixture.own)
			local third_before = key_list(fixture.third)
			local third_ref = fixture.third
			fixture:run()
			eq(same_keys(key_list(fixture.smods), smods_before), true, "SMODS keys stable")
			eq(same_keys(key_list(fixture.smods.Mods), mods_before), true, "Mods keys stable")
			eq(same_keys(key_list(fixture.third), third_before), true, "third keys stable")
			eq(rawget(fixture.smods.Mods, "ThirdMod"), third_ref, "third identity")
			eq(rawget(fixture.smods.Mods, "Multiplayer"), fixture.mp, "mp identity")
			local own_after = key_list(fixture.own)
			eq(#own_after, #own_before + 1, "own gains exactly one key")
			eq(has_key(own_after, "aisparring"), true, "own gains aisparring")
			for i = 1, #own_before do
				eq(has_key(own_after, own_before[i]), true, "own keeps " .. own_before[i])
			end
		end
	end)
end
