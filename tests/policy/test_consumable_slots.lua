-- Consumable slot pressure (docs/CLAUDE_BATCH3_REVIEW.md M2): a full set of
-- consumable slots is not by itself a reason to sell a useful targeted Tarot.
-- A slot is freed only for a concretely better, affordable consumable visible
-- in the shop, and then only the lowest-value held Tarot is sacrificed. The
-- safety-floor sales (harmful or unusable consumables) are unchanged.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local STRONG = { "competitive", "major_league", "expert" }

	-- A full-slot SHOP frame. No BUY_ITEM certificate is invented: while the
	-- slots are full the adapter itself offers none for a consumable.
	local function slots_frame(held, items, money, slots)
		local f = Support.shop_frame()
		f.match.consumable_slots = slots or 2
		f.self.money = money or 30
		f.self.consumables = {}
		local certs = {}
		for i = 1, #held do
			f.self.consumables[i] = { kind = "consumable", center = held[i], face_down = false }
			certs[#certs + 1] = { type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:" .. i }
		end
		f.shop.items = items or {}
		f.shop.boosters = {}
		certs[#certs + 1] = { type = "LEAVE_SHOP", certified = true }
		f.certificates.items = certs
		return f
	end

	local function consumable(center, cost)
		return { kind = "consumable", center = center, cost = cost, sell_cost = 1, face_down = false }
	end

	local function decide(difficulty, frame)
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		return result.action
	end

	test("full_slots_alone_never_sells_a_useful_tarot", function()
		for _, d in ipairs(STRONG) do
			local action = decide(d, slots_frame({ "c_death", "c_sun" }, {}))
			ctx.eq(action.type, "LEAVE_SHOP", d .. " empty shop")
		end
	end)

	test("a_same_value_offer_does_not_churn", function()
		for _, d in ipairs(STRONG) do
			local action = decide(d, slots_frame({ "c_death", "c_sun" }, { consumable("c_sun", 3) }))
			ctx.eq(action.type, "LEAVE_SHOP", d .. " equal worth")
		end
	end)

	test("an_unaffordable_offer_does_not_free_a_slot", function()
		for _, d in ipairs(STRONG) do
			-- $12 - $3 would dip below the difficulty money reserve.
			local action = decide(d, slots_frame({ "c_death", "c_sun" }, { consumable("c_saturn", 3) }, 12))
			ctx.eq(action.type, "LEAVE_SHOP", d .. " unaffordable")
		end
	end)

	test("a_superior_planet_frees_only_the_lowest_value_held", function()
		local pairs_of_held = {
			{ "c_death", "c_sun" },       -- Sun (suit) is the weakest
			{ "c_death", "c_strength" },  -- Strength is the weakest
		}
		for _, d in ipairs(STRONG) do
			for i = 1, #pairs_of_held do
				local held = pairs_of_held[i]
				local action = decide(d, slots_frame(held, { consumable("c_saturn", 3) }))
				ctx.eq(action.type, "SELL_CONSUMABLE", d .. " frame" .. i .. " sells")
				ctx.eq(action.consumable_ref, "consumable:2", d .. " frame" .. i .. " lowest")
			end
		end
	end)

	test("a_superior_tarot_frees_only_the_lowest_value_held", function()
		for _, d in ipairs(STRONG) do
			local action = decide(d, slots_frame({ "c_death", "c_sun" }, { consumable("c_strength", 3) }))
			ctx.eq(action.type, "SELL_CONSUMABLE", d .. " sells")
			ctx.eq(action.consumable_ref, "consumable:2", d .. " lowest")
		end
	end)

	test("the_slot_sale_is_deterministic", function()
		for _, d in ipairs(STRONG) do
			local frame = slots_frame({ "c_death", "c_sun" }, { consumable("c_saturn", 3) })
			local first = Support.run(env, d, frame)
			local second = Support.run(env, d, frame)
			ctx.eq(first.action.id, second.action.id, d .. " stable")
		end
	end)

	test("sell_then_buy_then_no_further_sale", function()
		for _, d in ipairs(STRONG) do
			-- Full slots, Sun is the weakest, a better Strength is on offer.
			local first = Support.run(env, d, slots_frame({ "c_death", "c_sun" }, { consumable("c_strength", 3) }))
			ctx.eq(first.action.type, "SELL_CONSUMABLE", d .. " step1 sell")
			ctx.eq(first.action.consumable_ref, "consumable:2", d .. " step1 sund")

			-- The slot is free now: the adapter can certify the purchase.
			local second_frame = slots_frame({ "c_death" }, { consumable("c_strength", 3) }, 30, 2)
			second_frame.certificates.items = {
				{ type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:1" },
				{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
				{ type = "LEAVE_SHOP", certified = true },
			}
			local second = Support.run(env, d, second_frame)
			ctx.eq(second.action.type, "BUY_ITEM", d .. " step2 buy")
			ctx.eq(second.action.item_ref, "shop:1", d .. " step2 item")

			-- Full again with the better Tarot, an empty shop: no churn.
			local third = Support.run(env, d, slots_frame({ "c_death", "c_strength" }, {}))
			ctx.eq(third.action.type, "LEAVE_SHOP", d .. " step3 leave")
		end
	end)

	test("safety_floor_sales_are_preserved", function()
		-- A harmful Spectral and an unusable targeted Tarot are still sold.
		for _, d in ipairs(Support.DIFFICULTIES) do
			local harmful = decide(d, slots_frame({ "c_ectoplasm" }, {}))
			ctx.eq(harmful.type, "SELL_CONSUMABLE", d .. " ectoplasm")
			local dead = decide(d, slots_frame({ "c_magician" }, {}))
			ctx.eq(dead.type, "SELL_CONSUMABLE", d .. " magician")
			local hanged = decide(d, slots_frame({ "c_hanged_man" }, {}))
			ctx.eq(hanged.type, "SELL_CONSUMABLE", d .. " hanged man")
		end
	end)
end
