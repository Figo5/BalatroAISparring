return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	local function produce(engine, opts)
		local pipeline = support.pipeline(bundle, engine, opts or {})
		is_true(pipeline.adapter ~= nil, "adapter factory: " .. tostring(pipeline.adapter_code))
		local result, code = pipeline.adapter.step()
		return result, code, pipeline
	end

	local function capture(engine, opts)
		local result, code = produce(engine, opts)
		is_true(result ~= nil, "produce failed: " .. tostring(code))
		local handle, rcode = bundle.reader.capture(result.runtime, result.ui_view)
		is_true(handle ~= nil, "reader capture: " .. tostring(rcode))
		return result, handle
	end

	local function action_types(handle)
		local list = bundle.actions.generate(handle)
		local seen = {}
		for i = 1, #list do
			seen[list[i].type] = true
		end
		return seen, list
	end

	test("factory_binds_role_session_and_ports", function()
		local engine = support.engine()
		local revision = bundle.StateRevision.factory()
		local base = { role = "ai_staged", session = "s1", codec = bundle.codec, revision = revision, G = engine.G, MP = engine.MP }

		local function with(overrides)
			local ports = {}
			for key, value in next, base do
				ports[key] = value
			end
			for key, value in next, overrides do
				if value == "<nil>" then
					ports[key] = nil
				else
					ports[key] = value
				end
			end
			return bundle.EngineAdapter.factory(ports)
		end

		local adapter, code = with({ role = "human_practice" })
		eq(adapter, nil)
		eq(code, "engine_bad_role")
		local adapter2, code2 = with({ session = "<nil>" })
		eq(adapter2, nil)
		eq(code2, "engine_bad_session")
		local adapter3, code3 = with({ codec = "<nil>" })
		eq(adapter3, nil)
		eq(code3, "engine_bad_codec")
		local adapter4, code4 = with({ revision = "<nil>" })
		eq(adapter4, nil)
		eq(code4, "engine_bad_revision")
		local adapter5, code5 = with({ G = "<nil>" })
		eq(adapter5, nil)
		eq(code5, "engine_bad_engine")
	end)

	test("play_hand_positive_end_to_end", function()
		local engine = support.engine({
			hand = { support.card({ center = "c_ace" }), support.card({ center = "c_king" }) },
			jokers = { support.card({ set = "Joker", center = "j_joker", area_type = "joker" }) },
			consumeables = { support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot" }) },
		})
		local result, handle = capture(engine)
		eq(result.ui_view.phase, "PLAY_HAND")
		local plain = bundle.obs.export(handle)
		eq(plain.phase, "PLAY_HAND")
		eq(#plain.self.hand, 2)
		eq(plain.self.hand[1].center, "c_ace")
		eq(#plain.self.jokers, 1)
		eq(#plain.self.consumables, 1)
		is_true(plain.match.ruleset ~= nil)
		local seen = action_types(handle)
		is_true(seen.PLAY_CARDS == true, "PLAY_CARDS")
		is_true(seen.DISCARD_CARDS == true, "DISCARD_CARDS")
		is_true(seen.SELL_JOKER == true, "SELL_JOKER")
		is_true(seen.USE_CONSUMABLE == true, "USE_CONSUMABLE")
	end)

	test("face_down_cards_are_redacted", function()
		local engine = support.engine({ hand = { support.card({ facing = "back", center = "c_ace" }) } })
		local _, handle = capture(engine)
		local plain = bundle.obs.export(handle)
		eq(#plain.self.hand, 1)
		is_true(plain.self.hand[1].redacted == true)
		eq(plain.self.hand[1].center, nil)
	end)

	test("shop_zones_are_distinct_and_typed", function()
		local engine = support.engine({
			state = STATES.SHOP,
			shop_jokers = { support.card({ center = "c_ace", cost = 3, center_set = "Default" }) },
			shop_boosters = { support.card({ set = "Booster", center = "p_arcana_normal_1", cost = 4, center_set = "Booster" }) },
			shop_vouchers = { support.card({ set = "Voucher", center = "v_seed_money", cost = 10, center_set = "Voucher" }) },
		})
		local _, handle = capture(engine)
		local plain = bundle.obs.export(handle)
		eq(plain.phase, "SHOP")
		eq(plain.shop.items[1].kind, "card")
		eq(plain.shop.boosters[1].kind, "booster")
		eq(plain.shop.vouchers[1].center, "v_seed_money")
		local seen = action_types(handle)
		is_true(seen.BUY_ITEM == true, "BUY_ITEM")
		is_true(seen.OPEN_BOOSTER == true, "OPEN_BOOSTER")
		is_true(seen.BUY_VOUCHER == true, "BUY_VOUCHER")
		is_true(seen.REROLL == true, "REROLL")
		is_true(seen.LEAVE_SHOP == true, "LEAVE_SHOP")
	end)

	test("booster_pack_phase", function()
		local engine = support.engine({
			state = STATES.TAROT_PACK,
			pack_cards = { support.card({ center = "c_temperance" }) },
		})
		local _, handle = capture(engine)
		local plain = bundle.obs.export(handle)
		eq(plain.phase, "BOOSTER_SELECTION")
		eq(#plain.booster.cards, 1)
		local seen = action_types(handle)
		is_true(seen.SELECT_BOOSTER_ITEM == true, "SELECT_BOOSTER_ITEM")
	end)

	test("pvp_selecting_hand_is_multiplier_pvp", function()
		local engine = support.engine({ blind_key = "bl_mp_nemesis", blind_pvp = true })
		local result, handle = capture(engine)
		eq(result.ui_view.phase, "MULTIPLAYER_PVP")
		local plain = bundle.obs.export(handle)
		eq(plain.phase, "MULTIPLAYER_PVP")
	end)

	test("round_eval_reports_cash_out_control", function()
		local engine = support.engine({ state = STATES.ROUND_EVAL, round_eval = {} })
		local result, code = produce(engine)
		is_true(result ~= nil, "produce: " .. tostring(code))
		eq(result.control, "cash_out")
		eq(result.runtime, nil)
	end)

	test("pvp_ready_is_blind_selection_not_control", function()
		local engine = support.engine({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		})
		local result, code = produce(engine)
		is_true(result ~= nil, "produce: " .. tostring(code))
		eq(result.control, nil)
		eq(result.ui_view.phase, "BLIND_SELECTION")
		local handle, rcode = bundle.reader.capture(result.runtime, result.ui_view)
		is_true(handle ~= nil, "reader: " .. tostring(rcode))
		local seen = action_types(handle)
		is_true(seen.SELECT_BLIND == true, "SELECT_BLIND must be offered for PvP ready")
	end)

	test("nonadjacent_pair_is_certified", function()
		local engine = support.engine({
			hand = {
				support.card({ rank = "Ace" }),
				support.card({ rank = "2" }),
				support.card({ rank = "Ace" }),
			},
		})
		local _, handle = capture(engine)
		local list = bundle.actions.generate(handle)
		for _, action in ipairs(list) do
			if action.type == "PLAY_CARDS" and #action.card_refs == 2
				and action.card_refs[1] == "hand:1" and action.card_refs[2] == "hand:3" then
				return
			end
		end
		error("bounded catalogue missed a non-adjacent pair")
	end)

	test("masked_opponent_hands_are_not_projected", function()
		local engine = support.engine({
			info_received = true,
			enemy_hands = 3,
			hands_text = "???",
		})
		local _, handle = capture(engine)
		local plain = bundle.obs.export(handle)
		is_true(plain.opponent == nil or plain.opponent.hands == nil, "raw hidden hands leaked")
	end)

	test("visible_opponent_hands_are_projected", function()
		local engine = support.engine({
			info_received = true,
			enemy_hands = 3,
			hands_text = "3",
		})
		local _, handle = capture(engine)
		local plain = bundle.obs.export(handle)
		is_true(plain.opponent ~= nil and plain.opponent.hands == 3, "visible hands were hidden")
	end)

	test("sell_consumable_is_certified", function()
		local engine = support.engine({
			consumeables = {
				support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot", area_type = "joker" }),
			},
		})
		local _, handle = capture(engine)
		local seen = action_types(handle)
		is_true(seen.SELL_CONSUMABLE == true, "SELL_CONSUMABLE must be offered for a sellable consumable")
	end)

	test("missing_ruleset_fails_closed", function()
		local engine = support.engine({ omit_ruleset = true })
		local result, code = produce(engine)
		eq(result, nil)
		eq(code, "engine_build_failed")
	end)

	test("unsupported_state_fails_closed", function()
		local engine = support.engine({ state = STATES.MENU })
		local result, code = produce(engine)
		eq(result, nil)
		eq(code, "engine_unsupported_state")
	end)

	test("booster_in_shop_items_fails_closed", function()
		local engine = support.engine({
			state = STATES.SHOP,
			shop_jokers = { support.card({ set = "Booster", center = "p_arcana_normal_1", cost = 4 }) },
		})
		local result, code = produce(engine)
		eq(result, nil)
		eq(code, "engine_build_failed")
	end)

	test("adapter_never_calls_ui_callbacks", function()
		local engine = support.engine({
			hand = { support.card({}), support.card({}) },
			jokers = { support.card({ set = "Joker", area_type = "joker" }) },
		})
		local result = produce(engine)
		is_true(result ~= nil)
		eq(#engine.calls, 0, "adapter invoked a UI callback")
	end)

	test("consumable_selection_with_target_port", function()
		local engine = support.engine({
			hand = { support.card({ center = "c_ace" }), support.card({ center = "c_king" }) },
			consumeables = { support.card({ set = "Tarot", consumeable = true, center = "c_star", max_highlighted = 3 }) },
		})
		local result, code = produce(engine, {
			target_selection = function()
				return { source_ordinal = 1, min_targets = 1, max_targets = 3 }
			end,
		})
		is_true(result ~= nil, "produce: " .. tostring(code))
		eq(result.ui_view.phase, "CONSUMABLE_SELECTION")
		local handle, rcode = bundle.reader.capture(result.runtime, result.ui_view)
		is_true(handle ~= nil, "reader: " .. tostring(rcode))
		local plain = bundle.obs.export(handle)
		is_true(plain.consumable_target ~= nil)
		eq(plain.consumable_target.source_ref, "consumable:1")
		eq(#plain.consumable_target.targets, 2)
		local seen = action_types(handle)
		is_true(seen.USE_CONSUMABLE == true, "USE_CONSUMABLE")
		is_true(seen.SELECT_TARGETS == true, "SELECT_TARGETS")
	end)

	test("candidates_are_bounded_and_deterministic", function()
		local hand = {}
		for i = 1, 8 do
			hand[i] = support.card({ center = "c_card" .. tostring(i) })
		end
		local engine = support.engine({ hand = hand })
		local result = produce(engine)
		is_true(result ~= nil)
		local play_count = 0
		local items = result.ui_view.certificates.items
		for i = 1, #items do
			if items[i].type == "PLAY_CARDS" then
				play_count = play_count + 1
			end
		end
		is_true(play_count > 0, "no play candidates")
		is_true(play_count <= 40, "unbounded play candidates: " .. tostring(play_count))
		is_true(#items <= 120, "certificate cap exceeded")

		local second = produce(engine)
		eq(second.ui_view.phase, result.ui_view.phase)
		eq(#second.ui_view.certificates.items, #items)
	end)

	test("structured_hands_survive_the_cap", function()
		-- M1: an 8-card hand must expose full-house/two-pair/straight/flush
		-- structure, not just the 28 lexicographic pairs that once filled the cap.
		local function has_refs(list, wanted)
			for _, action in ipairs(list) do
				if action.type == "PLAY_CARDS" and #action.card_refs == #wanted then
					local match = true
					for i = 1, #wanted do
						if action.card_refs[i] ~= wanted[i] then
							match = false
							break
						end
					end
					if match then
						return true
					end
				end
			end
			return false
		end
		local engine = support.engine({ hand = {
			support.card({ rank = "King" }), support.card({ rank = "King" }),
			support.card({ rank = "King" }), support.card({ rank = "Ace" }),
			support.card({ rank = "Ace" }), support.card({ rank = "Queen" }),
			support.card({ rank = "Queen" }), support.card({ rank = "Jack" }),
		} })
		local _, handle = capture(engine)
		local list = bundle.actions.generate(handle)
		is_true(has_refs(list, { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }), "full house missing")
		is_true(has_refs(list, { "hand:4", "hand:5", "hand:6", "hand:7" }), "two pair missing")
	end)

	test("pvp_ready_suppresses_blind_actions", function()
		-- H4a: once readied, no blind action may be offered while the AI waits
		-- for the human/server (an empty catalogue makes the loop back off).
		local engine = support.engine({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = true,
			blind_select = {},
		})
		local _, handle = capture(engine)
		local seen = action_types(handle)
		is_true(seen.SELECT_BLIND ~= true, "SELECT_BLIND offered while already ready")
		is_true(seen.SKIP_BLIND ~= true, "boss skip offered")
	end)

	test("boss_blind_has_no_skip_candidate", function()
		local engine = support.engine({
			state = STATES.BLIND_SELECT,
			blind_on_deck = "Boss",
			blind_states = { Small = "Skipped", Big = "Skipped", Boss = "Select" },
			blind_select = {},
		})
		local _, handle = capture(engine)
		local seen = action_types(handle)
		is_true(seen.SKIP_BLIND ~= true, "boss skip offered")
	end)

	test("face_down_identity_is_catalogue_invariant", function()
		-- H2: changing a hidden card's rank/suit must not change a single
		-- policy-visible candidate. The card may still be selected positionally,
		-- but it never forms a rank or suit group.
		local function catalogue(hidden_rank, hidden_suit)
			local engine = support.engine({
				hand = {
					support.card({ rank = "Ace" }),
					support.card({ rank = "King", suit = "Hearts" }),
					support.card({ rank = hidden_rank, suit = hidden_suit, facing = "back", sprite_facing = "back" }),
					support.card({ rank = "King", suit = "Hearts" }),
					support.card({ rank = "4", suit = "Hearts" }),
					support.card({ rank = "9", suit = "Hearts" }),
					support.card({ rank = "2", suit = "Diamonds" }),
					support.card({ rank = "6", suit = "Spades" }),
				},
			})
			local _, handle = capture(engine)
			local list = bundle.actions.generate(handle)
			local out = {}
			for _, action in ipairs(list) do
				if action.card_refs then
					out[#out + 1] = action.type .. ":" .. table.concat(action.card_refs, ",")
				end
			end
			table.sort(out)
			return table.concat(out, "|")
		end
		eq(catalogue("Ace", "Hearts"), catalogue("3", "Clubs"))
	end)
end
