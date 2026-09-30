-- hand_levels[*].played_this_round (docs/HAND_HISTORY_DESIGN.md): the AI's own
-- hand types this round, exported only while a hand is played, copied by the
-- reader only as an integer 0..1000, typed by the observation.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	local function engine(state, played)
		local e = support.engine({
			state = state,
			hand = { support.card({ rank = "King", suit = "Hearts" }), support.card({ rank = "King", suit = "Spades" }) },
			blind_key = "bl_eye",
		})
		e.G.GAME.hands = {
			Pair = { level = 2, chips = 25, mult = 3, visible = true, played_this_round = played },
			Flush = { level = 1, chips = 35, mult = 4, visible = true, played_this_round = 0 },
		}
		return e
	end

	local function step(e)
		local result, code = support.pipeline(bundle, e, {}).adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		return result
	end

	local function export(e)
		local result = step(e)
		local handle, code = bundle.reader.capture(result.runtime, result.ui_view)
		is_true(handle ~= nil, "capture: " .. tostring(code))
		return bundle.obs.export(handle)
	end

	test("played_this_round_is_exported_in_hand_phases_only", function()
		local ex = export(engine(STATES.SELECTING_HAND, 1))
		eq(ex.self.hand_levels.pair.played_this_round, 1, "pair")
		eq(ex.self.hand_levels.flush.played_this_round, 0, "flush")
		local shop = step(engine(STATES.SHOP, 1))
		local levels = shop.ui_view.self.hand_levels
		is_true(levels ~= nil and levels.pair.played_this_round == nil, "stale counts not exported in the shop")
	end)

	test("adapter_drops_bad_counts", function()
		for _, bad in ipairs({ -1, 1001, 1.5, "1" }) do
			local ex = export(engine(STATES.SELECTING_HAND, bad))
			eq(ex.self.hand_levels.pair.played_this_round, nil, "dropped " .. tostring(bad))
			eq(ex.self.hand_levels.pair.level, 2, "level kept " .. tostring(bad))
		end
	end)

	test("reader_rejects_bad_counts", function()
		for _, bad in ipairs({ -1, 1001, 1.5, "1", true }) do
			local result = step(engine(STATES.SELECTING_HAND, 1))
			result.ui_view.self.hand_levels.pair.played_this_round = bad
			local handle, code = bundle.reader.capture(result.runtime, result.ui_view)
			eq(handle, nil, "rejected " .. tostring(bad))
			eq(code, "reader_bad_view", "code " .. tostring(bad))
		end
	end)

	test("observation_bounds_the_count", function()
		local ex = export(engine(STATES.SELECTING_HAND, 1))
		ex.self.hand_levels.pair.played_this_round = 1001
		eq(bundle.obs.observe(ex), nil, "out of range")
	end)
end
