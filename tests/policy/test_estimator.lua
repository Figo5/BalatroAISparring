-- Worst-case cost of the play/discard estimators inside the real sandbox budget.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function card(rank, suit, center, edition, seal)
		return { kind = "card", rank = rank, suit = suit, center = center or "c_base", edition = edition, seal = seal, face_down = false }
	end

	local function heavy_frame()
		local hand = {
			card("Ace", "Hearts", "m_glass", "polychrome", "Red"),
			card("King", "Hearts", "m_lucky", "holo", "Red"),
			card("Queen", "Hearts", "m_steel"),
			card("Jack", "Hearts", "m_bonus", "foil"),
			card("10", "Spades", "m_mult"),
			card("10", "Clubs"),
			card("9", "Diamonds", "m_wild"),
			card("5", "Clubs", "m_stone"),
		}
		local jokers = {}
		for _, center in ipairs({ "j_photograph", "j_triboulet", "j_baron", "j_fibonacci", "j_abstract" }) do
			jokers[#jokers + 1] = { kind = "joker", center = center, face_down = false, edition = "polychrome" }
		end
		local certs = {}
		-- 60 plays and 60 discards: every 1..3 subset in order, then 4/5-card windows.
		local function refs(list)
			local out = {}
			for i = 1, #list do
				out[i] = "hand:" .. list[i]
			end
			return out
		end
		local subsets = {}
		for a = 1, 8 do
			subsets[#subsets + 1] = { a }
			for b = a + 1, 8 do
				subsets[#subsets + 1] = { a, b }
				for c = b + 1, 8 do
					subsets[#subsets + 1] = { a, b, c }
				end
			end
		end
		for i = 1, 60 do
			certs[#certs + 1] = { type = "PLAY_CARDS", certified = true, card_refs = refs(subsets[i]) }
		end
		for i = 1, 60 do
			certs[#certs + 1] = { type = "DISCARD_CARDS", certified = true, card_refs = refs(subsets[#subsets - i + 1]) }
		end
		local frame = Support.requirement_frame("100000", 3, 3)
		frame.self.hand = hand
		frame.self.hand_visible = true
		frame.self.jokers = jokers
		frame.certificates.items = certs
		return frame
	end

	test("estimators_fit_the_instruction_budget_at_120_candidates", function()
		local frame = heavy_frame()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, frame)
			ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		end
	end)

	test("rule_changing_joker_falls_back_to_category_ranking", function()
		-- Four Fingers makes four-card flushes real; the estimate would call
		-- them high cards, so the policy must not use it (and must not enter
		-- estimate-driven discard mode).
		local frame = Support.requirement_frame("1000", 2, 3, nil, { Support.joker("j_four_fingers") })
		local result = Support.run(env, "major_league", frame)
		ctx.is_true(result.ok == true)
		ctx.eq(result.action.type, "PLAY_CARDS")
	end)

	test("last_hand_without_a_clearing_play_discards_first", function()
		local frame = Support.requirement_frame("70", 1, 2)
		-- 64 < 70 remaining, one hand left, discards available.
		local result = Support.run(env, "competitive", frame)
		ctx.is_true(result.ok == true)
		ctx.eq(result.action.type, "DISCARD_CARDS")
	end)
end
