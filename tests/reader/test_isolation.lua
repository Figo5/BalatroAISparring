return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root

	local bundle = support.load(repo)

	local function make_reader()
		local spy = support.spy(bundle.obs)
		local reader, code = bundle.StateReader.factory(spy)
		is_true(reader ~= nil, "reader factory: " .. tostring(code))
		return reader, spy
	end

	test("engine_metatables_never_invoked", function()
		local log = {}
		local reader = make_reader()
		local hand = { support.engine_card({ canary = true, log = log, canary_name = "handcard" }) }
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = hand,
			hand_visible = true,
			log = log,
			g_canary = true,
			game_canary = true,
			mp_canary = true,
			enemy_canary = true,
			opponent = support.opponent({ score_visible = true, hands_visible = true }),
			info_received = true,
			score_text = "10",
			hands_text = "4",
			hide_score = false,
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		is_true(handle ~= nil)
		eq(#log, 0, "canary invocations: " .. table.concat(log, ","))
	end)

	test("hidden_poison_mutation_leaves_canonical_unchanged", function()
		local reader = make_reader()
		local card = support.engine_card({})
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = { card },
			hand_visible = true,
			opponent = support.opponent({ score_visible = true, hands_visible = true }),
			info_received = true,
			score_text = "10",
			hands_text = "4",
			hide_score = false,
			last_timer = 5,
		})
		local h1, c1 = reader.capture(engine.runtime, engine.ui_view)
		eq(c1, nil)
		local canon1 = bundle.obs.canonical(h1)
		is_true(type(canon1) == "string")

		card.base.rank = "ZZZ"
		card.sort_ID = 1
		card.ability.poison = "x"
		card.config.center.poison = "y"
		engine.MP.GAME.enemy.real_score = 999999
		engine.MP.GAME.enemy.highest_score = 888888
		engine.MP.GAME.enemy.last_timer = 12345
		engine.MP.GAME.pvp_timer_order = 3

		local h2, c2 = reader.capture(engine.runtime, engine.ui_view)
		eq(c2, nil)
		local canon2 = bundle.obs.canonical(h2)
		eq(canon1, canon2)
	end)

	test("repeated_capture_is_deterministic", function()
		local reader = make_reader()
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = { support.engine_card({}) },
			hand_visible = true,
		})
		local h1 = reader.capture(engine.runtime, engine.ui_view)
		local h2 = reader.capture(engine.runtime, engine.ui_view)
		eq(bundle.obs.canonical(h1), bundle.obs.canonical(h2))
		eq(bundle.obs.hash(h1), bundle.obs.hash(h2))
	end)

	test("export_isolation_does_not_mutate_stored_content", function()
		local reader = make_reader()
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = { support.engine_card({}) },
			hand_visible = true,
		})
		local handle = reader.capture(engine.runtime, engine.ui_view)
		local canon = bundle.obs.canonical(handle)

		local first = bundle.obs.export(handle)
		first.phase = "HACKED"
		first.self.money = -999
		first.self.hand[1].rank = "ZZZ"

		local second = bundle.obs.export(handle)
		eq(second.phase, "PLAY_HAND")
		eq(second.self.money, 10)
		eq(second.self.hand[1].rank, "K")
		eq(bundle.obs.canonical(handle), canon)
	end)

	test("no_cached_state_between_captures", function()
		local reader, spy = make_reader()
		local card = support.engine_card({})
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = { card },
			hand_visible = true,
		})
		local h1 = reader.capture(engine.runtime, engine.ui_view)
		local canon1 = bundle.obs.canonical(h1)
		eq(spy.frames[1].self.hand[1].face_down, false)

		rawset(card, "facing", "back")
		local h2 = reader.capture(engine.runtime, engine.ui_view)
		eq(spy.frames[2].self.hand[1].face_down, true)

		eq(bundle.obs.canonical(h1), canon1)
	end)

	test("rawget_spy_detects_control_forbidden_read", function()
		local engine = support.build({ phase = "BLIND_SELECTION" })
		support.track_engine(engine)
		local spy = support.install_rawget_spy()
		rawget(engine.G, "deck")
		spy.restore()
		is_true(#spy.hits >= 1, "control read must be detected")
	end)

	test("capture_never_reads_forbidden_raw_fields", function()
		local reader = make_reader()
		local engine = support.build({
			phase = "SHOP",
			shop_jokers = { support.engine_card({}) },
			shop_boosters = { support.engine_card({}) },
			opponent = support.opponent({ score_visible = true, hands_visible = true }),
			info_received = true, score_text = "10", hands_text = "4", hide_score = false,
			last_timer = 42, real_score = 7, highest_score = 5, pvp_timer_order = 9,
			blind_key = "bl_small",
		})
		support.track_engine(engine)
		local spy = support.install_rawget_spy()
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		spy.restore()
		eq(code, nil)
		is_true(handle ~= nil)
		eq(#spy.hits, 0, "forbidden reads: " .. table.concat(spy.hits, ","))
	end)

	test("not_plain_input_tables_rejected_without_metamethod", function()
		local reader = make_reader()
		local invoked = 0
		local engine = support.build({ phase = "BLIND_SELECTION" })
		local evil = setmetatable({}, {
			__index = function()
				invoked = invoked + 1
				return "poison"
			end,
		})
		engine.ui_view.match = evil
		local _, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, "reader_bad_view")
		eq(invoked, 0)
	end)
end
