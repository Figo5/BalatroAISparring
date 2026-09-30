return function()
	local function key_count(payload)
		local count = 0
		for _ in pairs(payload) do
			count = count + 1
		end
		return count
	end

	test("selection.default_payload_is_minimal_enums", function()
		local fx = fixture()
		eq(fx.controller.confirm_start(), true, "confirm starts")
		eq(#fx.starts, 1, "one request")
		local payload = fx.starts[1]
		eq(payload.mode, "normal", "mode enum")
		eq(payload.difficulty, "competitive", "difficulty enum")
		eq(payload.pacing, "normal", "pacing enum")
		eq(key_count(payload), 3, "no extra keys")
		eq(payload.gauntlet_index, nil, "no gauntlet index for normal match")
		eq(payload.seed, nil, "no seed ever")
		local keys = {}
		for key in pairs(payload) do
			keys[#keys + 1] = key
		end
		table.sort(keys)
		vec("default-payload-keys", table.concat(keys, ","))
	end)

	test("selection.gauntlet_payload_uses_validated_index", function()
		local fx = fixture()
		eq(fx.controller.handle_select("aisp:mode:gauntlet"), true, "select gauntlet")
		eq(fx.controller.selection().gauntlet_index, 1, "default gauntlet index")
		eq(fx.controller.handle_select("aisp:gauntlet:4"), true, "select index 4")
		eq(fx.controller.confirm_start(), true, "confirm starts")
		local payload = fx.starts[1]
		eq(payload.mode, "gauntlet", "mode enum")
		eq(payload.gauntlet_index, 4, "index enum")
		eq(key_count(payload), 4, "exactly four keys")
	end)

	test("selection.gauntlet_bounds_rejected", function()
		local fx = fixture()
		fx.controller.handle_select("aisp:mode:gauntlet")
		eq(fx.controller.handle_select("aisp:gauntlet:0"), nil, "index 0 rejected")
		eq(fx.controller.handle_select("aisp:gauntlet:6"), nil, "index 6 rejected")
		eq(fx.controller.handle_select("aisp:gauntlet:x"), nil, "non numeric rejected")
		eq(fx.controller.handle_select("aisp:gauntlet:2.5"), nil, "fractional rejected")
		eq(fx.controller.selection().gauntlet_index, 1, "selection unchanged after rejections")
	end)

	test("selection.gauntlet_index_requires_gauntlet_mode", function()
		local fx = fixture()
		eq(fx.controller.selection().mode, "normal", "normal default")
		eq(fx.controller.handle_select("aisp:gauntlet:2"), nil, "index rejected in normal mode")
		eq(fx.controller.selection().gauntlet_index, nil, "no index stored")
	end)

	test("selection.enum_ids_validated", function()
		local fx = fixture()
		eq(fx.controller.handle_select("aisp:difficulty:rookie"), true, "rookie")
		eq(fx.controller.handle_select("aisp:difficulty:major_league"), true, "major league")
		eq(fx.controller.handle_select("aisp:difficulty:expert"), true, "expert")
		eq(fx.controller.handle_select("aisp:difficulty:grandmaster"), nil, "unknown difficulty rejected")
		eq(fx.controller.handle_select("aisp:pacing:instant"), true, "instant")
		eq(fx.controller.handle_select("aisp:pacing:turbo"), nil, "unknown pacing rejected")
		eq(fx.controller.handle_select("aisp:mode:blitz"), nil, "unknown mode rejected")
		eq(fx.controller.handle_select("aisp:seed:deadbeef"), nil, "unknown namespace rejected")
		eq(fx.controller.handle_select(nil), nil, "nil id rejected")
	end)

	test("selection.mode_normal_clears_gauntlet_index", function()
		local fx = fixture()
		fx.controller.handle_select("aisp:mode:gauntlet")
		fx.controller.handle_select("aisp:gauntlet:3")
		eq(fx.controller.selection().gauntlet_index, 3, "index set")
		fx.controller.handle_select("aisp:mode:normal")
		eq(fx.controller.selection().gauntlet_index, nil, "index cleared")
	end)

	test("selection.payload_is_immutable_snapshot", function()
		local fx = fixture()
		fx.controller.confirm_start()
		local recorded = fx.starts[1]
		recorded.mode = "tampered"
		recorded.difficulty = "tampered"
		recorded.seed = "smuggled"
		local current = fx.controller.selection()
		eq(current.mode, "normal", "controller selection unaffected by payload mutation")
		eq(current.difficulty, "competitive", "controller difficulty unaffected")
		eq(current.seed, nil, "no seed stored")
		eq(fx.controller.last_request().mode, "normal", "stored request copy unaffected")
	end)

	test("selection.matches_module_contract_ids", function()
		local fx = fixture()
		local mc = fx.modules.MenuController
		eq(table.concat(mc.MODES, ","), "normal,gauntlet", "modes")
		eq(table.concat(mc.DIFFICULTIES, ","), "rookie,competitive,major_league,expert", "difficulties")
		eq(table.concat(mc.PACINGS, ","), "instant,normal", "pacings")
		eq(mc.GAUNTLET_COUNT, 5, "gauntlet count")
		eq(mc.RULESET.id, "major_league", "fixed major league ruleset")
		eq(mc.VERSION, "0.1.0-dev", "development build label")
		vec("modes", table.concat(mc.MODES, ","))
		vec("difficulties", table.concat(mc.DIFFICULTIES, ","))
		vec("pacings", table.concat(mc.PACINGS, ","))
	end)
end
