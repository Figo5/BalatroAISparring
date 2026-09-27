return function()
	local m = new_ai()
	local obs = m.Observation.factory(m.Codec)
	local acts = m.Actions.factory(obs, m.Codec)
	local CODE = acts.CODE

	local function type_set(list)
		local set = {}
		for i = 1, #list do
			set[list[i].type] = (set[list[i].type] or 0) + 1
		end
		return set
	end

	test("actions.play_and_discard.basic", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { entity({ rank = "A", suit = "Spades" }), entity({ rank = "K", suit = "Hearts" }) }
		f.certificates.items = {
			cert("PLAY_CARDS", { card_refs = { "hand:1", "hand:2" } }),
			cert("DISCARD_CARDS", { card_refs = { "hand:1" } }),
		}
		local set = type_set(actions_of(acts, ois(obs, f)))
		eq(set.PLAY_CARDS, 1, "play")
		eq(set.DISCARD_CARDS, 1, "discard")
	end)

	test("actions.play.discard.requires_resources_and_limits", function()
		local function frame()
			local f = syn("PLAY_HAND")
			f.self.hand_visible = true
			f.self.hand = { entity({ rank = "A", suit = "Spades" }), entity({ rank = "K", suit = "Hearts" }) }
			f.certificates.items = {
				cert("PLAY_CARDS", { card_refs = { "hand:1", "hand:2" } }),
				cert("DISCARD_CARDS", { card_refs = { "hand:1" } }),
			}
			return f
		end
		local f = frame()
		f.self.hands = 0
		eq(type_set(actions_of(acts, ois(obs, f))).PLAY_CARDS, nil, "no hands")
		f = frame()
		f.self.discards = 0
		eq(type_set(actions_of(acts, ois(obs, f))).DISCARD_CARDS, nil, "no discards")
		f = frame()
		f.context.max_play = 1
		eq(type_set(actions_of(acts, ois(obs, f))).PLAY_CARDS, nil, "oversize selection")
		f = frame()
		f.context.max_play = nil
		eq(type_set(actions_of(acts, ois(obs, f))).PLAY_CARDS, nil, "missing max_play")
	end)

	test("actions.play.denied_without_hand_visibility", function()
		local f = syn("PLAY_HAND")
		f.certificates.items = { cert("PLAY_CARDS", { card_refs = { "hand:1" } }) }
		eq(obs_code(obs, f), obs.CODE.BAD_TARGET_REF, "no visible hand -> ref denied")
		f.certificates.items = {}
		eq(#actions_of(acts, ois(obs, f)), 0, "no hand no play")
	end)

	test("actions.blind.only_in_blind_selection", function()
		local f = syn("BLIND_SELECTION")
		f.certificates.items = { cert("SELECT_BLIND"), cert("SKIP_BLIND") }
		eq(#actions_of(acts, ois(obs, f)), 2, "two blind actions")
		local pvp = syn("MULTIPLAYER_PVP")
		pvp.certificates.items = { cert("SELECT_BLIND") }
		eq(#actions_of(acts, ois(obs, pvp)), 0, "pvp readiness is not select_blind")
	end)

	test("actions.booster.select_one_and_skip", function()
		local f = syn("BOOSTER_SELECTION")
		f.self.jokers = {}
		f.booster = {
			kind = "Buffoon",
			choices = 1,
			cards = { entity({ kind = "joker", center = "j_1" }), entity({ kind = "card", center = "c_1", rank = "A", suit = "Spades" }) },
		}
		f.certificates.items = {
			cert("SELECT_BOOSTER_ITEM", { card_refs = { "booster:1", "booster:2" }, capacity_ok = true }),
			cert("SELECT_BOOSTER_ITEM", { card_refs = { "booster:1" }, capacity_ok = true }),
			cert("SKIP_BOOSTER"),
		}
		local list = actions_of(acts, ois(obs, f))
		eq(#list, 2, "one select plus skip")
		for i = 1, #list do
			if list[i].type == "SELECT_BOOSTER_ITEM" then
				eq(#list[i].card_refs, 1, "exactly one booster ref")
			end
		end
		f.booster.choices = 0
		local second = actions_of(acts, ois(obs, f))
		eq(#second, 1, "skip only at choices 0")
		eq(second[1].type, "SKIP_BOOSTER", "skip")
	end)

	test("actions.sell.existing_only", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 0 }
		f.self.jokers = { entity({ center = "j_1" }) }
		f.self.consumables = { entity({ center = "c_1" }) }
		f.certificates.items = {
			cert("SELL_JOKER", { joker_ref = "joker:1" }),
			cert("SELL_CONSUMABLE", { consumable_ref = "consumable:1" }),
		}
		local set = type_set(actions_of(acts, ois(obs, f)))
		eq(set.SELL_JOKER, 1, "sell joker")
		eq(set.SELL_CONSUMABLE, 1, "sell consumable")
	end)

	test("actions.reorder.permutation_required", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { entity({ rank = "A", suit = "Spades" }), entity({ rank = "K", suit = "Hearts" }) }
		f.certificates.items = {
			cert("REORDER_HAND", { order = { "hand:2", "hand:1" } }),
			cert("REORDER_HAND", { order = { "hand:1" } }),
		}
		local list = actions_of(acts, ois(obs, f))
		eq(#list, 1, "incomplete order denied")
		eq(list[1].order[1], "hand:2", "full order kept")
	end)

	test("actions.reorder.jokers", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 0 }
		f.self.jokers = { entity({ center = "j_1" }), entity({ center = "j_2" }) }
		f.certificates.items = {
			cert("REORDER_JOKERS", { order = { "joker:2", "joker:1" } }),
			cert("REORDER_JOKERS", { order = { "joker:1" } }),
		}
		local list = actions_of(acts, ois(obs, f))
		eq(#list, 1, "incomplete permutation denied")
		eq(list[1].order[1], "joker:2", "valid permutation kept")
	end)

	test("actions.phase.denies_cert_out_of_phase", function()
		local f = syn("CONSUMABLE_SELECTION")
		f.consumable_target = { source = entity({ center = "c_1" }) }
		f.certificates.items = { cert("SELECT_BLIND"), cert("SKIP_BLIND"), cert("REROLL"), cert("LEAVE_SHOP") }
		eq(#actions_of(acts, ois(obs, f)), 0, "no blind/reroll/leave here")
	end)

	test("actions.context.blocked_and_expired_deny", function()
		local f = syn("BLIND_SELECTION")
		f.certificates.items = { cert("SELECT_BLIND") }
		f.context.blocked = true
		eq(#actions_of(acts, ois(obs, f)), 0, "blocked")
		f.context.blocked = false
		f.context.timer_expired = true
		eq(#actions_of(acts, ois(obs, f)), 0, "expired")
		f.context.timer_expired = false
		eq(#actions_of(acts, ois(obs, f)), 1, "allowed")
	end)

	test("actions.context.default_deny_when_missing", function()
		local f = syn("BLIND_SELECTION")
		f.certificates.items = { cert("SELECT_BLIND") }
		f.context = nil
		eq(#actions_of(acts, ois(obs, f)), 0, "missing context denies")
	end)

	test("actions.phase.match_complete_empty", function()
		eq(#actions_of(acts, ois(obs, syn("MATCH_COMPLETE"))), 0, "terminal")
	end)

	test("actions.output.dedupe_and_order_invariant", function()
		local f = syn("BLIND_SELECTION")
		f.certificates.items = { cert("SELECT_BLIND"), cert("SELECT_BLIND"), cert("SKIP_BLIND") }
		local list = actions_of(acts, ois(obs, f))
		eq(#list, 2, "deduped")
		local g = clone(f)
		g.certificates.items = { cert("SKIP_BLIND"), cert("SELECT_BLIND") }
		eq(action_ids(actions_of(acts, ois(obs, g))), action_ids(list), "order invariant")
	end)

	test("actions.output.missing_catalog_empty", function()
		local f = syn("BLIND_SELECTION")
		f.certificates = nil
		eq(#actions_of(acts, ois(obs, f)), 0, "no catalog")
	end)

	test("actions.robust.generate_never_crashes", function()
		local probes = { nil, 0, "x", {}, function() end, true }
		for i = 1, #probes do
			local ok, list, code = pcall(acts.generate, probes[i])
			truthy(ok, "no crash " .. tostring(i))
			eq(list, nil, "nil result " .. tostring(i))
			eq(code, CODE.UNKNOWN_HANDLE, "unknown handle code " .. tostring(i))
		end
		local foreign = m.Observation.factory(m.Codec)
		local h = ois(foreign, syn("BLIND_SELECTION"))
		local ok2, list2, code2 = pcall(acts.generate, h)
		truthy(ok2, "foreign no crash")
		eq(list2, nil, "foreign nil")
		eq(code2, CODE.UNKNOWN_HANDLE, "foreign code")
	end)

	test("actions.output.too_many_is_explicit_invariant", function()
		eq(acts.CODE.TOO_MANY, "actions_too_many", "code exposed")
		local f = syn("SHOP")
		f.shop = { reroll_cost = 0, items = {}, vouchers = {}, boosters = {} }
		f.self.jokers = {}
		f.self.consumables = {}
		local items = {}
		for i = 1, 64 do
			f.self.jokers[i] = entity({ center = "j_" .. i })
			f.self.consumables[i] = entity({ center = "c_" .. i })
			items[#items + 1] = cert("SELL_JOKER", { joker_ref = "joker:" .. i })
			items[#items + 1] = cert("SELL_CONSUMABLE", { consumable_ref = "consumable:" .. i })
		end
		f.certificates.items = items
		local list = actions_of(acts, ois(obs, f))
		eq(#list, 128, "128 distinct candidates at the cap, no silent truncation")
	end)
end
