return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function run(difficulty, frame)
		return Support.run(env, difficulty, frame)
	end

	local function next_centers(centers, order)
		local out = {}
		for i = 1, #order do
			local index = tonumber(string.match(order[i], ":(%d+)$"))
			out[i] = centers[index]
		end
		return out
	end

	test("policy_orders_known_addmult_before_known_xmult", function()
		local frame = Support.joker_order_frame({ "j_cavendish", "j_joker", "j_joker" }, {
			{ 3, 2, 1 },
			{ 2, 1, 3 },
			{ 1, 3, 2 },
		})
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = run(difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. "_ok:" .. tostring(result.code))
			ctx.eq(result.action.type, "REORDER_JOKERS", difficulty .. "_type")
			ctx.truthy(Support.same_refs(result.action.order, { "joker:3", "joker:2", "joker:1" }), difficulty .. "_best_improvement")
			ctx.vector("reorder_best_" .. difficulty, result.action.id)
		end
	end)

	test("policy_does_not_reverse_an_already_ordered_set", function()
		local frame = Support.joker_order_frame({ "j_joker", "j_cavendish" }, { { 2, 1 } })
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = run(difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. "_ok")
			ctx.eq(result.action.type, "LEAVE_SHOP", difficulty .. "_leaves")
		end
	end)

	test("policy_stable_target_yields_no_reorder", function()
		local frame = Support.joker_order_frame({ "j_joker", "j_joker", "j_cavendish" }, {
			{ 3, 2, 1 },
			{ 2, 1, 3 },
			{ 1, 3, 2 },
		})
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = run(difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. "_ok")
			ctx.eq(result.action.type, "LEAVE_SHOP", difficulty .. "_no_reorder")
		end
	end)

	test("policy_values_known_copying_joker_placements", function()
		local frame = Support.joker_order_frame({ "j_blueprint", "j_cavendish", "j_joker" }, {
			{ 1, 3, 2 },
			{ 3, 2, 1 },
		})
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = run(difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. "_ok")
			if difficulty == "rookie" then
				ctx.eq(result.action.type, "LEAVE_SHOP", difficulty .. "_copy_anchor")
			else
				ctx.eq(result.action.type, "REORDER_JOKERS", difficulty .. "_copy_gain")
				ctx.truthy(Support.same_refs(result.action.order, { "joker:1", "joker:3", "joker:2" }), difficulty .. "_copy_target")
			end
		end
	end)

	test("policy_orders_known_jokers_around_an_unknown_anchor", function()
		local frame = Support.joker_order_frame({ "j_unrecognized_alpha", "j_cavendish", "j_joker" }, {
			{ 1, 3, 2 },
		})
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = run(difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. "_ok")
			ctx.eq(result.action.type, "REORDER_JOKERS", difficulty .. "_type")
			ctx.truthy(Support.same_refs(result.action.order, { "joker:1", "joker:3", "joker:2" }), difficulty .. "_anchor_fixed")
		end
	end)

	test("policy_reorder_two_step_reobserved_order_converges", function()
		local difficulty = "competitive"
		local variants = { { 4, 3, 2, 1 }, { 2, 1, 3, 4 }, { 1, 3, 2, 4 }, { 1, 2, 4, 3 } }
		local centers = { "j_cavendish", "j_joker", "j_cavendish", "j_joker" }

		local first = run(difficulty, Support.joker_order_frame(centers, variants))
		ctx.is_true(first.ok == true, "step1_ok:" .. tostring(first.code))
		ctx.eq(first.action.type, "REORDER_JOKERS", "step1_type")
		ctx.truthy(Support.same_refs(first.action.order, { "joker:4", "joker:3", "joker:2", "joker:1" }), "step1_order")

		local second_centers = next_centers(centers, first.action.order)
		local second = run(difficulty, Support.joker_order_frame(second_centers, variants))
		ctx.is_true(second.ok == true, "step2_ok:" .. tostring(second.code))
		ctx.eq(second.action.type, "REORDER_JOKERS", "step2_type")
		ctx.truthy(Support.same_refs(second.action.order, { "joker:1", "joker:3", "joker:2", "joker:4" }), "step2_order")

		local third_centers = next_centers(second_centers, second.action.order)
		local third = run(difficulty, Support.joker_order_frame(third_centers, variants))
		ctx.is_true(third.ok == true, "step3_ok")
		ctx.eq(third.action.type, "LEAVE_SHOP", "step3_stable")
	end)

	test("policy_reorder_never_preempts_a_real_action", function()
		local frame = Support.jokers_with_play_frame()
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, "candidates")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = run(difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. "_ok")
			ctx.eq(result.action.type, "PLAY_CARDS", difficulty .. "_plays")
		end
	end)

	test("policy_never_emits_reorder_hand", function()
		local frame = Support.reorder_adjacent_frame()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = run(difficulty, frame)
			ctx.eq(result.ok, false, difficulty .. "_not_ok")
			ctx.eq(result.code, "policy_no_action", difficulty .. "_code")
		end
	end)
end