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
				if overrides.quit_throws then
					error("quit listener failed")
				end
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

	-- Live crash (September 29): the menu passed the bare definition to the real
	-- G.FUNCS.overlay_menu, which expects `{ definition = ... }`; the failed
	-- UIBox build left G.OVERLAY_MENU == true and the next draw crashed.
	test("every live menu screen opens through the real overlay_menu shape", function()
		local instance, state = build_live()
		eq(instance.install(), true, "install")
		local controller = instance.controller()
		local G = state.ui.G
		local function opened(label, before)
			is_true(#state.ustate.overlays == before + 1, label .. " overlay built")
			is_true(type(G.OVERLAY_MENU) == "table", label .. " leaves a real overlay, not the boolean sentinel")
		end
		local n = #state.ustate.overlays
		controller.open_settings()
		opened("settings", n)
		n = #state.ustate.overlays
		G.FUNCS.aisp_select({ config = { id = "aisp:difficulty:rookie" } })
		opened("refresh after select", n)
		n = #state.ustate.overlays
		eq(controller.open_confirm(), true, "confirm prompt")
		opened("confirm", n)
		n = #state.ustate.overlays
		controller.cancel_confirm()
		is_true(G.OVERLAY_MENU ~= true, "cancel never leaves the sentinel")
	end)

	test("a failing overlay build never leaves the boolean sentinel behind", function()
		local instance, state = build_live()
		eq(instance.install(), true, "install")
		local G = state.ui.G
		local real = G.FUNCS.overlay_menu
		G.FUNCS.overlay_menu = function(args)
			G.OVERLAY_MENU = true
			error("UIBox build failed")
		end
		instance.controller().open_settings()
		is_true(G.OVERLAY_MENU ~= true, "sentinel cleared after a failed build")
		G.FUNCS.overlay_menu = real
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
		timeout_state.set_now(timeout_state.now() + support.menu(ctx.repo_root).MenuController.ACK_TIMEOUT + 1)
		timeout_controller.update(timeout_state.now())
		eq(timeout_state.quits(), 0, "timeout does not quit")
		eq(timeout_controller.state(), "failed", "failed state")
	end)

	-- Handoff review (M1/M2/F3/F4/F7): the launcher acks only after ~40 s of
	-- gates; a modal waiting screen stays up and is never closed before the
	-- quit; the ack re-checks the main menu; uninstall closes our screen.
	test("start keeps a modal waiting screen and a slow ack still quits once", function()
		local instance, state = build_live()
		eq(instance.install(), true, "install")
		local controller = instance.controller()
		local G = state.ui.G
		eq(controller.open_confirm(), true, "confirm prompt")
		local exits_before = state.ustate.exits
		eq(controller.confirm_start(), true, "start sent")
		is_true(type(G.OVERLAY_MENU) == "table", "waiting screen is up")
		eq(G.OVERLAY_MENU.config and G.OVERLAY_MENU.config.no_esc, true, "waiting screen is modal (no_esc)")
		eq(state.ustate.exits, exits_before, "the waiting screen is not closed (no settings save before quit)")
		state.set_now(state.now() + 45)
		controller.update(state.now())
		eq(controller.state(), "awaiting_ack", "a 45 s gate is still inside the ack window")
		state.transport.push({ ok = true, code = "practice_host_start_accepted", ticket = "t1" })
		controller.update(state.now())
		eq(state.quits(), 1, "quit exactly once after the slow ack")
		eq(state.ustate.exits, exits_before, "still no overlay exit before the quit")
	end)

	test("an ack after the game left the main menu never quits", function()
		local instance, state = build_live()
		eq(instance.install(), true, "install")
		local controller = instance.controller()
		eq(controller.open_confirm(), true, "confirm prompt")
		eq(controller.confirm_start(), true, "start sent")
		state.ui.G.STAGE = 2
		state.transport.push({ ok = true, code = "practice_host_start_accepted", ticket = "t1" })
		local status = controller.update(state.now())
		eq(status, "failed", "refused")
		eq(state.quits(), 0, "no quit mid-run")
	end)

	test("confirm, diagnostic and error screens are modal", function()
		local instance, state = build_live()
		eq(instance.install(), true, "install")
		local controller = instance.controller()
		local G = state.ui.G
		eq(controller.open_confirm(), true, "confirm prompt")
		eq(G.OVERLAY_MENU.config and G.OVERLAY_MENU.config.no_esc, true, "confirm is modal")
		controller.open_settings()
		is_true(G.OVERLAY_MENU.config == nil or G.OVERLAY_MENU.config.no_esc ~= true, "settings keep Esc")
	end)

	test("uninstall closes an open AI Sparring screen before unregistering", function()
		local instance, state = build_live()
		eq(instance.install(), true, "install")
		local controller = instance.controller()
		local G = state.ui.G
		controller.open_settings()
		is_true(type(G.OVERLAY_MENU) == "table", "settings open")
		controller.uninstall()
		eq(G.OVERLAY_MENU, nil, "our screen was closed")
		eq(G.FUNCS.aisp_select, nil, "callbacks unregistered")
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

	test("the acknowledgement timeout fires through the companion update", function()
		-- Regression: the live companion update used to pass the frame delta as
		-- the controller clock, so `now - started_at` was always negative and the
		-- 10 s acknowledgement timeout never fired.
		local instance, state = build_live()
		instance.install()
		local controller = instance.controller()
		eq(controller.open_confirm(), true, "confirm prompt")
		eq(controller.confirm_start(), true, "start sent")
		-- Never accept the ack; advance the real injected clock past the bound.
		state.set_now(state.now() + support.menu(ctx.repo_root).MenuController.ACK_TIMEOUT + 1)
		local status = instance.update(0.016)
		eq(status, "failed", "update surfaces the timeout")
		eq(controller.state(), "failed", "failed state")
		eq(state.quits(), 0, "timeout never quits")
	end)

	test("a dead worker transport is rebuilt for the next attempt", function()
		local made = {}
		local ports = {
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
			read_discovery = function()
				return support.marker()
			end,
			identity = support.identity(),
			transport_factory = function()
				local built = support.transport()
				made[#made + 1] = built
				return built
			end,
			encode = support.encoder({}),
			json_null = support.NULL,
			JSON = {},
			decode = function()
				return nil
			end,
			quit = function()
				return true
			end,
		}
		local host = host_module.live_host(ports)
		eq(host.available(), true, "available")
		eq(#made, 0, "availability opens no connection (launcher idle timeout, H1)")
		local first = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		is_true(first ~= nil, "first request")
		eq(#made, 1, "first transport built at request time")
		made[1].error_code = "companion_transport_error"
		eq(host.poll_start(first).status, "error", "error surfaced")
		-- The next attempt must rebuild a fresh worker, not reuse the dead one.
		local second = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		is_true(second ~= nil, "second request")
		eq(#made, 2, "a fresh transport was built")
		made[2].push({ ok = true, code = "practice_host_start_accepted", ticket = "t2" })
		local response = host.poll_start(second)
		eq(response.status, "ok", "new worker accepted")
		eq(response.ticket, "t2", "ticket from the new worker")
	end)

	-- Live review H1: the launcher drops a connection after 10 s idle and the
	-- LÖVE channels are process-global by name, so a kept-open connection died
	-- before Start and a rebuilt worker replayed the dead worker's queue.
	local function h1_host(made)
		return host_module.live_host({
			companion = { role = "live", discovery_path = "C:/repo/work/aisparring-host/practice_host.json" },
			read_discovery = function()
				return support.marker()
			end,
			identity = support.identity(),
			transport_factory = function()
				local built = support.transport()
				made[#made + 1] = built
				return built
			end,
			encode = support.encoder({}),
			json_null = support.NULL,
			JSON = {},
			decode = function()
				return nil
			end,
			quit = function()
				return true
			end,
		})
	end

	test("every start opens a fresh connection and releases it after the answer", function()
		local made = {}
		local host = h1_host(made)
		for _ = 1, 3 do
			eq(host.available(), true, "available")
		end
		eq(#made, 0, "browsing the menu opens no connection")
		local first = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		eq(#made, 1, "one connection for the start")
		eq(#made[1].sent, 1, "the request is sent on the fresh connection immediately")
		made[1].push({ ok = false, code = "practice_host_ticket_active" })
		eq(host.poll_start(first).status, "rejected", "rejection surfaced")
		eq(made[1].closed, true, "connection released after the answer")
		local second = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		eq(#made, 2, "the retry uses a new connection")
		eq(#made[2].sent, 1, "only the retry's own request is sent on it")
		made[2].push({ ok = true, code = "practice_host_start_accepted", ticket = "t9" })
		eq(host.poll_start(second).status, "ok", "accepted")
		eq(made[2].closed, true, "released")
	end)

	test("an abandoned request frees the host for the next Start (L4)", function()
		local made = {}
		local host = h1_host(made)
		local first = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		is_true(first ~= nil, "first request")
		local busy_id, busy_code = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		eq(busy_id, nil, "busy while pending")
		eq(host.abandon(first), true, "abandon")
		eq(made[1].closed, true, "abandoned connection released")
		local second = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		is_true(second ~= nil, "a new Start is accepted after abandon")
	end)

	test("a menu timeout abandons the host request so Start works again", function()
		local instance, state = build_live()
		instance.install()
		local controller = instance.controller()
		eq(controller.open_confirm(), true, "confirm")
		eq(controller.confirm_start(), true, "start sent")
		state.set_now(state.now() + support.menu(ctx.repo_root).MenuController.ACK_TIMEOUT + 1)
		eq(instance.update(0.016), "failed", "timed out")
		controller.reset()
		eq(controller.open_confirm(), true, "confirm again")
		eq(controller.confirm_start(), true, "a retry is accepted, not refused as busy")
	end)

	test("a quit that reports failure shows the closable error, not the waiting screen (L1)", function()
		local instance, state = build_live({ quit_throws = true })
		instance.install()
		local controller = instance.controller()
		eq(controller.open_confirm(), true, "confirm")
		eq(controller.confirm_start(), true, "start sent")
		local waiting = state.ui.G.OVERLAY_MENU
		state.transport.push({ ok = true, code = "practice_host_start_accepted", ticket = "t1" })
		controller.update(state.now())
		eq(state.quits(), 1, "quit attempted once")
		eq(controller.state(), "failed", "a failed quit is a failure")
		is_true(type(state.ui.G.OVERLAY_MENU) == "table" and not rawequal(state.ui.G.OVERLAY_MENU, waiting),
			"the waiting screen was replaced by the error screen (it has a Close button)")
	end)

	test("a worker that stopped before answering is an error, not a silent wait", function()
		local made = {}
		local host = h1_host(made)
		local id = host.request_start({ mode = "normal", difficulty = "rookie", pacing = "normal" })
		made[1].worker_stopped = function()
			return true
		end
		local response = host.poll_start(id)
		is_true(response ~= nil, "answered")
		eq(response.status, "error", "a stopped worker is an error")
		eq(made[1].closed, true, "released")
	end)

	test("rebuilt thread transports never share channels (no replay)", function()
		local names = {}
		local channels = {}
		local function channel(name)
			if channels[name] == nil then
				local queue = {}
				channels[name] = {
					push = function(_, value)
						queue[#queue + 1] = value
					end,
					pop = function()
						return table.remove(queue, 1)
					end,
					clear = function()
						for i = #queue, 1, -1 do
							queue[i] = nil
						end
					end,
					queue = queue,
				}
			end
			return channels[name]
		end
		local ports = {
			love = { thread = { getChannel = channel } },
			control_thread = { start = function(_, _, to_name, from_name)
				names[#names + 1] = { to_name, from_name }
				return {}
			end },
			decode = function()
				return nil
			end,
		}
		local info = { port = 27962, pid = 4242, nonce = "abcdef0123456789abcdef0123456789" }
		local first = host_module.thread_transport(ports, info)
		is_true(first ~= nil, "first transport")
		first.send("OLD-START")
		first.close()
		local second = host_module.thread_transport(ports, info)
		is_true(second ~= nil, "second transport")
		eq(#names, 2, "two workers started")
		is_true(names[1][1] ~= names[2][1] and names[1][2] ~= names[2][2], "distinct channel pairs")
		eq(#channels[names[2][1]].queue, 0, "the new worker's inbox holds no old request")
	end)
end
