-- Targeted Tarots on hand cards (docs/HAND_TARGETS_DESIGN.md): the policy
-- simulates each certified use on a copy of the hand and uses the Tarot only
-- on a clear gain in the best estimated play; otherwise it is held.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local STRONG = { "competitive", "major_league", "expert" }

	local function card(rank, suit, center)
		return { kind = "card", rank = rank, suit = suit, center = center or "c_base", face_down = false }
	end

	-- `uses`: { { refs }, ... } for one held Tarot, plus the plays of each card
	-- pair so there is always a play to fall back on.
	local function frame(hand, center, uses)
		local f = Support.requirement_frame("100000", 3, 0)
		f.self.hand = hand
		f.self.consumables = { { kind = "consumable", center = center, face_down = false } }
		local items = {}
		for i = 1, #hand do
			items[#items + 1] = { type = "PLAY_CARDS", certified = true, card_refs = { "hand:" .. i } }
			for j = i + 1, #hand do
				items[#items + 1] = { type = "PLAY_CARDS", certified = true, card_refs = { "hand:" .. i, "hand:" .. j } }
			end
		end
		for _, refs in ipairs(uses) do
			items[#items + 1] = { type = "USE_CONSUMABLE_ON_HAND", certified = true, source_ref = "consumable:1", card_refs = refs }
		end
		f.certificates.items = items
		return f
	end

	local function pick(difficulty, f)
		local result = Support.run(env, difficulty, f)
		ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		local a = result.action
		return a.type == "USE_CONSUMABLE_ON_HAND" and table.concat(a.card_refs, "+") or a.type
	end

	test("strength_turns_a_kicker_into_three_of_a_kind", function()
		local hand = { card("9", "Spades"), card("9", "Hearts"), card("8", "Clubs"), card("4", "Diamonds"), card("2", "Spades") }
		for _, d in ipairs(STRONG) do
			ctx.eq(pick(d, frame(hand, "c_strength", { { "hand:3" }, { "hand:4" }, { "hand:5" } })), "hand:3", d)
		end
	end)

	test("death_overwrites_the_left_card_whatever_the_ref_order", function()
		-- The 5 sits left of an Ace: Death makes it a third Ace. The refs are
		-- listed right-first; position, not ref order, decides.
		local hand = { card("5", "Clubs"), card("Ace", "Spades"), card("Ace", "Hearts"), card("3", "Diamonds"), card("2", "Spades") }
		for _, d in ipairs(STRONG) do
			ctx.eq(pick(d, frame(hand, "c_death", { { "hand:2", "hand:1" }, { "hand:2", "hand:4" } })), "hand:2+hand:1", d)
		end
	end)

	test("a_suit_tarot_completes_a_flush", function()
		local hand = { card("2", "Hearts"), card("6", "Hearts"), card("9", "Hearts"), card("Jack", "Hearts"), card("4", "Spades") }
		for _, d in ipairs(STRONG) do
			ctx.eq(pick(d, frame(hand, "c_sun", { { "hand:5" } })), "hand:5", d)
		end
	end)

	test("a_tarot_without_gain_is_held", function()
		-- Strength on the 2 (it becomes a 3) leaves the pair of Kings best.
		local hand = { card("King", "Spades"), card("King", "Hearts"), card("7", "Clubs"), card("4", "Diamonds"), card("2", "Spades") }
		for _, d in ipairs(STRONG) do
			ctx.eq(pick(d, frame(hand, "c_strength", { { "hand:5" } })), "PLAY_CARDS", d)
		end
	end)

	test("generator_keeps_hand_refs_to_the_hand_phases", function()
		local hand = { card("9", "Spades"), card("9", "Hearts"), card("8", "Clubs") }
		local function count(f)
			local n = 0
			for _, a in ipairs(Support.generate(env, f)) do
				if a.type == "USE_CONSUMABLE_ON_HAND" then
					n = n + 1
				end
			end
			return n
		end
		ctx.eq(count(frame(hand, "c_strength", { { "hand:3" } })), 1, "play phase")
		-- Three targets: dropped. (A ref that is not a hand card already fails
		-- the observation: observation_invalid_target_ref.)
		ctx.eq(count(frame(hand, "c_strength", { { "hand:1", "hand:2", "hand:3" } })), 0, "three targets")
		local discard = frame(hand, "c_strength", { { "hand:3" } })
		discard.phase = "DISCARD"
		ctx.eq(count(discard), 0, "discard phase")
	end)

	test("rookie_never_uses_hand_tarots", function()
		local hand = { card("9", "Spades"), card("9", "Hearts"), card("8", "Clubs"), card("4", "Diamonds"), card("2", "Spades") }
		ctx.eq(pick("rookie", frame(hand, "c_strength", { { "hand:3" } })), "PLAY_CARDS", "rookie")
	end)

	test("many_candidates_stay_within_the_budget", function()
		local hand = {}
		local ranks = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King" }
		local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
		for i = 1, 12 do
			hand[i] = card(ranks[i], suits[(i % 4) + 1])
		end
		local uses = {}
		for a = 1, 12 do
			for b = a + 1, 12 do
				if #uses < 24 then
					uses[#uses + 1] = { "hand:" .. a, "hand:" .. b }
				end
			end
		end
		local f = frame(hand, "c_death", uses)
		f.self.jokers = { Support.joker("j_photograph"), Support.joker("j_triboulet"), Support.joker("j_baron"),
			Support.joker("j_fibonacci"), Support.joker("j_abstract") }
		for _, d in ipairs(STRONG) do
			local result = Support.run(env, d, f)
			ctx.is_true(result.ok == true, d .. ":" .. tostring(result.code))
		end
	end)
end
