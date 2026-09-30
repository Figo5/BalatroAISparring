-- Under The Psychic (a hand of fewer than five cards scores nothing) the
-- adapter also offers rank groups and two pair padded to five cards with the
-- highest other visible-rank cards. Nothing changes for other blinds, for a
-- disabled Psychic, or for discards.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)

	-- Split two pair (Kings at 1 and 6, Fours at 3 and 8) plus kickers.
	local SPEC = { { "King", "Hearts" }, { "2", "Clubs" }, { "4", "Spades" }, { "9", "Diamonds" },
		{ "Queen", "Clubs" }, { "King", "Spades" }, { "7", "Hearts" }, { "4", "Diamonds" } }

	local function actions(blind_key, disabled)
		local hand = {}
		for i = 1, #SPEC do
			hand[i] = support.card({ rank = SPEC[i][1], suit = SPEC[i][2], center = "c_base" })
		end
		local engine = support.engine({ hand = hand, blind_key = blind_key })
		engine.G.GAME.blind.disabled = disabled
		local result, code = support.pipeline(bundle, engine, {}).adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		local handle = assert(bundle.reader.capture(result.runtime, result.ui_view))
		return bundle.actions.generate(handle)
	end

	local function has(list, kind, want)
		for _, a in ipairs(list) do
			if a.type == kind and #a.card_refs == #want then
				local set = {}
				for _, r in ipairs(a.card_refs) do
					set[r] = true
				end
				local all = true
				for _, r in ipairs(want) do
					all = all and set[r] == true
				end
				if all then
					return true
				end
			end
		end
		return false
	end

	-- Both pairs plus the top kicker (Queen, hand:5).
	local PADDED = { "hand:1", "hand:6", "hand:3", "hand:8", "hand:5" }

	test("psychic_offers_a_padded_split_two_pair", function()
		is_true(has(actions("bl_psychic"), "PLAY_CARDS", PADDED), "padded two pair offered")
	end)

	test("no_padding_for_other_or_disabled_blinds", function()
		is_true(not has(actions("bl_small"), "PLAY_CARDS", PADDED), "small blind")
		is_true(not has(actions("bl_psychic", true), "PLAY_CARDS", PADDED), "disabled psychic")
	end)

	test("psychic_padding_is_play_only", function()
		local list = actions("bl_psychic")
		is_true(not has(list, "DISCARD_CARDS", PADDED), "no padded discard")
		local plays = 0
		for _, a in ipairs(list) do
			if a.type == "PLAY_CARDS" then
				plays = plays + 1
			end
		end
		is_true(plays <= 40, "within the selection cap")
	end)
end
