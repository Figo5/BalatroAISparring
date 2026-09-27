return function()
	local m = new_ai()
	local Codec = m.Codec
	local obs = m.Observation.factory(Codec)
	local acts = m.Actions.factory(obs, Codec)

	test("vectors.codec", function()
		vec("enc-map-order", Codec.encode({ b = 1, a = "x" }))
		vec("enc-array", Codec.encode({ 1, 2, 3 }))
		vec("fnv-empty", Codec.hash_string(""))
		vec("fnv-a", Codec.hash_string("a"))
		vec("fnv-abc", Codec.hash_string("abc"))
		vec("fnv-hello", Codec.hash_string("hello"))
	end)

	test("vectors.observation_and_actions", function()
		local f = syn("SHOP")
		f.shop = {
			reroll_cost = 2,
			items = { entity({ kind = "card", center = "c_1", cost = 1 }) },
			vouchers = {},
			boosters = { entity({ kind = "booster", center = "b_1", cost = 0 }) },
		}
		f.self.money = 5
		f.certificates.items = {
			cert("BUY_ITEM", { item_ref = "shop:1" }),
			cert("OPEN_BOOSTER", { item_ref = "shop_booster:1" }),
			cert("REROLL"),
		}
		local handle = ois(obs, f)
		vec("obs.canonical.shop", obs.canonical(handle))
		vec("obs.hash.shop", obs.hash(handle))
		vec("actions.shop.ids", action_ids(actions_of(acts, handle)))
	end)

	test("vectors.play", function()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { entity({ rank = "A", suit = "Spades" }), entity({ rank = "K", suit = "Hearts" }) }
		f.self.money = -4
		f.self.credit_limit = 2
		f.certificates.items = {
			cert("PLAY_CARDS", { card_refs = { "hand:1", "hand:2" } }),
			cert("DISCARD_CARDS", { card_refs = { "hand:2" } }),
			cert("REORDER_HAND", { order = { "hand:2", "hand:1" } }),
		}
		local handle = ois(obs, f)
		vec("obs.canonical.play", obs.canonical(handle))
		vec("obs.hash.play", obs.hash(handle))
		vec("actions.play.ids", action_ids(actions_of(acts, handle)))
	end)
end
