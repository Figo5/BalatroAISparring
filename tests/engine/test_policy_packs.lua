-- End to end: engine pack -> EngineAdapter -> StateReader -> AIObservation
-- export -> sandboxed baseline policy. Pack cards reach the policy as
-- playing-card records (kind "card"), so the policy must classify them by
-- their public center key; this pins that against the real adapter output.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES
	local repo = ctx.repo_root

	local function read_file(path)
		local handle = assert(io.open(path, "rb"))
		local content = handle:read("*a")
		handle:close()
		return content
	end

	local policy_env = dofile(repo .. "/tools/lua/policy_env.lua")
	assert(policy_env.configure(
		read_file(repo .. "/AISparring/ai/codec.lua"),
		read_file(repo .. "/AISparring/ai/observation.lua"),
		read_file(repo .. "/AISparring/ai/actions.lua")) == true)
	local baseline = dofile(repo .. "/AISparring/ai/baseline_policy.lua")

	local function decide(engine, difficulty)
		local pipeline = support.pipeline(bundle, engine, {})
		local result, code = pipeline.adapter.step()
		is_true(result ~= nil, "produce: " .. tostring(code))
		local handle, rcode = bundle.reader.capture(result.runtime, result.ui_view)
		is_true(handle ~= nil, "capture: " .. tostring(rcode))
		local export = bundle.obs.export(handle)
		return policy_env.run(assert(baseline.source(difficulty)), export), export
	end

	local function spectral(centers)
		local cards = {}
		for i = 1, #centers do
			cards[i] = support.card({ center = centers[i], set = "Spectral", consumeable = true })
		end
		local jokers = {}
		for i = 1, 3 do
			jokers[i] = support.card({ center = "j_joker", set = "Joker", area_type = "joker" })
		end
		-- Arcana/Spectral packs deal the hand; the UI (and the adapter) only
		-- allow a skip once it is there.
		local hand = { support.card({ rank = "2", center = "c_base" }), support.card({ rank = "9", center = "c_base" }) }
		return support.engine({ state = STATES.SPECTRAL_PACK, pack_cards = cards, jokers = jokers, hand = hand, pack_choices = 1 })
	end

	test("spectral_pack_cards_reach_the_policy_as_card_records", function()
		local _, export = decide(spectral({ "c_hex" }), "rookie")
		eq(export.phase, "BOOSTER_SELECTION")
		eq(export.booster.cards[1].kind, "card")
		eq(export.booster.cards[1].center, "c_hex")
	end)

	test("policy_skips_a_spectral_pack_of_refused_cards", function()
		for _, difficulty in ipairs({ "rookie", "competitive", "major_league", "expert" }) do
			local result = decide(spectral({ "c_hex", "c_ectoplasm" }), difficulty)
			is_true(result.ok == true, difficulty)
			eq(result.action.type, "SKIP_BOOSTER", difficulty)
		end
	end)

	test("policy_takes_a_harmless_card_from_the_same_pack", function()
		for _, difficulty in ipairs({ "rookie", "competitive", "major_league", "expert" }) do
			local result = decide(spectral({ "c_hex", "c_sigil" }), difficulty)
			is_true(result.ok == true, difficulty)
			eq(result.action.type, "SELECT_BOOSTER_ITEM", difficulty)
			eq(result.action.card_refs[1], "booster:2", difficulty)
		end
	end)
end
