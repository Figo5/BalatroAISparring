return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local repo = ctx.repo_root

	local bundle = support.load(repo)
	is_true(bundle.obs ~= nil, "observation factory: " .. tostring(bundle.obs_code))
	is_true(type(bundle.StateReader.factory) == "function", "state reader factory")

	local function make_reader()
		local spy = support.spy(bundle.obs)
		local reader, code = bundle.StateReader.factory(spy)
		is_true(reader ~= nil, "reader factory: " .. tostring(code))
		return reader, spy
	end

	test("positive_play_hand_primitives_and_entities", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = { support.engine_card({}), support.engine_card({}) },
			hand_visible = true,
			current_score = "1,234",
			blind_requirement = "300",
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		is_true(handle ~= nil)

		local frame = spy.frames[1]
		eq(frame.phase, "PLAY_HAND")
		eq(frame.self.money, 10)
		eq(frame.self.credit_limit, 5)
		eq(frame.self.hands, 4)
		eq(frame.self.discards, 3)
		eq(frame.self.current_score, "1,234")
		eq(frame.self.blind_requirement, "300")
		eq(frame.match.ante, 3)
		eq(frame.match.round, 2)
		eq(#frame.self.hand, 2)
		eq(frame.self.hand[1].rank, "K")
		eq(frame.self.hand[1].suit, "Hearts")
		eq(frame.self.hand[1].face_down, false)

		local exported = bundle.obs.export(handle)
		eq(exported.phase, "PLAY_HAND")
		eq(exported.self.money, 10)
		eq(exported.self.credit_limit, 5)
		eq(exported.match.ante, 3)
		eq(exported.self.hand[1].id, "hand:1")
		eq(exported.self.hand[1].rank, "K")
	end)

	test("positive_all_phases", function()
		local specs = {
			{ phase = "BLIND_SELECTION" },
			{ phase = "PLAY_HAND", hand = { support.engine_card({}) }, hand_visible = true },
			{ phase = "DISCARD", hand = { support.engine_card({}) }, hand_visible = true },
			{ phase = "MULTIPLAYER_PVP", hand = { support.engine_card({}) }, hand_visible = true },
			{ phase = "SHOP", shop_jokers = { support.engine_card({ center = "j_foo" }) } },
			{ phase = "BOOSTER_SELECTION", pack_cards = { support.engine_card({}) } },
			{ phase = "CONSUMABLE_SELECTION", consumeables = { support.engine_card({ center = "c_tarot" }) } },
			{ phase = "MATCH_COMPLETE" },
		}
		for i = 1, #specs do
			local reader, spy = make_reader()
			local engine = support.build(specs[i])
			local handle, code = reader.capture(engine.runtime, engine.ui_view)
			eq(code, nil, "phase " .. specs[i].phase .. " code=" .. tostring(code))
			is_true(handle ~= nil, "phase " .. specs[i].phase)
			local frame = spy.frames[1]
			eq(frame.phase, specs[i].phase, "phase " .. specs[i].phase)
			local exported = bundle.obs.export(handle)
			eq(exported.phase, specs[i].phase, "export phase " .. specs[i].phase)
			if specs[i].phase == "MATCH_COMPLETE" then
				eq(frame.self, nil)
				eq(frame.opponent, nil)
				eq(frame.shop, nil)
			else
				is_true(frame.self ~= nil, "self present " .. specs[i].phase)
			end
		end
	end)

	test("positive_shop_and_booster_and_vouchers", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "SHOP",
			shop_jokers = { support.engine_card({}), support.engine_card({}) },
			shop_vouchers = { support.engine_card({}) },
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		local frame = spy.frames[1]
		eq(#frame.shop.items, 2)
		eq(#frame.shop.vouchers, 1)
		eq(frame.shop.reroll_cost, 5)

		local reader2, spy2 = make_reader()
		local engine2 = support.build({
			phase = "BOOSTER_SELECTION",
			pack_cards = { support.engine_card({}), support.engine_card({ facing = "back" }) },
		})
		local handle2, code2 = reader2.capture(engine2.runtime, engine2.ui_view)
		eq(code2, nil)
		local frame2 = spy2.frames[1]
		eq(#frame2.booster.cards, 2)
		eq(frame2.booster.cards[1].face_down, false)
		eq(frame2.booster.cards[2].face_down, true)
		eq(frame2.booster.kind, "buffoon")
	end)

	test("source_ref_binding_from_ordinal", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "CONSUMABLE_SELECTION",
			consumeables = {
				support.engine_card({ center = "c_first" }),
				support.engine_card({ center = "c_second" }),
			},
			consumable_target = {
				source = support.card_record({ ordinal = 2 }),
				targets = {},
			},
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		local frame = spy.frames[1]
		eq(frame.consumable_target.source_ref, "consumable:2")
		eq(frame.consumable_target.source.face_down, false)
		eq(frame.consumable_target.source.center, "c_king")
		local exported = bundle.obs.export(handle)
		if exported.consumable_target.source_ref ~= nil then
			eq(exported.consumable_target.source_ref, "consumable:2")
		end
	end)

	test("target_ordinals_bind_engine_facing", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "CONSUMABLE_SELECTION",
			hand = { support.engine_card({ facing = "front" }), support.engine_card({ facing = "back" }) },
			hand_visible = true,
			consumeables = { support.engine_card({}) },
			consumable_target = {
				source = support.card_record({ ordinal = 1 }),
				targets = {
					support.card_record({ ordinal = 1, rank = "A" }),
					support.card_record({ ordinal = 2, rank = "Q" }),
				},
			},
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		local frame = spy.frames[1]
		eq(#frame.consumable_target.targets, 2)
		eq(frame.consumable_target.targets[1].face_down, false)
		eq(frame.consumable_target.targets[1].rank, "A")
		eq(frame.consumable_target.targets[2].face_down, true)
	end)

	test("deck_total_only_maps_unsupported", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "BLIND_SELECTION",
			deck = { total = 52, by_suit = { Hearts = 13 }, by_rank = { K = 4 } },
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		local frame = spy.frames[1]
		eq(frame.self.deck.total, 52)
		eq(frame.self.deck.by_suit, nil)
		eq(frame.self.deck.by_rank, nil)
		local exported = bundle.obs.export(handle)
		eq(exported.self.deck.total, 52)
		eq(exported.self.deck.by_suit, nil)
		eq(exported.self.deck.by_rank, nil)
	end)

	test("deck_maps_cannot_leak_face_down_identity", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = { support.engine_card({ facing = "back" }) },
			hand_visible = true,
			deck = { total = 44, by_rank = { K = 4, A = 4 }, by_suit = { Hearts = 13 } },
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		local frame = spy.frames[1]
		eq(frame.self.hand[1].face_down, true)
		eq(frame.self.deck.total, 44)
		eq(frame.self.deck.by_rank, nil)
		eq(frame.self.deck.by_suit, nil)
	end)

	test("positive_all_real_pack_states", function()
		local packs = {
			"TAROT_PACK", "SPECTRAL_PACK", "PLANET_PACK", "STANDARD_PACK",
			"BUFFOON_PACK", "SMODS_BOOSTER_OPENED",
		}
		for i = 1, #packs do
			local reader, spy = make_reader()
			local engine = support.build({
				phase = "BOOSTER_SELECTION",
				state = support.STATES[packs[i]],
				pack_cards = { support.engine_card({}) },
			})
			local handle, code = reader.capture(engine.runtime, engine.ui_view)
			eq(code, nil, "pack " .. packs[i])
			is_true(handle ~= nil, "pack " .. packs[i])
			eq(spy.frames[1].phase, "BOOSTER_SELECTION", "pack " .. packs[i])
		end
	end)

	test("smods_booster_resolved_by_name_not_magic", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "BOOSTER_SELECTION",
			state = 77,
			pack_cards = { support.engine_card({}) },
			states_override = {
				BLIND_SELECT = 13, SELECTING_HAND = 9, SHOP = 3, TAROT_PACK = 4, SPECTRAL_PACK = 5,
				PLANET_PACK = 6, STANDARD_PACK = 7, BUFFOON_PACK = 8, SMODS_BOOSTER_OPENED = 77, GAME_OVER = 12,
			},
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		eq(spy.frames[1].phase, "BOOSTER_SELECTION")
	end)

	test("shop_boosters_distinct_zone_and_facing", function()
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "SHOP",
			shop_jokers = { support.engine_card({}) },
			shop_boosters = { support.engine_card({}), support.engine_card({ facing = "back" }) },
			certificates = {
				version = 1,
				items = { { type = "OPEN_BOOSTER", certified = true, item_ref = "shop_booster:1" } },
			},
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		eq(code, nil)
		local frame = spy.frames[1]
		eq(#frame.shop.boosters, 2)
		eq(frame.shop.boosters[1].face_down, false)
		eq(frame.shop.boosters[2].face_down, true)
		local exported = bundle.obs.export(handle)
		eq(exported.shop.items[1].id, "shop:1")
		eq(exported.shop.boosters[1].id, "shop_booster:1")
	end)
end
