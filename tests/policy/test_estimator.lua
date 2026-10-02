-- Worst-case cost of the play/discard estimators inside the real sandbox budget.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function card(rank, suit, center, edition, seal)
		return { kind = "card", rank = rank, suit = suit, center = center or "c_base", edition = edition, seal = seal, face_down = false }
	end

	local function heavy_frame()
		local hand = {
			card("Ace", "Hearts", "m_glass", "polychrome", "Red"),
			card("King", "Hearts", "m_lucky", "holo", "Red"),
			card("Queen", "Hearts", "m_steel"),
			card("Jack", "Hearts", "m_bonus", "foil"),
			card("10", "Spades", "m_mult"),
			card("10", "Clubs"),
			card("9", "Diamonds", "m_wild"),
			card("5", "Clubs", "m_stone"),
		}
		local jokers = {}
		for _, center in ipairs({ "j_photograph", "j_triboulet", "j_baron", "j_fibonacci", "j_abstract" }) do
			jokers[#jokers + 1] = { kind = "joker", center = center, face_down = false, edition = "polychrome" }
		end
		local certs = {}
		-- 60 plays and 60 discards: every 1..3 subset in order, then 4/5-card windows.
		local function refs(list)
			local out = {}
			for i = 1, #list do
				out[i] = "hand:" .. list[i]
			end
			return out
		end
		local subsets = {}
		for a = 1, 8 do
			subsets[#subsets + 1] = { a }
			for b = a + 1, 8 do
				subsets[#subsets + 1] = { a, b }
				for c = b + 1, 8 do
					subsets[#subsets + 1] = { a, b, c }
				end
			end
		end
		for i = 1, 60 do
			certs[#certs + 1] = { type = "PLAY_CARDS", certified = true, card_refs = refs(subsets[i]) }
		end
		for i = 1, 60 do
			certs[#certs + 1] = { type = "DISCARD_CARDS", certified = true, card_refs = refs(subsets[#subsets - i + 1]) }
		end
		local frame = Support.requirement_frame("100000", 3, 3)
		frame.self.hand = hand
		frame.self.hand_visible = true
		frame.self.jokers = jokers
		frame.certificates.items = certs
		return frame
	end

	test("estimators_fit_the_instruction_budget_at_120_candidates", function()
		local frame = heavy_frame()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		end
	end)

	test("rule_changing_joker_falls_back_to_category_ranking", function()
		-- Four Fingers makes four-card flushes real; the estimate would call
		-- them high cards, so the policy must not use it (and must not enter
		-- estimate-driven discard mode).
		local frame = Support.requirement_frame("1000", 2, 3, nil, { Support.joker("j_four_fingers") })
		local result = Support.run(env, "major_league", frame)
		ctx.is_true(result.ok == true)
		ctx.eq(result.action.type, "PLAY_CARDS")
	end)

	test("last_hand_without_a_clearing_play_discards_first", function()
		local frame = Support.requirement_frame("70", 1, 2)
		-- 64 < 70 remaining, one hand left, discards available.
		local result = Support.run(env, "competitive", frame)
		ctx.is_true(result.ok == true)
		ctx.eq(result.action.type, "DISCARD_CARDS")
	end)

	test("hand_levels_change_what_clears", function()
		-- Level-1 pair of Aces = (10+22)*2 = 64 < 150. With a displayed Pair at
		-- level 4 (40 chips, 5 mult) it is (40+22)*5 = 310 and clears.
		local frame = Support.requirement_frame("150", 2, 3)
		ctx.eq(Support.run(env, "competitive", frame).action.type, "DISCARD_CARDS")
		frame.self.hand_levels = { pair = { level = 4, chips = 40, mult = 5 } }
		local leveled = Support.run(env, "competitive", frame)
		ctx.eq(leveled.action.type, "PLAY_CARDS")
		ctx.eq(#leveled.action.card_refs, 2)
		-- Rookie ignores levels and requirement: it plays its pair either way.
		ctx.eq(Support.run(env, "rookie", frame).action.type, "PLAY_CARDS")
	end)

	test("shop_prefers_the_joker_that_raises_the_panel_most", function()
		local frame = Support.shop_frame()
		frame.shop.items = {
			{ kind = "joker", center = "j_joker", cost = 4, face_down = false },
			{ kind = "joker", center = "j_duo", cost = 4, face_down = false },
		}
		frame.self.money = 30
		-- With Gros Michel (+15 mult) owned, x2 beats another +4 mult on pairs.
		frame.self.jokers = { Support.joker("j_gros_michel") }
		frame.certificates.items = {
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:2", capacity_ok = true },
			{ type = "LEAVE_SHOP", certified = true },
		}
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == true, difficulty)
			ctx.eq(result.action.type, "BUY_ITEM", difficulty)
			ctx.eq(result.action.item_ref, "shop:2", difficulty .. " buys The Duo (x2 on pairs)")
		end
		-- With no Jokers, +4 mult outscores x2 on the pair-heavy panel.
		frame.self.jokers = {}
		ctx.eq(Support.run(env, "major_league", frame).action.item_ref, "shop:1")
	end)

	test("joker_order_puts_additive_mult_before_xmult", function()
		local frame = Support.shop_frame()
		frame.shop.items = {}
		frame.self.money = 0
		frame.self.jokers = { Support.joker("j_cavendish"), Support.joker("j_gros_michel") }
		frame.certificates.items = {
			{ type = "REORDER_JOKERS", certified = true, order = { "joker:2", "joker:1" } },
			{ type = "LEAVE_SHOP", certified = true },
		}
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local result = Support.run(env, difficulty, frame)
			ctx.eq(result.action.type, "REORDER_JOKERS", difficulty .. " moves +15 mult before x3")
		end
		-- Already in the best order: no reorder is offered as an improvement.
		frame.self.jokers = { Support.joker("j_gros_michel"), Support.joker("j_cavendish") }
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			ctx.eq(Support.run(env, difficulty, frame).action.type, "LEAVE_SHOP", difficulty)
		end
	end)

	test("large_hand_stays_within_budget", function()
		-- 20 visible cards (hand-size vouchers/Jokers): the draw-aware discard
		-- evaluation is skipped above 12 cards, so the budget holds.
		local frame = heavy_frame()
		local ranks = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King" }
		for i = #frame.self.hand + 1, 20 do
			frame.self.hand[i] = card(ranks[(i % #ranks) + 1], i % 2 == 0 and "Clubs" or "Diamonds")
		end
		local refs = {}
		for i = 16, 20 do
			refs[#refs + 1] = "hand:" .. i
		end
		frame.certificates.items[#frame.certificates.items + 1] = { type = "DISCARD_CARDS", certified = true, card_refs = refs }
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		end
	end)

	test("draw_aware_discard_keeps_the_flush_draw", function()
		-- Four Hearts plus four junk off-suit cards, nothing made: discarding the
		-- off-suit cards (keeping the draw) beats breaking the draw.
		local frame = Support.requirement_frame("2000", 3, 3)
		frame.self.hand = {
			card("2", "Hearts"), card("6", "Hearts"), card("9", "Hearts"), card("Queen", "Hearts"),
			card("3", "Clubs"), card("5", "Spades"), card("7", "Diamonds"), card("Jack", "Clubs"),
		}
		local function d(list)
			local refs = {}
			for i = 1, #list do
				refs[i] = "hand:" .. list[i]
			end
			return { type = "DISCARD_CARDS", certified = true, card_refs = refs }
		end
		frame.certificates.items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:4" } },
			d({ 5, 6, 7, 8 }),
			d({ 1, 2, 5 }),
			d({ 1, 2, 3, 4 }),
		}
		local result = Support.run(env, "major_league", frame)
		ctx.is_true(result.ok == true)
		ctx.eq(result.action.type, "DISCARD_CARDS")
		ctx.truthy(Support.same_refs(result.action.card_refs, { "hand:5", "hand:6", "hand:7", "hand:8" }), "keeps the four Hearts")
	end)

	local KNOWN = { "j_joker", "j_cavendish", "j_gros_michel", "j_duo", "j_trio", "j_scholar", "j_smiley", "j_sly" }

	local function reorder_frame(centers, orders)
		local frame = Support.shop_frame()
		frame.self.money = 0
		frame.shop.items = {}
		frame.self.jokers = {}
		for i = 1, #centers do
			frame.self.jokers[i] = Support.joker(centers[i])
		end
		local items = {}
		for _, order in ipairs(orders) do
			local refs = {}
			for i = 1, #order do
				refs[i] = "joker:" .. order[i]
			end
			items[#items + 1] = { type = "REORDER_JOKERS", certified = true, order = refs }
		end
		items[#items + 1] = { type = "LEAVE_SHOP", certified = true }
		frame.certificates.items = items
		return frame
	end

	test("many_jokers_and_reorders_stay_within_budget", function()
		-- 32 owned Jokers, 17 reorder candidates and 16 shop Jokers.
		local centers = {}
		for i = 1, 32 do
			centers[i] = KNOWN[(i % #KNOWN) + 1]
		end
		local orders = {}
		local reversed = {}
		for i = 1, 32 do
			reversed[i] = 33 - i
		end
		orders[1] = reversed
		for k = 1, 16 do
			local order = {}
			for i = 1, 32 do
				order[i] = i
			end
			order[k], order[k + 1] = order[k + 1], order[k]
			orders[#orders + 1] = order
		end
		local frame = reorder_frame(centers, orders)
		frame.self.money = 200
		for i = 1, 16 do
			frame.shop.items[i] = { kind = "joker", center = KNOWN[(i % #KNOWN) + 1], cost = 5, face_down = false }
			table.insert(frame.certificates.items, 1, { type = "BUY_ITEM", certified = true, item_ref = "shop:" .. i, capacity_ok = true })
		end
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		end
	end)

	test("joker_order_settles_in_a_few_steps", function()
		-- Repeatedly apply the chosen adjacent swap until the policy leaves:
		-- it must stop (no oscillation) with +mult before xmult.
		local centers = { "j_cavendish", "j_duo", "j_joker", "j_gros_michel" }
		for step = 1, 8 do
			local orders = {}
			for k = 1, #centers - 1 do
				local order = { 1, 2, 3, 4 }
				order[k], order[k + 1] = order[k + 1], order[k]
				orders[#orders + 1] = order
			end
			local result = Support.run(env, "major_league", reorder_frame(centers, orders))
			ctx.is_true(result.ok == true)
			if result.action.type == "LEAVE_SHOP" then
				ctx.eq(centers[#centers] == "j_cavendish" or centers[#centers] == "j_duo", true, "xmult last")
				ctx.eq(centers[1] == "j_joker" or centers[1] == "j_gros_michel", true, "+mult first")
				return
			end
			local next_centers = {}
			for i = 1, #result.action.order do
				next_centers[i] = centers[tonumber(string.match(result.action.order[i], ":(%d+)$"))]
			end
			centers = next_centers
		end
		error("reordering did not settle within 8 steps")
	end)

	test("rule_changing_joker_owned_disables_shop_gain", function()
		local frame = Support.shop_frame()
		frame.self.money = 30
		frame.self.jokers = { Support.joker("j_splash") }
		frame.shop.items = {
			{ kind = "joker", center = "j_joker", cost = 4, face_down = false },
			{ kind = "joker", center = "j_stuntman", cost = 4, face_down = false },
		}
		frame.certificates.items = {
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:2", capacity_ok = true },
			{ type = "LEAVE_SHOP", certified = true },
		}
		-- With the estimate off both Jokers score the flat kind value: the
		-- canonical id tie-break picks the first.
		ctx.eq(Support.run(env, "major_league", frame).action.item_ref, "shop:1")
	end)

	local function draw_frame(hand, discards)
		local frame = Support.requirement_frame("100000", 3, 3)
		frame.self.hand = hand
		local items = { { type = "PLAY_CARDS", certified = true, card_refs = { "hand:1" } } }
		for _, list in ipairs(discards) do
			local refs = {}
			for i = 1, #list do
				refs[i] = "hand:" .. list[i]
			end
			items[#items + 1] = { type = "DISCARD_CARDS", certified = true, card_refs = refs }
		end
		frame.certificates.items = items
		return frame
	end

	test("expert_keeps_two_pair_for_a_full_house_draw", function()
		local frame = draw_frame({
			card("King", "Spades"), card("King", "Hearts"), card("7", "Clubs"), card("7", "Diamonds"),
			card("2", "Spades"), card("4", "Hearts"), card("9", "Clubs"), card("Jack", "Diamonds"),
		}, { { 5, 6, 7, 8 }, { 3, 4, 5, 6 }, { 1, 2, 3, 4 } })
		local result = Support.run(env, "expert", frame)
		ctx.is_true(result.ok == true)
		ctx.eq(result.action.type, "DISCARD_CARDS")
		ctx.truthy(Support.same_refs(result.action.card_refs, { "hand:5", "hand:6", "hand:7", "hand:8" }), "keeps both pairs")
	end)

	test("expert_values_a_connected_run_with_two_gaps", function()
		-- No pairs and no three-card suit. 6-7-8 and A-Q-J are both runs
		-- missing two ranks; either is a deep-draw keep, dropping only two
		-- cards is not. Every tier stays legal.
		local hand = {
			card("6", "Spades"), card("7", "Hearts"), card("8", "Clubs"), card("Ace", "Diamonds"),
			card("3", "Clubs"), card("Queen", "Hearts"), card("Jack", "Spades"), card("2", "Diamonds"),
		}
		local frame = draw_frame(hand, { { 4, 5, 6, 7, 8 }, { 1, 2, 3, 5, 8 }, { 5, 8 } })
		local expert = Support.run(env, "expert", frame)
		ctx.is_true(expert.ok == true)
		ctx.eq(expert.action.type, "DISCARD_CARDS")
		ctx.truthy(Support.same_refs(expert.action.card_refs, { "hand:4", "hand:5", "hand:6", "hand:7", "hand:8" })
			or Support.same_refs(expert.action.card_refs, { "hand:1", "hand:2", "hand:3", "hand:5", "hand:8" }), "keeps a two-gap run")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			ctx.is_true(Support.run(env, difficulty, frame).ok == true, difficulty)
		end
		-- Without the broadway keep on offer, 6-7-8 is the only run to keep
		-- (3-J-2 is not connected).
		local only = Support.run(env, "expert", draw_frame(hand, { { 4, 5, 6, 7, 8 }, { 1, 2, 3, 4, 6 }, { 5, 8 } }))
		ctx.is_true(only.ok == true)
		ctx.truthy(Support.same_refs(only.action.card_refs, { "hand:4", "hand:5", "hand:6", "hand:7", "hand:8" }), "keeps 6-7-8")
	end)

	local function use_frame(centers, money, jokers)
		local frame = Support.shop_frame()
		frame.shop.items = {}
		frame.self.money = money
		frame.self.jokers = {}
		for i = 1, jokers do
			frame.self.jokers[i] = Support.joker("j_joker")
		end
		frame.self.consumables = {}
		local items = {}
		for i = 1, #centers do
			frame.self.consumables[i] = { kind = "consumable", center = centers[i], face_down = false }
			items[#items + 1] = { type = "USE_CONSUMABLE", certified = true, source_ref = "consumable:" .. i, target_refs = {} }
		end
		items[#items + 1] = { type = "LEAVE_SHOP", certified = true }
		frame.certificates.items = items
		return frame
	end

	test("harmful_spectrals_are_not_used_blindly", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			-- Wraith zeroes $30; Ankh/Hex would destroy two other Jokers;
			-- Ectoplasm/Ouija cost hand size.
			for _, case in ipairs({
				{ "c_wraith", 30, 1 }, { "c_ankh", 5, 3 }, { "c_hex", 5, 3 },
				{ "c_ectoplasm", 5, 1 }, { "c_ouija", 5, 1 },
			}) do
				local result = Support.run(env, difficulty, use_frame({ case[1] }, case[2], case[3]))
				ctx.eq(result.action.type, "LEAVE_SHOP", difficulty .. " " .. case[1])
			end
			-- Harmless situations are still allowed.
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_wraith" }, 3, 1)).action.type, "USE_CONSUMABLE")
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_ankh" }, 5, 1)).action.type, "USE_CONSUMABLE")
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_hex" }, 5, 1)).action.type, "USE_CONSUMABLE", difficulty .. " hex one joker")
			-- The Wraith boundary: $9 is allowed, $10 is refused.
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_wraith" }, 9, 1)).action.type, "USE_CONSUMABLE", difficulty .. " wraith $9")
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_wraith" }, 10, 1)).action.type, "LEAVE_SHOP", difficulty .. " wraith $10")
		end
	end)

	test("targeted_consumables_are_not_bought_and_are_sold", function()
		-- Targeted consumables outside the hand-phase allowlist (The Hanged
		-- Man, docs/HAND_TARGETS_DESIGN.md) can never be used live: buy The
		-- Hermit instead, and sell a held one.
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local frame = Support.shop_frame()
			frame.self.money = 20
			frame.shop.items = {
				{ kind = "consumable", center = "c_hanged_man", cost = 3, sell_cost = 1, face_down = false },
				{ kind = "consumable", center = "c_hermit", cost = 3, sell_cost = 1, face_down = false },
			}
			frame.shop.boosters = {}
			frame.certificates.items = {
				{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
				{ type = "BUY_ITEM", certified = true, item_ref = "shop:2", capacity_ok = true },
				{ type = "LEAVE_SHOP", certified = true },
			}
			ctx.eq(Support.run(env, difficulty, frame).action.item_ref, "shop:2", difficulty .. " hermit")
			frame.shop.items[2] = nil
			frame.certificates.items = { frame.certificates.items[1], frame.certificates.items[3] }
			ctx.eq(Support.run(env, difficulty, frame).action.type, "LEAVE_SHOP", difficulty .. " no hanged man")
			local sell = Support.shop_frame()
			sell.shop.items, sell.shop.boosters = {}, {}
			sell.self.consumables = { { kind = "consumable", center = "c_hanged_man", face_down = false } }
			sell.certificates.items = {
				{ type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:1" },
				{ type = "LEAVE_SHOP", certified = true },
			}
			ctx.eq(Support.run(env, difficulty, sell).action.type, "SELL_CONSUMABLE", difficulty .. " sell hanged man")
			-- An allowlisted Death is kept while a slot is free (Rookie, which
			-- never uses it, sells it).
			sell.self.consumables[1].center = "c_death"
			sell.match.consumable_slots = 2
			local want = difficulty == "rookie" and "SELL_CONSUMABLE" or "LEAVE_SHOP"
			ctx.eq(Support.run(env, difficulty, sell).action.type, want, difficulty .. " death, free slot")
			-- Full slots alone do not sell it: the shop is empty, so there is
			-- nothing for the freed slot (docs/CLAUDE_BATCH3_REVIEW.md M2).
			-- Rookie, which can never use it, still sells it.
			sell.match.consumable_slots = 1
			local full = difficulty == "rookie" and "SELL_CONSUMABLE" or "LEAVE_SHOP"
			ctx.eq(Support.run(env, difficulty, sell).action.type, full, difficulty .. " death, full slots")
		end
	end)

	test("hermit_is_held_until_money_reaches_20", function()
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_hermit" }, 8, 1)).action.type, "LEAVE_SHOP", difficulty .. " hold at $8")
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_hermit" }, 20, 1)).action.type, "USE_CONSUMABLE", difficulty .. " use at $20")
			-- Two held consumables fill the two shop slots: use it to free one.
			ctx.eq(Support.run(env, difficulty, use_frame({ "c_hermit", "c_fool" }, 8, 1)).action.source_ref, "consumable:1", difficulty .. " full slots")
			-- A card that cannot be used live (targeted Magician, outside the v1
			-- allowlist) is not counted as worth a slot, so the Hermit is not
			-- spent at $8. (The adapter never offers USE for it without targets.)
			local dead = use_frame({ "c_hermit", "c_magician" }, 8, 1)
			table.remove(dead.certificates.items, 2)
			ctx.eq(Support.run(env, difficulty, dead).action.type, "LEAVE_SHOP", difficulty .. " magician not counted")
		end
		-- Rookie keeps the simple rule: use at once.
		ctx.eq(Support.run(env, "rookie", use_frame({ "c_hermit" }, 8, 1)).action.type, "USE_CONSUMABLE", "rookie")
	end)

	test("psychic_boss_plays_five_cards", function()
		-- A pair outscores a 5-card high card normally; under The Psychic a
		-- hand of fewer than 5 cards scores nothing, so the 5-card play wins.
		local frame = Support.pair_frame()
		frame.certificates.items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:2" } },
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" } },
		}
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local normal = Support.run(env, difficulty, frame)
			ctx.eq(#normal.action.card_refs, 2, difficulty .. " normal pair")
			frame.match.blind = "bl_psychic"
			local boss = Support.run(env, difficulty, frame)
			ctx.eq(#boss.action.card_refs, 5, difficulty .. " psychic five")
			-- A disabled Psychic (Chicot / Luchador) is a normal blind again.
			frame.match.blind_disabled = true
			ctx.eq(#Support.run(env, difficulty, frame).action.card_refs, 2, difficulty .. " disabled psychic")
			frame.match.blind_disabled = nil
			frame.match.blind = "bl_small"
		end
	end)

	-- A Pair (A A) and a Heart flush (A 2 5 9 K) in one hand; normally the
	-- flush wins. docs/HAND_HISTORY_DESIGN.md.
	local function eye_mouth_frame(blind, played, extra)
		local frame = Support.pair_frame()
		local function c(rank, suit)
			return { kind = "card", rank = rank, suit = suit, center = "c_base", face_down = false }
		end
		frame.self.hand = { c("Ace", "Hearts"), c("Ace", "Diamonds"), c("2", "Hearts"), c("5", "Hearts"), c("9", "Hearts"), c("King", "Hearts") }
		frame.certificates.items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:2" } },
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:3", "hand:4", "hand:5", "hand:6" } },
			{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:3", "hand:4" } },
		}
		frame.match.blind = blind
		frame.self.hand_levels = {}
		for name, n in pairs(played) do
			local base = ({ pair = { 10, 2 }, flush = { 35, 4 }, high_card = { 5, 1 } })[name]
			frame.self.hand_levels[name] = { level = 1, chips = base[1], mult = base[2], played_this_round = n }
		end
		for k, v in pairs(extra or {}) do
			frame.match[k] = v
		end
		return frame
	end

	local function pick(difficulty, frame)
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty)
		if result.action.type ~= "PLAY_CARDS" then
			return result.action.type
		end
		return #result.action.card_refs == 2 and "pair" or "flush"
	end

	test("eye_and_mouth_block_hand_types", function()
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			ctx.eq(pick(difficulty, eye_mouth_frame("bl_small", {})), "flush", difficulty .. " normal")
			-- The Eye: the flush was already played this round.
			ctx.eq(pick(difficulty, eye_mouth_frame("bl_eye", { flush = 1 })), "pair", difficulty .. " eye")
			-- The Mouth: a Pair was played first, so only Pairs score.
			ctx.eq(pick(difficulty, eye_mouth_frame("bl_mouth", { pair = 1 })), "pair", difficulty .. " mouth")
			-- Disabled (Chicot / Luchador): back to normal.
			ctx.eq(pick(difficulty, eye_mouth_frame("bl_eye", { flush = 1 }, { blind_disabled = true })), "flush", difficulty .. " disabled")
			-- Nothing played yet this round: no restriction.
			ctx.eq(pick(difficulty, eye_mouth_frame("bl_mouth", { flush = 0 })), "flush", difficulty .. " first hand")
			-- Both types already played under The Eye: every play scores
			-- nothing, so a discard is preferred.
			ctx.eq(pick(difficulty, eye_mouth_frame("bl_eye", { flush = 1, pair = 1 })), "DISCARD_CARDS", difficulty .. " all blocked")
			-- The same without a displayed requirement (no requirement-based
			-- discard trigger): still a discard (code review L6).
			local no_req = eye_mouth_frame("bl_eye", { flush = 1, pair = 1 })
			no_req.self.blind_requirement = nil
			ctx.eq(pick(difficulty, no_req), "DISCARD_CARDS", difficulty .. " all blocked, no requirement")
		end
		-- Rookie is not boss-aware.
		ctx.eq(pick("rookie", eye_mouth_frame("bl_eye", { flush = 1 })), "flush", "rookie")
	end)

	test("eye_blocks_types_in_the_rule_joker_fallback", function()
		-- Four Fingers switches the estimate off; the category fallback must
		-- still respect The Eye.
		for _, difficulty in ipairs({ "competitive", "expert" }) do
			local frame = eye_mouth_frame("bl_eye", { flush = 1 })
			frame.self.jokers = { Support.joker("j_four_fingers") }
			ctx.eq(pick(difficulty, frame), "pair", difficulty .. " fallback eye")
			local normal = eye_mouth_frame("bl_small", {})
			normal.self.jokers = { Support.joker("j_four_fingers") }
			ctx.eq(pick(difficulty, normal), "flush", difficulty .. " fallback normal")
		end
	end)

	test("planets_are_used_before_other_consumables", function()
		local result = Support.run(env, "competitive", use_frame({ "c_fool", "c_jupiter" }, 5, 0))
		ctx.eq(result.action.type, "USE_CONSUMABLE")
		ctx.eq(result.action.source_ref, "consumable:2")
	end)

	test("harmful_spectrals_are_not_picked_from_packs", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			-- A Spectral pick is used at once: with three Jokers owned, Hex
			-- and Ectoplasm are refused, so the pack is skipped...
			local frame = Support.booster_frame()
			frame.self.jokers = { Support.joker("j_joker"), Support.joker("j_joker"), Support.joker("j_joker") }
			frame.booster.kind = "spectral"
			frame.booster.cards = {
				{ kind = "card", center = "c_hex", face_down = false },
				{ kind = "card", center = "c_ectoplasm", face_down = false },
			}
			frame.certificates.items = {
				{ type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { "booster:1" } },
				{ type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { "booster:2" } },
				{ type = "SKIP_BOOSTER", certified = true },
			}
			ctx.eq(Support.run(env, difficulty, frame).action.type, "SKIP_BOOSTER", difficulty)
			-- ...but a harmless card in the same pack is still taken.
			frame.booster.cards[3] = { kind = "card", center = "c_sigil", face_down = false }
			table.insert(frame.certificates.items, 3, { type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { "booster:3" } })
			local pick = Support.run(env, difficulty, frame)
			ctx.eq(pick.action.type, "SELECT_BOOSTER_ITEM", difficulty)
			ctx.truthy(Support.same_refs(pick.action.card_refs, { "booster:3" }), difficulty .. " picks sigil")
		end
	end)

	test("harmful_consumables_are_not_bought_and_are_sold", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local shop = use_frame({}, 20, 1)
			shop.shop.items = { { kind = "consumable", center = "c_ouija", cost = 4, sell_cost = 2, face_down = false } }
			shop.certificates.items = {
				{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
				{ type = "LEAVE_SHOP", certified = true },
			}
			ctx.eq(Support.run(env, difficulty, shop).action.type, "LEAVE_SHOP", difficulty .. " no ouija")
			-- A held Ectoplasm frees its slot; a held planet is kept.
			for _, case in ipairs({ { "c_ectoplasm", "SELL_CONSUMABLE" }, { "c_jupiter", "LEAVE_SHOP" } }) do
				local held = use_frame({ case[1] }, 20, 1)
				held.certificates.items = {
					{ type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:1" },
					{ type = "LEAVE_SHOP", certified = true },
				}
				ctx.eq(Support.run(env, difficulty, held).action.type, case[2], difficulty .. " " .. case[1])
			end
		end
	end)

	-- M4: Glass is estimated from the projected own-card multiplier, not a
	-- hardcoded value. The same hand with a projected x1.5 (Standard) and x2
	-- (vanilla/Major League) must rank the certified plays differently.
	local function glass_pair_or_trips_frame(xmult)
		local f = Support.requirement_frame("10", 3, 3)
		f.self.hand_visible = true
		f.self.hand = {
			{ kind = "card", rank = "10", suit = "Hearts", center = "m_glass", xmult = xmult, face_down = false },
			{ kind = "card", rank = "10", suit = "Spades", center = "c_ten", face_down = false },
			{ kind = "card", rank = "2", suit = "Clubs", center = "c_two", face_down = false },
			{ kind = "card", rank = "2", suit = "Diamonds", center = "c_two", face_down = false },
			{ kind = "card", rank = "2", suit = "Spades", center = "c_two", face_down = false },
		}
		f.certificates.items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:2" } },
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:3", "hand:4", "hand:5" } },
			{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:1" } },
		}
		return f
	end

	test("glass_projection_changes_the_estimated_play", function()
		local low = Support.run(env, "competitive", glass_pair_or_trips_frame(150))
		local high = Support.run(env, "competitive", glass_pair_or_trips_frame(200))
		ctx.is_true(low.ok == true, tostring(low.code))
		ctx.is_true(high.ok == true, tostring(high.code))
		ctx.eq(low.action.type, "PLAY_CARDS", "x1.5 still plays")
		ctx.eq(high.action.type, "PLAY_CARDS", "x2 plays")
		ctx.eq(table.concat(low.action.card_refs, ","), "hand:3,hand:4,hand:5", "x1.5 prefers three 2s")
		ctx.eq(table.concat(high.action.card_refs, ","), "hand:1,hand:2", "x2 prefers the glass pair")
	end)

	test("a_malformed_glass_projection_is_refused_before_policy", function()
		for _, bad in ipairs({ 1.5, "150", 50, 20000 }) do
			local handle = env.obs.observe(glass_pair_or_trips_frame(bad))
			ctx.eq(handle, nil, "malformed xmult " .. tostring(bad))
		end
	end)
end

