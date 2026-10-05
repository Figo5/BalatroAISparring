-- The Psychic (a hand of fewer than five cards scores nothing) must still be
-- honoured when the AI owns a rule-changing Joker, i.e. on every path that
-- skips the numeric estimate and falls back to the category ranking: the
-- RULE_JOKERS early return, the play-work-cap early return, and the category
-- fallback itself (docs/CLAUDE_BATCH3_REVIEW.md M1). The single documented
-- exception is the exhausted-hand terminal (M-A): a 1-4 card hand under an
-- active Psychic with no certified discard may play a short card so an already
-- lost round can end; five or more cards stay fail-closed.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local STRONG = { "competitive", "major_league", "expert" }
	local RULE_JOKERS = { "j_four_fingers", "j_shortcut", "j_smeared", "j_splash", "j_pareidolia" }

	local function card(rank, suit, center)
		return { kind = "card", rank = rank, suit = suit, center = center or "c_base", face_down = false }
	end

	-- The cheapest decision shape: bare pair versus the padded five-card pair.
	local PAIR = { "hand:1", "hand:2" }
	local PADDED = { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }

	local DEFAULT_ITEMS = {
		{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
		{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
		{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:3", "hand:4", "hand:5" } },
	}

	local function psychic_frame(hand, extra)
		local f = Support.pair_frame()
		f.self.hand = hand
		f.match.blind = "bl_psychic"
		f.certificates.items = DEFAULT_ITEMS
		if extra ~= nil then
			for k, v in pairs(extra) do
				if k == "jokers" then
					f.self.jokers = v
				elseif k == "disabled" then
					f.match.blind_disabled = true
				elseif k == "items" then
					f.certificates.items = v
				end
			end
		end
		return f
	end

	local function decides(difficulty, frame)
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		if result.action.type ~= "PLAY_CARDS" then
			return result.action.type
		end
		return #result.action.card_refs
	end

	test("psychic_plays_five_cards_with_each_rule_joker", function()
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades"),
		}
		for _, d in ipairs(STRONG) do
			-- No rule Joker: the numeric estimate path already plays five.
			ctx.eq(decides(d, psychic_frame(hand)), 5, d .. " baseline")
			for _, center in ipairs(RULE_JOKERS) do
				local frame = psychic_frame(hand, { jokers = { Support.joker(center) } })
				ctx.eq(decides(d, frame), 5, d .. " " .. center)
			end
		end
	end)

	test("psychic_plays_five_cards_when_padding_includes_a_stone", function()
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("5", "Clubs", "m_stone"),
			card("King", "Diamonds"), card("Queen", "Spades"),
		}
		for _, d in ipairs(STRONG) do
			ctx.eq(decides(d, psychic_frame(hand)), 5, d .. " stone kicker")
			ctx.eq(decides(d, psychic_frame(hand, { jokers = { Support.joker("j_splash") } })), 5, d .. " stone + splash")
		end
	end)

	test("psychic_plays_five_cards_past_the_play_work_cap", function()
		-- Enough distinct plays, cards and Jokers push the projected estimate
		-- cost past PLAY_WORK, so the category fallback decides even without a
		-- rule Joker: the five-card requirement must not be lost there.
		local hand = {}
		local ranks = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King" }
		local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
		for i = 1, 60 do
			hand[i] = card(ranks[((i - 1) % 12) + 1], suits[((i - 1) % 4) + 1])
		end
		hand[1] = card("Ace", "Spades")
		hand[2] = card("Ace", "Hearts")
		hand[3] = card("King", "Clubs")
		hand[4] = card("Queen", "Diamonds")
		hand[5] = card("Jack", "Spades")
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
		}
		for k = 3, 48 do
			items[#items + 1] = { type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:" .. k } }
		end
		local jokers = {}
		for i = 1, 8 do
			jokers[i] = Support.joker("j_joker")
		end
		local frame = psychic_frame(hand, { items = items, jokers = jokers })
		for _, d in ipairs(STRONG) do
			ctx.eq(decides(d, frame), 5, d .. " work cap")
		end
	end)

	test("psychic_pads_over_a_face_down_card", function()
		-- The padded five-card play contains a face-down card, so it cannot be
		-- estimated or classified; the short pair still must not outrank it.
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades"),
		}
		hand[3].face_down = true
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
		}
		for _, d in ipairs(STRONG) do
			ctx.eq(decides(d, psychic_frame(hand, { items = items })), 5, d .. " face-down")
			ctx.eq(decides(d, psychic_frame(hand, { items = items, jokers = { Support.joker("j_splash") } })), 5, d .. " face-down + splash")
		end
	end)

	test("psychic_without_a_five_card_candidate_never_plays_short", function()
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades"),
		}
		-- A legal discard is offered alongside the undersized pair: the short
		-- pair scores nothing, so the discard wins.
		local with_discard = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:3", "hand:4", "hand:5" } },
		}
		for _, d in ipairs(STRONG) do
			local result = Support.run(env, d, psychic_frame(hand, { items = with_discard }))
			ctx.is_true(result.ok == true, d .. ":" .. tostring(result.code))
			ctx.eq(result.action.type, "DISCARD_CARDS", d .. " discards over a short play")
		end
		-- Only undersized plays: none may be chosen, so there is no action at all
		-- (nil, not even a zero score).
		local only_short = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1" } },
		}
		for _, d in ipairs(STRONG) do
			local result = Support.run(env, d, psychic_frame(hand, { items = only_short }))
			ctx.truthy(result.ok ~= true and result.code == "policy_no_action",
				d .. ":" .. tostring(result.code))
		end
	end)

	test("psychic_pads_over_a_face_down_card_in_every_position", function()
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
		}
		for position = 1, #PADDED do
			local hand = {
				card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
				card("Queen", "Diamonds"), card("Jack", "Spades"),
			}
			hand[position].face_down = true
			for _, d in ipairs(STRONG) do
				ctx.eq(decides(d, psychic_frame(hand, { items = items })), 5, d .. " hidden@" .. position)
			end
		end
	end)

	test("psychic_hidden_identity_never_perturbs_the_choice", function()
		-- Two frames identical in every visible field but with different
		-- underlying ranks behind the face-down padding choose identically, so
		-- hidden identities never leak into the ranking.
		local function hidden(rank3, rank4)
			local hand = {
				card("Ace", "Spades"), card("Ace", "Hearts"), card(rank3, "Clubs"),
				card(rank4, "Diamonds"), card("Jack", "Spades"),
			}
			for i = 1, #hand do
				hand[i].face_down = true
			end
			return hand
		end
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
		}
		for _, d in ipairs(STRONG) do
			local first = Support.run(env, d, psychic_frame(hidden("King", "Queen"), { items = items }))
			ctx.is_true(first.ok == true, d .. ":" .. tostring(first.code))
			ctx.eq(first.action.type, "PLAY_CARDS", d .. " plays")
			ctx.eq(#first.action.card_refs, 5, d .. " five")
			local second = Support.run(env, d, psychic_frame(hidden("2", "3"), { items = items }))
			ctx.eq(second.action.id, first.action.id, d .. " stable under hidden perturbation")
		end
	end)

	test("psychic_pads_with_all_stone_and_unusual_identities", function()
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
		}
		local all_stone = {
			card("5", "Clubs", "m_stone"), card("6", "Clubs", "m_stone"), card("7", "Clubs", "m_stone"),
			card("8", "Clubs", "m_stone"), card("9", "Clubs", "m_stone"),
		}
		local unusual = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades", "c_unrecognized_center"),
		}
		for _, d in ipairs(STRONG) do
			ctx.eq(decides(d, psychic_frame(all_stone, { items = items })), 5, d .. " all stone")
			ctx.eq(decides(d, psychic_frame(unusual, { items = items })), 5, d .. " unusual center")
		end
	end)

	test("psychic_decision_is_deterministic", function()
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades"),
		}
		hand[3].face_down = true
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
		}
		for _, d in ipairs(STRONG) do
			local first = decides(d, psychic_frame(hand, { items = items }))
			for _ = 1, 3 do
				ctx.eq(decides(d, psychic_frame(hand, { items = items })), first, d .. " stable")
			end
			ctx.vector("psychic_determinism_" .. d, tostring(first))
		end
	end)

	test("disabled_psychic_is_a_normal_blind", function()
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades"),
		}
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = PAIR },
			{ type = "PLAY_CARDS", certified = true, card_refs = PADDED },
			{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:3", "hand:4", "hand:5" } },
		}
		for _, d in ipairs(STRONG) do
			local frame = psychic_frame(hand, { items = items, disabled = true, jokers = { Support.joker("j_splash") } })
			ctx.eq(decides(d, frame), 5, d .. " Splash adds the three kickers with Psychic disabled")
		end
	end)

	test("non_psychic_blind_keeps_the_cheap_play", function()
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades"),
		}
		for _, d in ipairs(STRONG) do
			local frame = psychic_frame(hand, { jokers = { Support.joker("j_splash") } })
			frame.match.blind = "bl_small"
			ctx.eq(decides(d, frame), 5, d .. " Splash adds scoring kickers")
		end
	end)

	-- M-A: the exhausted-hand terminal. Under an active Psychic, a 1-4 card hand
	-- with no certified discard is already lost: vanilla lets a short play be
	-- made for zero score so the round can end. The catalogue is shaped exactly
	-- as the engine adapter emits it there: rank groups and singletons only (a
	-- padded five needs five cards) and no DISCARD_CARDS (none are left).
	local function terminal_frame(n, opts)
		opts = opts or {}
		local ranks = { "Ace", "Ace", "King", "Queen" }
		local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
		local hand = {}
		for i = 1, n do
			hand[i] = card(ranks[i], suits[i])
		end
		local items = {}
		for i = 1, n do
			items[#items + 1] = { type = "PLAY_CARDS", certified = true, card_refs = { "hand:" .. i } }
		end
		if n >= 2 then
			items[#items + 1] = { type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:2" } }
		end
		local frame = psychic_frame(hand, {
			items = opts.items or items,
			jokers = opts.jokers,
			disabled = opts.disabled,
		})
		frame.self.discards = opts.discards or 0
		return frame
	end

	test("psychic_terminal_plays_a_short_card_on_an_exhausted_hand", function()
		for _, d in ipairs(STRONG) do
			for n = 1, 4 do
				local result = Support.run(env, d, terminal_frame(n))
				ctx.is_true(result.ok == true, d .. " n=" .. n .. ":" .. tostring(result.code))
				ctx.eq(result.action.type, "PLAY_CARDS", d .. " n=" .. n .. " plays")
				local count = #result.action.card_refs
				ctx.is_true(count >= 1 and count <= n, d .. " n=" .. n .. " short")
				local first = result.action.id
				for _ = 1, 3 do
					ctx.eq(Support.run(env, d, terminal_frame(n)).action.id, first, d .. " n=" .. n .. " stable")
				end
				ctx.vector("psychic_terminal_" .. d .. "_" .. n, tostring(first))
			end
		end
	end)

	test("psychic_terminal_prefers_a_certified_discard", function()
		-- The terminal escape must never fire while a discard is certified.
		for _, d in ipairs(STRONG) do
			local frame = terminal_frame(3, { discards = 2 })
			frame.certificates.items[#frame.certificates.items + 1] =
				{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:1", "hand:2", "hand:3" } }
			local result = Support.run(env, d, frame)
			ctx.is_true(result.ok == true, d .. ":" .. tostring(result.code))
			ctx.eq(result.action.type, "DISCARD_CARDS", d .. " discards over a short play")
		end
	end)

	test("psychic_terminal_is_closed_when_five_or_more_cards_remain", function()
		-- A malformed/incomplete catalogue that omits every five-card play while
		-- the hand still holds five cards must stay fail-closed.
		local hand = {
			card("Ace", "Spades"), card("Ace", "Hearts"), card("King", "Clubs"),
			card("Queen", "Diamonds"), card("Jack", "Spades"),
		}
		local items = {
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1" } },
			{ type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:2" } },
		}
		for _, d in ipairs(STRONG) do
			local frame = psychic_frame(hand, { items = items })
			frame.self.discards = 0
			local result = Support.run(env, d, frame)
			ctx.truthy(result.ok ~= true and result.code == "policy_no_action", d .. ":" .. tostring(result.code))
		end
	end)

	test("psychic_terminal_is_off_for_a_disabled_or_absent_boss", function()
		for _, d in ipairs(STRONG) do
			-- Disabled Psychic: the short pair is an ordinary positive play, so
			-- the pair (not the floor) is chosen.
			local disabled = terminal_frame(2, { disabled = true })
			local result = Support.run(env, d, disabled)
			ctx.is_true(result.ok == true, d .. " disabled:" .. tostring(result.code))
			ctx.eq(result.action.type, "PLAY_CARDS", d .. " disabled plays")
			ctx.eq(#result.action.card_refs, 2, d .. " disabled keeps the pair")
			-- Same shape on an ordinary blind.
			local small = terminal_frame(2)
			small.match.blind = "bl_small"
			local normal = Support.run(env, d, small)
			ctx.is_true(normal.ok == true, d .. " small:" .. tostring(normal.code))
			ctx.eq(#normal.action.card_refs, 2, d .. " small keeps the pair")
		end
	end)

	test("psychic_terminal_does_not_leak_into_later_decisions", function()
		for _, d in ipairs(STRONG) do
			local source = Support.source(env, d)
			local first = Support.run_source(env, source, terminal_frame(3))
			ctx.eq(first.action.type, "PLAY_CARDS", d .. " terminal")
			local normal = terminal_frame(3)
			normal.match.blind = "bl_small"
			local second = Support.run_source(env, source, normal)
			ctx.eq(second.action.type, "PLAY_CARDS", d .. " normal")
			ctx.eq(#second.action.card_refs, 2, d .. " normal keeps the pair")
		end
	end)
end
