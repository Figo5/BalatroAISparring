return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local host_module = support.host(ctx.repo_root)

	local function build_host(overrides)
		overrides = overrides or {}
		local encoded = {}
		local transport = overrides.transport or support.transport()
		local ports = {
			companion = {
				role = "live",
				discovery_path = overrides.discovery_path or "C:/repo/work/aisparring-host/practice_host.json",
			},
			read_discovery = overrides.read_discovery or function()
				return support.marker(overrides.marker)
			end,
			identity = overrides.identity or support.identity(),
			transport = transport,
			encode = support.encoder(encoded),
			json_null = support.NULL,
			wire = overrides.wire,
			decode = function()
				return nil
			end,
			JSON = {},
			quit = overrides.quit or function()
				return true
			end,
		}
		local host, code = host_module.live_host(ports)
		return host, code, encoded, transport
	end

	test("available requires a validated marker and fresh identity", function()
		local host = build_host()
		eq(host.available(), true, "available")
		eq(host.diagnostics_path(), "C:/repo/work/aisparring-host", "diagnostics directory")

		local stale = build_host({ identity = support.identity({ create_time = 999999.0 }) })
		eq(stale.available(), false, "stale identity unavailable")

		local absent = build_host({ read_discovery = function()
			return nil
		end })
		eq(absent.available(), false, "absent marker unavailable")
	end)

	test("request_start rejects a bad selection", function()
		local host = build_host()
		eq(select(1, host.request_start({ mode = "normal" })), nil, "missing keys")
		eq(select(1, host.request_start({ mode = "normal", difficulty = "expert", pacing = "normal" })), nil, "bad difficulty")
		eq(select(1, host.request_start({ mode = "gauntlet", difficulty = "rookie", pacing = "normal" })), nil, "gauntlet without index")
		eq(select(1, host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal", gauntlet_index = 2 })), nil, "index on normal")
	end)

	test("request_start binds identity and sends a strict envelope", function()
		local host, _, encoded, transport = build_host()
		local request_id, code = host.request_start({ mode = "normal", difficulty = "competitive", pacing = "instant" })
		is_true(type(request_id) == "string" and #request_id > 0, "request id")
		eq(code, host_module.CODE.OK, "code")
		eq(#transport.sent, 1, "one frame sent")
		local envelope = encoded[1]
		eq(envelope.schema, "aisparring.practice_host.request.v1", "schema")
		eq(envelope.op, "start", "op")
		eq(envelope.auth, string.rep("a", 64), "auth from marker")
		eq(envelope.request.gauntlet, support.NULL, "normal mode sends json null")
		eq(envelope.request.session_id, "host-session-1", "session id")
		eq(envelope.request.difficulty, "competitive", "difficulty")
		eq(envelope.request.pacing, "instant", "pacing")
		eq(envelope.request.live_pid, 777, "current pid")
		eq(envelope.request.live_create_time, 200000.0, "current create time")
	end)

	test("gauntlet index maps to a host-owned label", function()
		local host, _, encoded = build_host()
		local request_id = host.request_start({ mode = "gauntlet", difficulty = "rookie", pacing = "normal", gauntlet_index = 2 })
		is_true(request_id ~= nil, "accepted")
		eq(encoded[1].request.gauntlet, "Test2", "label")
	end)

	test("normal mode without a json null sentinel fails closed", function()
		local encoded = {}
		local ports = {
			companion = { role = "live", discovery_path = "C:/repo/work/x/practice_host.json" },
			read_discovery = function()
				return support.marker()
			end,
			identity = support.identity(),
			transport = support.transport(),
			encode = support.encoder(encoded),
			json_null = nil,
			JSON = {},
			decode = function()
				return nil
			end,
		}
		local host = host_module.live_host(ports)
		local request_id, code = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		eq(request_id, nil, "rejected")
		eq(code, host_module.CODE.JSON_NULL_UNSUPPORTED, "code")
	end)

	test("the wire encoder emits explicit gauntlet null for a normal start", function()
		local smods = support.load(ctx.repo_root, "work/reference/offline/smods-json.lua")
		local WireJson = support.load(ctx.repo_root, "AISparring/integration/wire_json.lua")
		local wire = WireJson.factory(smods)
		local host, _, _, transport = build_host({ wire = wire })
		local request_id = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		is_true(request_id ~= nil, "accepted without any null sentinel")
		eq(#transport.sent, 1, "one frame")
		is_true(string.find(transport.sent[1], '"gauntlet":null', 1, true) ~= nil, "explicit null")
		is_true(string.find(transport.sent[1], '"observation"', 1, true) == nil, "host envelope has no observation")
	end)

	test("poll promotes an accepted ack and a rejection", function()
		local host, _, _, transport = build_host()
		local request_id = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		eq(host.poll_start(request_id), nil, "pending")
		transport.push({ ok = true, code = "practice_host_start_accepted", ticket = "ticket-1" })
		local response = host.poll_start(request_id)
		eq(response.status, "ok", "status")
		eq(response.ticket, "ticket-1", "ticket")

		local second_id = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		transport.push({ ok = false, code = "practice_host_bad_enum" })
		eq(host.poll_start(second_id).status, "rejected", "rejected")
	end)

	test("transport failure surfaces as an error, not a rejection", function()
		local host, _, _, transport = build_host()
		local request_id = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		transport.error_code = "companion_transport_error"
		local response = host.poll_start(request_id)
		eq(response.status, "error", "error status")
	end)

	test("a second request while pending is busy", function()
		local host = build_host()
		is_true(host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" }) ~= nil, "first")
		local second, code = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		eq(second, nil, "busy")
		eq(code, host_module.CODE.BUSY, "code")
	end)

	test("quit delegates to the injected adapter", function()
		local calls = 0
		local host = build_host({ quit = function()
			calls = calls + 1
			return true
		end })
		eq(host.quit(), true, "quit ok")
		eq(calls, 1, "called once")
	end)

	-- Full live assembly: reviewed menu modules + companion host.
	local function build_live(overrides)
		overrides = overrides or {}
		local ui, ustate = support.fake_ui()
		local menu = support.menu(ctx.repo_root)
		local encoded = {}
		local transport = overrides.transport or support.transport()
		local quits = 0
		local now = overrides.now or 100
		local ports = {
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
			transport = transport,
			encode = support.encoder(encoded),
			json_null = support.NULL,
			decode = function()
				return nil
			end,
			JSON = {},
			clock = { now = function()
				return now
			end },
			quit = function()
				quits = quits + 1
				return true
			end,
		}
		local instance = host_module.live(ports)
		return instance, { ui = ui, ustate = ustate, transport = transport, encoded = encoded, quits = function()
			return quits
		end, now = function()
			return now
		end, set_now = function(value)
			now = value
		end }
	end

	test("live assembly installs the menu and only quits on a confirmed ack", function()
		local instance, state = build_live()
		is_true(instance ~= nil, "instance")
		eq(instance.install(), true, "install")
		eq(instance.install(), true, "idempotent install")
		local controller = instance.controller()

		local decorated = controller.decorate_play_menu(state.ui.G.UIDEF.override_main_menu_play_button())
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
		walk(decorated)
		eq(found, true, "practice button appended to the play menu")

		eq(controller.open_confirm(), true, "confirm prompt")
		eq(controller.confirm_start(), true, "start sent")
		eq(controller.state(), "awaiting_ack", "awaiting ack")
		eq(state.quits(), 0, "no quit before ack")
		state.transport.push({ ok = true, code = "practice_host_start_accepted", ticket = "t1" })
		controller.update(state.now())
		eq(state.quits(), 1, "quit exactly once after ack")
		controller.update(state.now())
		eq(state.quits(), 1, "still once")
	end)

	test("cancel, rejection and timeout never quit", function()
		local cancel, cancel_state = build_live()
		cancel.install()
		local cancel_controller = cancel.controller()
		cancel_controller.open_confirm()
		cancel_controller.confirm_start()
		cancel_controller.cancel_confirm()
		eq(cancel_state.quits(), 0, "cancel does not quit")

		local rejected, rejected_state = build_live()
		rejected.install()
		local rejected_controller = rejected.controller()
		rejected_controller.open_confirm()
		rejected_controller.confirm_start()
		rejected_state.transport.push({ ok = false, code = "practice_host_bad_enum" })
		rejected_controller.update(rejected_state.now())
		eq(rejected_state.quits(), 0, "rejection does not quit")
		eq(rejected_controller.state(), "failed", "failed state")

		local timeout, timeout_state = build_live()
		timeout.install()
		local timeout_controller = timeout.controller()
		timeout_controller.open_confirm()
		timeout_controller.confirm_start()
		timeout_state.set_now(timeout_state.now() + 30)
		timeout_controller.update(timeout_state.now())
		eq(timeout_state.quits(), 0, "timeout does not quit")
		eq(timeout_controller.state(), "failed", "failed state")
	end)

	test("non-main-menu probe suppresses the practice button", function()
		local instance, state = build_live()
		instance.install()
		state.ui.G.STAGE = 2
		local controller = instance.controller()
		local name, code = controller.can_open()
		eq(name, nil, "cannot open")
		eq(code, controller.CODE.NOT_MAIN_MENU, "code")
	end)
end
