return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function step(difficulty, frame, expected_type)
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, difficulty .. "_candidates_" .. expected_type)
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty .. "_ok:" .. tostring(result.code))
		ctx.eq(result.action.type, expected_type, difficulty .. "_type")
		ctx.truthy(Support.member_of(list, result.action.id), difficulty .. "_member")
		ctx.vector("lifecycle_" .. expected_type .. "_" .. difficulty, result.action.id)
	end

	test("policy_lifecycle_progression_is_legal", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			step(difficulty, Support.blind_frame(), "SELECT_BLIND")
			step(difficulty, Support.play_frame(), "PLAY_CARDS")
			step(difficulty, Support.discard_only_frame(), "DISCARD_CARDS")
			step(difficulty, Support.booster_frame(), "SELECT_BOOSTER_ITEM")
			step(difficulty, Support.shop_frame(), "BUY_ITEM")
			step(difficulty, Support.consumable_frame(), "USE_CONSUMABLE")
			local reorder = Support.run(env, difficulty, Support.reorder_adjacent_frame())
			ctx.is_true(reorder.ok == false, difficulty .. "_reorder_no_action")
			ctx.eq(reorder.code, "policy_no_action", difficulty .. "_reorder_code")
			ctx.eq(reorder.action, nil, difficulty .. "_reorder_nil")
			local complete = Support.run(env, difficulty, Support.complete_frame())
			ctx.eq(complete.ok, false, difficulty .. "_complete_no_action")
			ctx.eq(complete.code, "policy_no_action", difficulty .. "_complete_code")
		end
	end)

	test("policy_lifecycle_frames_are_schema_honest", function()
		local frames = {
			Support.blind_frame(),
			Support.play_frame(),
			Support.discard_only_frame(),
			Support.shop_frame(),
			Support.booster_frame(),
			Support.consumable_frame(),
			Support.pvp_frame(),
			Support.blocked_frame(),
			Support.complete_frame(),
		}
		for i = 1, #frames do
			local frame = frames[i]
			local plain = Support.export(env, frame)
			ctx.eq(plain.schema_version, 1, "version" .. i)
			ctx.eq(plain.phase, frame.phase, "phase" .. i)
			if frame.phase ~= "MATCH_COMPLETE" then
				ctx.truthy(type(plain.match) == "table", "match" .. i)
				ctx.truthy(type(plain.context) == "table", "context" .. i)
			end
		end
	end)

	test("policy_lifecycle_repeats_identically", function()
		local sequence = {
			Support.blind_frame(),
			Support.play_frame(),
			Support.shop_frame(),
			Support.booster_frame(),
			Support.consumable_frame(),
		}
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			for i = 1, #sequence do
				local first = Support.choose_id(env, difficulty, sequence[i])
				local second = Support.choose_id(env, difficulty, sequence[i])
				ctx.eq(first, second, difficulty .. "_step" .. i)
			end
		end
	end)
end
