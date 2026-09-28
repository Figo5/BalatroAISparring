return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local host = support.host(ctx.repo_root)
	local identity = support.identity()

	local function inspect(overrides, id)
		return host.inspect_marker(support.marker(overrides), id or identity)
	end

	test("valid marker accepted with fresh identity", function()
		local info, code = inspect()
		is_true(info ~= nil, "info")
		eq(code, host.CODE.OK, "code")
		eq(info.port, 8788, "port")
		eq(info.session, "host-session-1", "session")
	end)

	test("foreign schema rejected", function()
		local info, code = inspect({ schema = "other" })
		eq(info, nil, "info")
		eq(code, host.CODE.MARKER_SCHEMA, "code")
	end)

	test("wrong host version rejected", function()
		local _, code = inspect({ version = "practice_host/2" })
		eq(code, host.CODE.MARKER_VERSION, "code")
	end)

	test("non-loopback host rejected", function()
		local _, code = inspect({ host = "0.0.0.0" })
		eq(code, host.CODE.MARKER_HOST, "code")
	end)

	test("invalid and out-of-range ports rejected", function()
		eq(select(2, inspect({ port = 0 })), host.CODE.MARKER_PORT, "zero")
		eq(select(2, inspect({ port = 70000 })), host.CODE.MARKER_PORT, "high")
		eq(select(2, inspect({ port = "8788" })), host.CODE.MARKER_PORT, "string")
	end)

	test("short or non-hex secret rejected", function()
		eq(select(2, inspect({ secret = "abcd" })), host.CODE.MARKER_SECRET, "short")
		eq(select(2, inspect({ secret = string.rep("z", 64) })), host.CODE.MARKER_SECRET, "nonhex")
	end)

	test("missing ops rejected", function()
		eq(select(2, inspect({ ops = { "available" } })), host.CODE.MARKER_OPS, "ops")
	end)

	test("enum mismatch rejected", function()
		eq(
			select(2, inspect({ enums = { difficulty = { "rookie" }, pacing = { "instant", "normal" }, mode = { "normal", "gauntlet" }, gauntlet = { "Test1" } } })),
			host.CODE.MARKER_ENUMS,
			"enums"
		)
	end)

	test("stale marker identity rejected", function()
		local stale = support.identity({ create_time = 500000.0 })
		local _, code = inspect({}, stale)
		eq(code, host.CODE.IDENTITY_STALE, "code")
	end)

	test("absent identity port fails closed", function()
		local _, code = host.inspect_marker(support.marker(), nil)
		eq(code, host.CODE.IDENTITY_UNAVAILABLE, "code")
	end)

	test("non-table marker is absent", function()
		local _, code = host.inspect_marker("nope", identity)
		eq(code, host.CODE.MARKER_ABSENT, "code")
	end)

	test("status probe uses lobby code not socket state", function()
		local probe = host.status_probe({
			G = { STAGES = { MAIN_MENU = 1, RUN = 2 }, STAGE = 1 },
			MP = { LOBBY = { connected = true, code = nil } },
			mp_compatible = true,
		})
		local result = probe()
		eq(result.main_menu, true, "main_menu")
		eq(result.active_run, false, "active_run")
		eq(result.mp_connected, false, "no active lobby with connected socket")
		eq(result.mp_compatible, true, "compatible")

		local running = host.status_probe({
			G = { STAGES = { MAIN_MENU = 1, RUN = 2 }, STAGE = 2 },
			MP = { LOBBY = { connected = false, code = "ROOM1" } },
			mp_compatible = true,
		})()
		eq(running.main_menu, false, "not main menu")
		eq(running.active_run, true, "run")
		eq(running.mp_connected, true, "active lobby by code even if socket flag false")
	end)
end
