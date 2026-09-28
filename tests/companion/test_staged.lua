return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local host_module = support.host(ctx.repo_root)

	local function clock()
		local state = { value = 1000 }
		return {
			now = function()
				return state.value
			end,
			advance = function(delta)
				state.value = state.value + delta
			end,
		}, state
	end

	test("missing bootstrap and bad descriptors fail closed", function()
		local instance, code = host_module.staged({ role = "staged" })
		eq(instance, nil, "no bootstrap")
		eq(code, host_module.CODE.STAGED_BOOTSTRAP_FAILED, "code")

		local ports = support.staged_ports(ctx.repo_root)
		ports.descriptors = { role = "ai" }
		local bad, bad_code = host_module.staged(ports)
		eq(bad, nil, "bad descriptors")
		eq(bad_code, host_module.CODE.STAGED_ENV_BAD, "bad code")
	end)

	test("declared role crossing the descriptors is rejected", function()
		local ports = support.staged_ports(ctx.repo_root, { descriptors = { role = "ai" } })
		ports.role = "human"
		local instance, code = host_module.staged(ports)
		eq(instance, nil, "rejected")
		eq(code, host_module.CODE.STAGED_ROLE_CROSSED, "code")
	end)

	test("no attestation source at all fails closed", function()
		local ports = support.staged_ports(ctx.repo_root)
		ports.launcher_attestation = nil
		local instance, code = host_module.staged(ports)
		eq(instance, nil, "rejected")
		eq(code, host_module.CODE.STAGED_ATTESTATION_MISSING, "code")
	end)

	test("an attestation that does not match the descriptors is rejected", function()
		local RuntimeBootstrap = support.load(ctx.repo_root, "AISparring/integration/runtime_bootstrap.lua")
		local ports = support.staged_ports(ctx.repo_root)
		ports.launcher_attestation = support.attestation(support.descriptors(), { nonce = "other" })
		local instance, code = host_module.staged(ports)
		eq(instance, nil, "not installed")
		eq(code, RuntimeBootstrap.CODE.LAUNCHER_UNVERIFIED, "bootstrap rejects the mismatched verdict")
	end)

	local json = support.json(ctx.repo_root)

	test("human staged role boots without policy modules and never activates", function()
		local ports = support.staged_ports(ctx.repo_root, { descriptors = { role = "human" } })
		local instance, code = host_module.staged(ports)
		is_true(instance ~= nil, "instance")
		eq(code, host_module.CODE.OK, "code")
		local status = instance.status()
		eq(status.staged_role, "human", "role")
		eq(status.activated, false, "not activated")
		eq(status.handshake, "sent", "hello sent")
		-- A hello ack arms the human coordination driver but never a policy loop.
		ports.channels.from_worker:push(json.encode({ ok = true }))
		instance.update(0)
		eq(instance.status().activated, false, "still no activation")
		eq(instance.uninstall(), true, "uninstall")
	end)

	test("ai staged role activates only after the authenticated hello ack", function()
		local ports = support.staged_ports(ctx.repo_root, { descriptors = { role = "ai" } })
		local instance, code = host_module.staged(ports)
		is_true(instance ~= nil, "instance")
		eq(code, host_module.CODE.OK, "code")
		eq(instance.status().activated, false, "not activated before ack")
		eq(instance.status().handshake, "sent", "hello sent")
		ports.channels.from_worker:push(json.encode({ ok = true }))
		instance.update(0)
		local status = instance.status()
		eq(status.handshake, "acked", "acked")
		eq(status.activated, true, "activated")
		eq(status.state, "active", "state")
	end)

	test("staged status never leaks credentials, session or nonce", function()
		local ports = support.staged_ports(ctx.repo_root, { descriptors = { role = "ai" } })
		local instance = host_module.staged(ports)
		local status = instance.status()
		local secrets = {
			ports.descriptors.credential,
			ports.descriptors.session,
			ports.descriptors.nonce,
			ports.descriptors.content_hash,
		}
		local function scan(value)
			if type(value) == "string" then
				for i = 1, #secrets do
					eq(value ~= secrets[i], true, "secret leaked: " .. value)
				end
			elseif type(value) == "table" then
				for _, item in pairs(value) do
					scan(item)
				end
			end
		end
		scan(status)
	end)

	test("descriptors can be read from the strict launcher environment", function()
		local values = support.env_values({ role = "ai", difficulty = "major_league" })
		local ports = support.staged_ports(ctx.repo_root, { descriptors = { role = "ai", difficulty = "major_league" } })
		ports.descriptors = nil
		ports.env_reader = support.env_reader(values)
		local instance, code = host_module.staged(ports)
		is_true(instance ~= nil, "instance")
		eq(code, host_module.CODE.OK, "code")
		eq(instance.status().staged_role, "ai", "role")
	end)

	test("a present attestation file is checked field by field", function()
		local descriptors = support.descriptors()
		local cases = {
			{ name = "nonce", overrides = { nonce = "wrong" }, code = host_module.CODE.STAGED_ATTESTATION_UNVERIFIED },
			{ name = "role", overrides = { role = "human" }, code = host_module.CODE.STAGED_ATTESTATION_UNVERIFIED },
			{ name = "hash", overrides = { content_hash = "wrong" }, code = host_module.CODE.STAGED_ATTESTATION_UNVERIFIED },
			{ name = "path", overrides = { save_root = "/stage/Other" }, code = host_module.CODE.STAGED_ATTESTATION_PATH },
		}
		for _, case in ipairs(cases) do
			local reader, reader_state = support.attestation_reader()
			reader_state.blob = support.attestation_blob(descriptors, case.overrides)
			local ports = support.staged_ports(ctx.repo_root, {
				attestation_reader = reader,
				attestation_path = "/stage/AppData/Balatro/aisparring-launcher-attestation.json",
			})
			local instance, code = host_module.staged(ports)
			eq(instance, nil, case.name .. ": rejected")
			eq(code, case.code, case.name .. ": code")
		end
	end)

	test("a deferred attestation file stays pending, then boots on appearance", function()
		local descriptors = support.descriptors()
		local reader, reader_state = support.attestation_reader()
		local fake_clock = clock()
		local ports = support.staged_ports(ctx.repo_root, {
			attestation_reader = reader,
			attestation_path = "/stage/AppData/Balatro/aisparring-launcher-attestation.json",
			clock = fake_clock,
		})
		local instance, code = host_module.staged(ports)
		is_true(instance ~= nil, "pending instance")
		eq(code, host_module.CODE.OK, "deferred boot is not fatal")
		local pending = instance.status()
		eq(pending.booted, false, "not booted")
		eq(pending.pending, true, "pending")
		eq(pending.state, "awaiting_attestation", "state")
		-- Still pending before the launcher writes the file.
		instance.update(0)
		eq(instance.status().booted, false, "still pending")
		-- The launcher now writes a valid session-bound attestation.
		reader_state.blob = support.attestation_blob(descriptors)
		instance.update(0)
		local booted = instance.status()
		eq(booted.booted, true, "booted")
		eq(booted.handshake, "sent", "hello sent after attestation")
		eq(booted.activated, false, "no policy capability before auth")
		ports.channels.from_worker:push(json.encode({ ok = true }))
		instance.update(0)
		eq(instance.status().activated, true, "activated only after the hello ack")
	end)

	test("a slow second role is waited for within the host-plus-margin bound", function()
		-- The host waits up to 90 s for both roles' probes before writing the
		-- attestation, so the companion must still be pending at 90 s and only
		-- give up after its own strictly larger bound.
		local descriptors = support.descriptors()
		local reader, reader_state = support.attestation_reader()
		local fake_clock = clock()
		local ports = support.staged_ports(ctx.repo_root, {
			attestation_reader = reader,
			attestation_path = "/stage/AppData/Balatro/aisparring-launcher-attestation.json",
			clock = fake_clock,
		})
		local instance = host_module.staged(ports)
		fake_clock.advance(90)
		local state = instance.update(0)
		eq(state, "awaiting_attestation", "still waiting at the host bound")
		eq(instance.status().pending, true, "still pending at the host bound")
		-- The slow second role finally lands inside the companion's larger bound.
		fake_clock.advance(10)
		reader_state.blob = support.attestation_blob(descriptors)
		instance.update(0)
		eq(instance.status().booted, true, "booted inside the companion bound")
	end)

	test("a deferred attestation that never arrives fails gracefully", function()
		local reader, _reader_state = support.attestation_reader()
		local fake_clock = clock()
		local ports = support.staged_ports(ctx.repo_root, {
			attestation_reader = reader,
			attestation_path = "/stage/AppData/Balatro/aisparring-launcher-attestation.json",
			clock = fake_clock,
		})
		local instance = host_module.staged(ports)
		fake_clock.advance(host_module.LIMITS.attestation_timeout + 1)
		local state, code = instance.update(0)
		eq(state, "failed", "graceful failure")
		eq(code, host_module.CODE.STAGED_ATTESTATION_TIMEOUT, "timeout code")
		eq(instance.status().activated, false, "never activated")
	end)

	test("AI window is titled and minimized once, only after attestation", function()
		local descriptors = support.descriptors()
		local reader, reader_state = support.attestation_reader()
		local window, window_state = support.window()
		local fake_clock = clock()
		local ports = support.staged_ports(ctx.repo_root, {
			attestation_reader = reader,
			attestation_path = "/stage/AppData/Balatro/aisparring-launcher-attestation.json",
			clock = fake_clock,
			window = window,
			window_state = window_state,
		})
		local instance, code = host_module.staged(ports)
		is_true(instance ~= nil, "pending instance")
		eq(code, host_module.CODE.OK, "deferred boot")
		-- No window operation may happen before the attestation is validated.
		eq(#window_state.calls, 0, "no window calls while awaiting attestation")
		instance.update(0)
		eq(#window_state.calls, 0, "still no window calls while pending")
		-- The launcher writes the valid session-bound attestation.
		reader_state.blob = support.attestation_blob(descriptors)
		instance.update(0)
		eq(instance.status().booted, true, "booted")
		eq(#window_state.titles, 1, "title set once")
		eq(window_state.titles[1], host_module.WINDOW.ai_title, "AI title")
		eq(window_state.minimizes, 1, "AI minimized once")
		eq(window_state.calls[1].op, "setTitle", "title first")
		eq(window_state.calls[2].op, "minimize", "minimize second")
		-- Later ticks never retry the window operations.
		instance.update(0)
		instance.update(0)
		eq(#window_state.titles, 1, "title never repeated")
		eq(window_state.minimizes, 1, "minimize never repeated")
	end)

	test("human window is titled and never minimized", function()
		local window, window_state = support.window()
		local ports = support.staged_ports(ctx.repo_root, {
			descriptors = { role = "human" },
			window = window,
			window_state = window_state,
		})
		local instance, code = host_module.staged(ports)
		is_true(instance ~= nil, "instance")
		eq(code, host_module.CODE.OK, "code")
		eq(#window_state.titles, 1, "title set once")
		eq(window_state.titles[1], host_module.WINDOW.human_title, "human title")
		eq(window_state.minimizes, 0, "human never minimized")
		instance.update(0)
		instance.update(0)
		eq(window_state.minimizes, 0, "still never minimized")
		eq(#window_state.titles, 1, "title never repeated")
	end)

	test("a missing or throwing window method fails closed before startup", function()
		local cases = {
			{ name = "missing setTitle", role = "human", opts = { missing_title = true }, code = host_module.CODE.WINDOW_UNAVAILABLE },
			{ name = "throwing setTitle", role = "human", opts = { fail_title = true }, code = host_module.CODE.WINDOW_FAILED },
			{ name = "missing minimize", role = "ai", opts = { missing_minimize = true }, code = host_module.CODE.WINDOW_UNAVAILABLE },
			{ name = "throwing minimize", role = "ai", opts = { fail_minimize = true }, code = host_module.CODE.WINDOW_FAILED },
		}
		for _, case in ipairs(cases) do
			local window = support.window(case.opts)
			local ports, meta = support.staged_ports(ctx.repo_root, {
				descriptors = { role = case.role },
				window = window,
			})
			local instance, code = host_module.staged(ports)
			eq(instance, nil, case.name .. ": no instance")
			eq(code, case.code, case.name .. ": code")
			-- No authenticated hello / startup request was ever sent.
			eq(meta.channels.to_worker:pop(), nil, case.name .. ": no startup request")
		end
	end)

	test("live role never touches the injected window", function()
		local ui = support.fake_ui()
		local menu = support.menu(ctx.repo_root)
		local window, window_state = support.window()
		local instance = host_module.live({
			practice_menu = menu.PracticeMenu,
			menu_controller = menu.MenuController,
			G = ui.G,
			MP = { LOBBY = { connected = true, code = nil } },
			UIBox_button = ui.UIBox_button,
			create_UIBox_generic_options = ui.create_UIBox_generic_options,
			notify = ui.notify,
			mp_compatible = true,
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
			read_discovery = function()
				return support.marker()
			end,
			identity = support.identity(),
			transport = support.transport(),
			encode = support.encoder({}),
			json_null = support.NULL,
			decode = function()
				return nil
			end,
			JSON = {},
			clock = { now = function() return 100 end },
			quit = function() return true end,
			window = window,
		})
		is_true(instance ~= nil, "live instance")
		if instance ~= nil then
			instance.install()
			instance.update(100)
			instance.uninstall()
		end
		eq(#window_state.calls, 0, "live companion never stages a window")
	end)
end
