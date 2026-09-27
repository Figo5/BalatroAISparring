return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root

	local bundle = support.load(repo)
	local CODE = bundle.StateReader.CODE

	local function make_reader()
		local spy = support.spy(bundle.obs)
		local reader, code = bundle.StateReader.factory(spy)
		is_true(reader ~= nil, "reader factory: " .. tostring(code))
		return reader, spy
	end

	local function capture_code(opts)
		local reader = make_reader()
		local engine = support.build(opts)
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		return handle, code, engine
	end

	test("factory_requires_observation", function()
		local reader, code = bundle.StateReader.factory(nil)
		eq(reader, nil)
		eq(code, "reader_bad_observation")
		local reader2, code2 = bundle.StateReader.factory({ observe = "no" })
		eq(reader2, nil)
		eq(code2, "reader_bad_observation")
	end)

	test("wrong_role_refused", function()
		local _, code = capture_code({ role = "human_practice" })
		eq(code, CODE.BAD_ROLE)
		local _, code2 = capture_code({ omit_role = true })
		eq(code2, CODE.BAD_ROLE)
		local _, code3 = capture_code({ role = "ai" })
		eq(code3, CODE.BAD_ROLE)
	end)

	test("epoch_rules", function()
		local _, c1 = capture_code({ epoch = -1 })
		eq(c1, CODE.BAD_EPOCH)
		local _, c2 = capture_code({ epoch = 1.5 })
		eq(c2, CODE.BAD_EPOCH)
		local _, c3 = capture_code({ epoch = "1" })
		eq(c3, CODE.BAD_EPOCH)
		local _, c4 = capture_code({ epoch = 1, view_epoch = 2 })
		eq(c4, CODE.EPOCH_MISMATCH)
		local _, c5 = capture_code({ epoch = 1, view_epoch = -1 })
		eq(c5, CODE.BAD_VIEW)
	end)

	test("unknown_engine_state_refused", function()
		local _, code = capture_code({ state = 987654 })
		eq(code, CODE.UNSUPPORTED_STATE)
		local _, code2 = capture_code({ omit_states = true })
		eq(code2, CODE.UNSUPPORTED_STATE)
		local _, code3 = capture_code({ state = nil })
		-- nil state falls back to the phase default, which is valid
		eq(code3, nil)
	end)

	test("ambiguous_engine_state_refused", function()
		local _, code = capture_code({
			state = 9,
			states_override = {
				BLIND_SELECT = 13, SELECTING_HAND = 9, SHOP = 9, TAROT_PACK = 4, SPECTRAL_PACK = 5,
				PLANET_PACK = 6, STANDARD_PACK = 7, BUFFOON_PACK = 8, SMODS_BOOSTER_OPENED = 999, GAME_OVER = 12,
			},
		})
		eq(code, CODE.UNSUPPORTED_STATE)
	end)

	test("old_pack_short_names_refused", function()
		local _, code = capture_code({
			phase = "BOOSTER_SELECTION",
			state = 4,
			pack_cards = { support.engine_card({}) },
			states_override = {
				BLIND_SELECT = 13, SELECTING_HAND = 9, SHOP = 3, TAROT = 4, SPECTRAL = 5,
				PLANET = 6, STANDARD = 7, BUFFOON = 8, GAME_OVER = 12,
			},
		})
		eq(code, CODE.UNSUPPORTED_STATE)
	end)

	test("phase_mismatch_refused", function()
		local _, code = capture_code({ phase = "PLAY_HAND", view_phase = "SHOP" })
		eq(code, CODE.PHASE_MISMATCH)
	end)

	test("stale_shop_in_hand_phase_refused", function()
		local _, code = capture_code({
			phase = "PLAY_HAND",
			shop = { reroll_cost = 5, items = {}, vouchers = {} },
		})
		eq(code, CODE.PHASE_MISMATCH)
	end)

	test("stale_booster_in_hand_phase_refused", function()
		local _, code = capture_code({
			phase = "PLAY_HAND",
			booster = { kind = "buffoon", choices = 1, skips = 0, cards = {} },
		})
		eq(code, CODE.PHASE_MISMATCH)
	end)

	test("stale_target_in_shop_phase_refused", function()
		local _, code = capture_code({
			phase = "SHOP",
			consumable_target = { source = support.card_record({ ordinal = 1 }), targets = {} },
		})
		eq(code, CODE.PHASE_MISMATCH)
	end)

	test("stale_hand_not_carried_into_shop", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "SHOP",
			hand = { support.engine_card({}) },
			hand_visible = true,
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		is_true(handle ~= nil)
		local frame = spy.frames[1]
		eq(frame.self.hand, nil)
		eq(frame.self.hand_visible, nil)
	end)

	test("oversized_hand_view_refused", function()
		local hand = {}
		for i = 1, 65 do
			hand[i] = support.engine_card({})
		end
		local _, code = capture_code({ phase = "PLAY_HAND", hand = hand, hand_visible = true })
		eq(code, CODE.BAD_VIEW)
	end)

	test("oversized_shop_view_refused", function()
		local items = {}
		for i = 1, 17 do
			items[i] = support.engine_card({})
		end
		local _, code = capture_code({ phase = "SHOP", shop_jokers = items })
		eq(code, CODE.BAD_VIEW)
	end)

	test("malformed_self_refused", function()
		local _, code = capture_code({ phase = "PLAY_HAND", self_override = "nope" })
		eq(code, CODE.BAD_VIEW)
	end)

	test("missing_engine_zone_refused", function()
		local _, code = capture_code({ phase = "PLAY_HAND", omit_jokers = true })
		eq(code, CODE.ENTITY_MISMATCH)
	end)

	test("entity_count_mismatch_refused", function()
		local _, code = capture_code({
			phase = "SHOP",
			shop_jokers = { support.engine_card({}), support.engine_card({}) },
			shop_records = { support.card_record({}) },
		})
		eq(code, CODE.ENTITY_MISMATCH)
	end)

	test("optional_zone_omission_allowed", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "SHOP",
			shop_jokers = { support.engine_card({}) },
			shop_records = false,
			voucher_records = false,
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		is_true(handle ~= nil)
		local frame = spy.frames[1]
		eq(frame.shop.items, nil)
		eq(frame.shop.vouchers, nil)
		eq(frame.shop.reroll_cost, 5)
	end)

	test("duplicate_target_ordinals_refused", function()
		local _, code = capture_code({
			phase = "CONSUMABLE_SELECTION",
			hand = { support.engine_card({}), support.engine_card({}) },
			hand_visible = true,
			consumeables = { support.engine_card({}) },
			consumable_target = {
				source = support.card_record({ ordinal = 1 }),
				targets = {
					support.card_record({ ordinal = 1 }),
					support.card_record({ ordinal = 1 }),
				},
			},
		})
		eq(code, CODE.ENTITY_MISMATCH)
	end)

	test("non_plain_runtime_and_view_refused", function()
		local reader = make_reader()
		local engine = support.build({ phase = "BLIND_SELECTION" })
		setmetatable(engine.runtime, {})
		local _, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, CODE.BAD_RUNTIME)

		local engine2 = support.build({ phase = "BLIND_SELECTION" })
		setmetatable(engine2.ui_view, {})
		local _, code2 = reader.capture(engine2.runtime, engine2.ui_view)
		eq(code2, CODE.BAD_VIEW)
	end)

	test("bad_target_ordinal_refused", function()
		local _, code = capture_code({
			phase = "CONSUMABLE_SELECTION",
			consumeables = { support.engine_card({}) },
			consumable_target = {
				source = support.card_record({ ordinal = 0 }),
				targets = {},
			},
		})
		eq(code, CODE.BAD_VIEW)
	end)
end
