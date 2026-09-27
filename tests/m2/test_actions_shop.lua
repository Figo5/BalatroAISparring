return function()
	local m = new_ai()
	local obs = m.Observation.factory(m.Codec)
	local acts = m.Actions.factory(obs, m.Codec)

	local function shop(items, vouchers)
		local f = syn("SHOP")
		f.shop = { reroll_cost = 0, items = items or {}, vouchers = vouchers or {} }
		return f
	end

	test("actions.shop.buy_card_affordable", function()
		local f = shop({ entity({ kind = "card", center = "c_1", cost = 3 }) })
		f.self.money = 3
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "affordable")
		f.self.money = 2
		eq(#actions_of(acts, ois(obs, f)), 0, "insufficient")
	end)

	test("actions.shop.free_buy_at_negative_money", function()
		local f = shop({ entity({ kind = "card", center = "c_1", cost = 0 }) })
		f.self.money = -6
		f.self.credit_limit = 0
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "free buy allowed while bankrupt")
	end)

	test("actions.shop.credit_limit_extends_spendable", function()
		local f = shop({ entity({ kind = "card", center = "c_1", cost = 5 }) })
		f.self.money = -2
		f.self.credit_limit = 7
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "spendable = money + credit")
		f.self.credit_limit = 3
		eq(#actions_of(acts, ois(obs, f)), 0, "still short")
	end)

	test("actions.shop.voucher_predicate_differs_for_free", function()
		local f = shop({}, { entity({ center = "v_1", cost = 0 }) })
		f.self.money = -3
		f.self.credit_limit = 0
		f.certificates.items = { cert("BUY_VOUCHER", { voucher_ref = "shop_voucher:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "free voucher denied at negative spendable")
		f.self.money = 0
		eq(#actions_of(acts, ois(obs, f)), 1, "free voucher allowed at zero")
	end)

	test("actions.shop.reroll_cost", function()
		local f = syn("SHOP")
		f.shop = { reroll_cost = 4, items = {}, vouchers = {} }
		f.self.money = 3
		f.self.credit_limit = 0
		f.certificates.items = { cert("REROLL") }
		eq(#actions_of(acts, ois(obs, f)), 0, "insufficient reroll")
		f.self.credit_limit = 1
		eq(#actions_of(acts, ois(obs, f)), 1, "affordable reroll")
		f.shop.reroll_cost = 0
		f.self.money = -9
		f.self.credit_limit = 0
		eq(#actions_of(acts, ois(obs, f)), 1, "free reroll allowed while bankrupt")
		f.shop.reroll_cost = 3
		eq(#actions_of(acts, ois(obs, f)), 0, "missing cost denies")
	end)

	test("actions.shop.joker_capacity", function()
		local f = shop({ entity({ kind = "joker", center = "j_1", cost = 1 }) })
		f.self.money = 10
		f.self.jokers = {}
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "no capacity_ok")
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1", capacity_ok = true }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "capacity_ok with free slot")
		local full = {}
		for i = 1, 5 do
			full[i] = entity({ center = "j_" .. i })
		end
		f.self.jokers = full
		eq(#actions_of(acts, ois(obs, f)), 0, "full slots deny")
		f.shop.items[1].edition = "negative"
		eq(#actions_of(acts, ois(obs, f)), 1, "negative edition exception")
	end)

	test("actions.shop.consumable_capacity", function()
		local f = shop({ entity({ kind = "consumable", center = "c_1", cost = 1 }) })
		f.self.money = 10
		f.self.consumables = {}
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1", capacity_ok = true }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "consumable slot free")
		f.self.consumables = { entity({ center = "c_a" }), entity({ center = "c_b" }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "consumable slots full")
	end)

	test("actions.shop.booster_kind_gating", function()
		local f = syn("SHOP")
		f.self.money = 10
		f.shop = {
			reroll_cost = 0,
			items = {},
			vouchers = {},
			boosters = { entity({ kind = "booster", center = "b_1", cost = 1 }) },
		}
		f.certificates.items = { cert("OPEN_BOOSTER", { item_ref = "shop_booster:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "OPEN_BOOSTER accepts shop_booster zone")
		f.certificates.items = { cert("OPEN_BOOSTER", { item_ref = "shop:1" }) }
		eq(obs_code(obs, f), obs.CODE.BAD_TARGET_REF, "OPEN_BOOSTER never uses generic shop zone")
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop_booster:1" }) }
		eq(obs_code(obs, f), obs.CODE.BAD_TARGET_REF, "BUY_ITEM never uses shop_booster zone")
		f.shop.items = { entity({ kind = "booster", center = "b_2", cost = 1 }) }
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		eq(obs_code(obs, f), obs.CODE.BAD_ENTITY, "booster kind rejected inside shop.items")
	end)

	test("actions.shop.rejects_redacted_and_missing_cost", function()
		local f = shop({ { face_down = true } })
		f.self.money = 10
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "redacted item denied")
		f.shop.items = { entity({ kind = "card", center = "c_1" }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "missing cost denied")
	end)

	test("actions.shop.voucher_zone", function()
		local f = shop({ entity({ kind = "card", center = "c_1", cost = 1 }) }, { entity({ center = "v_1", cost = 1 }) })
		f.self.money = 10
		f.certificates.items = { cert("BUY_VOUCHER", { voucher_ref = "shop:1" }) }
		eq(obs_code(obs, f), obs.CODE.BAD_TARGET_REF, "wrong voucher zone rejected at schema")
		f.certificates.items = { cert("BUY_VOUCHER", { voucher_ref = "shop_voucher:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "correct voucher zone")
	end)

	test("actions.shop.leave_shop", function()
		local f = shop({})
		f.certificates.items = { cert("LEAVE_SHOP") }
		local list = actions_of(acts, ois(obs, f))
		eq(#list, 1, "leave")
		eq(list[1].type, "LEAVE_SHOP", "type")
	end)

	test("actions.shop.capacity_requires_explicit_certificate", function()
		local f = shop({ entity({ kind = "joker", center = "j_1", cost = 1, edition = "negative" }) })
		f.self.money = 10
		f.self.jokers = {}
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "negative edition without capacity_ok denied")
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1", capacity_ok = false }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "capacity_ok=false denied")
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1", capacity_ok = true }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "capacity_ok plus negative edition")
	end)

	test("actions.shop.missing_owned_list_denies_normal_purchase", function()
		local f = shop({ entity({ kind = "joker", center = "j_1", cost = 1 }) })
		f.self.money = 10
		f.self.jokers = nil
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1", capacity_ok = true }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "unknown owned count denies")
		f.self.consumables = nil
		f.shop.items = { entity({ kind = "consumable", center = "c_1", cost = 1 }) }
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1", capacity_ok = true }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "unknown consumable count denies")
	end)
end
