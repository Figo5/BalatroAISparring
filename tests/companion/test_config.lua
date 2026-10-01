-- Authoritative installed-config boundary regressions (the confirmed live bug).
--
-- Steamodded's `load_mod_config` overlays the user-persisted saved config
-- recursively over the installed default, so `smods.Mods["AISparring"].config`
-- can carry a stale `role`/`discovery_path` (the live d1a9a80 install pointed at
-- the current phase-h host, but a saved descriptor from an older checkout overrode
-- it). core.lua must read BOTH the companion descriptor and the enable flag from
-- THIS mod's own installed `config.lua` through the trusted `SMODS.load_file`
-- loader. Loader/chunk/non-table failures fail closed to the inert scaffold with
-- one bounded warn; an unrecognized role is inert silently; a recognizable role
-- with malformed live fields is rejected later by the host. None of those ever
-- falls back to the merged saved companion fields.
--
-- The fixture's `smods_merge` is an over-approximation of the real
-- `insert_saved_config` (see tests/companion/support.lua); it only builds the
-- untrusted merged `own.config` and never decides the descriptor.
return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root

	local M1_MODULES = {
		"src/status.lua",
		"src/logger.lua",
		"src/ai_mode.lua",
		"src/dependency.lua",
		"src/host.lua",
	}

	local function has_load(record, path)
		for i = 1, #record.loads do
			if record.loads[i] == path then
				return true
			end
		end
		return false
	end

	local AI_POLICY_PATHS = {
		"integration/state_reader.lua",
		"integration/engine_adapter.lua",
		"integration/production_executor.lua",
		"integration/state_revision.lua",
		"integration/action_broker.lua",
		"integration/decision_loop.lua",
		"ai/observation.lua",
		"ai/actions.lua",
	}

	-- Current install vs an old-checkout saved descriptor (the exact live bug).
	local CURRENT = "C:/current/work/aisparring-host/practice_host.json"
	local STALE = "C:/stale/work/aisparring-host/practice_host.json"
	local CURRENT_DIR = "C:/current/work/aisparring-host"

	test("companion descriptor is read from the mod's own config.lua via the MOD_ID loader", function()
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			companion = { role = "live", discovery_path = CURRENT },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(#fixture.record.config_loads, 1, "one authoritative config load")
		eq(fixture.record.config_loads[1].path, "config.lua", "config path")
		eq(fixture.record.config_loads[1].id, "AISparring", "config MOD_ID")
		eq(result.companion.role, "live", "live role")
		eq(result.companion.diagnostic_path, CURRENT_DIR, "current installed path")
	end)

	test("a saved stale live path cannot override the current installed live path", function()
		local fixture = support.core_env(repo, {
			installed_config = { ai_enabled = true, companion = { role = "live", discovery_path = CURRENT } },
			saved_config = { companion = { role = "live", discovery_path = STALE } },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.companion.role, "live", "live role")
		eq(result.companion.diagnostic_path, CURRENT_DIR, "authoritative current path, not the saved stale path")
		-- The merged table really did carry the stale value, so the assertion above
		-- proves the boundary ignored it rather than that the merge never happened.
		eq(fixture.own.config.companion.discovery_path, STALE, "merged config carries the stale saved path")
	end)

	test("a saved live descriptor cannot override an installed staged role", function()
		local save = "/stage/AppData/Balatro"
		local mods = "/stage/Mods"
		local values = support.env_values({ role = "ai", save_root = save, mods_root = mods })
		local fixture = support.core_env(repo, {
			installed_config = { ai_enabled = true, companion = { role = "staged" } },
			saved_config = { companion = { role = "live", discovery_path = STALE } },
			env_values = values,
			save_dir = save,
			mods_root = mods,
			mod_root = mods .. "/AISparring",
			files = {},
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.companion.role, "staged", "staged role survives a saved live descriptor")
		eq(result.companion.staged_role, "ai", "staged role is the environment role")
		eq(result.companion.pending, true, "armed pending, not a live boot")
		eq(has_load(fixture.record, "ui/practice_menu.lua"), false, "staged never loads the live menu")
	end)

	test("a saved staged descriptor cannot override an installed live role", function()
		local fixture = support.core_env(repo, {
			installed_config = { ai_enabled = true, companion = { role = "live", discovery_path = CURRENT } },
			saved_config = { companion = { role = "staged" } },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.companion.role, "live", "installed live role wins")
		eq(result.companion.staged_role, nil, "not degraded to staged")
	end)

	test("repository default stays inert under a stale saved enable and descriptor", function()
		local fixture = support.core_env(repo, {
			installed_config = { ai_enabled = false, companion = { role = nil, discovery_path = nil } },
			saved_config = { ai_enabled = true, companion = { role = "live", discovery_path = STALE } },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "scaffold_ready", "inert scaffold")
		eq(result.companion, nil, "no companion descriptor")
		eq(result.ai.requested, false, "saved enable does not arm the inert install")
		eq(#fixture.record.loads, #M1_MODULES, "only the five M1 modules")
		eq(has_load(fixture.record, "integration/companion_host.lua"), false, "host not loaded")
	end)

	test("persisted ai_enabled is not consulted; the installed config governs enablement", function()
		-- A stale saved ai_enabled=false must not disarm a certified install...
		local live = support.core_env(repo, {
			installed_config = { ai_enabled = true, companion = { role = "live", discovery_path = CURRENT } },
			saved_config = { ai_enabled = false },
		})
		local ok, result = live:run()
		eq(ok, true, "entrypoint ok")
		is_true(result.companion ~= nil, "installed enablement boots despite a saved false")
		-- ...and a stale saved true must not arm an inert install (covered above).
	end)

	test("a failed or malformed authoritative config fails closed without a saved fallback", function()
		local modes = { "absent", "loader_error", "not_function", "exec_error", "bad_return" }
		for i = 1, #modes do
			local mode = modes[i]
			local fixture = support.core_env(repo, {
				installed_config = { ai_enabled = true, companion = { role = "live", discovery_path = CURRENT } },
				saved_config = { ai_enabled = true, companion = { role = "live", discovery_path = STALE } },
				authoritative_config = mode,
			})
			local ok, result = fixture:run()
			eq(ok, true, "entrypoint ok (" .. mode .. ")")
			eq(result.companion, nil, "no saved companion fallback (" .. mode .. ")")
			eq(result.state, "scaffold_ready", "inert scaffold (" .. mode .. ")")
			eq(result.ai.requested, false, "no saved enable fallback (" .. mode .. ")")
			eq(has_load(fixture.record, "integration/companion_host.lua"), false, "host not loaded (" .. mode .. ")")
			eq(has_load(fixture.record, "ui/practice_menu.lua"), false, "menu not loaded (" .. mode .. ")")
		end
	end)

	test("a malformed authoritative role fails closed rather than using the saved role", function()
		local fixture = support.core_env(repo, {
			installed_config = { ai_enabled = true, companion = { role = "bogus", discovery_path = CURRENT } },
			saved_config = { companion = { role = "live", discovery_path = STALE } },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.companion, nil, "unrecognized role grants no companion")
		eq(result.state, "scaffold_ready", "inert scaffold")
	end)

	test("live role never loads the AI policy/executor set", function()
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			companion = { role = "live", discovery_path = CURRENT },
		})
		fixture:run()
		is_true(has_load(fixture.record, "ui/practice_menu.lua"), "live menu loaded")
		for i = 1, #AI_POLICY_PATHS do
			eq(has_load(fixture.record, AI_POLICY_PATHS[i]), false, "live must not load " .. AI_POLICY_PATHS[i])
		end
		eq(has_load(fixture.record, "integration/mp_driver.lua"), false, "live must not load the staged driver")
		eq(has_load(fixture.record, "integration/runtime_bootstrap.lua"), false, "live must not load the staged bootstrap")
	end)

	test("inert role loads only the five M1 modules and wraps no update", function()
		local fixture = support.core_env(repo, {})
		fixture:run()
		eq(#fixture.record.loads, #M1_MODULES, "only M1 modules")
		for i = 1, #M1_MODULES do
			eq(fixture.record.loads[i], M1_MODULES[i], "module " .. M1_MODULES[i])
		end
		eq(fixture.env.Game.update, fixture.original_update, "no update wrapper")
	end)
end
