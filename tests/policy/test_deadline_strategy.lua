return function(ctx)
	local support = ctx.support
	local env = support.env(ctx.repo_root)
	ctx.test("deadline_preserves_joker_purchase_but_skips_optional_shopping", function()
		local frame = support.shop_frame()
		frame.self.money = 40
		frame.shop.items[1].center = "j_sly"
		frame.match.timer_remaining = 60
		ctx.eq(support.run(env, "expert", frame).action.type, "BUY_ITEM")
		frame.shop.items = {}
		table.remove(frame.certificates.items, 1)
		ctx.eq(support.run(env, "expert", frame).action.type, "LEAVE_SHOP")
		frame.match.timer_remaining = nil
		ctx.eq(support.run(env, "expert", frame).action.type, "OPEN_BOOSTER")
	end)
	ctx.test("plasma_shop_prefers_chips_and_resets_between_decisions", function()
		local frame = support.two_joker_frame()
		frame.self.money = 40
		frame.self.jokers = {}
		frame.shop.items[1].center = "j_cavendish"
		frame.shop.items[2].center = "j_sly"
		frame.shop.items[1].cost, frame.shop.items[2].cost = 5, 5
		frame.match.score_balanced = true
		ctx.eq(support.run(env, "expert", frame).action.item_ref, "shop:2", "Plasma chip gain")
		frame.match.score_balanced = false
		ctx.eq(support.run(env, "expert", frame).action.item_ref, "shop:1", "ordinary mult gain")
	end)	ctx.test("deck_shop_panel_avoids_nonexistent_faces_and_suits", function()
		local frame = support.two_joker_frame()
		frame.self.money, frame.self.jokers = 40, {}
		frame.shop.items[1].center, frame.shop.items[2].center = "j_smiley", "j_joker"
		frame.shop.items[1].cost, frame.shop.items[2].cost = 5, 5
		frame.match.draw_profile = "standard"
		ctx.eq(support.run(env, "expert", frame).action.item_ref, "shop:1", "ordinary face gain")
		frame.match.draw_profile = "abandoned"
		ctx.eq(support.run(env, "expert", frame).action.item_ref, "shop:2", "no initial faces")
		frame.shop.items[1].center, frame.shop.items[2].center = "j_greedy_joker", "j_wrathful_joker"
		frame.match.draw_profile = "checkered"
		ctx.eq(support.run(env, "expert", frame).action.item_ref, "shop:2", "no initial diamonds")
		frame.match.draw_profile = "standard"
		ctx.eq(support.run(env, "expert", frame).ok, true, "profile resets")
	end)

end
