-- Targeted Tarots on hand cards (docs/HAND_TARGETS_DESIGN.md): the adapter
-- certifies USE_CONSUMABLE_ON_HAND for the v1 allowlist only, on visible
-- targets the effect would change, and none while a card is force-selected;
-- the executor highlights exactly the targets, lets the engine predicate
-- decide and clears the highlight on any failure.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	local function tarot(center, max_h, min_h)
		return support.card({
			set = "Tarot", consumeable = true, center = center, center_set = "Tarot",
			consumeable_data = { max_highlighted = max_h, min_highlighted = min_h },
		})
	end

	local function hand()
		local stone = support.card({ rank = "5", suit = "Clubs", center = "m_stone" })
		stone.ability.effect = "Stone Card"
		stone.config.center.replace_base_card = true
		return {
			support.card({ rank = "King", suit = "Hearts", center = "c_base" }),
			support.card({ rank = "9", suit = "Spades", center = "c_base" }),
			support.card({ rank = "4", suit = "Hearts", center = "c_base", facing = "back", sprite_facing = "back" }),
			stone,
			support.card({ rank = "2", suit = "Diamonds", center = "m_bonus" }),
		}
	end

	local function uses(consumeables, cards, opts)
		opts = opts or {}
		local engine = support.engine({ hand = cards or hand(), consumeables = consumeables, state = opts.state })
		local result, code = support.pipeline(bundle, engine, {}).adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		local handle = assert(bundle.reader.capture(result.runtime, result.ui_view))
		local out = {}
		for _, a in ipairs(bundle.actions.generate(handle)) do
			if a.type == "USE_CONSUMABLE_ON_HAND" then
				out[#out + 1] = a.source_ref .. "=" .. table.concat(a.card_refs, "+")
			end
		end
		table.sort(out)
		return table.concat(out, " ")
	end

	test("adapter_offers_allowlisted_tarots_on_visible_targets", function()
		-- Strength: every visible card (never the face-down one or the Stone).
		eq(uses({ tarot("c_strength", 2) }), "consumable:1=hand:1 consumable:1=hand:2 consumable:1=hand:5", "strength")
		-- Death: pairs of visible cards, lower position first.
		eq(uses({ tarot("c_death", 2, 2) }),
			"consumable:1=hand:1+hand:2 consumable:1=hand:1+hand:5 consumable:1=hand:2+hand:5", "death")
		-- The Sun: not on a card already of Hearts.
		eq(uses({ tarot("c_sun", 3) }), "consumable:1=hand:2 consumable:1=hand:5", "sun")
		-- Justice: not on an already-enhanced card (the Bonus 2).
		eq(uses({ tarot("c_justice", 1) }), "consumable:1=hand:1 consumable:1=hand:2", "justice")
		-- Outside the allowlist: nothing.
		eq(uses({ tarot("c_hanged_man", 2) }), "", "hanged man")
		eq(uses({ tarot("c_tower", 1) }), "", "tower")
	end)

	test("adapter_offers_none_when_forced_debuffed_or_outside_the_hand_phase", function()
		local cards = hand()
		cards[1].ability.forced_selection = true
		eq(uses({ tarot("c_strength", 2) }, cards), "", "forced card")
		local debuffed = tarot("c_strength", 2)
		debuffed.debuff = true
		eq(uses({ debuffed }), "", "debuffed tarot")
		eq(uses({ tarot("c_strength", 2) }, nil, { state = STATES.SHOP }), "", "shop")
	end)

	local function executor(consumeable, cards)
		local engine = support.engine({ hand = cards, consumeables = { consumeable } })
		local pipeline = support.pipeline(bundle, engine, {})
		local record = engine.G.FUNCS.use_card
		engine.G.FUNCS.use_card = function(e)
			record(e)
			local list = engine.G.consumeables.cards
			for i = #list, 1, -1 do
				if list[i] == e.config.ref_table then
					table.remove(list, i)
				end
			end
		end
		return engine, pipeline.executor
	end

	local function plain_hand()
		return {
			support.card({ rank = "King", suit = "Hearts" }),
			support.card({ rank = "9", suit = "Spades" }),
			support.card({ rank = "2", suit = "Clubs" }),
		}
	end

	test("executor_highlights_exactly_then_uses", function()
		local cards = plain_hand()
		local engine, ex = executor(tarot("c_death", 2, 2), cards)
		engine.G.hand.highlighted = { cards[3] }
		local action = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1", "hand:2" }, id = "death" }
		is_true(ex.validate(action) == true, "validate")
		is_true(ex.dispatch(action) == true, "dispatch")
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(#engine.G.hand.highlighted, 2)
		eq(engine.G.hand.highlighted[1], cards[1])
		eq(engine.G.hand.highlighted[2], cards[2])
	end)

	test("executor_clears_the_highlight_when_the_engine_refuses", function()
		local refused = tarot("c_strength", 2)
		refused._usable = false
		local engine, ex = executor(refused, plain_hand())
		local action = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:2" }, id = "refused" }
		is_true(ex.validate(action) == true, "validate")
		local ok, code = ex.dispatch(action)
		eq(ok, nil, "refused")
		eq(code, "exec_illegal", "code")
		eq(#engine.G.hand.highlighted, 0, "highlight cleared")
		-- A no-op use (source still held) is a clean failure, highlight cleared.
		local engine2, ex2 = executor(tarot("c_strength", 2), plain_hand())
		engine2.G.FUNCS.use_card = function() end
		local noop = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "noop" }
		is_true(ex2.validate(noop) == true, "validate noop")
		eq(ex2.dispatch(noop), nil, "noop refused")
		eq(#engine2.G.hand.highlighted, 0, "noop highlight cleared")
	end)

	test("executor_refuses_forced_oversized_or_out_of_bounds_selections", function()
		local cards = plain_hand()
		cards[3].ability.forced_selection = true
		local _, ex = executor(tarot("c_strength", 2), cards)
		local forced = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "forced" }
		eq(ex.validate(forced), nil, "forced card present")
		local _, ex2 = executor(tarot("c_strength", 2), plain_hand())
		local three = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1", "hand:2", "hand:3" }, id = "three" }
		eq(ex2.validate(three), nil, "three targets")
		local _, ex3 = executor(tarot("c_death", 2, 2), plain_hand())
		local one = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "one" }
		eq(ex3.validate(one), nil, "death needs two")
	end)
end
