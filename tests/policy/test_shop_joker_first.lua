-- Packs and vouchers against the best affordable Joker, after prices and
-- economy (M1 of docs/CLAUDE_BATCH2_REVIEW.md). Packs and vouchers must not
-- crowd out a Joker that is actually better because of mismatched score
-- scaling, but a Joker that would drain the money can still lose.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local STRONG = { "competitive", "major_league", "expert" }

	-- j_ride_the_bus is a scaling Joker the estimator does not model (flat
	-- value); j_cavendish is modelled (x3 mult) and gets a large gain.
	local function shop(opts)
		local frame = Support.voucher_frame()
		frame.self.money = opts.money
		frame.self.jokers = {}
		for i = 1, opts.owned or 1 do
			frame.self.jokers[i] = Support.joker("j_joker")
		end
		frame.shop.items = {}
		frame.shop.vouchers = {}
		frame.shop.boosters = {}
		local certs = {}
		if opts.joker ~= nil then
			frame.shop.items[1] = {
				kind = "joker", center = opts.joker, cost = opts.joker_cost, sell_cost = 3,
				edition = opts.joker_edition, face_down = false,
			}
			certs[#certs + 1] = { type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true }
		end
		if opts.pack ~= nil then
			frame.shop.boosters[1] = { kind = "booster", center = opts.pack, cost = opts.pack_cost, sell_cost = 2, face_down = false }
			certs[#certs + 1] = { type = "OPEN_BOOSTER", certified = true, item_ref = "shop_booster:1", capacity_ok = true }
		end
		if opts.voucher ~= nil then
			frame.shop.vouchers[1] = { center = opts.voucher, cost = opts.voucher_cost, face_down = false }
			certs[#certs + 1] = { type = "BUY_VOUCHER", certified = true, voucher_ref = "shop_voucher:1" }
		end
		certs[#certs + 1] = { type = "LEAVE_SHOP", certified = true }
		frame.certificates.items = certs
		return frame
	end

	local function chosen(difficulty, opts)
		local result = Support.run(env, difficulty, shop(opts))
		ctx.is_true(result.ok == true, difficulty .. " ok")
		return result.action.type
	end

	local function expect(opts, want, label)
		for _, difficulty in ipairs(STRONG) do
			local got = chosen(difficulty, opts)
			ctx.eq(got, want, difficulty .. " " .. label)
			ctx.vector("joker_first_" .. difficulty .. "_" .. label, got)
		end
	end

	test("review_repro_cheaper_pack_does_not_beat_the_joker", function()
		-- $12 with a $6-7 unmodelled Joker and a $4 Celestial or Buffoon pack:
		-- both fit, so the Joker is bought first.
		for _, pack in ipairs({ "p_celestial_normal_1", "p_buffoon_normal_1" }) do
			for _, price in ipairs({ 6, 7 }) do
				expect({ money = 12, joker = "j_ride_the_bus", joker_cost = price, pack = pack, pack_cost = 4 },
					"BUY_ITEM", pack .. "_" .. price)
			end
		end
	end)

	test("joker_first_across_joker_and_pack_prices", function()
		expect({ money = 20, joker = "j_ride_the_bus", joker_cost = 8, pack = "p_celestial_normal_1", pack_cost = 4 }, "BUY_ITEM", "20_8_4")
		expect({ money = 11, joker = "j_ride_the_bus", joker_cost = 5, pack = "p_buffoon_normal_1", pack_cost = 6 }, "BUY_ITEM", "11_5_6")
		expect({ money = 40, joker = "j_ride_the_bus", joker_cost = 10, pack = "p_buffoon_mega_1", pack_cost = 8 }, "BUY_ITEM", "40_10_8")
	end)

	test("joker_first_across_joker_and_voucher_prices", function()
		expect({ money = 12, joker = "j_ride_the_bus", joker_cost = 6, voucher = "v_overstock_norm", voucher_cost = 10 }, "BUY_ITEM", "v12_6_10")
		expect({ money = 20, joker = "j_ride_the_bus", joker_cost = 8, voucher = "v_antimatter", voucher_cost = 10 }, "BUY_ITEM", "v20_8_10")
		expect({ money = 30, joker = "j_ride_the_bus", joker_cost = 7, voucher = "v_grabber", voucher_cost = 10 }, "BUY_ITEM", "v30_7_10")
		-- The review's equal-price case: $20, Blueprint $10 vs Grabber $10.
		expect({ money = 20, joker = "j_blueprint", joker_cost = 10, voucher = "v_grabber", voucher_cost = 10 }, "BUY_ITEM", "v20_blueprint_grabber")
	end)

	test("joker_first_across_interest_breakpoints", function()
		-- $25: the Joker leaves $19 (interest 3), the pack $21 (interest 4).
		expect({ money = 25, joker = "j_ride_the_bus", joker_cost = 6, pack = "p_celestial_normal_1", pack_cost = 4 }, "BUY_ITEM", "i25_6_4")
		-- $30: the Joker drops below the $25 interest cap, the voucher does not.
		expect({ money = 30, joker = "j_ride_the_bus", joker_cost = 6, voucher = "v_grabber", voucher_cost = 5 }, "BUY_ITEM", "i30_6_5")
	end)

	test("joker_wins_when_only_one_fits_and_the_pack_is_slightly_cheaper", function()
		-- Review N3: $9 Ride the Bus $6 vs Celestial $4; $10 Ride the Bus $7 vs
		-- Buffoon $4. Only one fits; the $2-3 price gap no longer decides.
		expect({ money = 9, joker = "j_ride_the_bus", joker_cost = 6, pack = "p_celestial_normal_1", pack_cost = 4 }, "BUY_ITEM", "n3_9_6_4")
		expect({ money = 10, joker = "j_ride_the_bus", joker_cost = 7, pack = "p_buffoon_normal_1", pack_cost = 4 }, "BUY_ITEM", "n3_10_7_4")
	end)

	test("strong_joker_beats_weak_pack", function()
		expect({ money = 12, joker = "j_cavendish", joker_cost = 8, pack = "p_standard_normal_1", pack_cost = 4 }, "BUY_ITEM", "cavendish_standard")
		expect({ money = 12, joker = "j_cavendish", joker_cost = 8, pack = "p_celestial_normal_1", pack_cost = 4 }, "BUY_ITEM", "cavendish_celestial")
	end)

	test("weak_joker_that_drains_the_money_loses_to_a_strong_pack", function()
		-- $10: an unmodelled $9 Joker would leave $1 and cannot be bought with
		-- the pack; the $4 Celestial pack keeps the economy. Not an absolute
		-- Joker-first rule.
		expect({ money = 10, joker = "j_ride_the_bus", joker_cost = 9, pack = "p_celestial_normal_1", pack_cost = 4 }, "OPEN_BOOSTER", "drain_pack")
		expect({ money = 14, joker = "j_ride_the_bus", joker_cost = 13, voucher = "v_grabber", voucher_cost = 5 }, "BUY_VOUCHER", "drain_voucher")
	end)

	test("full_slots_leave_packs_and_vouchers_unconstrained", function()
		-- Five of five slots: no Joker is certified, so the pack and voucher
		-- are valued on their own.
		expect({ money = 12, owned = 5, pack = "p_celestial_normal_1", pack_cost = 4 }, "OPEN_BOOSTER", "full_pack")
		expect({ money = 12, owned = 5, voucher = "v_overstock_norm", voucher_cost = 10 }, "BUY_VOUCHER", "full_voucher")
	end)

	test("negative_joker_is_protected_with_full_slots", function()
		-- A Negative Joker needs no slot, so it is still the reference Joker.
		expect({ money = 12, owned = 5, joker = "j_ride_the_bus", joker_cost = 7, joker_edition = "negative",
			pack = "p_celestial_normal_1", pack_cost = 4 }, "BUY_ITEM", "negative_full")
	end)

	test("available_slot_joker_is_protected", function()
		expect({ money = 12, owned = 4, joker = "j_ride_the_bus", joker_cost = 7, pack = "p_buffoon_normal_1", pack_cost = 4 },
			"BUY_ITEM", "slot_free")
	end)

	test("rookie_keeps_simple_shop_scores", function()
		-- Rookie has no pack/voucher tiers; its flat scores are unchanged.
		local got = chosen("rookie", { money = 12, joker = "j_ride_the_bus", joker_cost = 6, pack = "p_celestial_normal_1", pack_cost = 4 })
		ctx.eq(got, "BUY_ITEM", "rookie")
	end)
end
