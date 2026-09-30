-- Voucher values, pack kind preference and value-aware picks inside a pack.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local STRONG = { "competitive", "major_league", "expert" }

	local function shop(money)
		local frame = Support.voucher_frame()
		frame.self.money = money
		frame.shop.vouchers = {}
		frame.certificates.items = {}
		return frame
	end

	local function offer_vouchers(frame, centers)
		for i = 1, #centers do
			frame.shop.vouchers[i] = { center = centers[i], cost = 10, face_down = false }
			frame.certificates.items[i] = { type = "BUY_VOUCHER", certified = true, voucher_ref = "shop_voucher:" .. i }
		end
		frame.certificates.items[#frame.certificates.items + 1] = { type = "LEAVE_SHOP", certified = true }
		return frame
	end

	test("strong_tiers_value_vouchers_by_effect", function()
		for _, difficulty in ipairs(STRONG) do
			-- Listed second, so the id tie-break alone would not pick it.
			local result = Support.run(env, difficulty, offer_vouchers(shop(40), { "v_tarot_merchant", "v_grabber" }))
			ctx.eq(result.action.type, "BUY_VOUCHER", difficulty)
			ctx.eq(result.action.voucher_ref, "shop_voucher:2", difficulty .. " grabber")
			-- Hieroglyph costs a hand every round: not worth buying.
			local skip = Support.run(env, difficulty, offer_vouchers(shop(40), { "v_hieroglyph" }))
			ctx.eq(skip.action.type, "LEAVE_SHOP", difficulty .. " hieroglyph")
		end
		-- Rookie keeps the flat voucher score.
		ctx.eq(Support.run(env, "rookie", offer_vouchers(shop(40), { "v_hieroglyph" })).action.type, "BUY_VOUCHER")
	end)

	local function pack_shop(centers, jokers)
		local frame = shop(40)
		frame.self.jokers = {}
		for i = 1, jokers do
			frame.self.jokers[i] = Support.joker("j_joker")
		end
		frame.shop.boosters = {}
		for i = 1, #centers do
			frame.shop.boosters[i] = { kind = "booster", center = centers[i], cost = 4, sell_cost = 2, face_down = false }
			frame.certificates.items[i] = { type = "OPEN_BOOSTER", certified = true, item_ref = "shop_booster:" .. i, capacity_ok = true }
		end
		frame.certificates.items[#frame.certificates.items + 1] = { type = "LEAVE_SHOP", certified = true }
		return frame
	end

	test("strong_tiers_prefer_joker_packs_only_with_a_free_slot", function()
		local packs = { "p_standard_normal_1", "p_buffoon_normal_1" }
		for _, difficulty in ipairs(STRONG) do
			local open = Support.run(env, difficulty, pack_shop(packs, 1))
			ctx.eq(open.action.item_ref, "shop_booster:2", difficulty .. " buffoon")
			-- All five Joker slots full: the Buffoon pack is never opened, not
			-- even as the only pack (only a Negative Joker could be taken).
			local full = Support.run(env, difficulty, pack_shop(packs, 5))
			ctx.eq(full.action.item_ref, "shop_booster:1", difficulty .. " full slots")
			local only = pack_shop({ "p_buffoon_normal_1" }, 5)
			table.insert(only.certificates.items, 2, { type = "REROLL", certified = true })
			local choice = Support.run(env, difficulty, only)
			ctx.truthy(choice.action.type ~= "OPEN_BOOSTER", difficulty .. " buffoon only: " .. tostring(choice.action.type))
		end
		-- Rookie has no pack preference: the tie goes to the first pack.
		ctx.eq(Support.run(env, "rookie", pack_shop(packs, 1)).action.item_ref, "shop_booster:1")
	end)

	test("vouchers_and_packs_do_not_crowd_out_an_affordable_joker", function()
		for _, difficulty in ipairs(STRONG) do
			-- $12: Overstock ($10) or an unmodelled scaling Joker ($6), not both.
			local frame = offer_vouchers(shop(12), { "v_overstock_norm" })
			frame.shop.items = { { kind = "joker", center = "j_ride_the_bus", cost = 6, sell_cost = 3, face_down = false } }
			table.insert(frame.certificates.items, 1, { type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true })
			ctx.eq(Support.run(env, difficulty, frame).action.type, "BUY_ITEM", difficulty .. " joker first")
			-- With every Joker slot full the voucher is not capped.
			frame.self.jokers = {}
			for i = 1, 5 do
				frame.self.jokers[i] = Support.joker("j_joker")
			end
			frame.certificates.items[1] = { type = "LEAVE_SHOP", certified = true }
			ctx.eq(Support.run(env, difficulty, frame).action.type, "BUY_VOUCHER", difficulty .. " slots full")
		end
	end)

	local function pack(kind, cards, owned)
		local frame = Support.booster_frame()
		frame.booster.kind = kind
		frame.booster.cards = cards
		frame.self.jokers = owned or {}
		frame.certificates.items = {}
		for i = 1, #cards do
			frame.certificates.items[i] = { type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { "booster:" .. i } }
		end
		frame.certificates.items[#cards + 1] = { type = "SKIP_BOOSTER", certified = true }
		return frame
	end

	test("strong_tiers_pick_the_planet_for_a_levelled_hand", function()
		for _, difficulty in ipairs(STRONG) do
			local frame = pack("celestial", {
				{ kind = "card", center = "c_jupiter", face_down = false },
				{ kind = "card", center = "c_mercury", face_down = false },
			})
			frame.self.hand_levels = {
				pair = { level = 5, chips = 30, mult = 6 },
				flush = { level = 1, chips = 35, mult = 4 },
			}
			local result = Support.run(env, difficulty, frame)
			ctx.truthy(Support.same_refs(result.action.card_refs, { "booster:2" }), difficulty .. " mercury")
		end
	end)

	test("strong_tiers_pick_the_joker_that_adds_the_most", function()
		for _, difficulty in ipairs(STRONG) do
			-- An unmodelled Joker first, Cavendish (x3 mult) second.
			local frame = pack("buffoon", {
				{ kind = "card", center = "j_unmodelled_test", face_down = false },
				{ kind = "card", center = "j_cavendish", face_down = false },
			}, { Support.joker("j_gros_michel") })
			local result = Support.run(env, difficulty, frame)
			ctx.truthy(Support.same_refs(result.action.card_refs, { "booster:2" }), difficulty .. " cavendish")
		end
	end)

	test("strong_tiers_pick_an_improved_playing_card", function()
		for _, difficulty in ipairs(STRONG) do
			local frame = pack("standard", {
				{ kind = "card", rank = "King", suit = "Spades", center = "c_base", face_down = false },
				{ kind = "card", rank = "4", suit = "Hearts", center = "m_glass", seal = "Red", face_down = false },
			})
			local result = Support.run(env, difficulty, frame)
			ctx.truthy(Support.same_refs(result.action.card_refs, { "booster:2" }), difficulty .. " glass red seal")
			-- Stone loses its rank and suit: not preferred over a plain card.
			frame.booster.cards[2] = { kind = "card", rank = "4", suit = "Hearts", center = "m_stone", face_down = false }
			local stone = Support.run(env, difficulty, frame)
			ctx.truthy(Support.same_refs(stone.action.card_refs, { "booster:1" }), difficulty .. " not stone")
		end
	end)
end
