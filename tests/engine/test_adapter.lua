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

	local function cert_types(result)
		local seen = {}
		for _, item in ipairs(result.ui_view.certificates.items) do
			seen[item.type] = true
		end
		return seen
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

	test("buy_joker_offered_only_with_slot_room", function()
		-- `CardArea.config.card_limit` is metatable-backed, so the adapter must
		-- read it with normal indexing (a rawget is always nil, which used to
		-- suppress every joker purchase).
		local shop_joker = support.card({ set = "Joker", center = "j_joker", cost = 3, center_set = "Joker" })
		local filler = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })

		local full = produce(support.engine({
			state = STATES.SHOP, shop_jokers = { shop_joker }, jokers = { filler }, joker_slots = 1,
		}))
		is_true(full ~= nil)
		is_true(cert_types(full).BUY_ITEM ~= true, "full-slot joker purchase offered")

		local room = produce(support.engine({
			state = STATES.SHOP, shop_jokers = { shop_joker }, jokers = {}, joker_slots = 1,
		}))
		is_true(room ~= nil)
		is_true(cert_types(room).BUY_ITEM == true, "joker purchase with room not offered")
	end)

	test("buy_consumable_offered_only_with_slot_room", function()
		local shop_consumable = support.card({
			set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot", cost = 3,
		})
		local filler = support.card({ set = "Tarot", consumeable = true, center = "c_star", center_set = "Tarot" })

		local full = produce(support.engine({
			state = STATES.SHOP, shop_jokers = { shop_consumable }, consumeables = { filler }, consumable_slots = 1,
		}))
		is_true(full ~= nil)
		is_true(cert_types(full).BUY_ITEM ~= true, "full-slot consumable purchase offered")

		local room = produce(support.engine({
			state = STATES.SHOP, shop_jokers = { shop_consumable }, consumeables = {}, consumable_slots = 1,
		}))
		is_true(room ~= nil)
		is_true(cert_types(room).BUY_ITEM == true, "consumable purchase with room not offered")
	end)

	test("buy_negative_joker_offered_over_full_slots", function()
		-- Mirrors `check_for_buy_space` with `ability.card_limit = 1`: a full
		-- joker area still offers the negative joker.
		local negative = support.card({
			set = "Joker", center = "j_joker", cost = 3, center_set = "Joker",
			edition = "negative", card_limit = 1,
		})
		local filler = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local result = produce(support.engine({
			state = STATES.SHOP, shop_jokers = { negative }, jokers = { filler }, joker_slots = 1,
		}))
		is_true(result ~= nil)
		is_true(cert_types(result).BUY_ITEM == true, "negative joker over a full area not offered")
	end)

	test("match_slot_limits_are_projected", function()
		local engine = support.engine({ hand_limit = 8, joker_slots = 5, consumable_slots = 2 })
		local _, handle = capture(engine)
		local plain = bundle.obs.export(handle)
		eq(plain.match.hand_size, 8)
		eq(plain.match.joker_slots, 5)
		eq(plain.match.consumable_slots, 2)
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

	test("smods_pack_with_card_offers_skip", function()
		-- H1: SMODS boosters stay skippable with an empty hand once a real pack
		-- card exists.
		local engine = support.engine({
			state = STATES.SMODS_BOOSTER_OPENED,
			pack_cards = { support.card({ rank = "2" }) },
			hand = {},
		})
		local result = produce(engine)
		is_true(result ~= nil)
		local seen = false
		for _, item in ipairs(result.ui_view.certificates.items) do
			if item.type == "SKIP_BOOSTER" then
				seen = true
			end
		end
		is_true(seen, "SMODS pack with a real card must offer an escape")
	end)

	test("smods_empty_opening_pack_offers_no_skip", function()
		-- A: before the opened booster's cards materialize, the real UI cannot
		-- skip, so the adapter must not offer it.
		local engine = support.engine({ state = STATES.SMODS_BOOSTER_OPENED, pack_cards = {}, hand = {} })
		local result = produce(engine)
		is_true(result ~= nil)
		for _, item in ipairs(result.ui_view.certificates.items) do
			is_true(item.type ~= "SKIP_BOOSTER", "premature skip offered before pack cards exist")
		end
	end)

	test("ankh_full_slots_not_offered", function()
		-- B: a held Ankh with full joker slots is a `use_card` no-op
		-- (`Card:check_use`), so the adapter must not offer it.
		local ankh = support.card({ set = "Spectral", center_set = "Spectral", consumeable_data = {}, center = "c_ankh", usable = true })
		local filler = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local engine = support.engine({ consumeables = { ankh }, jokers = { filler }, joker_slots = 1 })
		local result = produce(engine)
		is_true(result ~= nil)
		for _, item in ipairs(result.ui_view.certificates.items) do
			is_true(item.type ~= "USE_CONSUMABLE", "full-slot Ankh offered as a usable consumable")
		end
	end)

	test("ankh_with_free_slots_offered", function()
		-- Positive control: the same Ankh is offered when a joker slot is free.
		local ankh = support.card({ set = "Spectral", center_set = "Spectral", consumeable_data = {}, center = "c_ankh", usable = true })
		local engine = support.engine({ consumeables = { ankh }, jokers = {}, joker_slots = 1 })
		local result = produce(engine)
		is_true(result ~= nil)
		local seen = false
		for _, item in ipairs(result.ui_view.certificates.items) do
			if item.type == "USE_CONSUMABLE" then
				seen = true
			end
		end
		is_true(seen, "usable Ankh with a free slot must be offered")
	end)

	test("forced_selection_candidates_include_forced", function()
		-- Medium/H3: the adapter must not offer a play/discard that omits a
		-- blind-forced card (the executor refuses those). Every offered selection
		-- contains the forced ordinal, and at least one is offered.
		local forced = support.card({ rank = "Ace" })
		forced.ability.forced_selection = true
		local engine = support.engine({
			hand = { forced, support.card({ rank = "2" }), support.card({ rank = "3" }) },
		})
		local result = produce(engine)
		is_true(result ~= nil)
		local offered = false
		for _, item in ipairs(result.ui_view.certificates.items) do
			if item.type == "PLAY_CARDS" or item.type == "DISCARD_CARDS" then
				local has_forced = false
				for _, r in ipairs(item.card_refs) do
					if r == "hand:1" then
						has_forced = true
					end
				end
				is_true(has_forced, item.type .. " omitted a forced card")
				offered = true
			end
		end
		is_true(offered, "no play/discard candidate was offered with a forced card")
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

	-- Source-shaped Multiplayer timer (mp ui/game/timer.lua:3-31 and
	-- networking/action_handlers.lua:1359-1373): the gate reads the lobby
	-- config and MP.GAME; the button re-checks it and starts the timer.
	local function timer_engine(opts)
		opts = opts or {}
		local engine = support.engine({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = opts.ready_blind ~= false,
			blind_select = {},
			config_timer = opts.config_timer ~= false,
			timer = opts.timer,
			timer_started = opts.timer_started,
		})
		local MP = engine.MP
		local gate_open = opts.gate ~= false
		MP.UI = {
			can_timer_opponent = function()
				if opts.gate_throws then
					error("gate failure")
				end
				if not MP.LOBBY.config.timer then
					return false
				end
				if MP.GAME.timer <= 0 then
					return false
				end
				return gate_open and MP.GAME.ready_blind == true
			end,
		}
		engine.funcs.mp_timer_button = function(e)
			engine.calls[#engine.calls + 1] = { name = "mp_timer_button", e = e }
			if opts.button_noop then
				return
			end
			if MP.UI.can_timer_opponent() then
				if not MP.GAME.timer_started then
					MP.GAME.timer_started = true
				else
					MP.GAME.timer_started = false
				end
			end
		end
		return engine
	end

	test("start_timer_offered_only_while_readied_and_button_lit", function()
		local _, handle = capture(timer_engine())
		local seen = action_types(handle)
		is_true(seen.START_TIMER == true, "timer button lit but not offered")
		is_true(seen.SELECT_BLIND ~= true)
		local cases = {
			{ label = "not readied", opts = { ready_blind = false } },
			{ label = "lobby timer off", opts = { config_timer = false } },
			{ label = "already started", opts = { timer_started = true } },
			{ label = "timer consumed", opts = { timer = 0 } },
			{ label = "gate closed", opts = { gate = false } },
			{ label = "gate throws", opts = { gate_throws = true } },
		}
		for _, case in ipairs(cases) do
			local _, other = capture(timer_engine(case.opts))
			is_true(action_types(other).START_TIMER ~= true, case.label)
		end
	end)

	test("start_timer_absent_outside_the_pvp_blind", function()
		local engine = support.engine({
			state = STATES.BLIND_SELECT,
			blind_on_deck = "Small",
			ready_blind = true,
			blind_select = {},
			config_timer = true,
		})
		engine.MP.UI = { can_timer_opponent = function() return true end }
		local _, handle = capture(engine)
		is_true(action_types(handle).START_TIMER ~= true)
	end)

	test("being_timered_moves_the_epoch", function()
		local engine = timer_engine()
		local pipeline = support.pipeline(bundle, engine, {})
		local first = pipeline.adapter.step()
		local again = pipeline.adapter.step()
		eq(first.epoch, again.epoch, "unchanged state keeps the epoch")
		engine.MP.GAME.nemesis_timer_started = true
		local second = pipeline.adapter.step()
		is_true(first.epoch ~= second.epoch, "nemesis timer must change the decision epoch")
	end)

	test("blind_requirement_projected_only_for_a_normal_blind", function()
		local function requirement(opts, chips)
			local engine = support.engine(opts)
			if engine.G.GAME.blind ~= nil then
				engine.G.GAME.blind.chips = chips
			end
			local result = produce(engine)
			return result.ui_view.self.blind_requirement
		end
		local hand = { support.card({ rank = "Ace", suit = "Spades" }) }
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand }, 300), "300")
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand }, 1234.9), "1234")
		-- PvP: the target is the opponent's (possibly masked) score.
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand, blind_key = "bl_mp_nemesis", blind_pvp = true }, 300), nil)
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand, blind_pvp = true }, 300), nil)
		-- Multiplayer marks a finished non-PvP blind with -1.
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand }, -1), nil)
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand }, 0 / 0), nil)
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand, omit_blind = true }, 300), nil)
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand }, math.huge), nil)
		-- The nemesis key alone identifies PvP, even without the pvp flag.
		eq(requirement({ state = STATES.SELECTING_HAND, hand = hand, blind_key = "bl_mp_nemesis" }, 300), nil)
		-- Outside the hand phases (shop, blind select) it is never projected.
		eq(requirement({ state = STATES.SHOP }, 300), nil)
		eq(requirement({ state = STATES.BLIND_SELECT, blind_select = {} }, 300), nil)
	end)
end

