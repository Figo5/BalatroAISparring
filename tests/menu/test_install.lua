return function()
	local function wrapped(fx)
		return fx.ui.G.UIDEF[fx.modules.MenuController.BUILDER_KEY]
	end

	local function base_ids(fx)
		return collect_ids(fx.original_builder())
	end

	test("install.rejects_bad_ports", function()
		local env = safe_env()
		local m = load_modules(env)
		eq(m.MenuController.factory(nil), nil, "nil ports")
		eq(m.MenuController.factory({}), nil, "empty ports")
		eq(m.MenuController.factory({ ui = {}, menu = {}, host = {}, status = {}, clock = {} }), nil, "bad ui")
		local PracticeMenu = m.PracticeMenu
		eq(PracticeMenu.factory({}), nil, "bad practice ui")
	end)

	test("install.wraps_and_preserves_base_buttons", function()
		local fx = fixture()
		local before = base_ids(fx)
		truthy(#before >= 3, "base buttons exist")
		eq(fx.controller.install(), true, "install")
		local menu = wrapped(fx)()
		local after = collect_ids(menu)
		eq(#after, #before + 1, "exactly one button added")
		for i = 1, #before do
			eq(after[i], before[i], "base button preserved at " .. tostring(i))
		end
		eq(after[#after], fx.modules.MenuController.BUTTON_ID, "aisparring button appended last")
		local buttons = collect_buttons(menu)
		local found = false
		for i = 1, #buttons do
			if buttons[i].button == "aisp_open_menu" then
				found = true
			end
		end
		truthy(found, "aisparring callback present")
	end)

	test("install.is_idempotent", function()
		local fx = fixture()
		fx.controller.install()
		local first = wrapped(fx)
		fx.controller.install()
		eq(wrapped(fx), first, "same wrapper function")
		local menu = wrapped(fx)()
		local count = 0
		local buttons = collect_buttons(menu)
		for i = 1, #buttons do
			if buttons[i].button == "aisp_open_menu" then
				count = count + 1
			end
		end
		eq(count, 1, "single appended button")
	end)

	test("install.has_no_side_effects", function()
		local fx = fixture()
		eq(#fx.ustate.overlays, 0, "no overlay before")
		eq(fx.quits, 0, "no quit before")
		eq(fx.ustate.exits, 0, "no exit before")
		fx.controller.install()
		eq(#fx.ustate.overlays, 0, "install opens no overlay")
		eq(fx.quits, 0, "install never quits")
		eq(fx.ustate.exits, 0, "install exits nothing")
	end)

	test("install.button_hidden_outside_main_menu", function()
		local fx = fixture()
		fx.controller.install()
		fx.probe_result.main_menu = false
		local ids = collect_ids(wrapped(fx)())
		eq(#ids, #base_ids(fx), "no added button off main menu")
		fx.probe_result.main_menu = true
		fx.probe_result.mp_compatible = false
		ids = collect_ids(wrapped(fx)())
		eq(#ids, #base_ids(fx), "no added button when MP incompatible")
		fx.probe_result.mp_compatible = true
		fx.available = false
		ids = collect_ids(wrapped(fx)())
		eq(#ids, #base_ids(fx), "no added button when launcher unavailable")
		fx.available = true
		ids = collect_ids(wrapped(fx)())
		eq(#ids, #base_ids(fx) + 1, "button returns when enabled")
	end)

	test("install.uninstall_restores_original", function()
		local fx = fixture()
		local key = fx.modules.MenuController.BUILDER_KEY
		fx.ui.funcs.aisp_open_menu = "sentinel"
		fx.controller.install()
		neq(fx.ui.G.UIDEF[key], fx.original_builder, "builder replaced")
		neq(fx.ui.funcs.aisp_open_menu, "sentinel", "callback installed")
		eq(fx.controller.uninstall(), true, "uninstall")
		eq(fx.ui.G.UIDEF[key], fx.original_builder, "builder restored")
		eq(fx.ui.funcs.aisp_open_menu, "sentinel", "previous callback restored")
		eq(fx.controller.uninstall(), true, "second uninstall is a no-op")
		eq(fx.ui.funcs.aisp_open_menu, "sentinel", "callback still restored")
	end)

	test("install.uninstall_removes_owned_callbacks", function()
		local fx = fixture()
		fx.controller.install()
		truthy(fx.ui.funcs.aisp_open_menu ~= nil, "owned callback present")
		fx.controller.uninstall()
		eq(fx.ui.funcs.aisp_open_menu, nil, "owned callback removed")
		eq(fx.ui.funcs.aisp_confirm_start, nil, "all owned callbacks removed")
	end)

	test("menu_accepts_an_actual_metatable_game_table", function()
		-- The live `G` is `Game = Object:extend()` and carries a metatable
		-- (work/reference/game/engine/object.lua). The factory accepts any table
		-- for G while still validating the plain nested constant tables.
		local fx = fixture()
		local plain = fx.ui.G
		local object = setmetatable({}, {})
		for key, value in pairs(plain) do
			object[key] = value
		end
		truthy(getmetatable(object) ~= nil, "metatable present")
		fx.ui.G = object
		local menu, code = fx.modules.PracticeMenu.factory(fx.ui)
		truthy(menu ~= nil, "Object-shaped G accepted: " .. tostring(code))
	end)
end
