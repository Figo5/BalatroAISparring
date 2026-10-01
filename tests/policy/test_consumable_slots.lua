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
	-- A held consumable is either a bare center string or a table carrying a
	-- visible edition; the adapter exports the same `edition` field for owned
	-- consumables (the Negative's slot-providing card_limit = 1 is not exported,
	-- only the edition is, per the observation allowlist).
	local function held_record(spec)
		if type(spec) == "table" then
			return { kind = "consumable", center = spec.center, edition = spec.edition, face_down = false }
		end
		return { kind = "consumable", center = spec, face_down = false }
	end

	local function slots_frame(held, items, money, slots)
		local f = Support.shop_frame()
		f.match.consumable_slots = slots or 2
		f.self.money = money or 30
		f.self.consumables = {}
		local certs = {}
		for i = 1, #held do
			f.self.consumables[i] = held_record(held[i])
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

	-- A Negative Tarot owns card_limit = 1, so its slot disappearance cancels
	-- its removal: selling it frees nothing. The policy must sacrifice the
	-- regular Tarot instead and keep the Negative (Astra negative-slot finding).
	test("an_owned_negative_is_not_sold_to_free_a_slot", function()
		for _, d in ipairs(STRONG) do
			local action = decide(d, slots_frame(
				{ "c_death", "c_strength", { center = "c_sun", edition = "negative" } },
				{ consumable("c_star", 3), consumable("c_saturn", 3) }, 36, 3))
			ctx.eq(action.type, "SELL_CONSUMABLE", d .. " sells")
			ctx.eq(action.consumable_ref, "consumable:2", d .. " the regular Strength, not the Negative")
		end
	end)

	test("an_owned_negative_is_not_sold_regardless_of_offer_order", function()
		local orders = {
			{ consumable("c_star", 3), consumable("c_saturn", 3) },
			{ consumable("c_saturn", 3), consumable("c_star", 3) },
		}
		for _, d in ipairs(STRONG) do
			for i = 1, #orders do
				local action = decide(d, slots_frame(
					{ "c_death", "c_strength", { center = "c_sun", edition = "negative" } }, orders[i], 36, 3))
				ctx.eq(action.type, "SELL_CONSUMABLE", d .. " order" .. i .. " sells")
				ctx.eq(action.consumable_ref, "consumable:2", d .. " order" .. i .. " regular")
			end
		end
	end)

	-- The Negative is the only lower-worth card, but it is not slot-releasing,
	-- so it must not block the regular candidate the real upgrade needs.
	test("a_lower_worth_negative_does_not_block_the_regular_candidate", function()
		for _, d in ipairs(STRONG) do
			local action = decide(d, slots_frame(
				{ "c_death", { center = "c_sun", edition = "negative" } },
				{ consumable("c_saturn", 3) }, 36, 2))
			ctx.eq(action.type, "SELL_CONSUMABLE", d .. " sells the regular Death")
			ctx.eq(action.consumable_ref, "consumable:1", d .. " Death")
		end
	end)

	test("with_no_regular_upgrade_the_negative_is_kept", function()
		for _, d in ipairs(STRONG) do
			-- Star (worth 1) is no upgrade over anything held, so nothing is sold.
			local action = decide(d, slots_frame(
				{ "c_death", "c_strength", { center = "c_sun", edition = "negative" } },
				{ consumable("c_star", 3) }, 36, 3))
			ctx.eq(action.type, "LEAVE_SHOP", d .. " no useful upgrade")
		end
	end)

	test("a_regular_and_negative_pair_sells_the_regular_copy", function()
		-- Same visible center, a normal full row: base 1 + the Negative's
		-- card_limit 1 = a settled capacity of 2 holding 2 cards. Only the
		-- un-editioned copy releases a slot, so it is the one sold.
		for _, d in ipairs(STRONG) do
			local action = decide(d, slots_frame(
				{ { center = "c_sun", edition = "negative" }, "c_sun" },
				{ consumable("c_saturn", 3) }, 36, 2))
			ctx.eq(action.type, "SELL_CONSUMABLE", d .. " sells")
			ctx.eq(action.consumable_ref, "consumable:2", d .. " the regular copy")
		end
	end)

	test("an_unclassifiable_edition_is_never_sold_as_a_slot_release", function()
		for _, d in ipairs(STRONG) do
			-- Alone, an unknown edition cannot be proven slot-releasing: keep it.
			local alone = decide(d, slots_frame(
				{ { center = "c_sun", edition = "modded_alpha" } },
				{ consumable("c_saturn", 3) }, 36, 1))
			ctx.eq(alone.type, "LEAVE_SHOP", d .. " conservative")
			-- A regular candidate beside it may still free the slot.
			local with_regular = decide(d, slots_frame(
				{ "c_death", { center = "c_sun", edition = "modded_alpha" } },
				{ consumable("c_saturn", 3) }, 36, 2))
			ctx.eq(with_regular.type, "SELL_CONSUMABLE", d .. " regular frees the slot")
			ctx.eq(with_regular.consumable_ref, "consumable:1", d .. " Death")
		end
	end)

	test("safety_floor_sales_survive_a_negative_edition", function()
		for _, d in ipairs(Support.DIFFICULTIES) do
			local harmful = decide(d, slots_frame({ { center = "c_ectoplasm", edition = "negative" } }, {}, 30, 2))
			ctx.eq(harmful.type, "SELL_CONSUMABLE", d .. " negative harmful Spectral")
			local unusable = decide(d, slots_frame({ { center = "c_magician", edition = "negative" } }, {}, 30, 2))
			ctx.eq(unusable.type, "SELL_CONSUMABLE", d .. " negative unusable Tarot")
		end
	end)
end
