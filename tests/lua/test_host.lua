return function(ctx)
	local test, eq, repo = ctx.test, ctx.eq, ctx.repo_root

	local Host = dofile(repo .. "/AISparring/src/host.lua")

	local function make_mp(over)
		local mp = {
			id = "Multiplayer",
			version = "0.5.5",
			can_load = true,
			disabled = false,
			config = { ai_enabled = false },
			lovely = true,
			GAME = {},
			ACTIONS = { connect = function() end },
			MOD_ACTIONS = {},
			LOBBY = { connected = false, code = nil },
			register_mod_action = function() end,
			current_ruleset = function() end,
		}
		for key, value in pairs(over or {}) do
			mp[key] = value
		end
		return mp
	end

	local function wrap(entry)
		return { Mods = { Multiplayer = entry } }
	end

	test("inspect returns nil when SMODS is unavailable", function()
		local snapshot, err = Host.inspect(nil, {})
		eq(snapshot, nil, "no snapshot")
		eq(err, "smods_unavailable", "error code")
	end)

	test("identity requires MP to be the mod entry", function()
		local entry = make_mp()
		local snapshot = Host.inspect(wrap(entry), {})
		eq(snapshot.present, true, "present")
		eq(snapshot.identity_match, false, "identity mismatch")
		local ok = Host.inspect(wrap(entry), entry)
		eq(ok.identity_match, true, "identity match")
	end)

	test("snapshot normalizes non primitive values", function()
		local entry = make_mp({ version = {}, id = {}, can_load = "yes", disabled = "true" })
		local snapshot = Host.inspect(wrap(entry), entry)
		eq(snapshot.version, nil, "version nil")
		eq(snapshot.version_malformed, true, "version malformed")
		eq(snapshot.id, nil, "id nil")
		eq(snapshot.can_load, nil, "can_load nil")
		eq(snapshot.disabled, false, "disabled normalized")
	end)

	test("inspect detects missing structure and bad lobby state", function()
		local entry = make_mp({
			ACTIONS = false,
			current_ruleset = "nope",
			LOBBY = { connected = "yes", code = 5 },
		})
		local snapshot = Host.inspect(wrap(entry), entry)
		local seen = {}
		for i = 1, #snapshot.structure_missing do
			seen[snapshot.structure_missing[i]] = true
		end
		eq(seen.ACTIONS, true, "ACTIONS")
		eq(seen.current_ruleset, true, "current_ruleset")
		eq(seen["LOBBY.connected"], true, "LOBBY.connected")
		eq(seen["LOBBY.code"], true, "LOBBY.code")
		eq(seen.GAME, nil, "GAME ok")
	end)

	test("rejects incomplete Multiplayer without lovely marker", function()
		local entry = make_mp({ lovely = false })
		local snapshot = Host.inspect(wrap(entry), entry)
		local seen = {}
		for i = 1, #snapshot.structure_missing do
			seen[snapshot.structure_missing[i]] = true
		end
		eq(seen.lovely, true, "lovely missing")
	end)

	test("rejects partial load without ACTIONS.connect", function()
		local entry = make_mp({ ACTIONS = {} })
		local snapshot = Host.inspect(wrap(entry), entry)
		local seen = {}
		for i = 1, #snapshot.structure_missing do
			seen[snapshot.structure_missing[i]] = true
		end
		eq(seen["ACTIONS.connect"], true, "connect missing")
	end)

	test("read_ai_flag requires strictly boolean true", function()
		local function flag(config)
			local entry = make_mp({ config = config })
			local smods = { Mods = { AISparring = entry } }
			return Host.read_ai_flag(smods, "AISparring")
		end
		eq(flag({ ai_enabled = true }), true, "true")
		eq(flag({ ai_enabled = false }), false, "false")
		eq(flag({ ai_enabled = "true" }), false, "string")
		eq(flag({ ai_enabled = 1 }), false, "number")
		eq(flag(nil), false, "no config")
	end)
end
