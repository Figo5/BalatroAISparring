-- Shared fixtures for the engine adapter / production executor harness.
--
-- Builds a synthetic, metatable-aware Balatro-shaped engine (G/MP/G.FUNCS) with
-- recording callbacks. No game, Mods directory, network or live runtime is
-- touched. The schema/reader/broker modules are loaded from the real sources.

local Support = {}

local STATES = {
	SELECTING_HAND = 1,
	HAND_PLAYED = 2,
	DRAW_TO_HAND = 3,
	GAME_OVER = 4,
	SHOP = 5,
	PLAY_TAROT = 6,
	BLIND_SELECT = 7,
	ROUND_EVAL = 8,
	TAROT_PACK = 9,
	PLANET_PACK = 10,
	MENU = 11,
	SPECTRAL_PACK = 15,
	STANDARD_PACK = 17,
	BUFFOON_PACK = 18,
	NEW_ROUND = 19,
	SMODS_BOOSTER_OPENED = 999,
}

Support.STATES = STATES

local CALLBACK_NAMES = {
	"play_cards_from_highlighted",
	"discard_cards_from_highlighted",
	"buy_from_shop",
	"sell_card",
	"reroll_shop",
	"toggle_shop",
	"use_card",
	"select_blind",
	"skip_blind",
	"skip_booster",
	"cash_out",
	"mp_toggle_ready",
	"can_play",
	"can_buy",
	"can_discard",
	"can_sell_card",
	"can_use_consumeable",
	"can_open",
	"check_for_buy_space",
}

function Support.recorder()
	local calls = {}
	local funcs = {}
	for i = 1, #CALLBACK_NAMES do
		local name = CALLBACK_NAMES[i]
		funcs[name] = function(e)
			calls[#calls + 1] = { name = name, e = e }
		end
	end
	return funcs, calls
end

local Card = {}

function Card.can_sell_card(self)
	if self._sellable == false then
		return false
	end
	local area = rawget(self, "area")
	if type(area) ~= "table" then
		return false
	end
	if rawget(area.config, "type") ~= "joker" then
		return false
	end
	local ability = rawget(self, "ability")
	return rawget(ability, "eternal") ~= true
end

function Card.can_use_consumeable(self)
	return self._usable ~= false
end

Support.Card = Card

function Support.card(opts)
	opts = opts or {}
	local center = { key = opts.center or "c_king", set = opts.center_set or "Default" }
	local ability = {
		set = opts.set or "Default",
		consumeable = opts.consumeable or false,
		eternal = opts.eternal,
		-- Real `Card:set_ability` always stores these (card.lua:398-399), so the
		-- fixture mirrors the plain-numeric ability fields the buy-space
		-- predicate reads.
		card_limit = opts.card_limit or 0,
		extra_slots_used = opts.extra_slots_used or 0,
	}
	if opts.consumeable_data ~= nil then
		ability.consumeable = opts.consumeable_data
	elseif opts.consumeable then
		ability.consumeable = {}
	end
	if opts.max_highlighted ~= nil then
		ability.consumeable = ability.consumeable or {}
		ability.consumeable.max_highlighted = opts.max_highlighted
	end
	local card = {
		facing = opts.facing or "front",
		sprite_facing = opts.sprite_facing or "front",
		config = { center = center },
		ability = ability,
		base = { value = opts.rank or "King", suit = opts.suit or "Hearts" },
		cost = opts.cost or 0,
		sell_cost = opts.sell_cost or 1,
		debuff = opts.debuff or false,
		_sellable = opts.sellable,
		_usable = opts.usable,
	}
	if opts.edition ~= nil then
		card.edition = { type = opts.edition, [opts.edition] = true }
	end
	if opts.seal ~= nil then
		card.seal = opts.seal
	end
	if opts.area_type ~= nil then
		card.area = { config = { type = opts.area_type } }
	end
	return setmetatable(card, { __index = Card })
end

-- A `CardArea.config` clone of the real engine's metatable (cardarea.lua:13-28):
-- `card_limit` is served only by `__index` over `card_limits`, so a rawget reads
-- nil and a naive `card_limit =` write is intercepted by `__newindex`.
local function area_config(opts)
	local config = setmetatable({ card_limits = {} }, {
		__index = function(t, key)
			if key == "card_limit" then
				return (t.card_limits.total_slots or 0) - (t.card_limits.extra_slots_used or 0)
			end
		end,
		__newindex = function(t, key, value)
			if key == "card_limit" then
				if not t.card_limits.base then rawset(t.card_limits, "base", value) end
				if not t.card_limits.total_slots then rawset(t.card_limits, "total_slots", value) end
				rawset(t.card_limits, "mod", value - t.card_limits.base - (t.card_limits.extra_slots or 0) + (t.card_limits.extra_slots_used or 0))
			else
				rawset(t, key, value)
			end
		end,
	})
	config.highlighted_limit = 5
	config.card_limit = opts.limit or 5
	config.type = opts.type or "hand"
	return config
end

local function area(opts)
	opts = opts or {}
	local instance = {
		cards = opts.cards or {},
		highlighted = {},
		config = area_config(opts),
	}
	function instance:add_to_highlighted(card)
		self.highlighted[#self.highlighted + 1] = card
	end
	function instance:remove_from_highlighted(card)
		for i = #self.highlighted, 1, -1 do
			if self.highlighted[i] == card then
				table.remove(self.highlighted, i)
			end
		end
	end
	-- Real `CardArea:unhighlight_all` keeps blind-forced cards highlighted.
	function instance:unhighlight_all()
		for i = #self.highlighted, 1, -1 do
			local card = self.highlighted[i]
			if not (type(card.ability) == "table" and card.ability.forced_selection == true) then
				table.remove(self.highlighted, i)
			end
		end
	end
	return instance
end

Support.area = area

function Support.engine(opts)
	opts = opts or {}
	local funcs, calls = Support.recorder()

	local states = {}
	for key, value in next, STATES do
		states[key] = value
	end
	if opts.states_override ~= nil then
		states = opts.states_override
	end

	local blind_key = opts.blind_key or "bl_small"
	local game = {
		dollars = opts.dollars == nil and 10 or opts.dollars,
		bankrupt_at = opts.bankrupt_at == nil and -5 or opts.bankrupt_at,
		chips = opts.chips == nil and 0 or opts.chips,
		STOP_USE = opts.stop_use,
		round = opts.round or 1,
		skips = 0,
		pack_choices = opts.pack_choices == nil and 1 or opts.pack_choices,
		blind_on_deck = opts.blind_on_deck,
		round_resets = {
			ante = opts.ante or 1,
			hands = opts.hands_per_round or 4,
			discards = opts.discards_per_round or 3,
			blind_choices = { Small = blind_key, Big = "bl_big", Boss = opts.boss_blind or "bl_hook" },
			blind_states = opts.blind_states or { Small = "Select", Big = "Select", Boss = "Upcoming" },
		},
		current_round = {
			hands_left = opts.hands_left == nil and 4 or opts.hands_left,
			discards_left = opts.discards_left == nil and 3 or opts.discards_left,
			hands_played = opts.hands_played == nil and 1 or opts.hands_played,
			reroll_cost = opts.reroll_cost == nil and 5 or opts.reroll_cost,
		},
		blind = {
			block_play = opts.block_play or false,
			pvp = opts.blind_pvp,
			config = { blind = { key = blind_key } },
		},
	}
	if opts.omit_blind then
		game.blind = nil
	end

	local hand = area({ cards = opts.hand or {}, limit = opts.hand_limit or 8, type = "hand" })
	local jokers = area({ cards = opts.jokers or {}, limit = opts.joker_slots or 5, type = "joker" })
	local consumeables = area({ cards = opts.consumeables or {}, limit = opts.consumable_slots or 2, type = "consumeable" })
	local shop_jokers = area({ cards = opts.shop_jokers or {}, limit = 2, type = "shop" })
	local shop_booster = area({ cards = opts.shop_boosters or {}, limit = 2, type = "shop" })
	local shop_vouchers = area({ cards = opts.shop_vouchers or {}, limit = 2, type = "shop" })
	local pack_cards = area({ cards = opts.pack_cards or {}, limit = 5, type = "pack" })

	local G = {
		GAME = game,
		SETTINGS = { tutorial_complete = opts.tutorial_complete == nil and true or opts.tutorial_complete },
		CONTROLLER = { locked = opts.locked or false },
		play = { cards = opts.play_cards or {} },
		hand = hand,
		jokers = jokers,
		consumeables = consumeables,
		shop_jokers = shop_jokers,
		shop_booster = shop_booster,
		shop_vouchers = shop_vouchers,
		pack_cards = pack_cards,
		discard = { config = { card_limit = opts.discard_limit or 5 } },
		P_BLINDS = {
			bl_small = { key = "bl_small" },
			bl_big = { key = "bl_big" },
			bl_hook = { key = "bl_hook" },
			bl_mp_nemesis = { key = "bl_mp_nemesis" },
		},
		FUNCS = funcs,
		blind_select = opts.blind_select,
		round_eval = opts.round_eval,
		STATE = opts.state or STATES.SELECTING_HAND,
		STATES = states,
	}
	if opts.omit_p_blinds then
		G.P_BLINDS = nil
	end

	local config = {
		ruleset = opts.ruleset == nil and "ruleset_mp_majorleague" or opts.ruleset,
		timer = opts.config_timer,
		disable_live_and_timer_hud = opts.config_hud_disabled,
		hide_score_until_played = opts.hide_score,
		enemy_location_disabled = opts.location_disabled == nil and true or opts.location_disabled,
	}
	local MP = {
		LOBBY = { code = opts.lobby_code == nil and "LOBBY1" or opts.lobby_code, config = config },
		GAME = {
			lives = opts.lives == nil and 4 or opts.lives,
			timer = opts.timer == nil and 180 or opts.timer,
			timer_started = opts.timer_started or false,
			ready_blind = opts.ready_blind or false,
			enemy = {
				info_received = opts.info_received or false,
				score_text = opts.score_text,
				hands = opts.enemy_hands,
				hands_text = opts.hands_text,
				lives = opts.enemy_lives,
				location = opts.enemy_location,
			},
		},
		SP = { ruleset = opts.ruleset == nil and "ruleset_mp_majorleague" or opts.ruleset },
	}
	if opts.omit_ruleset then
		config.ruleset = nil
		MP.SP.ruleset = nil
	end

	return {
		G = G,
		MP = MP,
		funcs = funcs,
		calls = calls,
		hand = hand,
		jokers = jokers,
		consumeables = consumeables,
	}
end

-- Injected monotonic clock for the executor's bounded stall timeout.
function Support.clock(start)
	local instance = { t = start or 0 }
	function instance.now()
		return instance.t
	end
	function instance.advance(delta)
		instance.t = instance.t + delta
		return instance.t
	end
	function instance.set(value)
		instance.t = value
	end
	return instance
end

function Support.bundle(repo_root)
	local codec = dofile(repo_root .. "/AISparring/ai/codec.lua")
	local observation_module = dofile(repo_root .. "/AISparring/ai/observation.lua")
	local actions_module = dofile(repo_root .. "/AISparring/ai/actions.lua")
	local StateReader = dofile(repo_root .. "/AISparring/integration/state_reader.lua")
	local EngineAdapter = dofile(repo_root .. "/AISparring/integration/engine_adapter.lua")
	local ProductionExecutor = dofile(repo_root .. "/AISparring/integration/production_executor.lua")
	local StateRevision = dofile(repo_root .. "/AISparring/integration/state_revision.lua")
	local obs = observation_module.factory(codec)
	local actions = actions_module.factory(obs, codec)
	local reader = StateReader.factory(obs)
	return {
		codec = codec,
		observation = observation_module,
		actions = actions,
		obs = obs,
		reader = reader,
		StateReader = StateReader,
		EngineAdapter = EngineAdapter,
		ProductionExecutor = ProductionExecutor,
		StateRevision = StateRevision,
	}
end

function Support.pipeline(bundle, engine, opts)
	opts = opts or {}
	local revision = bundle.StateRevision.factory()
	local adapter, adapter_code = bundle.EngineAdapter.factory({
		role = opts.role or "ai_staged",
		session = opts.session or "session1",
		codec = bundle.codec,
		revision = revision,
		G = engine.G,
		MP = engine.MP,
		target_selection = opts.target_selection,
	})
	local executor, executor_code = bundle.ProductionExecutor.factory({
		role = opts.role or "ai_staged",
		session = opts.session or "session1",
		adapter = adapter,
		reader = bundle.reader,
		revision = revision,
		G = engine.G,
		MP = engine.MP,
		element_for = opts.element_for,
		clock = opts.clock,
		stall_timeout = opts.stall_timeout,
	})
	return { revision = revision, adapter = adapter, executor = executor, adapter_code = adapter_code, executor_code = executor_code }
end

return Support
