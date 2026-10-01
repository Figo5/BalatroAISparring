-- Reachable host diagnostics + unchanged refusals.
--
-- The Play entry is shown when practice can open AND when the only blocker is a
-- missing external launcher host. In the second case the entry must NOT open the
-- settings/start flow: it opens the bounded local diagnostic and nothing else.
-- Every other refusal (unreadable status probe, off main menu, incompatible
-- Multiplayer, an active lobby) keeps hiding or refusing exactly as before.
--
-- Pre-fix control: with the old "hide whenever can_open is not true" wrap, only
-- `unavailable_launcher_entry_opens_only_a_diagnostic` fails (the entry is not
-- appended), plus `test_install::install.button_hidden_outside_main_menu`.
-- `unavailable_launcher_start_still_refuses` calls `confirm_start` directly and
-- already passed on the old wrap.
return function()
	local function M(fx)
		return fx.modules.MenuController
	end

	local function wrapped(fx)
		return fx.ui.G.UIDEF[M(fx).BUILDER_KEY]
	end

	local function has_ai_entry(menu)
		local buttons = collect_buttons(menu)
		for i = 1, #buttons do
			if buttons[i].button == "aisp_open_menu" then
				return true
			end
		end
		return false
	end

	local function overlay_ids(fx)
		local overlay = fx.ustate.overlays[#fx.ustate.overlays]
		if type(overlay) ~= "table" then
			return {}
		end
		return collect_ids(overlay)
	end

	local function has_id(ids, wanted)
		for i = 1, #ids do
			if ids[i] == wanted then
				return true
			end
		end
		return false
	end

	local function notified(fx, needle)
		for i = 1, #fx.ustate.notifications do
			local note = fx.ustate.notifications[i]
			if type(note.message) == "string" and string.find(note.message, needle, 1, true) then
				return true
			end
		end
		return false
	end

	test("unavailable_launcher_entry_opens_only_a_diagnostic", function()
		local fx = fixture({ available = false })
		eq(fx.controller.install(), true, "install")
		truthy(has_ai_entry(wrapped(fx)()), "entry shown when launcher unavailable")

		local before = #fx.ustate.overlays
		fx.ui.funcs.aisp_open_menu()
		eq(#fx.ustate.overlays, before + 1, "one overlay opened")
		local ids = overlay_ids(fx)
		truthy(has_id(ids, "aisp:diagnostic:back"), "the diagnostic definition was opened")
		falsy(has_id(ids, "aisp:start"), "the settings/start screen was NOT opened")
		truthy(notified(fx, "launcher"), "the launcher-unavailable message is shown")
		eq(#fx.starts, 0, "no start request")
		eq(fx.quits, 0, "never quits")
		eq(fx.controller.state(), "idle", "stays idle")
	end)

	test("unavailable_launcher_start_still_refuses", function()
		local fx = fixture({ available = false })
		fx.controller.install()
		fx.ui.funcs.aisp_open_menu()
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "refused")
		eq(code, M(fx).CODE.LAUNCHER_UNAVAILABLE, "launcher unavailable code")
		eq(#fx.starts, 0, "no request sent")
		eq(fx.quits, 0, "never quits")
		eq(fx.controller.state(), "idle", "never enters awaiting_ack")
	end)

	test("unauthorized_entry_never_quits_across_updates", function()
		local fx = fixture({ available = false })
		fx.controller.install()
		fx.ui.funcs.aisp_open_menu()
		for i = 1, 5 do
			fx.now = i
			fx.controller.update(fx.now)
		end
		eq(fx.quits, 0, "still never quits")
		eq(#fx.starts, 0, "never requested a start")
	end)

	test("unreadable_status_probe_hides_entry_and_refuses", function()
		local fx = fixture()
		fx.status.probe = function()
			return nil
		end
		fx.controller.install()
		falsy(has_ai_entry(wrapped(fx)()), "no entry without a readable probe")
		local ok, code = fx.controller.can_open()
		eq(ok, nil, "cannot open")
		eq(code, M(fx).CODE.BAD_STATUS, "bad status code")
	end)

	test("off_main_menu_hides_entry_and_refuses", function()
		local fx = fixture({ probe = { main_menu = false, active_run = false, mp_connected = false, mp_compatible = true } })
		fx.controller.install()
		falsy(has_ai_entry(wrapped(fx)()), "no entry off the main menu")
		local ok, code = fx.controller.can_open()
		eq(ok, nil, "cannot open")
		eq(code, M(fx).CODE.NOT_MAIN_MENU, "not main menu code")
	end)

	test("incompatible_mp_hides_entry_and_refuses", function()
		local fx = fixture({ probe = { main_menu = true, active_run = false, mp_connected = false, mp_compatible = false } })
		fx.controller.install()
		falsy(has_ai_entry(wrapped(fx)()), "no entry when Multiplayer is incompatible")
		local ok, code = fx.controller.can_open()
		eq(ok, nil, "cannot open")
		eq(code, M(fx).CODE.INCOMPATIBLE_MP, "incompatible code")
	end)

	test("active_lobby_shows_entry_opens_settings_but_never_starts", function()
		local fx = fixture({ probe = { main_menu = true, active_run = false, mp_connected = true, mp_compatible = true } })
		fx.controller.install()
		truthy(has_ai_entry(wrapped(fx)()), "entry shown on the main menu")
		fx.ui.funcs.aisp_open_menu()
		local ids = overlay_ids(fx)
		truthy(has_id(ids, "aisp:start"), "settings opened (host available)")
		falsy(has_id(ids, "aisp:diagnostic:back"), "not the diagnostic")
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "refused")
		eq(code, M(fx).CODE.MP_CONNECTED, "connected-lobby code")
		eq(#fx.starts, 0, "no request sent")
		eq(fx.quits, 0, "never quits")
	end)

	test("available_host_still_opens_settings_and_starts", function()
		local fx = fixture()
		fx.controller.install()
		truthy(has_ai_entry(wrapped(fx)()), "entry shown")
		fx.ui.funcs.aisp_open_menu()
		local ids = overlay_ids(fx)
		truthy(has_id(ids, "aisp:start"), "settings opened")
		eq(fx.controller.confirm_start(), true, "start accepted with a host")
		eq(#fx.starts, 1, "one request sent")
		eq(fx.quits, 0, "no quit before an ack")
	end)

	-- L3: a connected lobby with no launcher. The entry appears (host is the only
	-- can_open blocker), clicking opens the launcher diagnostic, and Start is
	-- refused with the lobby code before any request. Nothing leaves the lobby.
	test("connected_lobby_and_unavailable_host_shows_diagnostic_never_starts", function()
		local fx = fixture({
			available = false,
			probe = { main_menu = true, active_run = false, mp_connected = true, mp_compatible = true },
		})
		fx.controller.install()
		truthy(has_ai_entry(wrapped(fx)()), "entry shown")
		fx.ui.funcs.aisp_open_menu()
		local ids = overlay_ids(fx)
		truthy(has_id(ids, "aisp:diagnostic:back"), "diagnostic opened")
		falsy(has_id(ids, "aisp:start"), "no settings/start screen")
		local ok, code = fx.controller.confirm_start()
		eq(ok, nil, "refused")
		eq(code, M(fx).CODE.MP_CONNECTED, "lobby refusal wins")
		eq(#fx.starts, 0, "no request sent")
		eq(fx.quits, 0, "never quits")
		eq(fx.controller.state(), "idle", "stays idle")
	end)

	-- M2: bounded, once-per-code Play-menu outcome diagnostics via the injected
	-- logger port. Only primitive event/code fields are ever sent.

	local function capture_logger()
		local records = {}
		return {
			record = function(fields)
				records[#records + 1] = fields
			end,
		}, records
	end

	local function count_code(records, code)
		local n = 0
		for i = 1, #records do
			if records[i].code == code then
				n = n + 1
			end
		end
		return n
	end

	test("menu_entry_logs_valid_entry_once_per_code", function()
		local logger, records = capture_logger()
		local fx = fixture({ logger = logger })
		fx.controller.install()
		truthy(has_ai_entry(wrapped(fx)()), "entry shown")
		truthy(has_ai_entry(wrapped(fx)()), "entry shown again")
		eq(#records, 1, "logged once despite repeated builds")
		eq(records[1].event, "menu_entry", "event")
		eq(records[1].code, M(fx).CODE.OK, "valid-entry code")
		eq(records[1].detail, nil, "no extra fields")
	end)

	test("menu_entry_logs_host_down_diagnostic_once", function()
		local logger, records = capture_logger()
		local fx = fixture({ available = false, logger = logger })
		fx.controller.install()
		truthy(has_ai_entry(wrapped(fx)()), "diagnostic entry shown")
		wrapped(fx)()
		eq(count_code(records, M(fx).CODE.LAUNCHER_UNAVAILABLE), 1, "diagnostic code once")
	end)

	test("menu_entry_logs_each_refusal_code_once", function()
		local logger, records = capture_logger()

		local bad = fixture({ logger = logger })
		bad.status.probe = function()
			return nil
		end
		bad.controller.install()
		wrapped(bad)()
		wrapped(bad)()

		local off = fixture({ logger = logger, probe = { main_menu = false, active_run = false, mp_connected = false, mp_compatible = true } })
		off.controller.install()
		wrapped(off)()
		wrapped(off)()

		local incompatible = fixture({ logger = logger, probe = { main_menu = true, active_run = false, mp_connected = false, mp_compatible = false } })
		incompatible.controller.install()
		wrapped(incompatible)()
		wrapped(incompatible)()

		eq(count_code(records, "menu_bad_status"), 1, "bad status once")
		eq(count_code(records, "menu_not_main_menu"), 1, "not main menu once")
		eq(count_code(records, "menu_incompatible_mp"), 1, "incompatible once")
	end)

	test("menu_entry_logs_malformed_definition_and_failed_button", function()
		local logger, records = capture_logger()

		local malformed = fixture({ logger = logger })
		malformed.ui.G.UIDEF[M(malformed).BUILDER_KEY] = function()
			return {}
		end
		malformed.controller.install()
		falsy(has_ai_entry(wrapped(malformed)()), "no entry on a malformed definition")

		local failed = fixture({ logger = logger })
		local real_button = failed.ui.UIBox_button
		failed.ui.UIBox_button = function(cfg)
			if type(cfg) == "table" and cfg.id == "aisparring_play_button" then
				error("synthetic button failure")
			end
			return real_button(cfg)
		end
		failed.controller.install()
		falsy(has_ai_entry(wrapped(failed)()), "no entry when the button builder throws")

		eq(count_code(records, "menu_definition_missing"), 1, "definition-missing once")
		eq(count_code(records, "menu_button_failed"), 1, "button-failed once")
	end)

	test("wrapper_replacement_is_detected_from_update_without_rewrapping", function()
		local logger, records = capture_logger()
		local fx = fixture({ logger = logger })
		fx.controller.install()
		local key = M(fx).BUILDER_KEY
		local replacement = function()
			return fx.original_builder()
		end
		fx.ui.G.UIDEF[key] = replacement
		fx.controller.update(0)
		fx.controller.update(0)
		eq(count_code(records, "menu_wrapper_replaced"), 1, "replacement detected once")
		eq(fx.ui.G.UIDEF[key], replacement, "another mod's builder is NOT overwritten")
		eq(fx.controller.install(), true, "install stays idempotent")
		eq(fx.ui.G.UIDEF[key], replacement, "install does not rewrap a replaced builder")
	end)

	test("throwing_or_malformed_logger_never_changes_menu_behaviour", function()
		local throwing = { record = function()
			error("logger exploded")
		end }
		local fx = fixture({ logger = throwing })
		fx.controller.install()
		truthy(has_ai_entry(wrapped(fx)()), "entry still shown with a throwing logger")
		fx.controller.update(0)
		eq(fx.controller.state(), "idle", "update still returns normally")

		local malformed = fixture({ logger = { record = "not a function" } })
		malformed.controller.install()
		truthy(has_ai_entry(wrapped(malformed)()), "entry shown with a malformed logger")
	end)
end
