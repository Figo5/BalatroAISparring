return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root
	local json = support.json(repo)

	local M1_MODULES = {
		"src/status.lua",
		"src/logger.lua",
		"src/ai_mode.lua",
		"src/dependency.lua",
		"src/host.lua",
	}

	local function count_loads(record)
		return #record.loads
	end

	local function has_load(record, path)
		for i = 1, #record.loads do
			if record.loads[i] == path then
				return true
			end
		end
		return false
	end

	test("default build stays on the inert scaffold with no companion loads", function()
		local fixture = support.core_env(repo, {})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "scaffold_ready", "state")
		eq(result.code, "ok", "code")
		eq(result.ai.status, "disabled_default_off", "ai off")
		eq(count_loads(fixture.record), #M1_MODULES, "only M1 modules loaded")
		eq(fixture.env.Game.update, fixture.original_update, "no update wrapper")
	end)

	test("requested AI without an installed companion config stays blocked", function()
		local fixture = support.core_env(repo, { ai_enabled = true })
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.ai.requested, true, "requested")
		eq(result.ai.status, "requested_no_companion_config", "blocked")
		eq(count_loads(fixture.record), #M1_MODULES, "only M1 modules loaded")
	end)

	test("dependency mismatch fails closed and loads no companion", function()
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			mp_version = "0.5.4",
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "fail_closed", "state")
		eq(result.code, "dependency_version_mismatch", "code")
		eq(result.companion, nil, "no companion")
		eq(count_loads(fixture.record), #M1_MODULES, "only M1 modules loaded")
	end)

	test("missing Multiplayer fails closed even with a companion config", function()
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			mp_present = false,
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
		})
		local _, result = fixture:run()
		eq(result.state, "fail_closed", "state")
		eq(result.code, "dependency_missing", "code")
	end)

	test("live companion boots the reviewed menu over a validated marker", function()
		-- Drive the whole live chain (core.lua -> companion_host -> nfs_reader ->
		-- real default_identity over the injected LuaJIT ffi) so availability is
		-- genuinely true, not just the install. The fake ffi reports the exact
		-- FILETIME the marker carries.
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			-- FILETIME ticks that decode to exactly the marker's create_time
			-- (100000.0) on both runtimes.
			ffi = support.fake_ffi({ ticks = 116445736000000000 }),
			discovery_marker = support.marker(),
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "companion_ready", "state")
		eq(result.code, "ok", "code")
		eq(result.companion.role, "live", "role")
		eq(result.companion.booted, true, "booted")
		eq(result.companion.handling, true, "handling")
		-- Boot-time host readiness: whether the Play entry would open settings or
		-- the unavailable diagnostic. It cannot explain a missing entry.
		eq(result.companion.host_available, true, "host available")
		eq(result.companion.host_available_code, "companion_ok", "availability code")
		local saw_code = false
		for _, line in ipairs(fixture.record.logs) do
			if string.find(line, "host_available_code=", 1, true) then
				saw_code = true
			end
		end
		is_true(saw_code, "availability code is logged (allowlisted)")
		-- With a readable, valid marker and a fresh identity, the reviewed
		-- can_open gate appends the AI Sparring entry to the real wrap.
		local menu = fixture.ui.G.UIDEF.override_main_menu_play_button()
		local found = false
		local function walk(node)
			if type(node) ~= "table" then
				return
			end
			if type(node.config) == "table" and node.config.button == "aisp_open_menu" then
				found = true
			end
			if type(node.nodes) == "table" then
				for i = 1, #node.nodes do
					walk(node.nodes[i])
				end
			end
		end
		walk(menu)
		eq(found, true, "AI entry appended when the host is available")
		-- The real injected companion logger bridge records exactly one bounded,
		-- primitive Play-menu outcome line (event/code only, no path/token).
		local entry_logs = 0
		for _, line in ipairs(fixture.record.logs) do
			if string.find(line, 'event="menu_entry"', 1, true) then
				entry_logs = entry_logs + 1
				is_true(string.find(line, 'code="menu_ok"', 1, true) ~= nil, "valid-entry code")
				is_true(string.find(line, "detail=", 1, true) == nil, "no extra fields")
			end
		end
		eq(entry_logs, 1, "one menu_entry outcome line")
		is_true(has_load(fixture.record, "integration/companion_host.lua"), "companion host loaded")
		is_true(has_load(fixture.record, "ui/practice_menu.lua"), "menu loaded")
		is_true(has_load(fixture.record, "integration/menu_controller.lua"), "controller loaded")
		is_true(fixture.env.Game.update ~= fixture.original_update, "update chain wrapped")
		fixture.env.Game.update(fixture.env.Game, 0.1)
		eq(fixture.record.updates, 1, "original update called once")
		eq(fixture.record.quits, 0, "no quit at boot or first frame")
		-- Capability flags never claim active transport from module presence.
		eq(result.capabilities.network_transport, false, "no transport claim")
		eq(result.capabilities.opponent, false, "no opponent claim")
		eq(result.scaffold_only, false, "companion build")
		-- The live companion is unchanged: it never stages a window.
		eq(#fixture.record.window.calls, 0, "live never stages a window")
		-- Startup log describes the actual boot, not the legacy M1 gate text
		-- (NATIVE_TEST_PROGRESS: "ai_gates_not_implemented ... misleading").
		local resolved = nil
		for _, line in ipairs(fixture.record.logs) do
			is_true(not string.find(line, "not_implemented", 1, true), line)
			if string.find(line, "ai_mode_resolved", 1, true) then
				resolved = line
			end
		end
		is_true(resolved ~= nil and string.find(resolved, "ai_companion_configured", 1, true) ~= nil, tostring(resolved))
	end)

	test("an unreadable marker keeps the companion armed and shows a reachable diagnostic entry", function()
		-- A missing host is now explained, not hidden: the entry appears and its
		-- callback opens the bounded diagnostic. Nothing starts, requests or
		-- quits. The status still carries the bounded reason.
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			files = {},
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "companion_ready", "installed")
		eq(result.companion.host_available, false, "host unavailable")
		eq(result.companion.host_available_code, "companion_marker_absent", "bounded reason")
		local wrapped = fixture.ui.G.UIDEF.override_main_menu_play_button
		is_true(type(wrapped) == "function", "builder wrapped")
		local menu = wrapped()
		local found = false
		local function walk(node)
			if type(node) ~= "table" then
				return
			end
			if type(node.config) == "table" and node.config.button == "aisp_open_menu" then
				found = true
			end
			if type(node.nodes) == "table" then
				for i = 1, #node.nodes do
					walk(node.nodes[i])
				end
			end
		end
		walk(menu)
		eq(found, true, "diagnostic entry shown without a readable marker")
		-- Clicking it opens the bounded diagnostic and never touches start/quit.
		local funcs = fixture.ui.funcs
		is_true(type(funcs.aisp_open_menu) == "function", "owned callback registered")
		funcs.aisp_open_menu()
		local overlay = fixture.ui.G.OVERLAY_MENU
		is_true(type(overlay) == "table", "an overlay was opened")
		local diagnostic = false
		local function walk_overlay(node)
			if type(node) ~= "table" then
				return
			end
			if type(node.config) == "table" and node.config.id == "aisp:diagnostic:back" then
				diagnostic = true
			end
			if type(node.nodes) == "table" then
				for i = 1, #node.nodes do
					walk_overlay(node.nodes[i])
				end
			end
		end
		walk_overlay(overlay.definition)
		eq(diagnostic, true, "the diagnostic definition was opened, not settings")
		eq(fixture.record.quits, 0, "never quits")
	end)

	test("staged AI companion reads the strict launcher environment", function()
		local save = "/stage/AppData/Balatro"
		local mods = "/stage/Mods"
		local mod = "/stage/Mods/AISparring"
		-- The attestation path derives from the expected role save root; the
		-- repository configuration carries no path override.
		local attestation_path = save .. "/aisparring-launcher-attestation.json"
		local attestation = {
			schema = "aisparring.launcher_attestation.v1",
			ok = true,
			nonce = "nonce1",
			session = "session-1",
			role = "ai",
			content_hash = "content1",
			control_port = 49321,
			expected_role_save_root = save,
			expected_role_mods_root = mods,
		}
		local values = support.env_values({ role = "ai", save_root = save, mods_root = mods })
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			env_values = values,
			save_dir = save,
			mods_root = mods,
			mod_root = mod,
			client = { send = function() end },
			companion = { role = "staged" },
			files = { [attestation_path] = json.encode(attestation) },
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "companion_ready", "state")
		eq(result.companion.role, "staged", "role")
		eq(result.companion.staged_role, "ai", "staged role")
		is_true(has_load(fixture.record, "integration/runtime_bootstrap.lua"), "bootstrap loaded")
		is_true(has_load(fixture.record, "integration/wire_json.lua"), "wire encoder loaded")
		is_true(has_load(fixture.record, "integration/decision_loop.lua"), "policy modules loaded for AI")
		-- After the validated attestation, the AI window is titled once and
		-- minimized once before any startup request.
		eq(fixture.record.window.titles[1], "Balatro AI Sparring 0.1.0-dev - AI runtime", "AI window title")
		eq(#fixture.record.window.titles, 1, "AI title set once")
		eq(fixture.record.window.minimizes, 1, "AI minimized once")
	end)

	test("staged companion without an attestation is armed pending, not fatal", function()
		local save = "/stage/AppData/Balatro"
		local mods = "/stage/Mods"
		local values = support.env_values({ role = "ai", save_root = save, mods_root = mods })
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			env_values = values,
			save_dir = save,
			mods_root = mods,
			mod_root = mods .. "/AISparring",
			companion = { role = "staged" },
			files = {},
		})
		local ok, result = fixture:run()
		eq(ok, true, "entrypoint ok")
		eq(result.state, "companion_ready", "armed, not failed")
		eq(result.code, "ok", "code")
		eq(result.companion.booted, false, "not booted yet")
		eq(result.companion.pending, true, "bounded pending")
		eq(result.companion.instance_state, "awaiting_attestation", "pending state")
		is_true(fixture.env.Game.update ~= fixture.original_update, "poll wrapper installed")
		-- A pending staged role performs no window operation at all.
		eq(#fixture.record.window.calls, 0, "no window ops before attestation")
		fixture.env.Game.update(fixture.env.Game, 0.1)
		eq(fixture.record.updates, 1, "original update still called once")
		eq(#fixture.record.window.calls, 0, "still no window ops while pending")
	end)

	test("companion status is primitive-only and mutating it is contained", function()
		local fixture = support.core_env(repo, {
			ai_enabled = true,
			discovery_marker = support.marker(),
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
		})
		fixture:run()
		local status = fixture:status()
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
		status.companion.booted = false
		status.state = "HACKED"
		local fresh = fixture:status()
		eq(fresh.state, "companion_ready", "state stable")
		eq(fresh.companion.booted, true, "companion stable")
	end)
end
