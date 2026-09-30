-- Instruction-budget regressions for the play phase on larger hands (H1 of
-- docs/CLAUDE_BATCH2_REVIEW.md). Frames come from the real engine adapter, so
-- the policy sees the adapter's own capped PLAY_CARDS/DISCARD_CARDS catalogue
-- (40 each), and every decision runs through the restricted policy
-- environment with its real instruction budget. The chosen action ids are
-- recorded as cross-runtime vectors, so Lua 5.1 and LuaJIT must agree exactly.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local Engine = dofile(ctx.repo_root .. "/tests/engine/support.lua")
	local bundle = Engine.bundle(ctx.repo_root)
	local budget = env.policy_env.INSTRUCTION_BUDGET

	-- Regression guard: measured worst case is about 1.33M (docs/BASELINE_POLICY.md);
	-- failing here leaves a margin before a live decision would be refused.
	local GUARD = 1600000
	local DIFFICULTIES = { "rookie", "competitive", "major_league", "expert" }
	local RANKS = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }
	local SUITS = { "Hearts", "Diamonds", "Clubs", "Spades" }
	local JOKERS = {
		"j_joker", "j_greedy_joker", "j_jolly", "j_duo", "j_scary_face",
		"j_even_steven", "j_fibonacci", "j_photograph", "j_abstract", "j_half",
	}
	local CENTERS = { "c_base", "m_glass", "m_mult", "m_bonus", "m_wild", "m_steel" }

	local function lcg(seed)
		local state = seed
		return function(n)
			state = (state * 1103515245 + 12345) % 2147483648
			return state % n + 1
		end
	end

	-- A seeded deal. `rich` adds enhancements, Red seals and editions, which
	-- are the costliest cards for the estimator (retriggers, x-mult, held).
	local function deal(seed, size, rich)
		local rnd = lcg(seed)
		local deck = {}
		for s = 1, 4 do
			for r = 1, 13 do
				deck[#deck + 1] = { RANKS[r], SUITS[s] }
			end
		end
		local hand = {}
		for i = 1, size do
			local c = table.remove(deck, rnd(#deck))
			local opts = { rank = c[1], suit = c[2], center = "c_base" }
			if rich then
				opts.center = CENTERS[rnd(#CENTERS)]
				if rnd(3) == 1 then
					opts.seal = "Red"
				end
				if rnd(4) == 1 then
					opts.edition = "polychrome"
				end
			end
			hand[i] = Engine.card(opts)
		end
		return hand
	end

	-- Many pairs plus a four-card suit: the widest draw search per candidate.
	local function paired(size)
		local hand = {}
		for i = 1, size do
			local rank = RANKS[((i - 1) % 6) * 2 + 1]
			local suit = i <= 4 and "Hearts" or SUITS[(i % 4) + 1]
			hand[i] = Engine.card({ rank = rank, suit = suit, center = "c_base" })
		end
		return hand
	end

	local function jokers(count)
		local out = {}
		for i = 1, count do
			out[i] = Engine.card({ center = JOKERS[((i - 1) % #JOKERS) + 1], set = "Joker", area_type = "joker" })
		end
		return out
	end

	-- pvp: a Multiplayer PvP blind (no displayed requirement). Otherwise a
	-- normal blind whose requirement no current play can reach.
	local function frame(hand, joker_count, pvp)
		local engine = Engine.engine({
			hand = hand,
			hand_limit = #hand,
			jokers = jokers(joker_count),
			joker_slots = joker_count > 5 and joker_count or 5,
			blind_pvp = pvp or nil,
			hands_left = 3,
			discards_left = 3,
		})
		if not pvp then
			engine.G.GAME.blind.chips = 100000000
		end
		local pipeline = Engine.pipeline(bundle, engine, {})
		local result, code = pipeline.adapter.step()
		assert(result ~= nil, "adapter: " .. tostring(code))
		local handle, rcode = bundle.reader.capture(result.runtime, result.ui_view)
		assert(handle ~= nil, "capture: " .. tostring(rcode))
		return bundle.obs.export(handle), bundle.actions.generate(handle)
	end

	local function count_type(list, kind)
		local n = 0
		for i = 1, #list do
			if list[i].type == kind then
				n = n + 1
			end
		end
		return n
	end

	local worst = 0

	-- One sandboxed decision; asserts it succeeded under the guard and returns
	-- the chosen id.
	local function decide(label, difficulty, export)
		local source = Support.source(env, difficulty)
		local result = env.policy_env.run(source, export)
		local used = env.policy_env.last_instructions()
		if used > worst then
			worst = used
		end
		ctx.truthy(result.code ~= "policy_budget_exceeded", label .. "_budget_exceeded")
		ctx.is_true(result.ok == true, label .. "_ok:" .. tostring(result.code))
		ctx.truthy(used <= GUARD, label .. "_instructions:" .. used)
		ctx.truthy(used < budget, label .. "_under_budget")
		return result.action
	end

	local function sweep(name, hand_for, rich_seed)
		for size = 9, 12 do
			for _, joker_count in ipairs({ 5, 8 }) do
				for _, pvp in ipairs({ true, false }) do
					local hand = hand_for(size, rich_seed + size * 31 + joker_count)
					local export, actions = frame(hand, joker_count, pvp)
					local mode = pvp and "pvp" or "noclear"
					ctx.eq(export.phase, pvp and "MULTIPLAYER_PVP" or "PLAY_HAND", name .. "_phase")
					ctx.eq(#export.self.hand, size, name .. "_hand_size")
					if not pvp then
						ctx.truthy(export.self.blind_requirement ~= nil, name .. "_requirement_visible")
					end
					-- The adapter's (near) full 40-candidate catalogues reach the
					-- policy; valuable cards are never offered, so a rich hand
					-- can come in slightly under the cap.
					ctx.truthy(count_type(actions, "DISCARD_CARDS") >= 36, name .. "_discard_candidates")
					ctx.truthy(count_type(actions, "PLAY_CARDS") >= 36, name .. "_play_candidates")
					for _, difficulty in ipairs(DIFFICULTIES) do
						local label = string.format("%s_%d_%dj_%s_%s", name, size, joker_count, mode, difficulty)
						local action = decide(label, difficulty, export)
						ctx.vector("budget_" .. label, action.type .. ":" .. tostring(action.id))
					end
				end
			end
		end
	end

	test("budget_holds_for_plain_9_to_12_card_hands", function()
		sweep("plain", function(size, seed)
			return deal(seed, size, false)
		end, 101)
	end)

	test("budget_holds_for_enhanced_9_to_12_card_hands", function()
		sweep("rich", function(size, seed)
			return deal(seed, size, true)
		end, 707)
	end)

	test("budget_holds_for_paired_9_to_12_card_hands", function()
		sweep("paired", function(size)
			return paired(size)
		end, 0)
	end)

	test("budget_decisions_are_deterministic", function()
		for _, pvp in ipairs({ true, false }) do
			local export = frame(deal(4242, 12, true), 8, pvp)
			for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
				local label = "repeat_" .. difficulty .. (pvp and "_pvp" or "_noclear")
				local first = decide(label, difficulty, export)
				for _ = 1, 2 do
					local again = decide(label, difficulty, export)
					ctx.eq(again.id, first.id, label)
				end
			end
		end
	end)

	test("budget_holds_for_absurd_hands_and_joker_rows", function()
		-- Far beyond real play: the metered/fallback paths must still bound it.
		for _, shape in ipairs({ { 16, 16 }, { 24, 24 }, { 32, 40 }, { 48, 64 } }) do
			local export = frame(deal(shape[1] * 7 + shape[2], shape[1], true), shape[2], false)
			for _, difficulty in ipairs({ "competitive", "expert" }) do
				local label = string.format("absurd_%d_%dj_%s", shape[1], shape[2], difficulty)
				local action = decide(label, difficulty, export)
				ctx.vector("budget_" .. label, action.type .. ":" .. tostring(action.id))
			end
		end
	end)

	test("budget_worst_case_recorded", function()
		ctx.truthy(worst > 0, "measured")
		ctx.truthy(worst <= GUARD, "worst:" .. worst)
	end)
end
