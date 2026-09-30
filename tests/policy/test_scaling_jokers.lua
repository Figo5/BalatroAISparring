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
			for _, center in ipairs({ "j_green_joker", "j_ride_the_bus", "j_obelisk", "j_hologram" }) do
				local result = Support.run(env, difficulty, shop({ "j_credit_card", center }))
				ctx.eq(result.action.item_ref, "shop:2", difficulty .. " " .. center)
			end
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
