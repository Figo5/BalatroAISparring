-- A shop Joker is valued at the position the reorder step would give it: an
-- additive Joker before owned x-mult Jokers, not at the end of the row.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function shop(owned, offers)
		local frame = Support.voucher_frame()
		frame.self.money = 40
		frame.self.jokers = {}
		for i = 1, #owned do
			frame.self.jokers[i] = Support.joker(owned[i])
		end
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

	test("additive_joker_is_valued_before_owned_xmult", function()
		-- Owning a x-mult Joker, an additive Joker is priced before it (as the
		-- reorder step will place it), so it now beats a per-card Joker that
		-- end-of-row placement preferred.
		local cases = {
			{ "j_cavendish", "j_scary_face", "j_joker" },
			{ "j_duo", "j_smiley", "j_half" },
		}
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			for k, case in ipairs(cases) do
				local result = Support.run(env, difficulty, shop({ case[1] }, { case[2], case[3] }))
				ctx.is_true(result.ok == true, difficulty)
				ctx.eq(result.action.item_ref, "shop:2", difficulty .. " " .. case[3])
				ctx.vector("joker_slot_" .. difficulty .. "_" .. k, result.action.item_ref)
			end
		end
		-- When the reorder step would never move the new Joker (an unknown or
		-- pinned Joker owned), it is priced at the end, as before.
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			for k, owned in ipairs({ { "j_cavendish", "j_space" }, { "j_cavendish", "j_misprint" } }) do
				local result = Support.run(env, difficulty, shop(owned, { "j_scary_face", "j_jolly" }))
				ctx.eq(result.action.item_ref, "shop:1", difficulty .. " anchored " .. owned[2])
				ctx.vector("joker_slot_anchored_" .. difficulty .. "_" .. k, result.action.item_ref)
			end
		end
		-- A neutral Joker behind the x-mult blocks the adjacent swaps, so the
		-- new Joker would stay at the end: price it there (review M-A).
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local result = Support.run(env, difficulty, shop({ "j_gros_michel", "j_cavendish", "j_scary_face" }, { "j_photograph", "j_joker" }))
			ctx.eq(result.action.item_ref, "shop:1", difficulty .. " blocked slot")
			ctx.vector("joker_slot_blocked_" .. difficulty, result.action.item_ref)
		end
		-- Without a x-mult Joker owned, placement changes nothing.
		local plain = Support.run(env, "competitive", shop({ "j_joker" }, { "j_scary_face", "j_joker" }))
		ctx.vector("joker_slot_plain", plain.action.item_ref)
	end)
end
