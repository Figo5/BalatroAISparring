return function()
	test("purity.builders_return_plain_definitions", function()
		local fx = fixture()
		local mc = fx.modules.MenuController
		local view = {
			options = mc.OPTIONS,
			selection = fx.controller.selection(),
			ruleset = mc.RULESET,
		}
		local definitions = {
			fx.menu.settings_definition(view),
			fx.menu.confirm_definition(view),
			fx.menu.session_definition(view),
			fx.menu.diagnostic_definition("setup", "C:/logs/x.log"),
			fx.menu.error_definition(mc.ERROR_MESSAGE, "C:/logs/x.log"),
		}
		for i = 1, #definitions do
			local definition = definitions[i]
			truthy(type(definition) == "table", "definition " .. tostring(i))
			truthy(type(definition.nodes) == "table", "definition nodes " .. tostring(i))
		end
	end)

	test("purity.settings_definition_rejects_bad_view", function()
		local fx = fixture()
		eq(fx.menu.settings_definition(nil), nil, "nil view")
		eq(fx.menu.settings_definition({}), nil, "empty view")
		eq(fx.menu.confirm_definition({ selection = {} }), nil, "missing options")
	end)

	test("purity.selection_refreshes_widgets", function()
		local fx = fixture()
		local before = #fx.ustate.overlays
		eq(fx.controller.handle_select("aisp:mode:gauntlet"), true, "select")
		eq(#fx.ustate.overlays, before + 1, "widgets refreshed after select")
	end)

	test("purity.no_engine_global_access_full_flow", function()
		local fx = fixture()
		eq(fx.controller.install(), true, "install")
		eq(fx.controller.open_settings(), true, "open settings")
		eq(fx.controller.open_confirm(), true, "open confirm")
		eq(fx.controller.confirm_start(), true, "confirm start")
		fx.poll_result = { status = "ok" }
		local state = fx.controller.update(0)
		eq(state, "quitting", "quit after ack")
		eq(fx.fired.count, 0, "no forbidden engine global access")
	end)

	test("purity.open_settings_launcher_missing_is_safe", function()
		local fx = fixture({ available = false })
		local ok, code = fx.controller.open_settings()
		eq(ok, nil, "refused")
		eq(code, fx.modules.MenuController.CODE.LAUNCHER_UNAVAILABLE, "launcher code")
		eq(fx.quits, 0, "never quits")
		eq(fx.fired.count, 0, "no forbidden global access")
	end)

	test("purity.module_constants_have_no_seed_surface", function()
		local fx = fixture()
		local mc = fx.modules.MenuController
		eq(mc.SEEDS, nil, "controller exposes no seed table")
		eq(mc.gauntlet_seed, nil, "controller exposes no seed mapper")
		eq(type(fx.menu.gauntlet_seed), "nil", "practice_menu exposes no seed mapper")
	end)
end
