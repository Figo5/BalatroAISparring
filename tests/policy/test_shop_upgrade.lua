return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function find_type(list, kind)
		for i = 1, #list do
			if list[i].type == kind then
				return list[i]
			end
		end
		return nil
	end

	local function choose(difficulty, frame, kind, label)
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, label .. "_candidates")
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty .. "_" .. label .. "_ok:" .. tostring(result.code))
		ctx.eq(result.action.type, kind, difficulty .. "_" .. label .. "_type")
		ctx.truthy(Support.member_of(list, result.action.id), difficulty .. "_" .. label .. "_member")
		ctx.eq(result.action.id, Support.find_candidate(list, result.action.id).id, difficulty .. "_" .. label .. "_canonical")
		local again = Support.run(env, difficulty, frame)
		ctx.eq(again.action.id, result.action.id, difficulty .. "_" .. label .. "_stable")
		ctx.vector("shop_upgrade_" .. label .. "_" .. difficulty, result.action.id)
		return result.action, list
	end

	local function expect_leave(difficulty, frame, label)
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, label .. "_candidates")
		ctx.truthy(find_type(list, "SELL_JOKER") ~= nil, label .. "_sell_offered")
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, label .. "_ok:" .. tostring(result.code))
		ctx.eq(result.action.type, "LEAVE_SHOP", label .. "_leaves")
		ctx.neq(result.action.type, "SELL_JOKER", label .. "_no_sell")
		return list
	end

	test("policy_shop_slot_pressure_sells_for_a_visible_upgrade", function()
		local frame = Support.full_slot_upgrade_frame()
		local list = Support.generate(env, frame)
		local sell = find_type(list, "SELL_JOKER")
		ctx.truthy(sell ~= nil, "sell_offered")
		ctx.eq(sell.joker_ref, "joker:1", "sell_ref")
		ctx.truthy(find_type(list, "BUY_ITEM") ~= nil, "competing_buy_offered")
		ctx.truthy(find_type(list, "LEAVE_SHOP") ~= nil, "leave_offered")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "SELL_JOKER", "slot_sell")
			ctx.eq(action.joker_ref, "joker:1", difficulty .. "_sell_ref")
		end
	end)

	test("policy_shop_prefers_the_editioned_upgrade_over_inferior_copies", function()
		local frame = Support.slot_freed_upgrade_frame()
		local action = choose("competitive", frame, "BUY_ITEM", "upgrade_pick")
		ctx.eq(action.item_ref, "shop:1", "picks_editioned_upgrade")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local picked = choose(difficulty, frame, "BUY_ITEM", "upgrade_pick")
			ctx.eq(picked.item_ref, "shop:1", difficulty .. "_prefers_upgrade")
		end
	end)

	test("policy_shop_two_step_sell_then_buy_then_no_further_sale", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local first = Support.run(env, difficulty, Support.full_slot_upgrade_frame())
			ctx.is_true(first.ok == true, difficulty .. "_step1_ok:" .. tostring(first.code))
			ctx.eq(first.action.type, "SELL_JOKER", difficulty .. "_step1_sell")
			ctx.eq(first.action.joker_ref, "joker:1", difficulty .. "_step1_ref")

			local second = Support.run(env, difficulty, Support.slot_freed_upgrade_frame())
			ctx.is_true(second.ok == true, difficulty .. "_step2_ok:" .. tostring(second.code))
			ctx.eq(second.action.type, "BUY_ITEM", difficulty .. "_step2_buy")
			ctx.eq(second.action.item_ref, "shop:1", difficulty .. "_step2_upgrade")

			local third = Support.run(env, difficulty, Support.post_upgrade_no_sale_frame())
			ctx.is_true(third.ok == true, difficulty .. "_step3_ok:" .. tostring(third.code))
			ctx.neq(third.action.type, "SELL_JOKER", difficulty .. "_step3_no_sale")
			ctx.eq(third.action.type, "LEAVE_SHOP", difficulty .. "_step3_leave")
		end
	end)

	test("policy_shop_does_not_sell_without_a_clear_upgrade", function()
		local frames = {
			Support.full_slot_equal_edition_frame(),
			Support.full_slot_worse_edition_frame(),
			Support.full_slot_unrecognized_center_frame(),
			Support.full_slot_different_center_frame(),
			Support.full_slot_debuffed_upgrade_frame(),
			Support.full_slot_negative_upgrade_frame(),
			Support.full_slot_unaffordable_upgrade_frame(),
		}
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			for i = 1, #frames do
				expect_leave(difficulty, frames[i], difficulty .. "_frame" .. i)
			end
		end
	end)

	test("policy_never_sells_outside_shop", function()
		local frames = {
			Support.sell_frame(),
			Support.non_shop_full_slot_sell_frame(),
		}
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			for i = 1, #frames do
				local list = Support.generate(env, frames[i])
				ctx.truthy(#list > 0, difficulty .. "_frame" .. i .. "_candidates")
				local result = Support.run(env, difficulty, frames[i])
				ctx.eq(result.ok, false, difficulty .. "_frame" .. i .. "_not_ok")
				ctx.eq(result.code, "policy_no_action", difficulty .. "_frame" .. i .. "_code")
				ctx.eq(result.action, nil, difficulty .. "_frame" .. i .. "_no_sell")
			end
		end
	end)

	-- A grown scaling Joker (Hologram, Green Joker...) is never sold for a
	-- fresh editioned copy: the sale would reset its built-up value.
	test("grown_scaling_joker_is_not_sold_for_a_fresh_copy", function()
		for _, center in ipairs({ "j_hologram", "j_green_joker", "j_trousers" }) do
			local frame = Support.full_slot_upgrade_frame()
			frame.shop.items[1].center = center
			frame.self.jokers[1].center = center
			for _, difficulty in ipairs(Support.DIFFICULTIES) do
				local result = Support.run(env, difficulty, frame)
				ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
				ctx.neq(result.action.type, "SELL_JOKER", difficulty .. "_" .. center)
			end
		end
	end)

	test("ungrown_scaling_joker_can_still_be_upgraded", function()
		local frame = Support.full_slot_upgrade_frame()
		frame.shop.items[1].center = "j_hologram"
		frame.self.jokers[1].center = "j_hologram"
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			frame.self.jokers[1].current = { kind = "xmult", value = 100 }
			ctx.eq(Support.run(env, difficulty, frame).action.type, "SELL_JOKER", difficulty .. " at x1")
			frame.self.jokers[1].current = { kind = "xmult", value = 125 }
			ctx.neq(Support.run(env, difficulty, frame).action.type, "SELL_JOKER", difficulty .. " at x1.25")
		end
	end)
end
