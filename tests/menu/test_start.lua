return function()
	local function has_error_notice(fx)
		for i = 1, #fx.ustate.notifications do
			if fx.ustate.notifications[i].message == fx.modules.MenuController.ERROR_MESSAGE then
				return true
			end
		end
		return false
	end

	test("start.refuses_when_run_active", function()
		local fx = fixture({ probe = { main_menu = true, active_run = true, mp_connected = false, mp_compatible = true } })
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "refused")
		eq(code, fx.modules.MenuController.CODE.RUN_ACTIVE, "run active code")
		eq(#fx.starts, 0, "no request sent")
		eq(fx.quits, 0, "never quits")
		eq(fx.controller.state(), "idle", "stays idle")
	end)

	test("start.refuses_when_mp_lobby_connected", function()
		local fx = fixture({ probe = { main_menu = true, active_run = false, mp_connected = true, mp_compatible = true } })
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "refused")
		eq(code, fx.modules.MenuController.CODE.MP_CONNECTED, "mp connected code")
		eq(#fx.starts, 0, "no request sent")
		eq(fx.quits, 0, "never quits")
	end)

	test("start.refuses_off_main_menu_and_incompatible_mp", function()
		local fx = fixture({ probe = { main_menu = false, active_run = false, mp_connected = false, mp_compatible = true } })
		local _, code = fx.controller.confirm_start()
		eq(code, fx.modules.MenuController.CODE.NOT_MAIN_MENU, "not main menu")
		fx = fixture({ probe = { main_menu = true, active_run = false, mp_connected = false, mp_compatible = false } })
		_, code = fx.controller.confirm_start()
		eq(code, fx.modules.MenuController.CODE.INCOMPATIBLE_MP, "incompatible mp")
		eq(fx.quits, 0, "never quits")
	end)

	test("start.missing_launcher_shows_diagnostic_never_quits", function()
		local fx = fixture({ available = false })
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "refused")
		eq(code, fx.modules.MenuController.CODE.LAUNCHER_UNAVAILABLE, "launcher code")
		eq(#fx.starts, 0, "no request sent")
		eq(fx.quits, 0, "never quits")
		truthy(#fx.ustate.overlays >= 1, "diagnostic shown")
	end)

	test("start.host_request_failure_never_quits", function()
		local fx = fixture({ request_nil = true })
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "failed")
		eq(code, fx.modules.MenuController.CODE.HOST_ERROR, "host error code")
		eq(fx.controller.state(), "failed", "failed state")
		eq(fx.quits, 0, "never quits")
		truthy(has_error_notice(fx), "error message shown")
	end)

	test("start.ack_pending_does_not_quit", function()
		local fx = fixture()
		fx.controller.confirm_start()
		eq(fx.controller.state(), "awaiting_ack", "awaiting ack")
		local state, code = fx.controller.update(0)
		eq(state, "awaiting_ack", "still awaiting")
		eq(code, fx.modules.MenuController.CODE.OK, "ok code")
		eq(fx.quits, 0, "no quit while pending")
	end)

	test("start.confirmed_ack_quits_exactly_once", function()
		local fx = fixture()
		fx.controller.confirm_start()
		fx.poll_result = { status = "ok" }
		local state = fx.controller.update(0)
		eq(state, "quitting", "quitting")
		eq(fx.quits, 1, "quit once")
		fx.controller.update(0)
		fx.controller.update(1)
		eq(fx.quits, 1, "still only one quit")
	end)

	test("start.rejection_never_quits", function()
		local fx = fixture()
		fx.controller.confirm_start()
		fx.poll_result = { status = "rejected", code = "not_allowed" }
		local state, code = fx.controller.update(0)
		eq(state, "failed", "failed")
		eq(code, fx.modules.MenuController.CODE.REJECTED, "rejected code")
		eq(fx.quits, 0, "never quits")
		truthy(has_error_notice(fx), "error message shown")
	end)

	test("start.timeout_never_quits", function()
		local fx = fixture()
		fx.controller.confirm_start()
		fx.now = fx.modules.MenuController.ACK_TIMEOUT + 1
		local state, code = fx.controller.update()
		eq(state, "failed", "failed")
		eq(code, fx.modules.MenuController.CODE.TIMEOUT, "timeout code")
		eq(fx.quits, 0, "never quits")
	end)

	test("start.malformed_ack_never_quits", function()
		local fx = fixture()
		fx.controller.confirm_start()
		fx.poll_result = "garbage"
		local state, code = fx.controller.update(0)
		eq(state, "failed", "failed")
		eq(code, fx.modules.MenuController.CODE.HOST_ERROR, "host error code")
		eq(fx.quits, 0, "never quits")
	end)

	test("start.cancel_does_nothing", function()
		local fx = fixture()
		fx.controller.confirm_start()
		local before = fx.quits
		local exits = fx.ustate.exits
		eq(fx.controller.cancel_confirm(), true, "cancel ok")
		eq(#fx.starts, 1, "start already requested once")
		eq(fx.quits, before, "cancel never quits")
		eq(fx.ustate.exits, exits + 1, "cancel closes the prompt")
	end)

	test("start.already_pending_rejected", function()
		local fx = fixture()
		fx.controller.confirm_start()
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "second start refused")
		eq(code, fx.modules.MenuController.CODE.ALREADY_PENDING, "already pending code")
		eq(#fx.starts, 1, "still one request")
	end)

	test("start.quit_failure_keeps_game_usable", function()
		local fx = fixture({ quit_fails = true })
		fx.controller.confirm_start()
		fx.poll_result = { status = "ok" }
		local state, code = fx.controller.update(0)
		eq(state, "failed", "failed")
		eq(code, fx.modules.MenuController.CODE.QUIT_FAILED, "quit failed code")
		eq(fx.quits, 1, "quit attempted once")
		truthy(has_error_notice(fx), "error message shown")
	end)

	test("start.end_practice_requests_host_only", function()
		local fx = fixture({ request_end = function()
			return true
		end })
		eq(fx.controller.end_practice(), true, "end ok")
		eq(fx.ends, 1, "host asked to end")
		eq(fx.quits, 0, "end never quits")
	end)
end
