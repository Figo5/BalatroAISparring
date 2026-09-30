-- Draw targets are priced with the effect-bearing cards they leave in hand
-- (Steel; Kings with Baron; Queens with Shoot the Moon), like the current best
-- play. Before, targets ignored held effects, so the AI would play away held
-- Steel cards rather than draw around them.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local Engine = dofile(ctx.repo_root .. "/tests/engine/support.lua")
	local bundle = Engine.bundle(ctx.repo_root)

	local function frame(pvp)
		local spec = {
			{ "8", "Clubs", "m_steel" }, { "Ace", "Diamonds", "m_steel" }, { "Ace", "Clubs" }, { "10", "Diamonds", "m_steel" },
			{ "Jack", "Clubs" }, { "2", "Diamonds" }, { "Jack", "Spades", "m_steel" }, { "7", "Diamonds" },
		}
		local hand = {}
		for i = 1, #spec do
			hand[i] = Engine.card({ rank = spec[i][1], suit = spec[i][2], center = spec[i][3] or "c_base" })
		end
		local jokers = {
			Engine.card({ center = "j_baron", set = "Joker", area_type = "joker" }),
			Engine.card({ center = "j_greedy_joker", set = "Joker", area_type = "joker" }),
		}
		local engine = Engine.engine({ hand = hand, jokers = jokers, hands_left = 3, discards_left = 3, blind_pvp = pvp or nil })
		if not pvp then
			engine.G.GAME.blind.chips = 100000000
		end
		local result = assert(Engine.pipeline(bundle, engine, {}).adapter.step())
		return bundle.obs.export(assert(bundle.reader.capture(result.runtime, result.ui_view))), hand
	end

	test("held_steel_cards_are_kept_when_drawing", function()
		for _, pvp in ipairs({ true, false }) do
			local export = frame(pvp)
			for _, difficulty in ipairs({ "competitive", "major_league", "expert" }) do
				local result = env.policy_env.run(Support.source(env, difficulty), export)
				ctx.is_true(result.ok == true, difficulty)
				local label = difficulty .. (pvp and "_pvp" or "_noclear")
				-- Playing the Steel two pair loses x1.5 per Steel card played; the
				-- plain Ace and Jack go instead (the old pricing played them).
				ctx.eq(result.action.type, "DISCARD_CARDS", label)
				if result.action.type == "DISCARD_CARDS" then
					-- Whatever it throws away, it is never a held Steel card.
					for _, ref in ipairs(result.action.card_refs) do
						local index = tonumber(string.match(ref, "(%d+)$"))
						ctx.truthy(export.self.hand[index].center ~= "m_steel", label .. " discarded steel " .. ref)
					end
				end
				ctx.vector("held_fx_" .. label, result.action.type .. ":" .. table.concat(result.action.card_refs or {}, ","))
			end
		end
	end)
end
