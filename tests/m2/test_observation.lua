return function()
	local m = new_ai()
	local Codec = m.Codec
	local Observation = m.Observation
	local obs = Observation.factory(Codec)
	local CODE = obs.CODE

	local PHASES = {
		"BLIND_SELECTION",
		"PLAY_HAND",
		"DISCARD",
		"SHOP",
		"BOOSTER_SELECTION",
		"CONSUMABLE_SELECTION",
		"MULTIPLAYER_PVP",
		"MATCH_COMPLETE",
	}

	test("observation.phase.all_minimal", function()
		for i = 1, #PHASES do
			local phase = PHASES[i]
			local f = syn(phase)
			if phase == "SHOP" then
				f.shop = { reroll_cost = 5 }
			elseif phase == "BOOSTER_SELECTION" then
				f.booster = { kind = "Buffoon", choices = 1 }
			elseif phase == "CONSUMABLE_SELECTION" then
				f.consumable_target = { source = entity({ center = "c_tarot" }) }
			end
			local plain = obs.export(ois(obs, f))
			eq(plain.phase, phase, "phase " .. phase)
			eq(plain.schema_version, 1, "version " .. phase)
		end
	end)

	test("observation.frame.invalid", function()
		eq(obs_code(obs, 5), CODE.BAD_FRAME, "number frame")
		eq(obs_code(obs, setmetatable({}, {})), CODE.BAD_FRAME, "metatable frame")
		local f = syn("PLAY_HAND")
		f.schema_version = 2
		eq(obs_code(obs, f), CODE.BAD_VERSION, "version 2")
		f.schema_version = 1.5
		eq(obs_code(obs, f), CODE.BAD_VERSION, "version 1.5")
		f.schema_version = 1
		f.phase = "NOPE"
		eq(obs_code(obs, f), CODE.UNKNOWN_PHASE, "unknown phase")
		f.phase = "PLAY_HAND"
		f.match = nil
		eq(obs_code(obs, f), CODE.MISSING_MATCH, "missing match")
		f.match = syn("PLAY_HAND").match
		f.self = nil
		eq(obs_code(obs, f), CODE.MISSING_SELF, "missing self")
	end)

	test("observation.privacy.unknown_fields_not_traversed", function()
		local f = syn("PLAY_HAND")
		f.seed = function()
			error("seed traversed")
		end
		f.rng = setmetatable({}, { __index = function()
			error("rng traversed")
		end })
		f.future_shop = { items = { function()
			error("future traversed")
		end } }
		f.self.secret = function()
			error("self secret traversed")
		end
		f.match.hidden = setmetatable({}, { __index = function()
			error("match hidden traversed")
		end })
		local plain = obs.export(ois(obs, f))
		eq(plain.seed, nil, "no seed")
		eq(plain.rng, nil, "no rng")
		eq(plain.future_shop, nil, "no future shop")
		eq(plain.self.secret, nil, "no secret")
		eq(plain.match.hidden, nil, "no hidden")
	end)

	test("observation.privacy.hidden_perturbation_invariance", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 3, items = { entity({ kind = "card", cost = 2, center = "c_1" }) } }
		local h1 = ois(obs, f)
		local f2 = clone(f)
		f2.seed = 12345
		f2.rng = { 1, 2, 3 }
		f2.opponent_private = { deck = { "A" } }
		f2.self.hidden_score = 999
		f2.match.secret = true
		local h2 = ois(obs, f2)
		eq(obs.canonical(h2), obs.canonical(h1), "bytes")
		eq(obs.hash(h2), obs.hash(h1), "hash")
	end)

	test("observation.visibility.face_down_redaction", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = {
			{ face_down = true, rank = function()
				error("poison traversed")
			end, suit = "Spades" },
			{ rank = "A", suit = "Hearts" },
			{ face_down = false, rank = "K", suit = "Clubs" },
		}
		local hand = obs.export(ois(obs, f)).self.hand
		eq(hand[1].redacted, true, "explicit face down redacted")
		eq(hand[1].rank, nil, "poison not copied")
		eq(hand[1].id, "hand:1", "id")
		eq(hand[2].redacted, true, "missing face_down redacts")
		eq(hand[3].redacted, nil, "identity visible")
		eq(hand[3].face_down, false, "explicit false")
		eq(hand[3].rank, "K", "identity copied")
	end)

	test("observation.visibility.face_down_must_be_boolean", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { { face_down = "no", rank = "A" } }
		eq(obs_code(obs, f), CODE.BAD_ENTITY, "nonboolean face_down")
	end)

	test("observation.visibility.hand_flag_and_phase", function()
		local f = syn("PLAY_HAND")
		f.self.hand = { entity({ rank = "A", suit = "Spades" }) }
		eq(obs.export(ois(obs, f)).self.hand, nil, "no flag no hand")
		f.self.hand_visible = true
		truthy(obs.export(ois(obs, f)).self.hand, "flag exposes hand")
	end)

	test("observation.visibility.stale_hand_dropped", function()
		local phases = { "SHOP", "BLIND_SELECTION" }
		for i = 1, #phases do
			local f = syn(phases[i])
			if phases[i] == "SHOP" then
				f.shop = { reroll_cost = 1 }
			end
			f.self.hand_visible = true
			f.self.hand = { setmetatable({}, { __index = function()
				error("stale traversed")
			end }) }
			eq(obs.export(ois(obs, f)).self.hand, nil, "dropped " .. phases[i])
		end
	end)

	test("observation.visibility.match_complete_drops_private", function()
		local f = syn("MATCH_COMPLETE")
		f.self = { money = 1 }
		f.opponent = { certified = true, displayed_score = "9" }
		f.certificates = { version = 1, items = { cert("SELECT_BLIND") } }
		local plain = obs.export(ois(obs, f))
		eq(plain.self, nil, "no self")
		eq(plain.opponent, nil, "no opponent")
		eq(plain.certificates, nil, "no certs")
	end)

	test("observation.phase.sections_ignored_when_not_permitted", function()
		local f = syn("PLAY_HAND")
		f.shop = { reroll_cost = setmetatable({}, { __index = function()
			error("shop traversed")
		end }) }
		f.booster = { cards = { function()
			error("booster traversed")
		end } }
		f.consumable_target = { source = setmetatable({}, { __index = function()
			error("target traversed")
		end }) }
		local plain = obs.export(ois(obs, f))
		eq(plain.shop, nil, "shop dropped")
		eq(plain.booster, nil, "booster dropped")
		eq(plain.consumable_target, nil, "target dropped")
	end)

	test("observation.opponent.certified_gate", function()
		local f = syn("MULTIPLAYER_PVP")
		f.opponent = { displayed_score = "100", timer = "0:30" }
		eq(obs.export(ois(obs, f)).opponent, nil, "uncertified dropped")
		f.opponent.certified = true
		local plain = obs.export(ois(obs, f))
		eq(plain.opponent.displayed_score, "100", "score")
		eq(plain.opponent.timer, "0:30", "timer")
	end)

	test("observation.opponent.raw_private_fields_omitted", function()
		local f = syn("MULTIPLAYER_PVP")
		f.opponent = { certified = true, real_score = 999, last_timer = 1, pvpTimerOrder = 2, hidden_location = true }
		eq(obs.export(ois(obs, f)).opponent, nil, "only private fields -> no opponent")
	end)

	test("observation.self.signed_money_and_credit", function()
		local f = syn("PLAY_HAND")
		f.self.money = -7
		f.self.credit_limit = 10
		local plain = obs.export(ois(obs, f))
		eq(plain.self.money, -7, "signed money")
		eq(plain.self.credit_limit, 10, "credit limit")
		f.self.money = 1.5
		eq(obs_code(obs, f), CODE.BAD_FIELD, "fractional money")
		f.self.money = 0
		f.self.credit_limit = -1
		eq(obs_code(obs, f), CODE.BAD_FIELD, "negative credit")
	end)

	test("observation.match.timer_with_gt", function()
		local f = syn("BLIND_SELECTION")
		f.match.timer = ">> 1:23"
		eq(obs.export(ois(obs, f)).match.timer, ">> 1:23", "timer")
	end)

	test("observation.entity.visible_text_bounded", function()
		local f = syn("PLAY_HAND")
		f.self.jokers = { entity({ center = "j_1", visible_text = "+4 Mult" }) }
		eq(obs.export(ois(obs, f)).self.jokers[1].visible_text, "+4 Mult", "text")
		f.self.jokers = { entity({ center = "j_1", visible_text = "bad\nline" }) }
		eq(obs_code(obs, f), CODE.BAD_ENTITY, "control char")
	end)

	test("observation.arrays.sparse_rejected", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { [1] = entity({ rank = "A", suit = "Spades" }), [3] = entity({ rank = "K", suit = "Hearts" }) }
		eq(obs_code(obs, f), CODE.SPARSE_ARRAY, "sparse")
	end)

	test("observation.entity.rejects_metatable_and_function_fields", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { setmetatable({ rank = "A" }, {}) }
		eq(obs_code(obs, f), CODE.BAD_ENTITY, "metatable entity")
		f.self.hand = { { face_down = false, rank = function() end } }
		eq(obs_code(obs, f), CODE.BAD_ENTITY, "function field")
	end)

	test("observation.deck.total_only", function()
		local f = syn("PLAY_HAND")
		f.self.deck = { total = 4, by_suit = { Spades = 2, Hearts = 2 }, by_rank = { A = 1 }, order = { "A" } }
		local deck = obs.export(ois(obs, f)).self.deck
		eq(deck.total, 4, "total kept")
		eq(deck.by_suit, nil, "by_suit dropped")
		eq(deck.by_rank, nil, "by_rank dropped")
		eq(deck.order, nil, "order dropped")
	end)

	test("observation.deck.maps_dropped_with_face_down_hand", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { { face_down = true, rank = "A" } }
		f.self.deck = { total = 44, by_rank = { A = 3 }, by_suit = { Spades = 12 } }
		local plain = obs.export(ois(obs, f))
		eq(plain.self.hand[1].redacted, true, "face-down redacted")
		eq(plain.self.deck.total, 44, "visible total kept")
		eq(plain.self.deck.by_rank, nil, "no rank aggregate")
		eq(plain.self.deck.by_suit, nil, "no suit aggregate")
	end)

	test("observation.certificates.unknown_type_rejected", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 1 }
		f.certificates.items = { { type = "NOPE", certified = true } }
		eq(obs_code(obs, f), CODE.BAD_CERTIFICATE, "unknown type")
	end)

	test("observation.certificates.certified_false_dropped", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 1 }
		f.certificates.items = { { type = "REROLL", certified = false }, { type = "REROLL", certified = true } }
		local items = obs.export(ois(obs, f)).certificates.items
		eq(#items, 1, "one kept")
		eq(items[1].type, "REROLL", "type")
	end)

	test("observation.certificates.refs_validated", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { entity({ rank = "A", suit = "Spades" }) }
		f.certificates.items = { cert("PLAY_CARDS", { card_refs = { "joker:1" } }) }
		eq(obs_code(obs, f), CODE.BAD_TARGET_REF, "wrong zone")
		f.certificates.items = { cert("PLAY_CARDS", { card_refs = { "hand:9" } }) }
		eq(obs_code(obs, f), CODE.BAD_TARGET_REF, "missing")
		f.certificates.items = { cert("PLAY_CARDS", { card_refs = { "hand:1", "hand:1" } }) }
		eq(obs_code(obs, f), CODE.DUPLICATE_REF, "duplicate")
	end)

	test("observation.certificates.catalog_bounded", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 1 }
		local items = {}
		for i = 1, 129 do
			items[i] = { type = "REROLL", certified = true }
		end
		f.certificates.items = items
		eq(obs_code(obs, f), CODE.TOO_LARGE, "129 items")
	end)

	test("observation.constants.mutation_isolated", function()
		local inst = Observation.factory(Codec)
		inst.PHASES.SHOP = nil
		inst.CODE.BAD_FIELD = "x"
		local f = syn("SHOP")
		f.shop = { reroll_cost = 2 }
		truthy(inst.observe(f), "instance copy mutation isolated")
		Observation.PHASES.SHOP = nil
		Observation.CODE.BAD_FIELD = "y"
		local inst2 = Observation.factory(Codec)
		truthy(inst2.observe(f), "module copy mutation isolated")
	end)

	test("observation.export.isolated_copy", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 4 }
		local h = ois(obs, f)
		local canonical = obs.canonical(h)
		local plain = obs.export(h)
		plain.phase = "MUTATED"
		plain.match.ante = 999
		rawset(h, "injected", true)
		eq(obs.canonical(h), canonical, "canonical unchanged")
		local again = obs.export(h)
		eq(again.phase, "SHOP", "stored phase")
		eq(again.match.ante, 1, "stored ante")
		f.match.ante = 7
		eq(obs.export(h).match.ante, 1, "source mutation isolated")
	end)

	test("observation.handle.opaque", function()
		eq(select(2, obs.export(nil)), CODE.UNKNOWN_HANDLE, "nil")
		eq(select(2, obs.export(123)), CODE.UNKNOWN_HANDLE, "number")
		eq(select(2, obs.export({})), CODE.UNKNOWN_HANDLE, "table")
		local other = Observation.factory(Codec)
		local h = ois(obs, syn("BLIND_SELECTION"))
		falsy(other.is_handle(h), "foreign handle")
		eq(select(2, other.export(h)), CODE.UNKNOWN_HANDLE, "foreign export")
	end)

	test("observation.consumable_target.source_ref_validated", function()
		local f = syn("CONSUMABLE_SELECTION")
		f.self.consumables = { entity({ center = "c_1" }) }
		f.consumable_target = { source = entity({ center = "c_1" }), source_ref = "consumable:1" }
		eq(obs.export(ois(obs, f)).consumable_target.source_ref, "consumable:1", "stored")
		f.consumable_target.source_ref = "consumable:9"
		eq(obs_code(obs, f), CODE.BAD_TARGET_REF, "must reference owned consumable")
		f.consumable_target.source_ref = "joker:1"
		eq(obs_code(obs, f), CODE.BAD_TARGET_REF, "must be consumable zone")
	end)
end
