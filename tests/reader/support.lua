local Support = {}

local function canary(log, name)
	return function(_, key)
		log[#log + 1] = name .. "." .. tostring(key)
		error("metatable canary invoked: " .. name .. "." .. tostring(key), 2)
	end
end

function Support.load(repo_root)
	local codec = dofile(repo_root .. "/AISparring/ai/codec.lua")
	local observation = dofile(repo_root .. "/AISparring/ai/observation.lua")
	local StateReader = dofile(repo_root .. "/AISparring/integration/state_reader.lua")
	local obs, code = observation.factory(codec)
	return { codec = codec, observation = observation, obs = obs, obs_code = code, StateReader = StateReader }
end

function Support.recording_observation()
	local handles = {}
	local last = nil
	local observation = {}
	function observation.observe(frame)
		last = frame
		local handle = setmetatable({}, { __metatable = "reader.test.handle" })
		handles[handle] = frame
		return handle
	end
	function observation.is_handle(value)
		return type(value) == "table" and handles[value] ~= nil
	end
	function observation.last_frame()
		return last
	end
	return observation
end

function Support.spy(real)
	local frames = {}
	local spy = {}
	function spy.observe(frame)
		frames[#frames + 1] = frame
		return real.observe(frame)
	end
	spy.is_handle = function(value)
		return real.is_handle(value)
	end
	spy.export = function(handle)
		return real.export(handle)
	end
	spy.canonical = function(handle)
		return real.canonical(handle)
	end
	spy.hash = function(handle)
		return real.hash(handle)
	end
	spy.frames = frames
	return spy
end

local STATES = {
	BLIND_SELECT = 13,
	SELECTING_HAND = 9,
	SHOP = 3,
	TAROT_PACK = 4,
	SPECTRAL_PACK = 5,
	PLANET_PACK = 6,
	STANDARD_PACK = 7,
	BUFFOON_PACK = 8,
	SMODS_BOOSTER_OPENED = 999,
	GAME_OVER = 12,
}

Support.STATES = STATES

Support.BY_PHASE = {
	BLIND_SELECTION = { state = STATES.BLIND_SELECT },
	PLAY_HAND = { state = STATES.SELECTING_HAND },
	DISCARD = { state = STATES.SELECTING_HAND },
	CONSUMABLE_SELECTION = { state = STATES.SELECTING_HAND },
	MULTIPLAYER_PVP = { state = STATES.SELECTING_HAND },
	SHOP = { state = STATES.SHOP },
	BOOSTER_SELECTION = { state = STATES.TAROT_PACK },
	MATCH_COMPLETE = { state = STATES.GAME_OVER },
}

local PHASE_HAND = {
	PLAY_HAND = true,
	DISCARD = true,
	MULTIPLAYER_PVP = true,
	CONSUMABLE_SELECTION = true,
	BOOSTER_SELECTION = true,
}

Support.PHASE_HAND = PHASE_HAND

function Support.engine_card(opts)
	opts = opts or {}
	local log = opts.log or {}
	local center = { key = opts.center or "c_king" }
	if opts.no_rank then
		center.no_rank = true
	end
	if opts.no_suit then
		center.no_suit = true
	end
	if opts.replace_base_card then
		center.replace_base_card = true
	end
	if opts.center_poison ~= nil then
		center.poison = opts.center_poison
	end
	local ability = {}
	if opts.effect ~= nil then
		ability.effect = opts.effect
	end
	if opts.ability_poison ~= nil then
		ability.poison = opts.ability_poison
	end
	local card = {}
	if opts.omit_facing ~= true then
		rawset(card, "facing", opts.facing == nil and "front" or opts.facing)
	end
	if opts.omit_sprite_facing ~= true then
		rawset(card, "sprite_facing", opts.sprite_facing == nil and "front" or opts.sprite_facing)
	end
	rawset(card, "config", { center = center })
	rawset(card, "ability", ability)
	rawset(card, "base", { rank = opts.base_rank or "P", suit = opts.base_suit or "POISON" })
	rawset(card, "sort_ID", 987654)
	if opts.canary then
		setmetatable(card, { __index = canary(log, opts.canary_name or "card") })
	end
	return card
end

function Support.card_record(opts)
	opts = opts or {}
	local rec = {}
	if opts.omit_face_down ~= true then
		if opts.face_down == nil then
			rec.face_down = false
		else
			rec.face_down = opts.face_down
		end
	end
	if opts.omit_shown ~= true then
		if opts.shown ~= nil then
			rec.shown = opts.shown
		else
			rec.shown = {
				center = true, rank = true, suit = true, edition = true, seal = true,
				kind = true, debuff = true, cost = true, sell_cost = true, visible_text = true,
			}
		end
	end
	if opts.ordinal ~= nil then
		rec.ordinal = opts.ordinal
	end
	local names = { "center", "rank", "suit", "kind", "edition", "seal" }
	for i = 1, #names do
		local name = names[i]
		if opts[name] ~= nil then
			rec[name] = opts[name]
		end
	end
	if opts.no_identity ~= true then
		if rec.center == nil and opts.suppress_center ~= true then
			rec.center = "c_king"
		end
		if rec.rank == nil and opts.suppress_rank ~= true then
			rec.rank = "K"
		end
		if rec.suit == nil and opts.suppress_suit ~= true then
			rec.suit = "Hearts"
		end
	end
	if opts.debuff ~= nil then
		rec.debuff = opts.debuff
	end
	if opts.cost ~= nil then
		rec.cost = opts.cost
	end
	if opts.sell_cost ~= nil then
		rec.sell_cost = opts.sell_cost
	end
	if opts.visible_text ~= nil then
		rec.visible_text = opts.visible_text
	end
	return rec
end

function Support.opponent(opts)
	opts = opts or {}
	local out = { certified = opts.certified == nil and true or opts.certified }
	local flags = { "score_visible", "hands_visible", "lives_visible", "location_visible", "timer_visible" }
	for i = 1, #flags do
		if opts[flags[i]] ~= nil then
			out[flags[i]] = opts[flags[i]]
		end
	end
	local values = { "displayed_score", "hands", "lives", "location", "timer" }
	for i = 1, #values do
		if opts[values[i]] ~= nil then
			out[values[i]] = opts[values[i]]
		end
	end
	return out
end

local function auto_records(cards, explicit, record_opts)
	if explicit == false then
		return nil
	end
	if explicit ~= nil then
		return explicit
	end
	local out = {}
	for i = 1, #cards do
		out[i] = Support.card_record(record_opts)
	end
	return out
end

function Support.build(opts)
	opts = opts or {}
	local log = opts.log or {}
	local phase = opts.phase or "PLAY_HAND"
	local by = Support.BY_PHASE[phase]
	local state = opts.state
	if state == nil then
		state = by and by.state or STATES.SELECTING_HAND
	end

	local hand = opts.hand or {}
	local jokers = opts.jokers or {}
	local consumeables = opts.consumeables or {}
	local shop_jokers = opts.shop_jokers or {}
	local shop_boosters = opts.shop_boosters or {}
	local shop_vouchers = opts.shop_vouchers or {}
	local pack_cards = opts.pack_cards or {}

	local game = {}
	rawset(game, "dollars", opts.dollars == nil and 10 or opts.dollars)
	rawset(game, "bankrupt_at", opts.bankrupt_at == nil and -5 or opts.bankrupt_at)
	rawset(game, "round", opts.round == nil and 2 or opts.round)
	rawset(game, "round_resets", { ante = opts.ante == nil and 3 or opts.ante })
	rawset(game, "current_round", {
		hands_left = opts.hands_left == nil and 4 or opts.hands_left,
		discards_left = opts.discards_left == nil and 3 or opts.discards_left,
		hands_played = opts.hands_played == nil and 1 or opts.hands_played,
	})
	if opts.blind ~= nil then
		rawset(game, "blind", opts.blind)
	elseif opts.blind_key ~= nil or opts.blind_pvp ~= nil then
		rawset(game, "blind", {
			config = { blind = { key = opts.blind_key } },
			pvp = opts.blind_pvp,
		})
	end
	if opts.game_canary then
		setmetatable(game, { __index = canary(log, "GAME") })
	end

	local states = {}
	for key, value in next, STATES do
		states[key] = value
	end
	if opts.states_override ~= nil then
		states = opts.states_override
	end

	local G = {}
	rawset(G, "GAME", game)
	rawset(G, "STATE", state)
	if opts.omit_states ~= true then
		rawset(G, "STATES", states)
	end
	if opts.omit_hand ~= true then
		rawset(G, "hand", { cards = hand })
	end
	if opts.omit_jokers ~= true then
		rawset(G, "jokers", { cards = jokers })
	end
	if opts.omit_consumeables ~= true then
		rawset(G, "consumeables", { cards = consumeables })
	end
	if opts.omit_shop_jokers ~= true then
		rawset(G, "shop_jokers", { cards = shop_jokers })
	end
	if opts.omit_shop_booster ~= true then
		rawset(G, "shop_booster", { cards = shop_boosters })
	end
	if opts.omit_shop_vouchers ~= true then
		rawset(G, "shop_vouchers", { cards = shop_vouchers })
	end
	if opts.omit_pack_cards ~= true then
		rawset(G, "pack_cards", { cards = pack_cards })
	end
	if opts.g_canary then
		setmetatable(G, { __index = canary(log, "G") })
	end

	local enemy = {}
	rawset(enemy, "info_received", opts.info_received)
	rawset(enemy, "score_text", opts.score_text)
	rawset(enemy, "hands_text", opts.hands_text)
	rawset(enemy, "real_score", opts.real_score)
	rawset(enemy, "highest_score", opts.highest_score)
	rawset(enemy, "last_timer", opts.last_timer)
	if opts.enemy_canary then
		setmetatable(enemy, { __index = canary(log, "enemy") })
	end
	local mp_game = { enemy = enemy }
	rawset(mp_game, "pvp_timer_order", opts.pvp_timer_order)

	local config = {
		timer = opts.config_timer,
		disable_live_and_timer_hud = opts.config_hud_disabled,
		hide_score_until_played = opts.hide_score,
		enemy_location_disabled = opts.location_disabled,
	}
	local lobby = { code = opts.lobby_code, config = config }
	local MP = {}
	rawset(MP, "GAME", mp_game)
	rawset(MP, "LOBBY", lobby)
	if opts.mp_canary then
		setmetatable(MP, { __index = canary(log, "MP") })
	end

	local runtime = {
		epoch = opts.epoch == nil and 1 or opts.epoch,
		G = G,
		MP = MP,
	}
	if opts.omit_role ~= true then
		runtime.role = opts.role == nil and "ai_staged" or opts.role
	end

	local view = Support.build_view(opts, phase, {
		hand = hand, jokers = jokers, consumeables = consumeables,
		shop_jokers = shop_jokers, shop_boosters = shop_boosters,
		shop_vouchers = shop_vouchers, pack_cards = pack_cards,
	})

	return { G = G, MP = MP, runtime = runtime, ui_view = view, log = log, phase = phase }
end

function Support.build_view(opts, phase, engine)
	local view = {}
	local epoch = opts.epoch == nil and 1 or opts.epoch
	view.epoch = opts.view_epoch == nil and epoch or opts.view_epoch
	view.phase = opts.view_phase == nil and phase or opts.view_phase

	view.match = {
		ruleset = opts.ruleset == nil and "standard" or opts.ruleset,
		blind = opts.blind,
		timer = opts.match_timer,
		timer_visible = opts.match_timer_visible,
		lives = opts.match_lives,
		hands_per_round = opts.hands_per_round,
		discards_per_round = opts.discards_per_round,
		hand_size = opts.hand_size,
		joker_slots = opts.joker_slots,
		consumable_slots = opts.consumable_slots,
	}

	local hand_visible = opts.hand_visible
	if hand_visible == nil then
		hand_visible = PHASE_HAND[phase] == true and #engine.hand > 0
	end

	view.self = {
		hand_visible = hand_visible,
		current_score = opts.current_score,
		blind_requirement = opts.blind_requirement,
		cards = {
			hand = auto_records(engine.hand, opts.hand_records, opts.hand_record_opts),
			joker = auto_records(engine.jokers, opts.joker_records, opts.joker_record_opts),
			consumable = auto_records(engine.consumeables, opts.consumable_records, opts.consumable_record_opts),
		},
	}
	if opts.self_override ~= nil then
		view.self = opts.self_override
	end
	if opts.deck ~= nil then
		view.self.deck = opts.deck
	end

	if opts.opponent ~= nil then
		view.opponent = opts.opponent
	end
	if opts.recognition ~= nil then
		view.recognition = opts.recognition
	end

	if opts.context ~= nil then
		view.context = opts.context
	end
	if opts.certificates ~= nil then
		view.certificates = opts.certificates
	end

	if phase == "SHOP" or opts.shop ~= nil then
		view.shop = opts.shop or {
			reroll_cost = 5,
			items = auto_records(engine.shop_jokers, opts.shop_records, opts.shop_record_opts),
			boosters = auto_records(engine.shop_boosters, opts.shop_booster_records, opts.shop_booster_record_opts),
			vouchers = auto_records(engine.shop_vouchers, opts.voucher_records, opts.voucher_record_opts),
		}
	end
	if phase == "BOOSTER_SELECTION" or opts.booster ~= nil then
		view.booster = opts.booster or {
			kind = "buffoon",
			choices = 1,
			skips = 0,
			cards = auto_records(engine.pack_cards, opts.booster_records, opts.booster_record_opts),
		}
	end
	if phase == "CONSUMABLE_SELECTION" or opts.consumable_target ~= nil then
		view.consumable_target = opts.consumable_target or {
			source = Support.card_record({ ordinal = 1 }),
			targets = {},
		}
	end
	return view
end

-- I3: instrument the test environment's global `rawget` so a read of a
-- forbidden raw field on a *tracked engine object* is detected directly,
-- instead of relying on an `__index` canary (which rawget never triggers).
local tracked = {}
local function rget(obj, key)
	if type(obj) ~= "table" then
		return nil
	end
	return rawget(obj, key)
end

local FORBIDDEN_KEYS = {
	deck = true, seed = true, seeds = true,
	real_score = true, highest_score = true, last_timer = true,
	pvp_timer_order = true, spent_in_shop = true, sells = true,
	sells_per_ante = true, mod_hash = true, hardware_id = true,
}

local function track(obj)
	if type(obj) == "table" then
		tracked[obj] = true
	end
end

function Support.track_engine(engine)
	track(engine.G)
	track(engine.MP)
	local game = rget(engine.G, "GAME")
	track(game)
	local mp_game = rget(engine.MP, "GAME")
	track(mp_game)
	track(rget(mp_game, "enemy"))
	track(rget(engine.MP, "LOBBY"))
	track(rget(game, "current_round"))
	track(rget(game, "round_resets"))
	track(rget(game, "blind"))
	local areas = {
		rget(engine.G, "hand"), rget(engine.G, "jokers"), rget(engine.G, "consumeables"),
		rget(engine.G, "shop_jokers"), rget(engine.G, "shop_booster"),
		rget(engine.G, "shop_vouchers"), rget(engine.G, "pack_cards"),
	}
	for i = 1, #areas do
		local area = areas[i]
		if type(area) == "table" then
			track(area)
			track(rawget(area, "cards"))
		end
	end
end

function Support.install_rawget_spy()
	local real = rawget
	local hits = {}
	_G.rawget = function(obj, key)
		if FORBIDDEN_KEYS[key] == true and tracked[obj] == true then
			hits[#hits + 1] = tostring(key)
		end
		return real(obj, key)
	end
	return {
		hits = hits,
		restore = function()
			_G.rawget = real
		end,
	}
end

return Support
