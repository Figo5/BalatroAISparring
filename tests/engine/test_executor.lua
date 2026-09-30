return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	local function setup(engine_opts, pipeline_opts)
		local engine = support.engine(engine_opts or {})
		local pipeline = support.pipeline(bundle, engine, pipeline_opts or {})
		is_true(pipeline.executor ~= nil, "executor factory: " .. tostring(pipeline.executor_code))
		is_true(pipeline.adapter ~= nil, "adapter factory: " .. tostring(pipeline.adapter_code))
		return engine, pipeline
	end

	local function no_ui_callbacks(engine, label)
		for i = 1, #engine.calls do
			local name = engine.calls[i].name
			if name == "can_play" or name == "can_buy" or name == "can_discard"
				or name == "can_sell_card" or name == "can_use_consumeable" or name == "can_open" then
				error((label or "ui") .. ": executor invoked UI predicate " .. name, 2)
			end
		end
	end

	local function remove_card(area, card)
		for i = #area.cards, 1, -1 do
			if area.cards[i] == card then
				table.remove(area.cards, i)
			end
		end
	end

	-- Real `G.FUNCS.use_card` removes the source from its area synchronously
	-- (`button_callbacks.lua:2209`); the fixture must model that so the
	-- executor's synchronous-removal check sees a real commit.
	local function real_use_card(engine)
		local record = engine.G.FUNCS.use_card
		engine.G.FUNCS.use_card = function(e)
			record(e)
			local card = e.config.ref_table
			remove_card(engine.G.pack_cards, card)
			remove_card(engine.G.consumeables, card)
			remove_card(engine.G.shop_booster, card)
			remove_card(engine.G.shop_vouchers, card)
		end
	end

	-- Real `G.FUNCS.select_blind` reads `e.UIBox:get_UIE_by_ID('tag_container')`
	-- and `e.config.ref_table` (button_callbacks.lua:2596-2598). The fixture
	-- reproduces that shape so a fabricated element with no `UIBox` fails.
	local function real_select_blind(engine)
		local record = engine.G.FUNCS.select_blind
		engine.G.FUNCS.select_blind = function(e)
			record(e)
			local tag = e.UIBox:get_UIE_by_ID("tag_container")
			local blind = e.config.ref_table
			if tag == nil or type(blind) ~= "table" then
				error("select_blind fixture: missing UIBox/ref_table")
			end
			engine.G.GAME.round_resets.blind = blind
			engine.G.blind_select = nil
			return true
		end
	end

	-- The real on-deck blind choice UIBox with a `select_blind_button` element
	-- (mp/ui/game/blind_choice.lua:210-228): the element's `UIBox` is the choice
	-- box and its `config.ref_table` is the on-deck blind config.
	local function blind_choice_box(engine, on_deck_lower, button, ref_table)
		local tag = { config = { ref_table = "tag" } }
		local element = { config = { button = button, ref_table = ref_table } }
		-- Like the real engine UIBox, `get_UIE_by_ID` is inherited through the
		-- class metatable, never a raw field, so a rawget lookup fails here.
		local UIBoxClass = {}
		UIBoxClass.__index = UIBoxClass
		function UIBoxClass:get_UIE_by_ID(id)
			if id == "tag_container" then
				return tag
			end
			if id == "select_blind_button" then
				return element
			end
			return nil
		end
		local box = setmetatable({}, UIBoxClass)
		element.UIBox = box
		engine.G.blind_select_opts = { [on_deck_lower] = box }
		return box, element
	end

	-- The real cash-out button UIBox: a separate box registered in `G.I.UIBOX`
	-- (`engine/ui.lua:92-97`) with `role.major = G.round_eval`
	-- (`functions/common_events.lua:1430-1443`, `engine/moveable.lua:478-488`),
	-- never part of `G.round_eval`'s element tree. Methods live on the class
	-- metatable, so a rawget lookup fails exactly as on the real engine.
	local function cash_out_box(round_eval, button)
		local UIBoxClass = {}
		UIBoxClass.__index = UIBoxClass
		function UIBoxClass:get_UIE_by_ID(id)
			if id == "cash_out_button" then
				return self._element
			end
			return nil
		end
		return setmetatable({ _element = button, role = { major = round_eval } }, UIBoxClass)
	end

	test("factory_binds_role_and_ports", function()
		local engine = support.engine()
		local adapter = bundle.EngineAdapter.factory({
			role = "ai_staged", session = "s1", codec = bundle.codec,
			revision = bundle.StateRevision.factory(), G = engine.G, MP = engine.MP,
		})
		local executor, code = bundle.ProductionExecutor.factory({
			role = "human_practice", session = "s1", adapter = adapter, reader = bundle.reader,
			revision = bundle.StateRevision.factory(), G = engine.G, MP = engine.MP,
		})
		eq(executor, nil)
		eq(code, "exec_bad_role")
		local executor2, code2 = bundle.ProductionExecutor.factory({
			role = "ai_staged", session = "s1", adapter = nil, reader = bundle.reader,
			revision = bundle.StateRevision.factory(), G = engine.G, MP = engine.MP,
		})
		eq(executor2, nil)
		eq(code2, "exec_bad_adapter")
	end)

	test("capture_returns_handle_and_epoch", function()
		local _, pipeline = setup()
		local handle, epoch = pipeline.executor.capture()
		is_true(handle ~= nil, "capture handle")
		is_true(type(epoch) == "number", "epoch")
		is_true(bundle.obs.is_handle(handle))
	end)

	test("play_validate_and_dispatch", function()
		local engine, pipeline = setup({
			hand = { support.card({}), support.card({}) },
		})
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "play-1" }
		local ok, code = pipeline.executor.validate(action)
		is_true(ok == true, "validate: " .. tostring(code))
		local dispatched, dcode = pipeline.executor.dispatch(action)
		is_true(dispatched == true, "dispatch: " .. tostring(dcode))
		eq(#engine.hand.highlighted, 2)
		eq(engine.calls[#engine.calls].name, "play_cards_from_highlighted")
		no_ui_callbacks(engine, "play")
	end)

	test("illegal_play_refused_when_no_hands_left", function()
		local _, pipeline = setup({
			hand = { support.card({}) },
			hands_left = 0,
		})
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1" }, id = "play-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("stale_revision_refused_before_callback", function()
		local engine, pipeline = setup({ hand = { support.card({}) } })
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1" }, id = "play-3" }
		local ok = pipeline.executor.validate(action)
		is_true(ok == true)
		engine.G.STATE = STATES.SHOP
		local dispatched, dcode = pipeline.executor.dispatch(action)
		eq(dispatched, nil)
		eq(dcode, "exec_stale_revision")
		eq(#engine.calls, 0)
	end)

	test("dispatch_requires_validate", function()
		local _, pipeline = setup({ hand = { support.card({}) } })
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1" }, id = "play-4" }
		local dispatched, dcode = pipeline.executor.dispatch(action)
		eq(dispatched, nil)
		eq(dcode, "exec_illegal")
	end)

	test("buy_item_validate_and_dispatch", function()
		local shop_card = support.card({ center = "c_ace", cost = 3, center_set = "Default" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card } })
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-1" }
		local ok, code = pipeline.executor.validate(action)
		is_true(ok == true, "validate: " .. tostring(code))
		local dispatched = pipeline.executor.dispatch(action)
		is_true(dispatched == true)
		eq(engine.calls[#engine.calls].name, "buy_from_shop")
		eq(engine.calls[#engine.calls].e.config.ref_table, shop_card)
	end)

	test("buy_item_unaffordable_refused", function()
		local shop_card = support.card({ center = "c_ace", cost = 100, center_set = "Default" })
		local _, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card } })
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("buy_joker_requires_slot_room", function()
		-- `CardArea.config.card_limit` is metatable-backed, so the executor must
		-- read it with normal indexing (rpath/rawget is always nil).
		local shop_joker = support.card({ set = "Joker", center = "j_joker", cost = 3, center_set = "Joker" })
		local filler = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local _, full = setup({
			state = STATES.SHOP, shop_jokers = { shop_joker }, jokers = { filler }, joker_slots = 1,
		})
		local refused = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-joker-full" }
		local ok, code = full.executor.validate(refused)
		eq(ok, nil)
		eq(code, "exec_illegal")

		local engine, pipeline = setup({
			state = STATES.SHOP, shop_jokers = { shop_joker }, jokers = {}, joker_slots = 1,
		})
		local accepted = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-joker-room" }
		is_true(pipeline.executor.validate(accepted) == true)
		is_true(pipeline.executor.dispatch(accepted) == true)
		eq(engine.calls[#engine.calls].name, "buy_from_shop")
	end)

	test("buy_consumable_requires_slot_room", function()
		local shop_consumable = support.card({
			set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot", cost = 3,
		})
		local filler = support.card({ set = "Tarot", consumeable = true, center = "c_star", center_set = "Tarot" })
		local _, full = setup({
			state = STATES.SHOP, shop_jokers = { shop_consumable }, consumeables = { filler }, consumable_slots = 1,
		})
		local refused = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-consumable-full" }
		local ok, code = full.executor.validate(refused)
		eq(ok, nil)
		eq(code, "exec_illegal")

		local _, pipeline = setup({
			state = STATES.SHOP, shop_jokers = { shop_consumable }, consumeables = {}, consumable_slots = 1,
		})
		local accepted = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-consumable-room" }
		is_true(pipeline.executor.validate(accepted) == true)
		is_true(pipeline.executor.dispatch(accepted) == true)
	end)

	test("buy_negative_joker_fits_one_over_limit", function()
		-- Mirrors `check_for_buy_space` with `ability.card_limit = 1`: a full
		-- joker area still fits the negative joker.
		local negative = support.card({
			set = "Joker", center = "j_joker", cost = 3, center_set = "Joker",
			edition = "negative", card_limit = 1,
		})
		local filler = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local _, pipeline = setup({
			state = STATES.SHOP, shop_jokers = { negative }, jokers = { filler }, joker_slots = 1,
		})
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-negative" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
	end)

	test("use_consumable_reads_area_limit_via_metatable", function()
		-- The Ankh `check_use` gate reads the joker area limit with normal
		-- indexing too; with a metatable-backed config a rawget would wrongly
		-- refuse a free slot.
		local ankh = support.card({ set = "Spectral", center_set = "Spectral", consumeable_data = {}, center = "c_ankh", usable = true })
		local engine, pipeline = setup({ consumeables = { ankh }, jokers = {}, joker_slots = 1 })
		real_use_card(engine)
		local action = { type = "USE_CONSUMABLE", source_ref = "consumable:1", target_refs = {}, id = "ankh-free" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
	end)

	test("sell_joker_validate_and_dispatch", function()
		local joker = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local engine, pipeline = setup({ jokers = { joker } })
		local action = { type = "SELL_JOKER", joker_ref = "joker:1", id = "sell-1" }
		local ok, code = pipeline.executor.validate(action)
		is_true(ok == true, "validate: " .. tostring(code))
		local dispatched = pipeline.executor.dispatch(action)
		is_true(dispatched == true)
		eq(engine.calls[#engine.calls].name, "sell_card")
		no_ui_callbacks(engine, "sell")
	end)

	test("reroll_and_leave_shop", function()
		local engine, pipeline = setup({ state = STATES.SHOP })
		-- The real `reroll_shop` replaces the shop contents; simulate the visible
		-- transition so the deferred-action latch releases before `LEAVE_SHOP`.
		local record_reroll = engine.G.FUNCS.reroll_shop
		engine.G.FUNCS.reroll_shop = function(e)
			record_reroll(e)
			engine.G.GAME.current_round.reroll_cost = 6
		end
		local reroll = { type = "REROLL", id = "reroll-1" }
		is_true(pipeline.executor.validate(reroll) == true)
		is_true(pipeline.executor.dispatch(reroll) == true)
		eq(engine.calls[#engine.calls].name, "reroll_shop")
		local leave = { type = "LEAVE_SHOP", id = "leave-1" }
		is_true(pipeline.executor.validate(leave) == true)
		is_true(pipeline.executor.dispatch(leave) == true)
		eq(engine.calls[#engine.calls].name, "toggle_shop")
	end)

	test("open_booster_and_voucher_use_card", function()
		local booster = support.card({ set = "Booster", center = "p_arcana_normal_1", cost = 4, center_set = "Booster" })
		local voucher = support.card({ set = "Voucher", center = "v_seed_money", cost = 10, center_set = "Voucher" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_boosters = { booster }, shop_vouchers = { voucher } })
		-- The real `use_card` consumes/redeems the shop item; simulate the target
		-- leaving its area so the action-specific latch releases.
		local record_use = engine.G.FUNCS.use_card
		local function remove(cards, card)
			for i = #cards, 1, -1 do
				if cards[i] == card then
					table.remove(cards, i)
				end
			end
		end
		engine.G.FUNCS.use_card = function(e)
			record_use(e)
			local card = e.config.ref_table
			remove(engine.G.shop_booster.cards, card)
			remove(engine.G.shop_vouchers.cards, card)
		end
		local open = { type = "OPEN_BOOSTER", item_ref = "shop_booster:1", id = "open-1" }
		is_true(pipeline.executor.validate(open) == true)
		is_true(pipeline.executor.dispatch(open) == true)
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, booster)
		local redeem = { type = "BUY_VOUCHER", voucher_ref = "shop_voucher:1", id = "voucher-1" }
		is_true(pipeline.executor.validate(redeem) == true)
		is_true(pipeline.executor.dispatch(redeem) == true)
		eq(engine.calls[#engine.calls].e.config.ref_table, voucher)
	end)

	test("select_booster_item_use_card", function()
		local pack_card = support.card({ center = "c_temperance" })
		local engine, pipeline = setup({ state = STATES.TAROT_PACK, pack_cards = { pack_card } })
		real_use_card(engine)
		local action = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, pack_card)
	end)

	test("use_consumable_empty_target", function()
		local consumable = support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot" })
		local engine, pipeline = setup({ consumeables = { consumable } })
		real_use_card(engine)
		local action = { type = "USE_CONSUMABLE", source_ref = "consumable:1", target_refs = {}, id = "use-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, consumable)
	end)

	test("use_consumable_targets_set_highlight", function()
		local consumable = support.card({ set = "Tarot", consumeable = true, center = "c_star", center_set = "Tarot", max_highlighted = 3 })
		local target = support.card({ center = "c_ace" })
		local engine, pipeline = setup({ consumeables = { consumable }, hand = { support.card({}), target } })
		real_use_card(engine)
		local action = { type = "USE_CONSUMABLE", source_ref = "consumable:1", target_refs = { "target:2" }, id = "use-2" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(#engine.hand.highlighted, 1)
		eq(engine.hand.highlighted[1], target)
	end)

	test("select_blind_uses_real_engine_element", function()
		-- Ordinary SELECT_BLIND must dispatch the real on-deck
		-- `select_blind_button`: its `UIBox` is the blind choice box and its
		-- `config.ref_table` is the on-deck blind config, exactly what the real
		-- callback reads (button_callbacks.lua:2596-2598).
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_select = {},
			blind_key = "bl_small",
			blind_on_deck = "Small",
		})
		local box, element = blind_choice_box(engine, "small", "select_blind", engine.G.P_BLINDS.bl_small)
		real_select_blind(engine)
		local action = { type = "SELECT_BLIND", id = "blind-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "select_blind")
		eq(engine.calls[#engine.calls].e, element)
		eq(engine.calls[#engine.calls].e.UIBox, box)
		eq(engine.calls[#engine.calls].e.config.ref_table, engine.G.P_BLINDS.bl_small)
		eq(engine.G.GAME.round_resets.blind, engine.G.P_BLINDS.bl_small)
	end)

	test("select_blind_missing_real_element_refused", function()
		-- No on-deck `select_blind_button`: the fabricated element would make the
		-- deferred `e.UIBox:get_UIE_by_ID('tag_container')` crash the game, so it
		-- is refused with ELEMENT_MISSING and the callback never runs.
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_select = {},
			blind_key = "bl_small",
			blind_on_deck = "Small",
		})
		local action = { type = "SELECT_BLIND", id = "blind-missing" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_element_missing")
		eq(#engine.calls, 0, "select_blind ran without a real element")
	end)

	test("select_blind_disabled_button_refused", function()
		-- The `run_info` variant of the blind choice has the same id but no
		-- `button='select_blind'`; it must never be dispatched.
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_select = {},
			blind_key = "bl_small",
			blind_on_deck = "Small",
		})
		blind_choice_box(engine, "small", nil, engine.G.P_BLINDS.bl_small)
		local action = { type = "SELECT_BLIND", id = "blind-disabled" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_element_missing")
		eq(#engine.calls, 0, "disabled select_blind_button was dispatched")
	end)

	test("select_blind_ref_table_mismatch_refused", function()
		-- A stale choice element pointing at a different blind is not the action
		-- this session validated; dispatching it would select the wrong blind.
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_select = {},
			blind_key = "bl_small",
			blind_on_deck = "Small",
		})
		blind_choice_box(engine, "small", "select_blind", engine.G.P_BLINDS.bl_big)
		local action = { type = "SELECT_BLIND", id = "blind-mismatch" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_element_missing")
		eq(#engine.calls, 0, "mismatched ref_table was dispatched")
	end)

	test("skip_blind_requires_element_port", function()
		local _, pipeline = setup({ state = STATES.BLIND_SELECT, blind_on_deck = "Small" })
		local action = { type = "SKIP_BLIND", id = "skip-1" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_element_missing")
	end)

	test("skip_blind_with_element_port", function()
		local marker = { config = { ref_table = "tag" } }
		local engine, pipeline = setup({ state = STATES.BLIND_SELECT, blind_on_deck = "Small" }, {
			element_for = function(name)
				if name == "skip_blind" then
					return marker
				end
				return nil
			end,
		})
		local action = { type = "SKIP_BLIND", id = "skip-2" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_blind")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("advance_ui_cash_out", function()
		local marker = { config = { button = "cash_out" } }
		local element_for = function(name)
			if name == "cash_out" then
				return marker
			end
			return nil
		end
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = {} }, { element_for = element_for })
		local ok, code = pipeline.executor.advance_ui()
		is_true(ok == true, "advance: " .. tostring(code))
		eq(engine.calls[#engine.calls].name, "cash_out")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("advance_ui_cash_out_uses_uibox_registry", function()
		-- Production wires no `element_for`; the executor resolves the real
		-- cash-out button from the `G.I.UIBOX` registry box bound to the current
		-- `G.round_eval` (common_events.lua:1430-1443). The button is NOT in
		-- `round_eval`'s own element tree, so `get_UIE_by_ID` there is nil.
		local round_eval = { get_UIE_by_ID = function() return nil end }
		local marker = { config = { button = "cash_out" } }
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = round_eval })
		engine.G.I = { UIBOX = { cash_out_box(round_eval, marker) } }
		local ok, code = pipeline.executor.advance_ui()
		is_true(ok == true, "advance: " .. tostring(code))
		eq(engine.calls[#engine.calls].name, "cash_out")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("advance_ui_cash_out_ignores_other_round_eval_box", function()
		-- A box still registered from an older round_eval must never be used;
		-- the cash-out waits (ELEMENT_MISSING) for the current tally box.
		local current = {}
		local older = {}
		local marker = { config = { button = "cash_out" } }
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = current })
		engine.G.I = { UIBOX = { cash_out_box(older, marker) } }
		local ok, code = pipeline.executor.advance_ui()
		eq(ok, nil)
		eq(code, "exec_element_missing")
		eq(#engine.calls, 0, "stale round_eval box was dispatched")
	end)

	test("advance_ui_cash_out_requires_button_config", function()
		-- Only a real `config.button == 'cash_out'` element is accepted; a
		-- non-button node under `round_eval`'s box is ignored.
		local round_eval = {}
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = round_eval })
		engine.G.I = { UIBOX = { cash_out_box(round_eval, { config = {} }) } }
		local ok, code = pipeline.executor.advance_ui()
		eq(ok, nil)
		eq(code, "exec_element_missing")
		eq(#engine.calls, 0, "non-cash-out element was dispatched")
	end)

	test("advance_ui_cash_out_without_registry_is_missing", function()
		-- Missing `G.I` / `G.I.UIBOX` fails closed without error.
		local _, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = {} })
		local ok, code = pipeline.executor.advance_ui()
		eq(ok, nil)
		eq(code, "exec_element_missing")
	end)

	test("advance_ui_cash_out_waits_for_tally_button", function()
		-- Cash-out must not run before the registered tally box actually exposes
		-- the button: the executor requires the real element and never fabricates
		-- a minimal one.
		local round_eval = {}
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = round_eval })
		engine.G.I = { UIBOX = { cash_out_box(round_eval, nil) } }
		local ok, code = pipeline.executor.advance_ui()
		eq(ok, nil)
		eq(code, "exec_element_missing")
		eq(#engine.calls, 0, "cash_out ran without a real element")
	end)

	test("select_blind_pvp_routes_through_ready_button", function()
		local marker = { config = { ref_table = "blind" } }
		local element_for = function(name)
			if name == "pvp_ready" then
				return marker
			end
			return nil
		end
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		}, { element_for = element_for })
		local action = { type = "SELECT_BLIND", id = "blind-pvp" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "mp_toggle_ready")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("select_blind_pvp_without_ready_element_refused", function()
		local _, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		})
		local action = { type = "SELECT_BLIND", id = "blind-pvp-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_element_missing")
	end)

	test("select_blind_pvp_already_ready_refused", function()
		local marker = { config = {} }
		local element_for = function()
			return marker
		end
		local _, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = true,
			blind_select = {},
		}, { element_for = element_for })
		local action = { type = "SELECT_BLIND", id = "blind-pvp-3" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("skip_booster_validate_and_dispatch", function()
		local engine, pipeline = setup({ state = STATES.STANDARD_PACK, pack_cards = { support.card({ rank = "2" }) } })
		local action = { type = "SKIP_BOOSTER", id = "skip-booster-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_booster")
	end)

	test("explicit_callback_false_is_not_success", function()
		local shop_card = support.card({ center = "c_ace", cost = 3, center_set = "Default" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card } })
		engine.G.FUNCS.buy_from_shop = function()
			return false
		end
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-false" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
	end)

	test("reorder_jokers_commits_permutation", function()
		local first = support.card({ set = "Joker", area_type = "joker" })
		local second = support.card({ set = "Joker", area_type = "joker" })
		local engine, pipeline = setup({ jokers = { first, second } })
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.G.jokers.cards[1], second)
		eq(engine.G.jokers.cards[2], first)
	end)

	test("reorder_rejects_non_permutation", function()
		local engine, pipeline = setup({ jokers = {
			support.card({ set = "Joker", area_type = "joker" }),
			support.card({ set = "Joker", area_type = "joker" }),
		} })
		local action = { type = "REORDER_JOKERS", order = { "joker:1", "joker:1" }, id = "reorder-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("sell_consumable_validate_and_dispatch", function()
		local consumable = support.card({
			set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot", area_type = "joker",
		})
		local engine, pipeline = setup({ consumeables = { consumable } })
		local action = { type = "SELL_CONSUMABLE", consumable_ref = "consumable:1", id = "sell-consumable-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "sell_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, consumable)
	end)

	test("broker_ports_expose_production_mode", function()
		local _, pipeline = setup()
		local ports = pipeline.executor.broker_ports()
		eq(ports.mode, "M3_PRODUCTION")
		eq(ports.production, true)
		is_true(type(ports.capture) == "function")
		is_true(type(ports.validate) == "function")
		is_true(type(ports.dispatch) == "function")
		local handle, epoch = ports.capture()
		is_true(handle ~= nil)
		is_true(type(epoch) == "number")
		local action = { type = "LEAVE_SHOP", id = "leave-broker" }
		eq(ports.validate(action, handle), false)
	end)

	test("skip_blind_source_element_fallback", function()
		-- Production wires no `element_for`; the executor derives `e.UIBox` from
		-- `G.blind_select_opts[self.lower(blind_on_deck)]` so `skip_blind` can read
		-- `tag_container` (button_callbacks.lua:2754).
		local tag = { config = { ref_table = "tag" } }
		local box = { get_UIE_by_ID = function(_, id)
			if id == "tag_container" then
				return tag
			end
			return nil
		end }
		local engine, pipeline = setup({ state = STATES.BLIND_SELECT, blind_on_deck = "Small", blind_select = {} })
		engine.G.blind_select_opts = { small = box }
		local action = { type = "SKIP_BLIND", id = "skip-fallback" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_blind")
		eq(engine.calls[#engine.calls].e.UIBox, box)
	end)

	test("skip_blind_boss_refused", function()
		-- H4b: the boss blind has no `tag_container`, so a boss skip has no
		-- effect and must not be offered or validated.
		local _, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_on_deck = "Boss",
			blind_states = { Small = "Skipped", Big = "Skipped", Boss = "Select" },
			blind_select = {},
		})
		local action = { type = "SKIP_BLIND", id = "skip-boss" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("select_blind_pvp_source_element_fallback", function()
		local marker = { config = { ref_table = "blind" } }
		local box = { get_UIE_by_ID = function(_, id)
			if id == "select_blind_button" then
				return marker
			end
			return nil
		end }
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		})
		engine.G.blind_select_opts = { boss = box }
		local action = { type = "SELECT_BLIND", id = "blind-pvp-fallback" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "mp_toggle_ready")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("select_blind_pvp_path_unchanged", function()
		-- The PvP path still routes through `mp_toggle_ready` with the real
		-- on-deck `select_blind_button` and never invokes `select_blind`.
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		})
		local _, element = blind_choice_box(engine, "boss", "select_blind", engine.G.P_BLINDS.bl_mp_nemesis)
		local action = { type = "SELECT_BLIND", id = "blind-pvp-unchanged" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(#engine.calls, 1)
		eq(engine.calls[1].name, "mp_toggle_ready")
		eq(engine.calls[1].e, element)
	end)

	test("select_booster_consumable_requires_can_use", function()
		-- C1: a pack consumable is used on selection, so the engine's
		-- `can_use_consumeable` is the gate rather than free consumable slots.
		local unusable = support.card({ set = "Spectral", center_set = "Spectral", consumeable_data = {}, center = "c_cryptid", usable = false })
		local engine, pipeline = setup({ state = STATES.TAROT_PACK, pack_cards = { unusable }, consumeables = {} })
		local action = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-unusable" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")

		local usable = support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot" })
		local engine2, pipeline2 = setup({ state = STATES.TAROT_PACK, pack_cards = { usable }, consumeables = {} })
		real_use_card(engine2)
		local action2 = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-usable" }
		is_true(pipeline2.executor.validate(action2) == true)
	end)

	test("select_booster_negative_joker_fits_one_over_the_limit", function()
		-- L3: this build's `can_select_card` (button_callbacks.lua:2135-2145)
		-- allows a joker when `#G.jokers.cards < card_limit +
		-- (ability.card_limit - ability.extra_slots_used)`. A negative edition
		-- stores `ability.card_limit = 1` (SMODS overrides.lua:2216), so it fits
		-- one over a full joker area but not two over.
		local function negative_joker()
			local card = support.card({ set = "Joker", center = "j_joker", area_type = "joker", edition = "negative" })
			card.ability.card_limit = 1
			card.ability.extra_slots_used = 0
			return card
		end
		local function filler()
			return support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		end
		local _, pipeline = setup({
			state = STATES.BUFFOON_PACK,
			pack_cards = { negative_joker() },
			jokers = { filler() },
			joker_slots = 1,
		})
		local action = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-negative" }
		is_true(pipeline.executor.validate(action) == true, "full area: a negative joker fits one over")
		local _, over = setup({
			state = STATES.BUFFOON_PACK,
			pack_cards = { negative_joker() },
			jokers = { filler(), filler() },
			joker_slots = 1,
		})
		local ok = over.executor.validate({ type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-negative-2" })
		is_true(ok ~= true, "already one over: the real can_select_card refuses")
	end)

	test("play_cards_requires_forced_selection", function()
		-- H3: a forced card cannot be un-highlighted and is cleared by a
		-- play/discard, so a selection omitting it is refused.
		local forced = support.card({ rank = "Ace" })
		forced.ability.forced_selection = true
		local engine, pipeline = setup({ hand = { forced, support.card({ rank = "2" }), support.card({ rank = "3" }) } })
		local omitted = { type = "PLAY_CARDS", card_refs = { "hand:2" }, id = "play-omitted" }
		local ok, code = pipeline.executor.validate(omitted)
		eq(ok, nil)
		eq(code, "exec_illegal")

		local included = { type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "play-included" }
		is_true(pipeline.executor.validate(included) == true)
		is_true(pipeline.executor.dispatch(included) == true)
		eq(#engine.hand.highlighted, 2)
	end)

	test("highlight_mismatch_blocks_callback", function()
		-- H3: `add_to_highlighted` silently drops an add at the highlight limit
		-- (cardarea.lua:149-150); the actual highlighted set must equal the
		-- requested set or the callback must not run.
		local engine, pipeline = setup({ hand = { support.card({ rank = "2" }), support.card({ rank = "3" }) } })
		engine.hand.add_to_highlighted = function() end
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "play-mismatch" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
		eq(#engine.calls, 0, "callback ran on a dropped highlight")
	end)

	test("gates_clear_blocks_shop_commit", function()
		-- M2: the executor holds legality on its own; a live STOP_USE blocks a
		-- purchase that the (blocked) view would not have offered.
		local shop_card = support.card({ center = "c_ace", cost = 3, center_set = "Default" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card }, stop_use = 1 })
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-gated" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("skip_booster_smods_state_dispatch", function()
		-- H1: SMODS boosters are skippable in `SMODS_BOOSTER_OPENED` with no hand.
		-- A: the real skip still requires a pack card to exist first, so the
		-- fixture uses a real pack card rather than an empty pack.
		local engine, pipeline = setup({
			state = STATES.SMODS_BOOSTER_OPENED,
			pack_cards = { support.card({ rank = "2" }) },
			hand = {},
		})
		local action = { type = "SKIP_BOOSTER", id = "skip-smods" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_booster")
	end)

	test("skip_booster_smods_empty_pack_refused", function()
		-- A: while the opened booster's cards have not materialized
		-- (`G.pack_cards.cards[1]` absent) the real UI cannot skip, so neither
		-- the executor may accept one.
		local _, pipeline = setup({ state = STATES.SMODS_BOOSTER_OPENED, pack_cards = {}, hand = {} })
		local action = { type = "SKIP_BOOSTER", id = "skip-smods-empty" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("select_booster_ankh_full_slots_refused", function()
		-- B: a pack Ankh with full joker slots is a `use_card` no-op
		-- (`Card:check_use`), even though `can_use_consumeable` passes, so the
		-- executor refuses it. The adapter uses the same predicate.
		local ankh = support.card({ set = "Spectral", center_set = "Spectral", consumeable_data = {}, center = "c_ankh", usable = true })
		local filler = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local _, pipeline = setup({
			state = STATES.SMODS_BOOSTER_OPENED,
			pack_cards = { ankh },
			jokers = { filler },
			joker_slots = 1,
			hand = {},
		})
		local action = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-ankh-full" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("reorder_reverted_by_align_cards_fails", function()
		-- NEW-1: `align_cards` can replace/re-sort `area.cards`; a reorder that
		-- does not stick must be a clean failure, never a "successful" submit
		-- that lets a deterministic policy loop in the shop forever.
		local first = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local second = support.card({ set = "Joker", center = "j_mult", area_type = "joker" })
		local engine, pipeline = setup({ state = STATES.SHOP, jokers = { first, second } })
		engine.G.jokers.align_cards = function(self)
			self.cards = { first, second }
		end
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-reverts" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
	end)

	test("advance_ui_no_control_clears_stale_control", function()
		-- NEW-2: if the engine leaves ROUND_EVAL without the AI pressing
		-- cash-out, the latched control is stale. `advance_ui` must clear it so
		-- the next `capture` can proceed instead of being blocked forever.
		local marker = { config = { button = "cash_out" } }
		local element_for = function(name)
			if name == "cash_out" then
				return marker
			end
			return nil
		end
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = {} }, { element_for = element_for })
		local handle, code = pipeline.executor.capture()
		eq(handle, nil)
		eq(code, "exec_control_required")
		eq(pipeline.executor.last_control_state(), "cash_out")

		engine.G.STATE = STATES.SHOP
		local ok, acode = pipeline.executor.advance_ui()
		eq(ok, nil)
		eq(acode, "exec_no_control")
		eq(pipeline.executor.last_control_state(), nil)

		local shop_handle, shop_code = pipeline.executor.capture()
		is_true(shop_handle ~= nil, "capture after stale control: " .. tostring(shop_code))
		eq(pipeline.executor.last_control_state(), nil)
	end)

	test("reorder_uses_metatable_area_methods", function()
		-- L1: `align_cards`/`set_ranks` live on the CardArea metatable on a real
		-- area (rawget is always nil); the executor must reach them by normal
		-- indexing and run them.
		local first = support.card({ set = "Joker", area_type = "joker" })
		local second = support.card({ set = "Joker", area_type = "joker" })
		local engine, pipeline = setup({ jokers = { first, second } })
		local calls = {}
		local methods = {
			set_ranks = function() calls[#calls + 1] = "set_ranks" end,
			align_cards = function() calls[#calls + 1] = "align_cards" end,
		}
		setmetatable(engine.G.jokers, { __index = methods })
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-mt" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(calls[1], "set_ranks")
		eq(calls[2], "align_cards")
		eq(engine.G.jokers.cards[1], second)
	end)

	test("reorder_refused_when_pinned", function()
		local first = support.card({ set = "Joker", area_type = "joker" })
		first.pinned = true
		local second = support.card({ set = "Joker", area_type = "joker" })
		local _, pipeline = setup({ jokers = { first, second } })
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-pinned" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	-- Source-shaped Multiplayer timer (mp ui/game/timer.lua:3-31 and
	-- networking/action_handlers.lua:1359-1373): the gate reads the lobby
	-- config and MP.GAME; the button re-checks it and starts the timer.
	local function timer_engine(opts)
		opts = opts or {}
		local engine = support.engine({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = opts.ready_blind ~= false,
			blind_select = {},
			config_timer = opts.config_timer ~= false,
			timer = opts.timer,
			timer_started = opts.timer_started,
		})
		local MP = engine.MP
		local gate_open = opts.gate ~= false
		MP.UI = {
			can_timer_opponent = function()
				if opts.gate_throws then
					error("gate failure")
				end
				if not MP.LOBBY.config.timer then
					return false
				end
				if MP.GAME.timer <= 0 then
					return false
				end
				return gate_open and MP.GAME.ready_blind == true
			end,
		}
		engine.funcs.mp_timer_button = function(e)
			engine.calls[#engine.calls + 1] = { name = "mp_timer_button", e = e }
			if opts.button_noop then
				return
			end
			if MP.UI.can_timer_opponent() then
				if not MP.GAME.timer_started then
					MP.GAME.timer_started = true
				else
					MP.GAME.timer_started = false
				end
			end
		end
		return engine
	end

	test("start_timer_presses_the_real_button_and_proves_the_effect", function()
		local engine = timer_engine()
		local pipeline = support.pipeline(bundle, engine, {})
		local action = { type = "START_TIMER", id = "timer-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "mp_timer_button")
		eq(engine.MP.GAME.timer_started, true)
		-- A second press would pause the timer: never valid once started.
		local ok, code = pipeline.executor.validate({ type = "START_TIMER", id = "timer-2" })
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("start_timer_refused_when_the_button_is_not_lit", function()
		for _, opts in ipairs({
			{ ready_blind = false },
			{ config_timer = false },
			{ gate = false },
			{ gate_throws = true },
			{ timer = 0 },
			{ timer_started = true },
		}) do
			local engine = timer_engine(opts)
			local pipeline = support.pipeline(bundle, engine, {})
			local ok, code = pipeline.executor.validate({ type = "START_TIMER", id = "timer-x" })
			eq(ok, nil)
			eq(code, "exec_illegal")
			for _, call in ipairs(engine.calls) do
				is_true(call.name ~= "mp_timer_button", "button pressed while not lit")
			end
		end
	end)

	test("start_timer_without_visible_effect_is_a_failure", function()
		local engine = timer_engine({ button_noop = true })
		local pipeline = support.pipeline(bundle, engine, {})
		local action = { type = "START_TIMER", id = "timer-noop" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
	end)

	test("start_timer_lifecycle_through_a_pvp_round", function()
		-- One PvP round against the pinned Multiplayer state machine:
		-- ready -> press -> (opponent arrives) -> round transition -> next PvP.
		local engine = timer_engine()
		local pipeline = support.pipeline(bundle, engine, {})
		local MP = engine.MP
		local function offered()
			local step = pipeline.adapter.step()
			local handle = bundle.reader.capture(step.runtime, step.ui_view)
			for _, action in ipairs(bundle.actions.generate(handle)) do
				if action.type == "START_TIMER" then
					return action
				end
			end
			return nil
		end
		local action = offered()
		is_true(action ~= nil, "readied: timer offered")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		is_true(offered() == nil, "started: never offered again (a press would pause)")
		-- The opponent readies: the real gate closes (enemy location loc_ready).
		MP.GAME.timer_started = false
		MP.GAME.enemy.location_type = "loc_ready"
		local gate = MP.UI.can_timer_opponent
		MP.UI.can_timer_opponent = function()
			if MP.GAME.enemy.location_type == "loc_ready" then
				return false
			end
			return gate()
		end
		is_true(offered() == nil, "opponent arrived: gate closed")
		-- Round transition (action_start_blind / end_pvp reset ready_blind and
		-- timer_started, action_handlers.lua:328-352, 495-506).
		MP.GAME.ready_blind = false
		MP.GAME.enemy.location_type = nil
		is_true(offered() == nil, "not readied: no timer")
		-- Next PvP blind, readied again: the timer is offered afresh.
		MP.GAME.ready_blind = true
		is_true(offered() ~= nil, "next PvP: offered again")
	end)

	test("start_timer_absent_while_multiplayer_ui_is_not_loaded", function()
		-- e.g. mid-reconnect or before Multiplayer's UI module has loaded.
		local engine = timer_engine()
		engine.MP.UI = nil
		local pipeline = support.pipeline(bundle, engine, {})
		local step = pipeline.adapter.step()
		local handle = bundle.reader.capture(step.runtime, step.ui_view)
		for _, action in ipairs(bundle.actions.generate(handle)) do
			is_true(action.type ~= "START_TIMER", "offered without the real gate")
		end
		local ok, code = pipeline.executor.validate({ type = "START_TIMER", id = "t" })
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)
end

