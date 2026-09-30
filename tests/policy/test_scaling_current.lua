-- Owned scaling Jokers use the value their card shows (`current`), with the
-- per-hand growth that happens before Jokers score
-- (docs/SCALING_VALUES_DESIGN.md).
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local STRONG = { "competitive", "major_league", "expert" }

	local function scaled(center, kind, value, step, debuff)
		local j = Support.joker(center)
		j.current = { kind = kind, value = value, step = step }
		j.debuff = debuff
		return j
	end

	-- Pair of Aces at level 1 = (10 + 22) * 2 = 64 against 150: discard.
	local function action(difficulty, jokers, kings)
		local frame = Support.requirement_frame("150", 2, 3, nil, jokers)
		if kings then
			frame.self.hand[1].rank, frame.self.hand[1].center = "King", "c_king"
			frame.self.hand[2].rank, frame.self.hand[2].center = "King", "c_king"
			frame.self.hand[3].rank, frame.self.hand[3].center = "2", "c_base"
		end
		local result = Support.run(env, difficulty, frame)
		ctx.is_true(result.ok == true, difficulty .. ":" .. tostring(result.code))
		return result.action.type
	end

	test("shown_value_counts_towards_the_requirement", function()
		for _, d in ipairs(STRONG) do
			-- Green Joker +3, +1 this hand: 32 * (2 + 4) = 192 >= 150.
			ctx.eq(action(d, { scaled("j_green_joker", "mult", 3, 1) }), "PLAY_CARDS", d .. " green")
			ctx.eq(action(d, { scaled("j_green_joker", "mult", 0, 0) }), "DISCARD_CARDS", d .. " green at 0")
			-- Without a shown value the Joker is still no effect.
			ctx.eq(action(d, { Support.joker("j_green_joker") }), "DISCARD_CARDS", d .. " no current")
			-- Hologram x3 (300 hundredths): 64 * 3 = 192.
			ctx.eq(action(d, { scaled("j_hologram", "xmult", 300) }), "PLAY_CARDS", d .. " hologram")
			ctx.eq(action(d, { scaled("j_hologram", "xmult", 300, nil, true) }), "DISCARD_CARDS", d .. " debuffed")
		end
	end)

	test("ride_the_bus_resets_on_a_scoring_face_card", function()
		for _, d in ipairs(STRONG) do
			local bus = { scaled("j_ride_the_bus", "mult", 10, 1) }
			-- Aces: 32 * (2 + 11) = 416.
			ctx.eq(action(d, bus), "PLAY_CARDS", d .. " no face")
			-- Kings reset it to 0: (10 + 20) * 2 = 60 < 150.
			ctx.eq(action(d, bus, true), "DISCARD_CARDS", d .. " face resets")
		end
	end)

	test("grown_mult_lowers_the_gain_of_a_new_mult_joker", function()
		local function pick(d, owned)
			local frame = Support.shop_frame()
			frame.self.money = 20
			frame.self.jokers = owned
			frame.shop.items = {
				{ kind = "joker", center = "j_joker", cost = 5, sell_cost = 2, face_down = false },
				{ kind = "joker", center = "j_sly", cost = 5, sell_cost = 2, face_down = false },
			}
			frame.certificates.items = {
				{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
				{ type = "BUY_ITEM", certified = true, item_ref = "shop:2", capacity_ok = true },
				{ type = "LEAVE_SHOP", certified = true },
			}
			return Support.run(env, d, frame).action.item_ref
		end
		for _, d in ipairs(STRONG) do
			ctx.eq(pick(d, { Support.joker("j_green_joker") }), "shop:1", d .. " +4 mult first")
			ctx.eq(pick(d, { scaled("j_green_joker", "mult", 30, 1) }), "shop:2", d .. " chips after +30 mult")
		end
	end)

	test("owned_grown_xmult_is_ordered_after_additive_jokers", function()
		local frame = Support.shop_frame()
		frame.shop.items = {}
		frame.self.money = 0
		frame.certificates.items = {
			{ type = "REORDER_JOKERS", certified = true, order = { "joker:2", "joker:1" } },
			{ type = "LEAVE_SHOP", certified = true },
		}
		for _, d in ipairs(STRONG) do
			-- Lucky Cat has no tier: without its value it never moves.
			frame.self.jokers = { Support.joker("j_lucky_cat"), Support.joker("j_gros_michel") }
			ctx.eq(Support.run(env, d, frame).action.type, "LEAVE_SHOP", d .. " unknown")
			frame.self.jokers = { scaled("j_lucky_cat", "xmult", 250), Support.joker("j_gros_michel") }
			ctx.eq(Support.run(env, d, frame).action.type, "REORDER_JOKERS", d .. " x2.5 after +15")
		end
	end)
end
