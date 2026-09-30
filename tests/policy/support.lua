local Support = {}

Support.DIFFICULTIES = { "rookie", "competitive", "major_league", "expert" }

local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then
		return nil
	end
	local content = handle:read("*a")
	handle:close()
	return content
end

local cached = nil

function Support.env(repo)
	if cached ~= nil then
		return cached
	end
	local env = {}
	env.codec = dofile(repo .. "/AISparring/ai/codec.lua")
	env.observation = dofile(repo .. "/AISparring/ai/observation.lua")
	env.actions = dofile(repo .. "/AISparring/ai/actions.lua")
	env.baseline = dofile(repo .. "/AISparring/ai/baseline_policy.lua")
	env.policy_env = dofile(repo .. "/tools/lua/policy_env.lua")
	local configured = env.policy_env.configure(
		read_file(repo .. "/AISparring/ai/codec.lua"),
		read_file(repo .. "/AISparring/ai/observation.lua"),
		read_file(repo .. "/AISparring/ai/actions.lua"))
	assert(configured == true, "policy_env_configure")
	env.obs = assert(env.observation.factory(env.codec), "observation_factory")
	env.acts = assert(env.actions.factory(env.obs, env.codec), "actions_factory")
	cached = env
	return env
end

function Support.match()
	return {
		ruleset = "majorleague",
		blind = "Small Blind",
		timer = "120",
		ante = 1,
		round = 1,
		lives = 4,
		hands_per_round = 4,
		discards_per_round = 3,
		hand_size = 8,
		joker_slots = 5,
		consumable_slots = 2,
	}
end

local function base_self()
	return {
		money = 10,
		credit_limit = 0,
		hands = 4,
		discards = 3,
		current_score = "0",
		-- Low enough that four weak plays still suffice, so these frames test
		-- play-vs-play and discard-vs-play choices, not the requirement logic
		-- (which has its own frames below).
		blind_requirement = "100",
		hand_visible = false,
		jokers = {},
		consumables = {},
		vouchers = {},
		tags = {},
		deck = { total = 52 },
	}
end

local function base_context()
	return { blocked = false, timer_expired = false }
end

local function card(rank, suit, center)
	return { kind = "card", rank = rank, suit = suit, center = center or "c_base", face_down = false }
end

local function play_cert(refs)
	return { type = "PLAY_CARDS", certified = true, card_refs = refs }
end

local function discard_cert(refs)
	return { type = "DISCARD_CARDS", certified = true, card_refs = refs }
end

local function handed(phase, hand, certs, extra)
	local self = base_self()
	self.hand_visible = true
	self.hand = hand
	if extra ~= nil then
		if extra.money ~= nil then
			self.money = extra.money
		end
		if extra.discards ~= nil then
			self.discards = extra.discards
		end
		if extra.jokers ~= nil then
			self.jokers = extra.jokers
		end
	end
	local context = base_context()
	context.max_play = 5
	context.max_discard = 5
	return {
		schema_version = 1,
		phase = phase,
		match = Support.match(),
		self = self,
		context = context,
		certificates = { version = 1, items = certs },
	}
end

local function pair_hand()
	return {
		card("Ace", "Spades", "c_ace"),
		card("Ace", "Hearts", "c_ace"),
		card("King", "Clubs", "c_king"),
		card("Queen", "Diamonds", "c_queen"),
		card("Jack", "Spades", "c_jack"),
	}
end

function Support.blind_frame()
	return {
		schema_version = 1,
		phase = "BLIND_SELECTION",
		match = Support.match(),
		self = base_self(),
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "SELECT_BLIND", certified = true },
			{ type = "SKIP_BLIND", certified = true },
		} },
	}
end

-- Readied at the PvP blind with the Multiplayer timer button lit: the only
-- certified choice is START_TIMER (plus optional Joker reorders).
function Support.timer_frame()
	local frame = Support.blind_frame()
	frame.certificates.items = { { type = "START_TIMER", certified = true } }
	return frame
end

-- Requirement-aware frames: a made pair of Aces (est. 64 with no Jokers) versus
-- discarding the rest, at a chosen remaining requirement.
function Support.requirement_frame(requirement, hands, discards, phase, jokers)
	local frame = handed(phase or "PLAY_HAND", pair_hand(), {
		play_cert({ "hand:1", "hand:2" }),
		play_cert({ "hand:5" }),
		discard_cert({ "hand:3", "hand:4", "hand:5" }),
	})
	frame.self.blind_requirement = requirement
	frame.self.hands = hands
	frame.self.discards = discards
	if jokers ~= nil then
		frame.self.jokers = jokers
	end
	return frame
end

function Support.joker(center)
	return { kind = "joker", center = center, face_down = false }
end

function Support.blind_zero_hands_frame()
	local frame = Support.blind_frame()
	frame.self.hands = 0
	return frame
end

function Support.play_frame()
	return handed("PLAY_HAND", pair_hand(), {
		play_cert({ "hand:1", "hand:2" }),
		discard_cert({ "hand:3", "hand:4", "hand:5" }),
		{ type = "REORDER_HAND", certified = true, order = { "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" } },
	})
end

function Support.pair_frame()
	return handed("PLAY_HAND", pair_hand(), {
		play_cert({ "hand:1", "hand:2" }),
		play_cert({ "hand:3", "hand:4", "hand:5" }),
		discard_cert({ "hand:3", "hand:4", "hand:5" }),
	})
end

function Support.flush_frame()
	return handed("PLAY_HAND", {
		card("2", "Hearts", "c_two"),
		card("3", "Hearts", "c_three"),
		card("4", "Hearts", "c_four"),
		card("5", "Hearts", "c_five"),
		card("7", "Hearts", "c_seven"),
		card("2", "Clubs", "c_two"),
	}, {
		play_cert({ "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }),
		play_cert({ "hand:1", "hand:6" }),
		play_cert({ "hand:5" }),
	})
end

function Support.ace_low_frame()
	return handed("PLAY_HAND", {
		card("Ace", "Spades", "c_ace"),
		card("2", "Hearts", "c_two"),
		card("3", "Clubs", "c_three"),
		card("4", "Diamonds", "c_four"),
		card("5", "Spades", "c_five"),
		card("9", "Hearts", "c_nine"),
	}, {
		play_cert({ "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }),
		play_cert({ "hand:1" }),
		play_cert({ "hand:1", "hand:2" }),
	})
end

function Support.ace_high_frame()
	return handed("PLAY_HAND", {
		card("10", "Spades", "c_ten"),
		card("Jack", "Hearts", "c_jack"),
		card("Queen", "Clubs", "c_queen"),
		card("King", "Diamonds", "c_king"),
		card("Ace", "Spades", "c_ace"),
		card("3", "Hearts", "c_three"),
	}, {
		play_cert({ "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }),
		play_cert({ "hand:1" }),
	})
end

function Support.nonadjacent_pair_frame()
	return handed("PLAY_HAND", {
		card("8", "Clubs", "c_eight"),
		card("King", "Diamonds", "c_king"),
		card("8", "Spades", "c_eight"),
		card("2", "Hearts", "c_two"),
		card("7", "Clubs", "c_seven"),
	}, {
		play_cert({ "hand:1", "hand:3" }),
		play_cert({ "hand:2", "hand:4" }),
		play_cert({ "hand:3" }),
	})
end

function Support.high_card_frame()
	return handed("PLAY_HAND", {
		card("Ace", "Spades", "c_ace"),
		card("King", "Hearts", "c_king"),
		card("9", "Clubs", "c_nine"),
		card("7", "Diamonds", "c_seven"),
		card("3", "Spades", "c_three"),
	}, {
		play_cert({ "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }),
		discard_cert({ "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }),
	})
end

function Support.preserve_frame()
	return handed("DISCARD", pair_hand(), {
		discard_cert({ "hand:1", "hand:2" }),
		discard_cert({ "hand:3", "hand:4", "hand:5" }),
	})
end

function Support.discard_only_frame()
	return handed("DISCARD", {
		card("Ace", "Spades", "c_ace"),
		card("King", "Hearts", "c_king"),
		card("9", "Clubs", "c_nine"),
		card("7", "Diamonds", "c_seven"),
		card("3", "Spades", "c_three"),
	}, {
		discard_cert({ "hand:1", "hand:2", "hand:3", "hand:4", "hand:5" }),
		discard_cert({ "hand:1" }),
	})
end

function Support.pvp_frame()
	return handed("MULTIPLAYER_PVP", pair_hand(), {
		play_cert({ "hand:1", "hand:2" }),
		discard_cert({ "hand:1", "hand:2" }),
	})
end

function Support.shop_frame()
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = base_self(),
		shop = {
			reroll_cost = 5,
			items = {
				{ kind = "joker", center = "c_joker", cost = 5, sell_cost = 2, face_down = false },
			},
			vouchers = {},
			boosters = {
				{ kind = "booster", center = "p_standard", cost = 4, sell_cost = 2, face_down = false },
			},
		},
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
			{ type = "OPEN_BOOSTER", certified = true, item_ref = "shop_booster:1", capacity_ok = true },
			{ type = "REROLL", certified = true },
			{ type = "LEAVE_SHOP", certified = true },
		} },
	}
end

function Support.two_joker_frame()
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = (function()
			local self = base_self()
			self.money = 30
			return self
		end)(),
		shop = {
			reroll_cost = 5,
			items = {
				{ kind = "joker", center = "c_joker", cost = 25, sell_cost = 12, face_down = false },
				{ kind = "joker", center = "c_joker", cost = 3, sell_cost = 1, face_down = false },
			},
			vouchers = {},
			boosters = {},
		},
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:2", capacity_ok = true },
			{ type = "LEAVE_SHOP", certified = true },
		} },
	}
end

function Support.tight_shop_frame()
	local self = base_self()
	self.money = 5
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = self,
		shop = {
			reroll_cost = 5,
			items = {
				{ kind = "card", rank = "Ace", suit = "Spades", center = "c_ace", cost = 5, sell_cost = 2, face_down = false },
			},
			vouchers = {},
			boosters = {},
		},
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "BUY_ITEM", certified = true, item_ref = "shop:1" },
			{ type = "REROLL", certified = true },
			{ type = "LEAVE_SHOP", certified = true },
		} },
	}
end

local function reroll_frame_with_money(amount)
	local self = base_self()
	self.money = amount
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = self,
		shop = { reroll_cost = 5, items = {}, vouchers = {}, boosters = {} },
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "REROLL", certified = true },
			{ type = "LEAVE_SHOP", certified = true },
		} },
	}
end

function Support.rich_reroll_frame()
	return reroll_frame_with_money(60)
end

function Support.poor_reroll_frame()
	return reroll_frame_with_money(5)
end

function Support.reroll_frame()
	local frame = reroll_frame_with_money(10)
	frame.certificates = { version = 1, items = {
		{ type = "REROLL", certified = true },
	} }
	return frame
end

function Support.voucher_frame()
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = base_self(),
		shop = {
			reroll_cost = 5,
			items = {},
			vouchers = { { center = "v_seed_money", cost = 5, face_down = false } },
			boosters = {},
		},
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "BUY_VOUCHER", certified = true, voucher_ref = "shop_voucher:1" },
		} },
	}
end

function Support.booster_shop_frame()
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = base_self(),
		shop = {
			reroll_cost = 5,
			items = {},
			vouchers = {},
			boosters = {
				{ kind = "booster", center = "p_standard", cost = 4, sell_cost = 2, face_down = false },
			},
		},
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "OPEN_BOOSTER", certified = true, item_ref = "shop_booster:1", capacity_ok = true },
		} },
	}
end

function Support.booster_frame()
	return {
		schema_version = 1,
		phase = "BOOSTER_SELECTION",
		match = Support.match(),
		self = base_self(),
		booster = {
			kind = "standard",
			choices = 1,
			skips = 0,
			cards = {
				card("Ace", "Spades", "c_ace"),
			},
		},
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { "booster:1" } },
			{ type = "SKIP_BOOSTER", certified = true },
		} },
	}
end

function Support.skip_booster_frame()
	local frame = Support.booster_frame()
	frame.certificates = { version = 1, items = {
		{ type = "SKIP_BOOSTER", certified = true },
	} }
	return frame
end

local function consumable_selection_frame(min_targets, max_targets, certs)
	local self = base_self()
	self.consumables = { { center = "c_hermit", face_down = false } }
	local context = base_context()
	context.target_selection = true
	context.min_targets = min_targets
	context.max_targets = max_targets
	return {
		schema_version = 1,
		phase = "CONSUMABLE_SELECTION",
		match = Support.match(),
		self = self,
		context = context,
		consumable_target = {
			source = { center = "c_hermit", face_down = false },
			source_ref = "consumable:1",
			min_targets = min_targets,
			max_targets = max_targets,
			targets = {
				card("Ace", "Spades", "c_ace"),
				card("King", "Hearts", "c_king"),
			},
		},
		certificates = { version = 1, items = certs },
	}
end

function Support.consumable_frame()
	return consumable_selection_frame(0, 1, {
		{ type = "USE_CONSUMABLE", certified = true, source_ref = "consumable:1", target_refs = {} },
		{ type = "USE_CONSUMABLE", certified = true, source_ref = "consumable:1", target_refs = { "target:1" } },
		{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:1" } },
	})
end

function Support.consumable_commit_frame()
	return consumable_selection_frame(1, 1, {
		{ type = "USE_CONSUMABLE", certified = true, source_ref = "consumable:1", target_refs = { "target:1" } },
		{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:1" } },
	})
end

function Support.consumable_highlight_only_frame()
	return consumable_selection_frame(1, 2, {
		{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:1" } },
	})
end

function Support.consumable_multi_target_frame()
	return consumable_selection_frame(2, 2, {
		{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:1" } },
		{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:2" } },
	})
end

function Support.sell_frame()
	local self = base_self()
	self.jokers = { { center = "c_joker", face_down = false } }
	return {
		schema_version = 1,
		phase = "PLAY_HAND",
		match = Support.match(),
		self = self,
		context = base_context(),
		certificates = { version = 1, items = {
			{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		} },
	}
end

local function joker_entity(center, extra)
	local out = { face_down = false, center = center }
	if extra ~= nil then
		for key, value in next, extra do
			out[key] = value
		end
	end
	return out
end

local function refs_from(order, zone)
	local refs = {}
	for i = 1, #order do
		refs[i] = zone .. ":" .. order[i]
	end
	return refs
end

-- Adapter-shaped joker ordering frame. `centers` are visible joker centers in
-- their current order; `index_orders` are the offered permutations expressed as
-- 1-based index arrays (the adapter offers reverse plus each adjacent swap).
function Support.joker_order_frame(centers, index_orders)
	local self = base_self()
	local list = {}
	for i = 1, #centers do
		list[i] = joker_entity(centers[i])
	end
	self.jokers = list
	local items = {}
	for i = 1, #index_orders do
		items[#items + 1] = {
			type = "REORDER_JOKERS",
			certified = true,
			order = refs_from(index_orders[i], "joker"),
		}
	end
	items[#items + 1] = { type = "LEAVE_SHOP", certified = true }
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = self,
		context = base_context(),
		certificates = { version = 1, items = items },
	}
end

function Support.jokers_with_play_frame()
	local frame = Support.pair_frame()
	frame.self.jokers = { joker_entity("j_cavendish"), joker_entity("j_joker") }
	frame.certificates.items[#frame.certificates.items + 1] = {
		type = "REORDER_JOKERS",
		certified = true,
		order = { "joker:2", "joker:1" },
	}
	return frame
end

-- Adapter-shaped PvP wait frame: no hands left, so the adapter emits no
-- PLAY_CARDS but does emit DISCARD, SELL_*, REORDER_HAND and REORDER_JOKERS.
function Support.adapter_pvp_zero_hands_frame()
	local self = base_self()
	self.hands = 0
	self.hand_visible = true
	self.hand = pair_hand()
	self.jokers = { joker_entity("j_unrecognized_one"), joker_entity("j_unrecognized_two") }
	self.consumables = { { center = "c_hermit", face_down = false } }
	local context = base_context()
	context.max_play = 5
	context.max_discard = 5
	return {
		schema_version = 1,
		phase = "MULTIPLAYER_PVP",
		match = Support.match(),
		self = self,
		context = context,
		certificates = { version = 1, items = {
			{ type = "DISCARD_CARDS", certified = true, card_refs = { "hand:1", "hand:2" } },
			{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
			{ type = "SELL_JOKER", certified = true, joker_ref = "joker:2" },
			{ type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:1" },
			{ type = "REORDER_HAND", certified = true, order = { "hand:2", "hand:1", "hand:3", "hand:4", "hand:5" } },
			{ type = "REORDER_JOKERS", certified = true, order = { "joker:2", "joker:1" } },
		} },
	}
end

local function consumable_selection_cards()
	return {
		card("Ace", "Spades", "c_ace"),
		card("King", "Hearts", "c_king"),
	}
end

-- Adapter-shaped CONSUMABLE_SELECTION frame with min_targets = 2: the generator
-- drops every single-target certificate, so only SELL_* and REORDER_* remain.
function Support.adapter_consumable_multi_target_frame()
	local self = base_self()
	local hand = consumable_selection_cards()
	self.hand_visible = true
	self.hand = hand
	self.consumables = { { center = "c_hermit", face_down = false } }
	self.jokers = { joker_entity("j_unrecognized_one"), joker_entity("j_unrecognized_two") }
	local context = base_context()
	context.target_selection = true
	context.min_targets = 2
	context.max_targets = 2
	return {
		schema_version = 1,
		phase = "CONSUMABLE_SELECTION",
		match = Support.match(),
		self = self,
		context = context,
		consumable_target = {
			source = { center = "c_hermit", face_down = false },
			source_ref = "consumable:1",
			min_targets = 2,
			max_targets = 2,
			targets = consumable_selection_cards(),
		},
		certificates = { version = 1, items = {
			{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:1" } },
			{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:2" } },
			{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
			{ type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:1" },
			{ type = "REORDER_HAND", certified = true, order = { "hand:2", "hand:1" } },
			{ type = "REORDER_JOKERS", certified = true, order = { "joker:2", "joker:1" } },
		} },
	}
end

-- Adapter-shaped CONSUMABLE_SELECTION frame with no visible target bounds: the
-- generator drops every targeted candidate, leaving only SELL_*.
function Support.consumable_missing_bounds_frame()
	local self = base_self()
	self.consumables = { { center = "c_hermit", face_down = false } }
	self.jokers = { joker_entity("j_unrecognized_one") }
	local context = base_context()
	context.target_selection = true
	return {
		schema_version = 1,
		phase = "CONSUMABLE_SELECTION",
		match = Support.match(),
		self = self,
		context = context,
		consumable_target = {
			source = { center = "c_hermit", face_down = false },
			source_ref = "consumable:1",
			targets = { card("Ace", "Spades", "c_ace") },
		},
		certificates = { version = 1, items = {
			{ type = "USE_CONSUMABLE", certified = true, source_ref = "consumable:1", target_refs = { "target:1" } },
			{ type = "SELECT_TARGETS", certified = true, target_refs = { "target:1" } },
			{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
			{ type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:1" },
		} },
	}
end

function Support.tie_frame()
	return handed("PLAY_HAND", {
		card("10", "Spades", "c_ten"),
		card("10", "Hearts", "c_ten"),
	}, {
		play_cert({ "hand:1" }),
		play_cert({ "hand:2" }),
	})
end

function Support.reorder_frame()
	return handed("PLAY_HAND", {
		card("Ace", "Spades", "c_ace"),
		card("King", "Hearts", "c_king"),
	}, {
		{ type = "REORDER_HAND", certified = true, order = { "hand:1", "hand:2" } },
	})
end

function Support.reorder_reverse_frame()
	return handed("PLAY_HAND", {
		card("Ace", "Spades", "c_ace"),
		card("King", "Hearts", "c_king"),
	}, {
		{ type = "REORDER_HAND", certified = true, order = { "hand:2", "hand:1" } },
	})
end

function Support.reorder_adjacent_frame()
	return handed("PLAY_HAND", {
		card("Ace", "Spades", "c_ace"),
		card("King", "Hearts", "c_king"),
		card("Queen", "Clubs", "c_queen"),
	}, {
		{ type = "REORDER_HAND", certified = true, order = { "hand:2", "hand:1", "hand:3" } },
		{ type = "REORDER_HAND", certified = true, order = { "hand:1", "hand:3", "hand:2" } },
		{ type = "REORDER_HAND", certified = true, order = { "hand:3", "hand:2", "hand:1" } },
	})
end

function Support.play_with_noop_reorder_frame()
	return handed("PLAY_HAND", {
		card("Ace", "Spades", "c_ace"),
		card("King", "Hearts", "c_king"),
	}, {
		{ type = "REORDER_HAND", certified = true, order = { "hand:1", "hand:2" } },
		play_cert({ "hand:1", "hand:2" }),
	})
end

function Support.poisoned_pair_frame()
	local frame = Support.pair_frame()
	frame.deck_preview = { seed = "AAPL-1234", order = { "Ace", "2", "3" } }
	frame.future_shop = { items = { { kind = "joker", cost = 0 } } }
	frame.rng_state = 987654321
	frame.self.deck = { total = 52, seed = "SEED", by_suit = { Spades = 13 } }
	frame.self.secret_hand = { card("Ace", "Spades", "c_ace") }
	return frame
end

function Support.complete_frame()
	return { schema_version = 1, phase = "MATCH_COMPLETE", match = Support.match() }
end

function Support.blocked_frame()
	local frame = Support.play_frame()
	frame.context.blocked = true
	return frame
end

function Support.observe(env, frame)
	local handle, code = env.obs.observe(frame)
	assert(handle ~= nil, tostring(code))
	return handle
end

function Support.export(env, frame)
	local handle = Support.observe(env, frame)
	local plain, code = env.obs.export(handle)
	assert(plain ~= nil, tostring(code))
	return plain
end

function Support.generate(env, frame)
	local handle = assert(env.obs.observe(frame))
	local list, code = env.acts.generate(handle)
	assert(list ~= nil, tostring(code))
	return list
end

function Support.source(env, difficulty)
	local source, code = env.baseline.source(difficulty)
	assert(source ~= nil, tostring(code))
	return source
end

function Support.run_source(env, source, frame)
	return env.policy_env.run(source, Support.export(env, frame))
end

function Support.run(env, difficulty, frame)
	return Support.run_source(env, Support.source(env, difficulty), frame)
end

function Support.choose_id(env, difficulty, frame)
	local result = Support.run(env, difficulty, frame)
	if result.ok ~= true then
		return "<" .. tostring(result.code) .. ">"
	end
	return result.action.id
end

function Support.member_of(list, id)
	for i = 1, #list do
		if list[i].id == id then
			return true
		end
	end
	return false
end

function Support.find_candidate(list, id)
	for i = 1, #list do
		if list[i].id == id then
			return list[i]
		end
	end
	return nil
end

function Support.find_by_refs(list, kind, refs)
	for i = 1, #list do
		local candidate = list[i]
		if candidate.type == kind then
			local actual = candidate.card_refs or candidate.target_refs or candidate.order
			if actual ~= nil and #actual == #refs then
				local same = true
				for j = 1, #refs do
					if actual[j] ~= refs[j] then
						same = false
					end
				end
				if same then
					return candidate
				end
			end
		end
	end
	return nil
end

function Support.same_refs(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function strip_comments(source)
	local out = {}
	local i = 1
	local n = #source
	while i <= n do
		local c = string.sub(source, i, i)
		if c == "-" and string.sub(source, i + 1, i + 1) == "-" then
			local eq = nil
			if string.sub(source, i + 2, i + 2) == "[" then
				local j = i + 3
				while string.sub(source, j, j) == "=" do
					j = j + 1
				end
				if string.sub(source, j, j) == "[" then
					eq = string.sub(source, i + 3, j - 1)
				end
			end
			if eq ~= nil then
				local close = "]" .. eq .. "]"
				local k = string.find(source, close, i + 4 + #eq, true)
				if k ~= nil then
					i = k + #close
				else
					i = n + 1
				end
			else
				local k = string.find(source, "\n", i + 2, true)
				if k ~= nil then
					i = k + 1
				else
					i = n + 1
				end
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

local function is_word_byte(byte)
	if byte == nil then
		return false
	end
	return (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95
end

local function has_ident(source, name)
	local start = 1
	while true do
		local first, last = string.find(source, name, start, true)
		if first == nil then
			return false
		end
		if not is_word_byte(string.byte(source, first - 1)) and not is_word_byte(string.byte(source, last + 1)) then
			return true
		end
		start = first + 1
	end
end

local function has_dotted(source, library, name)
	local start = 1
	while true do
		local first, last = string.find(source, library, start, true)
		if first == nil then
			return false
		end
		if not is_word_byte(string.byte(source, first - 1)) and not is_word_byte(string.byte(source, last + 1)) then
			local cursor = last + 1
			while string.sub(source, cursor, cursor) == " " do
				cursor = cursor + 1
			end
			if string.sub(source, cursor, cursor) == "." then
				cursor = cursor + 1
				while string.sub(source, cursor, cursor) == " " do
					cursor = cursor + 1
				end
				local after_name = cursor + #name
				if string.sub(source, cursor, after_name - 1) == name then
					if not is_word_byte(string.byte(source, after_name)) then
						return true
					end
				end
			end
		end
		start = first + 1
	end
end

function Support.forbidden_tokens()
	return {
		{ "require", "require" },
		{ "dofile", "dofile" },
		{ "loadstring", "loadstring" },
		{ "load", "load" },
		{ "setfenv", "setfenv" },
		{ "getfenv", "getfenv" },
		{ "rawset", "rawset" },
		{ "collectgarbage", "collectgarbage" },
		{ "package", "package" },
		{ "Client", "client" },
		{ "SMODS", "smods" },
		{ "_G", "global_table" },
		{ "G", "single_letter_g" },
		{ "MP", "mp" },
	}
end

local function dotted_tokens()
	return {
		{ "debug", "print", "debug" },
		{ "debug", "sethook", "debug" },
		{ "io", "open", "io" },
		{ "io", "write", "io" },
		{ "os", "exit", "os" },
		{ "os", "time", "os" },
		{ "os", "getenv", "os" },
		{ "love", "graphics", "love" },
		{ "math", "random", "math_random" },
		{ "math", "randomseed", "math_randomseed" },
		{ "string", "dump", "string_dump" },
	}
end

-- SHOP slot-pressure fixtures. The match offers five joker slots. A full board is
-- five visible jokers; the upgrade is a same-center copy with a recognized
-- non-negative edition (a strict upgrade over an un-editioned copy). These frames
-- are schema-honest: they are observed, exported and regenerated through the real
-- observation/actions modules before the policy ever sees them.
local function full_board(extra)
	local list = {
		joker_entity("j_cavendish"),
		joker_entity("j_joker"),
		joker_entity("j_blueprint"),
		joker_entity("j_unrecognized_alpha"),
		joker_entity("j_unrecognized_beta"),
	}
	if extra ~= nil then
		for index, entity in next, extra do
			list[index] = entity
		end
	end
	return list
end

local function short_board(extra)
	local list = {
		joker_entity("j_cavendish"),
		joker_entity("j_joker"),
		joker_entity("j_blueprint"),
		joker_entity("j_unrecognized_alpha"),
	}
	if extra ~= nil then
		for index, entity in next, extra do
			list[index] = entity
		end
	end
	return list
end

local function shop_with(items, certs, money)
	local self = base_self()
	self.money = money or 30
	return {
		schema_version = 1,
		phase = "SHOP",
		match = Support.match(),
		self = self,
		shop = {
			reroll_cost = 5,
			items = items,
			vouchers = {},
			boosters = {},
		},
		context = base_context(),
		certificates = { version = 1, items = certs },
	}
end

-- Competing SELL / LEAVE / BUY: the board is full and the shop offers a strictly
-- better same-center copy that the adapter cannot certify as a purchase (no free
-- slot), alongside an unrelated capacity-free card purchase and LEAVE_SHOP. Only
-- the slot-pressure sale can reach the visible upgrade.
function Support.full_slot_upgrade_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", edition = "polychrome", cost = 6, sell_cost = 3, face_down = false },
		{ kind = "card", rank = "Ace", suit = "Spades", center = "c_ace", cost = 3, sell_cost = 1, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "BUY_ITEM", certified = true, item_ref = "shop:2" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board()
	return frame
end

-- Second step: one slot has been freed, so the adapter can now certify the
-- purchase of the upgrade (shop:1) together with an inferior plain same-center
-- copy (shop:2). The buying policy must prefer the editioned upgrade.
function Support.slot_freed_upgrade_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", edition = "polychrome", cost = 6, sell_cost = 3, face_down = false },
		{ kind = "joker", center = "j_cavendish", cost = 6, sell_cost = 3, face_down = false },
		{ kind = "card", rank = "Ace", suit = "Spades", center = "c_ace", cost = 3, sell_cost = 1, face_down = false },
	}, {
		{ type = "BUY_ITEM", certified = true, item_ref = "shop:1", capacity_ok = true },
		{ type = "BUY_ITEM", certified = true, item_ref = "shop:2", capacity_ok = true },
		{ type = "BUY_ITEM", certified = true, item_ref = "shop:3" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = short_board()
	return frame
end

-- Third step: the board is full again and the shop no longer offers an upgrade
-- (only a plain same-center copy), so no further sale may be scored.
function Support.post_upgrade_no_sale_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", cost = 6, sell_cost = 3, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board({ [1] = joker_entity("j_cavendish", { edition = "polychrome" }) })
	return frame
end

function Support.full_slot_equal_edition_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", cost = 6, sell_cost = 3, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board()
	return frame
end

function Support.full_slot_worse_edition_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", cost = 6, sell_cost = 3, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board({ [1] = joker_entity("j_cavendish", { edition = "foil" }) })
	return frame
end

-- An unrecognized owned center never participates, even with a matching
-- editioned offer: the baseline does not guess a replacement ranking.
function Support.full_slot_unrecognized_center_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_unrecognized_alpha", edition = "polychrome", cost = 6, sell_cost = 3, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board({ [1] = joker_entity("j_unrecognized_alpha") })
	return frame
end

-- A same-kind offer of a different center is not a proven upgrade.
function Support.full_slot_different_center_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_other_center", edition = "polychrome", cost = 6, sell_cost = 3, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board()
	return frame
end

function Support.full_slot_debuffed_upgrade_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", edition = "polychrome", cost = 6, sell_cost = 3, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board({ [1] = joker_entity("j_cavendish", { debuff = true }) })
	return frame
end

function Support.full_slot_negative_upgrade_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", edition = "negative", cost = 6, sell_cost = 3, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	})
	frame.self.jokers = full_board()
	return frame
end

-- The upgrade costs 6 while the board only holds 4 in cash, but the joker's
-- visible sell_cost is 5. A sale must not be used to fund the purchase, because
-- the sale proceeds are never part of the observation.
function Support.full_slot_unaffordable_upgrade_frame()
	local frame = shop_with({
		{ kind = "joker", center = "j_cavendish", edition = "polychrome", cost = 6, sell_cost = 5, face_down = false },
	}, {
		{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
		{ type = "LEAVE_SHOP", certified = true },
	}, 4)
	frame.self.jokers = full_board()
	return frame
end

-- Full board and a same-center offer in a non-SHOP phase with no visible shop:
-- selling is never scored outside SHOP.
function Support.non_shop_full_slot_sell_frame()
	local self = base_self()
	self.hand_visible = true
	self.hand = pair_hand()
	self.jokers = full_board()
	self.consumables = { { face_down = false, center = "c_hermit" } }
	local context = base_context()
	context.max_play = 5
	context.max_discard = 5
	return {
		schema_version = 1,
		phase = "MULTIPLAYER_PVP",
		match = Support.match(),
		self = self,
		context = context,
		certificates = { version = 1, items = {
			{ type = "SELL_JOKER", certified = true, joker_ref = "joker:1" },
			{ type = "SELL_CONSUMABLE", certified = true, consumable_ref = "consumable:1" },
		} },
	}
end

function Support.scan_source(source)
	local code = strip_comments(source)
	local hits = {}
	local tokens = Support.forbidden_tokens()
	for i = 1, #tokens do
		if has_ident(code, tokens[i][1]) then
			hits[#hits + 1] = tokens[i][2]
		end
	end
	local dotted = dotted_tokens()
	for i = 1, #dotted do
		if has_dotted(code, dotted[i][1], dotted[i][2]) then
			hits[#hits + 1] = dotted[i][3]
		end
	end
	return hits
end

return Support
