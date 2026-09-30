-- Offered scaling Jokers are valued by a conservative mid-life proxy of their
-- public card text (shop and pack valuation only).
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function shop(offers)
		local frame = Support.voucher_frame()
		frame.self.money = 30
		frame.self.jokers = { Support.joker("j_joker") }
		frame.shop.items, frame.shop.vouchers, frame.shop.boosters = {}, {}, {}
		local certs = {}
		for i = 1, #offers do
			frame.shop.items[i] = { kind = "joker", center = offers[i], cost = 5, sell_cost = 2, face_down = false }
			certs[i] = { type = "BUY_ITEM", certified = true, item_ref = "shop:" .. i, capacity_ok = true }
		end
		certs[#certs + 1] = { type = "LEAVE_SHOP", certified = true }
		frame.certificates.items = certs
		return frame
	end

	test("scaling_jokers_beat_an_unmodelled_joker_at_equal_price", function()
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			for _, center in ipairs({ "j_green_joker", "j_ride_the_bus", "j_constellation", "j_hologram" }) do
				local result = Support.run(env, difficulty, shop({ "j_credit_card", center }))
				ctx.eq(result.action.item_ref, "shop:2", difficulty .. " " .. center)
			end
		end
	end)

	test("jokers_this_policy_cannot_grow_get_no_proxy", function()
		-- Throwback, Red Card, Campfire, Obelisk, Lucky Cat and Vampire keep the
		-- flat value: at equal price the first-listed Credit Card wins the tie.
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			for _, center in ipairs({ "j_throwback", "j_red_card", "j_campfire", "j_obelisk", "j_lucky_cat", "j_vampire" }) do
				local result = Support.run(env, difficulty, shop({ "j_credit_card", center }))
				ctx.eq(result.action.item_ref, "shop:1", difficulty .. " " .. center)
			end
		end
	end)

	test("ride_the_bus_has_no_proxy_next_to_face_card_jokers", function()
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local frame = shop({ "j_credit_card", "j_ride_the_bus" })
			frame.self.jokers = { Support.joker("j_scary_face") }
			ctx.eq(Support.run(env, difficulty, frame).action.item_ref, "shop:1", difficulty)
		end
	end)

	test("scaling_proxies_are_worth_more_early", function()
		-- Green Joker (+3 mult proxy) against a plain +4 Joker: at ante 1 the
		-- proxy is x1.25 (3.75), still below; Ride the Bus (+5) wins early and
		-- loses late (x0.75 = 3.75 < 4).
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local early = shop({ "j_joker", "j_ride_the_bus" })
			early.self.jokers = {}
			early.match.ante = 1
			ctx.eq(Support.run(env, difficulty, early).action.item_ref, "shop:2", difficulty .. " early")
			local late = shop({ "j_joker", "j_ride_the_bus" })
			late.self.jokers = {}
			late.match.ante = 6
			ctx.eq(Support.run(env, difficulty, late).action.item_ref, "shop:1", difficulty .. " late")
		end
	end)

	test("strong_modelled_joker_still_beats_a_scaling_proxy", function()
		-- Cavendish (x3) outranks Hologram's x1.3 mid-life proxy.
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local result = Support.run(env, difficulty, shop({ "j_hologram", "j_cavendish" }))
			ctx.eq(result.action.item_ref, "shop:2", difficulty)
			ctx.vector("scaling_vs_cavendish_" .. difficulty, result.action.item_ref)
		end
	end)
end
