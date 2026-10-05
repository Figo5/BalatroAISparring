return function(ctx)
	local support, eq, test = ctx.support, ctx.eq, ctx.test
	local bundle = support.bundle(ctx.repo_root)
	local function capture(e, pipeline)
		local step = assert((pipeline or support.pipeline(bundle, e, {})).adapter.step())
		-- These caller assertions must never override the actual own engine.
		step.ui_view.match.score_balanced = false
		step.ui_view.match.timer_remaining = 999
		local handle = assert(bundle.reader.capture(step.runtime, step.ui_view))
		return bundle.obs.export(handle), step.epoch
	end
	test("own_public_deck_and_deadline_come_from_engine", function()
		local e = support.engine({ config_timer = true, timer_started = true, timer = 50.9 })
		e.G.GAME.selected_back = { name = "Plasma Deck" }
		e.G.deck = setmetatable({}, { __index = function() error("hidden deck read") end })
		e.G.GAME.pseudorandom = setmetatable({}, { __index = function() error("future RNG read") end })
		local obs = capture(e)
		eq(obs.match.score_balanced, true)
		eq(obs.match.timer_remaining, 50)
		eq(obs.self.deck, nil)
		e.G.GAME.selected_back.name = "Red Deck"
		eq(capture(e).match.score_balanced, false)
	end)
	test("clock_changes_do_not_stale_legal_actions_but_deck_changes_do", function()
		local e = support.engine({ config_timer = true, timer_started = true, timer = 150 })
		e.G.GAME.selected_back = { name = "Red Deck" }
		local pipeline = support.pipeline(bundle, e, {})
		local _, first = capture(e, pipeline)
		e.MP.GAME.timer = 149
		local obs, second = capture(e, pipeline)
		eq(obs.match.timer_remaining, 149)
		eq(second, first)
		e.G.GAME.selected_back.name = "Plasma Deck"
		local _, third = capture(e, pipeline)
		ctx.is_true(third ~= second)
	end)
	test("inactive_or_hidden_own_timer_is_omitted", function()
		for _, opts in ipairs({ {}, { config_timer = true }, { config_timer = true, timer_started = true, config_hud_disabled = true } }) do
			eq(capture(support.engine(opts)).match.timer_remaining, nil)
		end
	end)
	test("pvp_own_deadline_never_uses_enemy_timer", function()
		local e = support.engine({ config_timer = true, timer_started = true, blind_pvp = true, timer = 45 })
		eq(capture(e).match.timer_remaining, nil, "timering opponent is not own deadline")
		e.MP.GAME.nemesis_timer_started = true
		e.MP.GAME.enemy.timer = setmetatable({}, { __index = function() error("enemy timer read") end })
		eq(capture(e).match.timer_remaining, 45)
		e.MP.is_layer_active = function() return false end
		eq(capture(e).match.timer_remaining, nil, "no own PvP timer on other layer")
	end)
	test("swashbuckler_projects_only_its_displayed_current_mult", function()
		local j = support.card({ center = "j_swashbuckler", center_set = "Joker", set = "Joker" })
		j.ability.mult = 17
		local e = support.engine({ jokers = { j } })
		local obs = capture(e)
		eq(obs.self.jokers[1].current.value, 17)
		eq(obs.self.jokers[1].current.kind, "mult")
		eq(obs.self.jokers[1].current.step, nil)
	end)
	test("playing_chip_upgrades_require_exact_visible_engine_values", function()
		local c = support.card({ rank = "Ace", suit = "Hearts", center = "m_bonus" })
		c.ability.bonus, c.ability.perma_bonus = 30, 40
		local e = support.engine({ hand = { c } })
		eq(capture(e).self.hand[1].bonus_chips, 70)
		local step = assert(support.pipeline(bundle, e, {}).adapter.step())
		step.ui_view.self.cards.hand[1].bonus_chips = 71
		local handle, code = bundle.reader.capture(step.runtime, step.ui_view)
		eq(handle, nil, "tampered projection rejected")
		eq(code, bundle.reader.CODE.BAD_VIEW)
		c.debuff = true
		eq(capture(e).self.hand[1].bonus_chips, nil)
		c.debuff, c.facing = false, "back"
		eq(capture(e).self.hand[1].bonus_chips, nil)
		c.facing = "front"
		for _, bad in ipairs({ -1, 0.5, 100001, math.huge, "40" }) do
			c.ability.perma_bonus = bad
			eq(capture(e).self.hand[1].bonus_chips, nil, "invalid value omitted")
		end
	end)
end
