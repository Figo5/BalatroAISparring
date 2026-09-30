-- The interest cap follows owned Seed Money ($50) and Money Tree ($100)
-- (docs/OWNED_VOUCHERS_DESIGN.md). Two identical unmodelled Jokers at $10 and
-- $5: when both purchases stay at the interest cap they tie (the first id
-- wins); when the cap is higher, the cheaper one keeps more interest.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local STRONG = { "competitive", "major_league", "expert" }

	local function shop(money, owned)
		local frame = Support.voucher_frame()
		frame.self.money = money
		frame.self.jokers = {}
		frame.self.vouchers = {}
		for i = 1, #owned do
			frame.self.vouchers[i] = { center = owned[i], face_down = false }
		end
		frame.shop.items = {
			{ kind = "joker", center = "j_credit_card", cost = 10, sell_cost = 5, face_down = false },
			{ kind = "joker", center = "j_credit_card", cost = 5, sell_cost = 2, face_down = false },
		}
		frame.shop.vouchers, frame.shop.boosters = {}, {}
		frame.certificates.items = {
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:2", capacity_ok = true },
			{ type = "LEAVE_SHOP", certified = true },
		}
		return frame
	end

	local function pick(difficulty, money, owned)
		local result = Support.run(env, difficulty, shop(money, owned))
		ctx.is_true(result.ok == true, difficulty)
		return result.action.item_ref
	end

	test("interest_cap_follows_owned_vouchers", function()
		for _, difficulty in ipairs(STRONG) do
			ctx.eq(pick(difficulty, 50, {}), "shop:1", difficulty .. " no voucher: tie")
			ctx.eq(pick(difficulty, 50, { "v_seed_money" }), "shop:2", difficulty .. " seed money")
			ctx.eq(pick(difficulty, 100, { "v_seed_money" }), "shop:1", difficulty .. " seed money capped")
			-- Money Tree alone raises the cap to 20 ($100).
			ctx.eq(pick(difficulty, 100, { "v_money_tree" }), "shop:2", difficulty .. " money tree")
			ctx.vector("interest_tree_" .. difficulty, pick(difficulty, 100, { "v_money_tree" }))
		end
	end)

	test("interest_cap_does_not_leak_between_decisions", function()
		local fn = assert(loadstring(Support.source(env, "competitive")))()
		local with = shop(100, { "v_money_tree" })
		local without = shop(100, {})
		ctx.eq(fn(Support.export(env, with), Support.generate(env, with)).item_ref, "shop:2", "with")
		ctx.eq(fn(Support.export(env, without), Support.generate(env, without)).item_ref, "shop:1", "without after with")
	end)
end
