return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function run_ok(difficulty, frame)
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty .. "_ok:" .. tostring(result.code))
		return result.action
	end

	local function legal(difficulty, frame, action)
		local list = Support.generate(env, frame)
		ctx.truthy(Support.member_of(list, action.id), difficulty .. "_candidate")
		ctx.eq(action.id, Support.find_candidate(list, action.id).id, difficulty .. "_id")
	end

	local function candidate_id(frame, kind, refs)
		local candidate = Support.find_by_refs(Support.generate(env, frame), kind, refs)
		ctx.truthy(candidate ~= nil, "candidate_missing_" .. kind)
		return candidate.id
	end

	local function choose(difficulty, frame, kind, label)
		local action = run_ok(difficulty, frame)
		ctx.eq(action.type, kind, (label or kind) .. "_" .. difficulty .. "_type")
		legal(difficulty, frame, action)
		ctx.vector("choice_" .. (label or kind) .. "_" .. difficulty, action.id)
		return action
	end

	test("policy_prefers_made_pair_over_weak_longer_play", function()
		local frame = Support.pair_frame()
		local pair_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:2" })
		local weak_id = candidate_id(frame, "PLAY_CARDS", { "hand:3", "hand:4", "hand:5" })
		ctx.neq(pair_id, weak_id, "distinct_candidates")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "PLAY_CARDS", "pair")
			ctx.eq(action.id, pair_id, difficulty .. "_pair_wins")
		end
	end)

	test("policy_ranks_flush_above_pair_and_high_card", function()
		local frame = Support.flush_frame()
		local flush_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" })
		local pair_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:6" })
		local high_id = candidate_id(frame, "PLAY_CARDS", { "hand:5" })
		ctx.neq(flush_id, pair_id, "distinct")
		ctx.neq(flush_id, high_id, "distinct_high")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "PLAY_CARDS", "flush")
			ctx.eq(action.id, flush_id, difficulty .. "_flush_wins")
		end
	end)

	test("policy_detects_nonadjacent_pair", function()
		local frame = Support.nonadjacent_pair_frame()
		local pair_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:3" })
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "PLAY_CARDS", "nonadjacent")
			ctx.eq(action.id, pair_id, difficulty .. "_pair_detected")
		end
	end)

	test("policy_recognizes_ace_low_straight", function()
		local frame = Support.ace_low_frame()
		local straight_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" })
		local ace_id = candidate_id(frame, "PLAY_CARDS", { "hand:1" })
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "PLAY_CARDS", "ace_low")
			ctx.eq(action.id, straight_id, difficulty .. "_wheel")
			ctx.neq(action.id, ace_id, difficulty .. "_not_high_card")
		end
	end)

	test("policy_recognizes_ace_high_straight", function()
		local frame = Support.ace_high_frame()
		local straight_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" })
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "PLAY_CARDS", "ace_high")
			ctx.eq(action.id, straight_id, difficulty .. "_broadway")
		end
	end)

	test("policy_discard_beats_weak_play", function()
		local frame = Support.high_card_frame()
		local discard_id = candidate_id(frame, "DISCARD_CARDS", { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" })
		local play_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" })
		ctx.neq(discard_id, play_id, "distinct")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "DISCARD_CARDS", "weak_discard")
			ctx.eq(action.id, discard_id, difficulty .. "_discard_wins")
		end
	end)

	test("policy_discard_preserves_made_components", function()
		local frame = Support.preserve_frame()
		local junk_id = candidate_id(frame, "DISCARD_CARDS", { "hand:3", "hand:4", "hand:5" })
		local break_id = candidate_id(frame, "DISCARD_CARDS", { "hand:1", "hand:2" })
		ctx.neq(junk_id, break_id, "distinct")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "DISCARD_CARDS", "preserve")
			ctx.eq(action.id, junk_id, difficulty .. "_keeps_pair")
			ctx.truthy(Support.same_refs(action.card_refs, { "hand:3", "hand:4", "hand:5" }), difficulty .. "_junk_refs")
		end
	end)

	test("policy_shop_buys_affordable_item", function()
		local frame = Support.shop_frame()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, frame, "BUY_ITEM", "shop")
		end
	end)

	test("policy_shop_prefers_cheaper_equivalent_item", function()
		local frame = Support.two_joker_frame()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "BUY_ITEM", "economy")
			ctx.eq(action.item_ref, "shop:2", difficulty .. "_cheaper")
		end
	end)

	test("policy_shop_respects_reserve", function()
		local frame = Support.tight_shop_frame()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, frame, "LEAVE_SHOP", "reserve")
		end
	end)

	test("policy_reroll_is_selective", function()
		local rich = Support.rich_reroll_frame()
		local poor = Support.poor_reroll_frame()
		choose("rookie", rich, "REROLL", "rich_reroll")
		choose("competitive", rich, "REROLL", "rich_reroll")
		-- $60 is far above the $25 interest cap, where money earns nothing:
		-- Major League also rerolls (tests/benchmark_runs.py held-out paired
		-- runs: about +0.33 blinds per run, docs/BASELINE_POLICY.md §5).
		choose("major_league", rich, "REROLL", "rich_reroll")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, poor, "LEAVE_SHOP", "poor_leave")
		end
	end)

	test("policy_blind_selects_rather_than_skips", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, Support.blind_frame(), "SELECT_BLIND", "blind")
		end
	end)

	test("policy_blind_selects_with_zero_visible_hands", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, Support.blind_zero_hands_frame(), "SELECT_BLIND", "blind_zero_hands")
		end
	end)

	test("policy_shop_single_action_coverage", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, Support.voucher_frame(), "BUY_VOUCHER", "voucher")
			choose(difficulty, Support.booster_shop_frame(), "OPEN_BOOSTER", "booster_shop")
			choose(difficulty, Support.reroll_frame(), "REROLL", "reroll_only")
		end
	end)

	test("policy_booster_selects_or_skips_when_offered", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, Support.booster_frame(), "SELECT_BOOSTER_ITEM", "booster_pick")
			choose(difficulty, Support.skip_booster_frame(), "SKIP_BOOSTER", "booster_skip")
		end
	end)

	test("policy_consumable_commits_legal_use", function()
		local frame = Support.consumable_frame()
		candidate_id(frame, "USE_CONSUMABLE", {})
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "USE_CONSUMABLE", "commit_optional")
			local again = Support.run(env, difficulty, frame)
			ctx.eq(again.action.id, action.id, difficulty .. "_commit_stable")
			ctx.neq(action.id, candidate_id(frame, "SELECT_TARGETS", { "target:1" }), difficulty .. "_not_highlight")
		end
	end)

	test("policy_consumable_prefers_committing_use_over_target_highlight", function()
		local frame = Support.consumable_commit_frame()
		local use_id = candidate_id(frame, "USE_CONSUMABLE", { "target:1" })
		local select_id = candidate_id(frame, "SELECT_TARGETS", { "target:1" })
		ctx.neq(use_id, select_id, "distinct")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "USE_CONSUMABLE", "commit_required")
			ctx.eq(action.id, use_id, difficulty .. "_commits")
			ctx.truthy(Support.same_refs(action.target_refs, { "target:1" }), difficulty .. "_commit_refs")
		end
	end)

	test("policy_two_step_target_progression_terminates", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local first = Support.run(env, difficulty, Support.consumable_highlight_only_frame())
			ctx.is_true(first.ok == true, difficulty .. "_step1_ok")
			ctx.eq(first.action.type, "SELECT_TARGETS", difficulty .. "_step1_selects")
			local second = Support.run(env, difficulty, Support.consumable_commit_frame())
			ctx.is_true(second.ok == true, difficulty .. "_step2_ok")
			ctx.eq(second.action.type, "USE_CONSUMABLE", difficulty .. "_step2_commits")
			ctx.neq(first.action.type, second.action.type, difficulty .. "_progress")
			local third = Support.run(env, difficulty, Support.consumable_commit_frame())
			ctx.eq(third.action.id, second.action.id, difficulty .. "_stable")
		end
	end)

	test("policy_multi_target_commit_is_reported_unsupported", function()
		local frame = Support.consumable_multi_target_frame()
		local list = Support.generate(env, frame)
		ctx.eq(#list, 0, "no_legal_candidate")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == false, difficulty .. "_not_ok")
			ctx.eq(result.code, "policy_no_action", difficulty .. "_code")
			ctx.eq(result.action, nil, difficulty .. "_no_invention")
		end
	end)

	test("policy_never_sells_even_when_it_is_the_only_offered_candidate", function()
		local frame = Support.sell_frame()
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, "sell_offered")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == false, difficulty .. "_not_ok")
			ctx.eq(result.code, "policy_no_action", difficulty .. "_code")
			ctx.eq(result.action, nil, difficulty .. "_no_sell")
		end
	end)

	test("policy_pvp_wait_with_no_hands_does_not_dump_jokers", function()
		local frame = Support.adapter_pvp_zero_hands_frame()
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, "adapter_candidates_present")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == false, difficulty .. "_not_ok")
			ctx.eq(result.code, "policy_no_action", difficulty .. "_code")
			ctx.eq(result.action, nil, difficulty .. "_no_action")
		end
	end)

	test("policy_multi_target_adapter_frame_never_sells_or_reorders", function()
		local frame = Support.adapter_consumable_multi_target_frame()
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, "adapter_candidates_present")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == false, difficulty .. "_not_ok")
			ctx.eq(result.code, "policy_no_action", difficulty .. "_code")
			ctx.eq(result.action, nil, difficulty .. "_no_action")
		end
	end)

	test("policy_missing_target_bounds_never_sells", function()
		local frame = Support.consumable_missing_bounds_frame()
		local list = Support.generate(env, frame)
		ctx.truthy(#list > 0, "adapter_candidates_present")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == false, difficulty .. "_not_ok")
			ctx.eq(result.code, "policy_no_action", difficulty .. "_code")
			ctx.eq(result.action, nil, difficulty .. "_no_action")
		end
	end)

	test("policy_pvp_plays_cards", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			choose(difficulty, Support.pvp_frame(), "PLAY_CARDS", "pvp")
		end
	end)

	test("policy_noop_reorder_yields_no_action", function()
		local frame = Support.reorder_frame()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.eq(result.ok, false, difficulty .. "_not_ok")
			ctx.eq(result.code, "policy_no_action", difficulty .. "_code")
			ctx.eq(result.action, nil, difficulty .. "_no_action")
		end
	end)

	test("policy_prefers_play_over_noop_reorder", function()
		local frame = Support.play_with_noop_reorder_frame()
		local play_id = candidate_id(frame, "PLAY_CARDS", { "hand:1", "hand:2" })
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = choose(difficulty, frame, "PLAY_CARDS", "over_noop_reorder")
			ctx.eq(action.id, play_id, difficulty .. "_play_not_reorder")
		end
	end)

	test("policy_never_selects_reorders", function()
		local frames = {
			Support.reorder_frame(),
			Support.reorder_reverse_frame(),
			Support.reorder_adjacent_frame(),
		}
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			for i = 1, #frames do
				local first = Support.run(env, difficulty, frames[i])
				local second = Support.run(env, difficulty, frames[i])
				ctx.is_true(first.ok == false, difficulty .. "_frame" .. i .. "_no_action")
				ctx.eq(first.code, "policy_no_action", difficulty .. "_frame" .. i .. "_code")
				ctx.eq(first.action, nil, difficulty .. "_frame" .. i .. "_nil")
				ctx.eq(second.code, first.code, difficulty .. "_frame" .. i .. "_stable")
			end
		end
	end)

	test("policy_reorder_reverse_and_adjacent_sequence_does_not_oscillate", function()
		local sequence = {
			Support.reorder_reverse_frame(),
			Support.reorder_adjacent_frame(),
			Support.reorder_reverse_frame(),
		}
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			for i = 1, #sequence do
				local result = Support.run(env, difficulty, sequence[i])
				ctx.is_true(result.ok == false, difficulty .. "_seq" .. i .. "_no_action")
				ctx.eq(result.code, "policy_no_action", difficulty .. "_seq" .. i .. "_code")
			end
		end
	end)

	test("policy_blocked_state_yields_no_action", function()
		local result = Support.run(env, "competitive", Support.blocked_frame())
		ctx.is_true(result.ok == false, "not_ok")
		ctx.eq(result.code, "policy_no_action", "code")
		ctx.eq(result.action, nil, "no_action")
	end)

	test("policy_match_complete_yields_no_action", function()
		local result = Support.run(env, "major_league", Support.complete_frame())
		ctx.is_true(result.ok == false, "not_ok")
		ctx.eq(result.code, "policy_no_action", "code")
	end)

	test("policy_never_invents_candidates", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local frames = {
				Support.blind_frame(),
				Support.play_frame(),
				Support.pair_frame(),
				Support.flush_frame(),
				Support.discard_only_frame(),
				Support.shop_frame(),
				Support.booster_frame(),
				Support.consumable_frame(),
			}
			for i = 1, #frames do
				local frame = frames[i]
				local action = run_ok(difficulty, frame)
				local list = Support.generate(env, frame)
				ctx.truthy(Support.member_of(list, action.id), difficulty .. "_frame" .. i)
			end
		end
	end)

	test("policy_start_timer_by_difficulty", function()
		local frame = Support.timer_frame()
		local list = Support.generate(env, frame)
		ctx.eq(#list, 1)
		ctx.eq(list[1].type, "START_TIMER")
		local rookie = Support.run(env, "rookie", frame)
		ctx.is_true(rookie.ok ~= true, "rookie leaves the timer alone")
		ctx.eq(rookie.code, "policy_no_action")
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local action = run_ok(difficulty, frame)
			ctx.eq(action.type, "START_TIMER", difficulty)
			legal(difficulty, frame, action)
		end
	end)

	local function kind_of(difficulty, frame)
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		return result.action
	end

	test("policy_plays_a_clearing_hand_instead_of_discarding", function()
		-- 64 >= 60 remaining: the pair clears, so no discard is spent.
		local frame = Support.requirement_frame("60", 2, 3)
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			local action = kind_of(difficulty, frame)
			ctx.eq(action.type, "PLAY_CARDS", difficulty)
			ctx.eq(#action.card_refs, 2, difficulty .. " plays the pair")
		end
	end)

	test("policy_discards_when_plays_cannot_reach_the_requirement", function()
		-- 64 x 2 hands << 1000: improve the hand while discards remain.
		local frame = Support.requirement_frame("1000", 2, 3)
		for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
			ctx.eq(kind_of(difficulty, frame).type, "DISCARD_CARDS", difficulty)
		end
		-- Rookie does not read the requirement: it plays its made pair.
		ctx.eq(kind_of("rookie", frame).type, "PLAY_CARDS", "rookie")
		-- Without discards everyone plays the best hand.
		local no_discards = Support.requirement_frame("1000", 2, 0)
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = kind_of(difficulty, no_discards)
			ctx.eq(action.type, "PLAY_CARDS", difficulty)
			ctx.eq(#action.card_refs, 2, difficulty)
		end
	end)

	test("policy_ignores_requirement_in_pvp", function()
		-- The PvP target is the opponent's score, never the blind requirement.
		local frame = Support.requirement_frame("100000", 2, 3, "MULTIPLAYER_PVP")
		ctx.eq(kind_of("major_league", frame).type, "PLAY_CARDS")
	end)

	test("policy_counts_visible_joker_effects", function()
		-- The Duo (x2 on a pair) lifts the pair to 128 >= 100: it clears,
		-- while without Jokers (Rookie's view) it would not.
		local frame = Support.requirement_frame("100", 1, 3, nil, { Support.joker("j_duo") })
		local action = kind_of("competitive", frame)
		ctx.eq(action.type, "PLAY_CARDS")
		ctx.eq(#action.card_refs, 2)
	end)

	test("policy_requirement_parsing_is_defensive", function()
		for _, text in ipairs({ "1,000", "1e3", "abc", "12.5.3", "0" }) do
			local frame = Support.requirement_frame(text, 2, 3)
			local result = Support.run(env, "major_league", frame)
			ctx.is_true(result.ok == true, text .. ":" .. tostring(result.code))
		end
	end)
end

