-- Trusted production executor: authoritative legality + committed callbacks.
--
-- Consumes the trusted `engine_adapter` (non-policy producer) and the bracket
-- `state_reader`, and exposes the `ports` triple the M2 action broker expects
-- (`capture`, `validate`, `dispatch`) plus explicit trusted non-policy UI
-- progression (`advance_ui`) for ROUND_EVAL cashout. MP PvP readiness is a
-- policy `SELECT_BLIND` mapped to the real ready button (see `validate_blind`).
--
-- Boundaries:
--
--   * The policy never reaches this module. It receives plain observation/action
--     records only. `dispatch` is reached only by the broker's trusted phase.
--   * `validate`/`dispatch` re-derive everything from the live engine and fail
--     closed. The adapter's certificates are candidates, never authority.
--   * Staleness is re-checked by recapturing the trusted revision immediately
--     before the callback; a changed revision refuses the commit.
--   * Only *pure* engine predicates (`Card:can_sell_card`,
--     `Card:can_use_consumeable`) are consulted on the committed target. UI
--     `can_*` callbacks (which mutate colour/visibility) are never called.
--   * UI elements are resolved from the injected `element_for` port when it
--     yields a real table, otherwise from the injected G itself (the real
--     `round_eval` cash-out button, the `blind_select_opts` UIBox for
--     `skip_blind`, the `select_blind_button` for the PvP ready element). This
--     is the source-backed fallback for a production companion that wires no
--     `element_for`; nothing beyond what the callback reads is fabricated.
--   * Refs are positional (`zone:ordinal`) exactly as the adapter produced them.
--     No engine id/memory address is used.
--
-- The module is globals-free: the engine is reached only through injected ports
-- and `G.FUNCS`/`G.<area>` tables obtained from those ports.

local ProductionExecutor = {}

ProductionExecutor.CODE = {
	OK = "exec_ok",
	BAD_PORTS = "exec_bad_ports",
	BAD_ROLE = "exec_bad_role",
	BAD_SESSION = "exec_bad_session",
	BAD_ADAPTER = "exec_bad_adapter",
	BAD_READER = "exec_bad_reader",
	BAD_ENGINE = "exec_bad_engine",
	CAPTURE_FAILED = "exec_capture_failed",
	CONTROL_REQUIRED = "exec_control_required",
	BAD_ACTION = "exec_bad_action",
	UNKNOWN_TYPE = "exec_unknown_type",
	UNKNOWN_REF = "exec_unknown_ref",
	STALE_REVISION = "exec_stale_revision",
	ILLEGAL = "exec_illegal",
	ELEMENT_MISSING = "exec_element_missing",
	CALLBACK_FAILED = "exec_callback_failed",
	NO_CONTROL = "exec_no_control",
	PENDING = "exec_pending",
	STALL_TIMEOUT = "exec_stall_timeout",
	REVOKED = "exec_revoked",
	CANCELED = "exec_canceled",
	NO_PENDING = "exec_no_pending",
	INTERNAL = "exec_internal_error",
}

local CODE = ProductionExecutor.CODE
local ROLE = "ai_staged"
local TOKEN_PATTERN = "^[0-9A-Za-z_%.-]+$"
local REF_PATTERN = "^([0-9A-Za-z_%-]+):([0-9]+)$"
local MAX_SELECTION = 64

-- Bounded stall window for a committed action whose anchored visible effect has
-- not appeared yet (e.g. vanilla `buy_from_shop` queues the remove/payment behind
-- a ~0.1s UI event, and a consumable use may run a longer card animation before
-- the source leaves `G.consumeables`). 10s is a defensible ceiling: long enough
-- not to reject a legitimate engine animation, short enough to bound a stuck
-- commit. Measured with the injected monotonic clock only; the executor never
-- sleeps and never freezes the engine's MP timers. Expiry is a terminal fault,
-- not a release (see `check_pending`).
local DEFAULT_STALL_TIMEOUT = 10.0

ProductionExecutor.ROLE = ROLE
ProductionExecutor.DEFAULT_STALL_TIMEOUT = DEFAULT_STALL_TIMEOUT

-- Which committed types hold a pending latch while waiting for their visible
-- effect. `SELECT_TARGETS` only sets the highlight, and `REORDER_*` is a
-- synchronous same-state permutation with no deferred engine effect, so both
-- are exempt: they must never block a later legitimate action indefinitely.
local LATCH_TYPES = {
	PLAY_CARDS = true,
	DISCARD_CARDS = true,
	SELECT_BLIND = true,
	SKIP_BLIND = true,
	SKIP_BOOSTER = true,
	BUY_ITEM = true,
	SELL_JOKER = true,
	SELL_CONSUMABLE = true,
	REROLL = true,
	BUY_VOUCHER = true,
	OPEN_BOOSTER = true,
	SELECT_BOOSTER_ITEM = true,
	USE_CONSUMABLE = true,
	LEAVE_SHOP = true,
	CASH_OUT = true,
}

local function is_int(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return value >= -2147483648 and value <= 2147483647
end

local function is_nat(value)
	return is_int(value) and value >= 0
end

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function rget(obj, key)
	if type(obj) ~= "table" or key == nil then
		return nil
	end
	return rawget(obj, key)
end

local function rpath(obj, a, b, c, d, e)
	local value = rget(obj, a)
	if b ~= nil then
		value = rget(value, b)
	end
	if c ~= nil then
		value = rget(value, c)
	end
	if d ~= nil then
		value = rget(value, d)
	end
	if e ~= nil then
		value = rget(value, e)
	end
	return value
end

local function token_of(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	if string.match(value, TOKEN_PATTERN) == nil then
		return nil
	end
	return value
end

local function dense_count(value, limit)
	if type(value) ~= "table" then
		return nil
	end
	local count = 0
	local maxn = 0
	for key in next, value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil
		end
		count = count + 1
		if count > limit then
			return nil
		end
		if key > maxn then
			maxn = key
		end
	end
	if count ~= maxn then
		return nil
	end
	return maxn
end

local ZONE_AREAS = {
	hand = "hand",
	target = "hand",
	joker = "jokers",
	consumable = "consumeables",
	shop = "shop_jokers",
	shop_booster = "shop_booster",
	shop_voucher = "shop_vouchers",
	booster = "pack_cards",
}

local function parse_ref(value)
	if type(value) ~= "string" or #value == 0 or #value > 64 then
		return nil
	end
	local zone, ordinal = string.match(value, REF_PATTERN)
	if zone == nil then
		return nil
	end
	local number = tonumber(ordinal)
	if number == nil or number < 1 or number > 2147483647 then
		return nil
	end
	return zone, number
end

local function resolve_action_blind(G)
	local game = rget(G, "GAME")
	local on_deck = rget(game, "blind_on_deck")
	local choices = rpath(game, "round_resets", "blind_choices")
	local key = rget(choices, on_deck)
	if type(key) ~= "string" then
		return nil
	end
	local blind = rget(rget(G, "P_BLINDS"), key)
	if type(blind) ~= "table" then
		return nil
	end
	return blind
end

-- True when the on-deck blind is the Multiplayer PvP blind. In that context the
-- policy's SELECT_BLIND must map to the real ready button (`mp_toggle_ready`),
-- never to the vanilla `select_blind`: the server's `startBlind` later invokes
-- `G.FUNCS.select_blind(MP.GAME.next_blind_context)` with the retired context.
local function pvp_blind_on_deck(G)
	local game = rget(G, "GAME")
	local on_deck = rget(game, "blind_on_deck")
	if type(on_deck) ~= "string" then
		return false
	end
	local resets = rget(game, "round_resets")
	local choice = rget(rget(resets, "blind_choices"), on_deck)
	if choice == "bl_mp_nemesis" then
		return true
	end
	local pvp_choice = rget(rget(resets, "pvp_blind_choices"), on_deck)
	return pvp_choice ~= nil and pvp_choice ~= false
end

local function resolve_ref(G, value)
	local zone, ordinal = parse_ref(value)
	if zone == nil then
		return nil
	end
	local area_key = ZONE_AREAS[zone]
	if area_key == nil then
		return nil
	end
	local area = rget(G, area_key)
	local cards = rget(area, "cards")
	local count = dense_count(cards, 256)
	if count == nil or ordinal > count then
		return nil
	end
	local card = rawget(cards, ordinal)
	if type(card) ~= "table" then
		return nil
	end
	return card, zone, ordinal
end

local function amount_field(value)
	if is_nat(value) then
		return value
	end
	return nil
end

local function ability_set(card)
	local set = rget(rget(card, "ability"), "set")
	if type(set) == "string" then
		return set
	end
	return nil
end

local function is_consumeable(card)
	-- Vanilla sets `self.ability.consumeable = center.config` (a table); follow
	-- engine truthiness rather than `== true`.
	local value = rget(rget(card, "ability"), "consumeable")
	return value ~= nil and value ~= false
end

local function item_kind(card)
	local set = ability_set(card)
	if set == "Joker" then
		return "joker"
	end
	if is_consumeable(card) then
		return "consumable"
	end
	if set == "Booster" then
		return "booster"
	end
	return "card"
end

local function is_negative(card)
	local edition = rget(card, "edition")
	return type(edition) == "table" and rget(edition, "type") == "negative"
end

local function slot_room(G, area_key, negative)
	local area = rget(G, area_key)
	local count = dense_count(rget(area, "cards"), 256)
	local limit = rpath(area, "config", "card_limit")
	if count == nil or not is_nat(limit) then
		return nil
	end
	if negative then
		return count < limit + 1
	end
	return count < limit
end

local function spendable_of(G)
	local dollars = rpath(G, "GAME", "dollars")
	local bankrupt = rpath(G, "GAME", "bankrupt_at")
	if not is_int(dollars) or not is_int(bankrupt) then
		return nil
	end
	return dollars - bankrupt
end

local function state_symbol(G, symbol)
	local states = rget(G, "STATES")
	local value = rget(states, symbol)
	local state = rget(G, "STATE")
	if is_int(value) and value == state then
		return true
	end
	return false
end

local BOOSTER_STATES = {
	"TAROT_PACK", "SPECTRAL_PACK", "PLANET_PACK", "STANDARD_PACK", "BUFFOON_PACK", "SMODS_BOOSTER_OPENED",
}

local function in_booster_state(G)
	for i = 1, #BOOSTER_STATES do
		if state_symbol(G, BOOSTER_STATES[i]) then
			return true
		end
	end
	return false
end

local function gates_clear(G)
	local stop_use = rpath(G, "GAME", "STOP_USE")
	if is_int(stop_use) and stop_use > 0 then
		return false
	end
	local locked = rget(rget(G, "CONTROLLER"), "locked")
	if locked ~= nil and locked ~= false then
		return false
	end
	local play_count = dense_count(rpath(G, "play", "cards"), 256)
	if play_count == nil then
		if rget(G, "play") ~= nil then
			return false
		end
		play_count = 0
	end
	if play_count > 0 then
		return false
	end
	return true
end

local function distinct_cards(G, refs, zone)
	local out = {}
	local seen = {}
	if type(refs) ~= "table" then
		return nil
	end
	local count = dense_count(refs, MAX_SELECTION)
	if count == nil or count == 0 then
		return nil
	end
	for i = 1, count do
		local card, ref_zone = resolve_ref(G, rawget(refs, i))
		if card == nil or ref_zone ~= zone then
			return nil
		end
		if seen[card] then
			return nil
		end
		seen[card] = true
		out[#out + 1] = card
	end
	return out
end

local function selection_bound(value)
	local count = dense_count(value, MAX_SELECTION)
	if count == nil then
		return nil
	end
	return count
end

local function call_predicate(card, name)
	if type(card[name]) ~= "function" then
		return nil
	end
	local ok, result = pcall(card[name], card)
	if not ok then
		return nil
	end
	return result
end

-- `Card:check_use` (card.lua:1581-1588) makes `G.FUNCS.use_card` a no-op for an
-- Ankh while the joker area is full, for both a held consumable and a pack card
-- that is USED on selection. The real engine sets `ability.name` from the center
-- (`Card:set_ability`, card.lua:278) and stamps each center with its key
-- (`game.lua:814-815`), so Ankh is identified by its engine name or its real
-- center key `c_ankh` (`G.P_CENTERS.c_ankh.name == "Ankh"`, game.lua:581). This
-- is the same predicate the adapter uses, so their candidate and commit views
-- agree.
local function is_ankh(card)
	if rget(rget(card, "ability"), "name") == "Ankh" then
		return true
	end
	return rget(rpath(card, "config", "center"), "key") == "c_ankh"
end

local function check_use_ok(G, card)
	if not is_ankh(card) then
		return true
	end
	local jokers = rget(G, "jokers")
	local jcount = dense_count(rget(jokers, "cards"), 256)
	local jlimit = rpath(jokers, "config", "card_limit")
	return jcount ~= nil and is_nat(jlimit) and jcount < jlimit
end

-- Engine areas a `G.FUNCS.use_card` commit removes its target from synchronously
-- (`button_callbacks.lua:2209`). After such a commit the anchored source must be
-- gone; otherwise the callback was a no-op early return (e.g. Ankh with full
-- joker slots, `card.lua:1581-1588`) and must be reported as a clean failure
-- instead of being latched into a false "waiting for effect" state.
local USE_CARD_LEAVE = {
	USE_CONSUMABLE = "consumeables",
	SELECT_BOOSTER_ITEM = "pack_cards",
	OPEN_BOOSTER = "shop_booster",
	BUY_VOUCHER = "shop_vouchers",
}

-- Cards the current blind forces into every selection
-- (`G.hand.cards[i].ability.forced_selection`, set by e.g. Cerulean Bell). Read
-- only as raw fields; the highlight guard that honours them lives in
-- `CardArea:remove_from_highlighted` (cardarea.lua:187-188).
local function forced_hand_cards(G)
	local hand = rget(G, "hand")
	local cards = rget(hand, "cards")
	local count = dense_count(cards, MAX_SELECTION)
	if count == nil then
		return nil
	end
	local out = {}
	for i = 1, count do
		local card = rawget(cards, i)
		if type(card) == "table" and rget(rget(card, "ability"), "forced_selection") == true then
			out[#out + 1] = card
		end
	end
	return out
end

local function contains_card(list, card)
	for i = 1, #list do
		if list[i] == card then
			return true
		end
	end
	return false
end

function ProductionExecutor.factory(ports)
	if type(ports) ~= "table" then
		return nil, CODE.BAD_PORTS
	end
	if rawget(ports, "role") ~= ROLE then
		return nil, CODE.BAD_ROLE
	end
	local session = token_of(rawget(ports, "session"), 64)
	if session == nil then
		return nil, CODE.BAD_SESSION
	end
	local adapter = rawget(ports, "adapter")
	if type(adapter) ~= "table" or type(adapter.step) ~= "function" then
		return nil, CODE.BAD_ADAPTER
	end
	local reader = rawget(ports, "reader")
	if type(reader) ~= "table" or type(reader.capture) ~= "function" then
		return nil, CODE.BAD_READER
	end
	local revision = rawget(ports, "revision")
	if type(revision) ~= "table" or type(revision.current) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local G = rawget(ports, "G")
	local MP = rawget(ports, "MP")
	if type(G) ~= "table" or type(MP) ~= "table" then
		return nil, CODE.BAD_ENGINE
	end
	local element_for = rawget(ports, "element_for")
	if element_for ~= nil and type(element_for) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local funcs_port = rawget(ports, "funcs")
	if funcs_port ~= nil and type(funcs_port) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	-- Injected monotonic clock. Either a table with `now()` (matching the
	-- decision loop's clock port) or a bare function returning a number. Without
	-- one the pending latch has no timeout and only a proven completion releases.
	local clock_port = rawget(ports, "clock")
	local clock = nil
	if clock_port ~= nil then
		if type(clock_port) == "table" then
			if type(rawget(clock_port, "now")) ~= "function" then
				return nil, CODE.BAD_PORTS
			end
			clock = clock_port
		elseif type(clock_port) == "function" then
			clock = clock_port
		else
			return nil, CODE.BAD_PORTS
		end
	end
	local stall_timeout = rawget(ports, "stall_timeout")
	if stall_timeout == nil then
		stall_timeout = DEFAULT_STALL_TIMEOUT
	end
	if type(stall_timeout) ~= "number" or stall_timeout ~= stall_timeout
		or stall_timeout == math.huge or stall_timeout <= 0 then
		return nil, CODE.BAD_PORTS
	end

	local instance = {}
	local last_validated = nil
	local last_control = nil
	local pending = nil
	local revoked = false
	-- Terminal fault latched by a stall timeout. A timed-out commit is never
	-- released back to a usable executor (that would let the old queued action be
	-- retried and duplicated); only a trusted session cancel/reset clears it.
	local fault = nil

	local function funcs()
		if funcs_port ~= nil then
			local ok, value = pcall(funcs_port)
			if ok and type(value) == "table" then
				return value
			end
			return nil
		end
		return rget(G, "FUNCS")
	end

	local function clock_now()
		if clock == nil then
			return nil
		end
		local ok, value = pcall(function()
			if type(clock) == "function" then
				return clock()
			end
			return clock.now()
		end)
		if not ok or type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return value
	end

	-- Source-backed trusted UI-element lookup. The injected `element_for` port is
	-- consulted first, but only a real (non-nil table) result is accepted: the
	-- production companion currently passes a default nil-returning function, so
	-- the executor falls back to deriving the exact element from the injected G.
	-- Nothing is fabricated beyond what the engine callback actually reads.
	local function resolve_element(name)
		if element_for ~= nil then
			local ok, value = pcall(element_for, name)
			if ok and type(value) == "table" then
				return value
			end
		end
		local game = rget(G, "GAME")
		if name == "cash_out" then
			-- `G.FUNCS.cash_out` clears its own `e.config.button`
			-- (button_callbacks.lua:2915) and reads the round tally
			-- (`G.GAME.current_round.dollars`), so the real `G.round_eval`
			-- cash-out button element must exist before committing; nothing is
			-- fabricated and cash-out waits for the tally UI.
			local round_eval = rget(G, "round_eval")
			if type(round_eval) ~= "table" then
				return nil
			end
			local lookup = round_eval.get_UIE_by_ID
			if type(lookup) ~= "function" then
				return nil
			end
			local ok, ui = pcall(lookup, round_eval, "cash_out_button")
			if ok and type(ui) == "table" then
				return ui
			end
			return nil
		elseif name == "skip_blind" or name == "pvp_ready" then
			if type(game) ~= "table" then
				return nil
			end
			local on_deck = rget(game, "blind_on_deck")
			if type(on_deck) ~= "string" then
				return nil
			end
			local box = rget(rget(G, "blind_select_opts"), string.lower(on_deck))
			if type(box) ~= "table" then
				return nil
			end
			if name == "skip_blind" then
				-- `G.FUNCS.skip_blind` reads
				-- `e.UIBox:get_UIE_by_ID('tag_container')` (2754); the blind
				-- choice UIBox is the real `e.UIBox`.
				return { UIBox = box }
			end
			-- `select_blind_button`'s `config.ref_table` is the blind config
			-- (mp/ui/game/blind_choice.lua:210-228); `mp_toggle_ready` takes the
			-- real element.
			local lookup = box.get_UIE_by_ID
			if type(lookup) ~= "function" then
				return nil
			end
			local ok, ui = pcall(lookup, box, "select_blind_button")
			if ok and type(ui) == "table" then
				return ui
			end
			return nil
		end
		return nil
	end

	-- True when `card` (engine table identity) is still present in `area_key`.
	local function card_in_area(area_key, card)
		local area = rget(G, area_key)
		local cards = rget(area, "cards")
		local count = dense_count(cards, 256)
		if count == nil then
			return false
		end
		for i = 1, count do
			if rawget(cards, i) == card then
				return true
			end
		end
		return false
	end

	local function snapshot_shop_ids()
		local out = {}
		local keys = { "shop_jokers", "shop_booster", "shop_vouchers" }
		for k = 1, #keys do
			local area = rget(G, keys[k])
			local cards = rget(area, "cards")
			local count = dense_count(cards, 256) or 0
			for i = 1, count do
				out[#out + 1] = rawget(cards, i)
			end
		end
		return out
	end

	local function shop_ids_changed(before)
		local now_ids = snapshot_shop_ids()
		if #now_ids ~= #before then
			return true
		end
		for i = 1, #now_ids do
			if now_ids[i] ~= before[i] then
				return true
			end
		end
		return false
	end

	-- Action-specific completion anchor, captured from the exact dispatched target
	-- before the callback runs. A generic canonical/epoch change is deliberately
	-- NOT a release signal: an unrelated opponent/score/money update changes the
	-- fingerprint too. Completion is proven only by the anchored target leaving its
	-- expected area, an action-appropriate phase transition, `ready_blind`, or a
	-- real shop-content generation change for a reroll.
	local function build_pending(action_type, target)
		if LATCH_TYPES[action_type] ~= true then
			return nil
		end
		local started = clock_now()
		local deadline = nil
		if started ~= nil then
			deadline = started + stall_timeout
		end
		local p = {
			type = action_type,
			state = rget(G, "STATE"),
			started = started,
			deadline = deadline,
		}
		if action_type == "PLAY_CARDS" or action_type == "DISCARD_CARDS" then
			p.kind = "cards_leave_hand"
			p.cards = target
		elseif action_type == "REROLL" then
			p.kind = "reroll"
			p.reroll_cost = rpath(G, "GAME", "current_round", "reroll_cost")
			p.shop_ids = snapshot_shop_ids()
		elseif action_type == "SELECT_BLIND" then
			p.kind = "blind"
			p.pvp = pvp_blind_on_deck(G)
		elseif action_type == "SKIP_BLIND" then
			p.kind = "skip_blind"
			p.blind_on_deck = rpath(G, "GAME", "blind_on_deck")
		elseif action_type == "BUY_ITEM" then
			p.kind = "card_leave"
			p.area_key = "shop_jokers"
			p.card = target
		elseif action_type == "SELL_JOKER" then
			p.kind = "card_leave"
			p.area_key = "jokers"
			p.card = target
		elseif action_type == "SELL_CONSUMABLE" or action_type == "USE_CONSUMABLE" then
			p.kind = "card_leave"
			p.area_key = "consumeables"
			p.card = target
		elseif action_type == "BUY_VOUCHER" then
			p.kind = "card_leave"
			p.area_key = "shop_vouchers"
			p.card = target
		elseif action_type == "OPEN_BOOSTER" then
			p.kind = "card_leave"
			p.area_key = "shop_booster"
			p.card = target
		elseif action_type == "SELECT_BOOSTER_ITEM" then
			p.kind = "card_leave"
			p.area_key = "pack_cards"
			p.card = target
		else
			-- LEAVE_SHOP, SKIP_BOOSTER, CASH_OUT: phase transition only.
			p.kind = "phase"
		end
		return p
	end

	local function pending_completed(p)
		if p.kind == "card_leave" then
			if type(p.card) ~= "table" then
				-- No identity to anchor on: never claim completion (fail closed
				-- to the bounded stall timeout).
				return false
			end
			if not card_in_area(p.area_key, p.card) then
				return true
			end
			if rget(G, "STATE") ~= p.state then
				return true
			end
			return false
		elseif p.kind == "cards_leave_hand" then
			if type(p.cards) ~= "table" then
				return false
			end
			local any_left = false
			for i = 1, #p.cards do
				if card_in_area("hand", p.cards[i]) then
					any_left = true
				end
			end
			if not any_left then
				return true
			end
			if rget(G, "STATE") ~= p.state then
				return true
			end
			return false
		elseif p.kind == "reroll" then
			if rpath(G, "GAME", "current_round", "reroll_cost") ~= p.reroll_cost then
				return true
			end
			if p.shop_ids ~= nil and shop_ids_changed(p.shop_ids) then
				return true
			end
			return false
		elseif p.kind == "blind" then
			if p.pvp == true and rget(rget(MP, "GAME"), "ready_blind") == true then
				return true
			end
			if rget(G, "STATE") ~= p.state then
				return true
			end
			return false
		elseif p.kind == "skip_blind" then
			if rget(G, "STATE") ~= p.state then
				return true
			end
			if rpath(G, "GAME", "blind_on_deck") ~= p.blind_on_deck then
				return true
			end
			return false
		end
		-- kind == "phase": only a real phase transition completes.
		return rget(G, "STATE") ~= p.state
	end

	local function check_pending()
		if pending == nil then
			return nil
		end
		if pending_completed(pending) then
			pending = nil
			return nil
		end
		local now = clock_now()
		if now ~= nil and pending.deadline ~= nil and now >= pending.deadline then
			pending = nil
			fault = CODE.STALL_TIMEOUT
			return CODE.STALL_TIMEOUT
		end
		return CODE.PENDING
	end

	local function gate()
		if revoked then
			return nil, CODE.REVOKED
		end
		if fault ~= nil then
			return nil, fault
		end
		local block = check_pending()
		if block ~= nil then
			return nil, block
		end
		return true
	end

	local function capture_epoch()
		local allowed, gate_code = gate()
		if allowed == nil then
			return nil, gate_code
		end
		local result = adapter.step()
		if type(result) ~= "table" then
			return nil, CODE.CAPTURE_FAILED
		end
		if result.control ~= nil then
			last_control = result.control
			return nil, CODE.CONTROL_REQUIRED
		end
		if not is_nat(result.epoch) then
			return nil, CODE.CAPTURE_FAILED
		end
		last_control = nil
		return result
	end

	local function validate_play_like(action, t)
		if not state_symbol(G, "SELECTING_HAND") then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		local refs = rget(action, "card_refs")
		local count = selection_bound(refs)
		if count == nil or count < 1 or count > 5 then
			return nil, CODE.ILLEGAL
		end
		local cards = distinct_cards(G, refs, "hand")
		if cards == nil then
			return nil, CODE.UNKNOWN_REF
		end
		-- H3: a blind-forced card (e.g. Cerulean Bell) cannot be un-highlighted
		-- (cardarea.lua:187-188) and is cleared by play/discard (state_events.lua
		-- 384-386, 459-461), so a selection that omits it would silently drop the
		-- rule. Require every forced card to be part of the selection.
		local forced = forced_hand_cards(G)
		if forced == nil then
			return nil, CODE.ILLEGAL
		end
		for i = 1, #forced do
			if not contains_card(cards, forced[i]) then
				return nil, CODE.ILLEGAL
			end
		end
		local current_round = rpath(G, "GAME", "current_round")
		if t == "PLAY_CARDS" then
			local hands_left = rget(current_round, "hands_left")
			if not is_int(hands_left) or hands_left <= 0 then
				return nil, CODE.ILLEGAL
			end
			local block_play = rpath(G, "GAME", "blind", "block_play")
			if block_play ~= nil and block_play ~= false then
				return nil, CODE.ILLEGAL
			end
		else
			local discards_left = rget(current_round, "discards_left")
			if not is_int(discards_left) or discards_left <= 0 then
				return nil, CODE.ILLEGAL
			end
		end
		return cards
	end

	local function validate_buy(action)
		if not state_symbol(G, "SHOP") then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		local card, zone = resolve_ref(G, rget(action, "item_ref"))
		if card == nil or zone ~= "shop" then
			return nil, CODE.UNKNOWN_REF
		end
		local kind = item_kind(card)
		if kind ~= "card" and kind ~= "joker" and kind ~= "consumable" then
			return nil, CODE.ILLEGAL
		end
		local cost = rget(card, "cost")
		if not is_nat(cost) then
			return nil, CODE.ILLEGAL
		end
		local spendable = spendable_of(G)
		if cost > 0 and (spendable == nil or spendable < cost) then
			return nil, CODE.ILLEGAL
		end
		if kind == "joker" then
			if slot_room(G, "jokers", is_negative(card)) ~= true then
				return nil, CODE.ILLEGAL
			end
		elseif kind == "consumable" then
			if slot_room(G, "consumeables", is_negative(card)) ~= true then
				return nil, CODE.ILLEGAL
			end
		end
		return card
	end

	local function validate_open_booster(action)
		if not state_symbol(G, "SHOP") then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		local card, zone = resolve_ref(G, rget(action, "item_ref"))
		if card == nil or zone ~= "shop_booster" then
			return nil, CODE.UNKNOWN_REF
		end
		if item_kind(card) ~= "booster" then
			return nil, CODE.ILLEGAL
		end
		local cost = rget(card, "cost")
		if not is_nat(cost) then
			return nil, CODE.ILLEGAL
		end
		local spendable = spendable_of(G)
		if cost > 0 and (spendable == nil or spendable < cost) then
			return nil, CODE.ILLEGAL
		end
		return card
	end

	local function validate_buy_voucher(action)
		if not state_symbol(G, "SHOP") then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		local card, zone = resolve_ref(G, rget(action, "voucher_ref"))
		if card == nil or zone ~= "shop_voucher" then
			return nil, CODE.UNKNOWN_REF
		end
		local cost = rget(card, "cost")
		local spendable = spendable_of(G)
		if not is_nat(cost) or spendable == nil or spendable < cost then
			return nil, CODE.ILLEGAL
		end
		return card
	end

	local function validate_select_booster(action)
		if not in_booster_state(G) then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		local refs = rget(action, "card_refs")
		if selection_bound(refs) ~= 1 then
			return nil, CODE.ILLEGAL
		end
		local card, zone = resolve_ref(G, rawget(refs, 1))
		if card == nil or zone ~= "booster" then
			return nil, CODE.UNKNOWN_REF
		end
		if not is_nat(rpath(G, "GAME", "pack_choices")) or rpath(G, "GAME", "pack_choices") <= 0 then
			return nil, CODE.ILLEGAL
		end
		local kind = item_kind(card)
		if kind == "joker" then
			-- L3: vanilla `can_select_card` (button_callbacks.lua:2113) accepts a
			-- negative-edition joker regardless of free joker slots; only a
			-- non-negative joker needs slot room.
			if not is_negative(card) and slot_room(G, "jokers", false) ~= true then
				return nil, CODE.ILLEGAL
			end
		elseif kind == "consumable" then
			-- C1: a pack consumable is USED on selection. Require the engine's
			-- own `Card:can_use_consumeable` (button_callbacks.lua:2102), never a
			-- free-slot check. B: the same `check_use` slot predicate that
			-- refuses a held Ankh also refuses a pack Ankh (its `use_card`
			-- no-op), so the candidate and commit boundaries agree.
			if call_predicate(card, "can_use_consumeable") ~= true or not check_use_ok(G, card) then
				return nil, CODE.ILLEGAL
			end
		end
		return card
	end

	local function validate_skip_booster()
		if not in_booster_state(G) then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		local hand = rget(G, "hand")
		local hand_first = rget(rget(hand, "cards"), 1)
		local hand_limit = rpath(hand, "config", "card_limit")
		-- H1/A: mirror `G.FUNCS.can_skip_booster` as patched by SMODS
		-- (smods-booster.toml:124-126), but the real UI always requires a pack
		-- card FIRST (`G.pack_cards.cards[1]`, button_callbacks.lua:2133). After
		-- opening, the booster leaves the play area and its cards are created a
		-- beat later, so a state-only skip would let the AI skip a paid pack
		-- before any card appears. Keep the pack-card guard for every state.
		local cards = rpath(G, "pack_cards", "cards")
		local pack_first = type(rget(cards, 1)) == "table"
		local skippable = pack_first and (state_symbol(G, "SMODS_BOOSTER_OPENED")
			or state_symbol(G, "PLANET_PACK") or state_symbol(G, "STANDARD_PACK")
			or state_symbol(G, "BUFFOON_PACK") or hand_first ~= nil
			or (is_nat(hand_limit) and hand_limit <= 0))
		if not skippable then
			return nil, CODE.ILLEGAL
		end
		return true
	end

	local function validate_blind(action)
		if not state_symbol(G, "BLIND_SELECT") then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		if type(rget(G, "blind_select")) ~= "table" then
			return nil, CODE.ILLEGAL
		end
		if resolve_action_blind(G) == nil then
			return nil, CODE.ILLEGAL
		end
		if pvp_blind_on_deck(G) then
			-- A PvP blind can only be committed through the ready toggle: the
			-- real button (element_for("pvp_ready"), or the source-backed
			-- `select_blind_button` fallback) retains the context the server
			-- later replays into select_blind. Direct selection before the
			-- server's startBlind is refused.
			if type(resolve_element("pvp_ready")) ~= "table" then
				return nil, CODE.ELEMENT_MISSING
			end
			if rget(rget(MP, "GAME"), "ready_blind") == true then
				return nil, CODE.ILLEGAL
			end
		end
		return true
	end

	local function validate_reorder(action, zone)
		local area_key = ZONE_AREAS[zone]
		if area_key == nil then
			return nil, CODE.BAD_ACTION
		end
		local area = rget(G, area_key)
		local cards = rget(area, "cards")
		local count = dense_count(cards, MAX_SELECTION)
		if count == nil or count < 2 then
			return nil, CODE.ILLEGAL
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		for i = 1, count do
			local card = rawget(cards, i)
			if type(card) == "table" and rget(card, "pinned") == true then
				-- L1: `CardArea:align_cards` forcibly re-sorts pinned jokers
				-- (cardarea.lua:528); a permutation that moves one is not
				-- authoritative, so it is not a valid committed reorder.
				return nil, CODE.ILLEGAL
			end
		end
		local order = rget(action, "order")
		local order_count = dense_count(order, MAX_SELECTION)
		if order_count == nil or order_count ~= count then
			return nil, CODE.ILLEGAL
		end
		local resolved = {}
		local seen = {}
		for i = 1, order_count do
			local card, ref_zone = resolve_ref(G, rawget(order, i))
			if card == nil or ref_zone ~= zone then
				return nil, CODE.UNKNOWN_REF
			end
			if seen[card] then
				return nil, CODE.ILLEGAL
			end
			seen[card] = true
			resolved[i] = card
		end
		for i = 1, count do
			if seen[rawget(cards, i)] ~= true then
				return nil, CODE.ILLEGAL
			end
		end
		return { cards = resolved, area_key = area_key }
	end

	local function validate_use_consumable(action)
		local source, zone = resolve_ref(G, rget(action, "source_ref"))
		if source == nil or zone ~= "consumable" then
			return nil, CODE.UNKNOWN_REF
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		-- H5/B: mirror `Card:check_use` (card.lua:1581-1588) via the shared
		-- predicate. Ankh passes `can_use_consumeable` with full joker slots but
		-- `use_card` then `check_use` early-returns; refuse it here instead of
		-- committing a no-op. The adapter applies the same predicate so it never
		-- offers what this refuses.
		if not check_use_ok(G, source) then
			return nil, CODE.ILLEGAL
		end
		local refs = rget(action, "target_refs")
		local count = 0
		if refs ~= nil then
			local bound = selection_bound(refs)
			if bound == nil then
				return nil, CODE.BAD_ACTION
			end
			count = bound
		end
		if count == 0 then
			if call_predicate(source, "can_use_consumeable") ~= true then
				return nil, CODE.ILLEGAL
			end
		else
			-- M3 (targeted consumables, implemented legally): the
			-- highlight-dependent clause of `can_use_consumeable`
			-- (card.lua:1564-1569) cannot be satisfied before the highlights
			-- exist, so validate the raw highlight bounds here and re-check the
			-- real predicate in `dispatch` immediately after applying them.
			local cards = distinct_cards(G, refs, "target")
			if cards == nil then
				return nil, CODE.UNKNOWN_REF
			end
			local consumeable = rget(rget(source, "ability"), "consumeable")
			if type(consumeable) ~= "table" then
				return nil, CODE.ILLEGAL
			end
			local mod_num = rawget(consumeable, "mod_num")
			local max_highlighted = rawget(consumeable, "max_highlighted")
			local max_targets = is_nat(mod_num) and mod_num or (is_nat(max_highlighted) and max_highlighted or nil)
			local min_highlighted = rawget(consumeable, "min_highlighted")
			local min_targets = is_nat(min_highlighted) and min_highlighted or 1
			if max_targets == nil or count < min_targets or count > max_targets then
				return nil, CODE.ILLEGAL
			end
		end
		return source
	end

	local function validate_sell(action, ref_field, zone)
		local card, ref_zone = resolve_ref(G, rget(action, ref_field))
		if card == nil or ref_zone ~= zone then
			return nil, CODE.UNKNOWN_REF
		end
		if not gates_clear(G) then
			return nil, CODE.ILLEGAL
		end
		-- `Card:can_sell_card` (card.lua:1640) is the same pure gate for jokers
		-- and consumables: `G.consumeables` is created with `type = 'joker'`
		-- (game.lua:2239), so consumables use the normal sell button too.
		local result = call_predicate(card, "can_sell_card")
		if result ~= true then
			return nil, CODE.ILLEGAL
		end
		return card
	end

	local function validate_action(action)
		if not is_plain(action) then
			return nil, CODE.BAD_ACTION
		end
		local t = rget(action, "type")
		if type(t) ~= "string" then
			return nil, CODE.BAD_ACTION
		end
		if t == "PLAY_CARDS" or t == "DISCARD_CARDS" then
			return validate_play_like(action, t)
		elseif t == "SELECT_TARGETS" then
			if not gates_clear(G) then
				return nil, CODE.ILLEGAL
			end
			local refs = rget(action, "target_refs")
			local cards = distinct_cards(G, refs, "target")
			if cards == nil then
				return nil, CODE.UNKNOWN_REF
			end
			return cards
		elseif t == "BUY_ITEM" then
			return validate_buy(action)
		elseif t == "SELL_JOKER" then
			return validate_sell(action, "joker_ref", "joker")
		elseif t == "SELL_CONSUMABLE" then
			return validate_sell(action, "consumable_ref", "consumable")
		elseif t == "REROLL" then
			if not state_symbol(G, "SHOP") or not gates_clear(G) then
				return nil, CODE.ILLEGAL
			end
			local reroll = rpath(G, "GAME", "current_round", "reroll_cost")
			local spendable = spendable_of(G)
			if not is_nat(reroll) then
				return nil, CODE.ILLEGAL
			end
			if reroll > 0 and (spendable == nil or spendable < reroll) then
				return nil, CODE.ILLEGAL
			end
			return true
		elseif t == "BUY_VOUCHER" then
			return validate_buy_voucher(action)
		elseif t == "OPEN_BOOSTER" then
			return validate_open_booster(action)
		elseif t == "LEAVE_SHOP" then
			if not state_symbol(G, "SHOP") or not gates_clear(G) then
				return nil, CODE.ILLEGAL
			end
			return true
		elseif t == "SELECT_BOOSTER_ITEM" then
			return validate_select_booster(action)
		elseif t == "SKIP_BOOSTER" then
			return validate_skip_booster()
		elseif t == "SELECT_BLIND" then
			return validate_blind(action)
		elseif t == "SKIP_BLIND" then
			if not state_symbol(G, "BLIND_SELECT") or not gates_clear(G) then
				return nil, CODE.ILLEGAL
			end
			local game = rget(G, "GAME")
			local on_deck = rget(game, "blind_on_deck")
			local states = rpath(game, "round_resets", "blind_states")
			-- H4b: only the Small/Big blinds mount a `tag_container`; a boss
			-- skip (including the PvP boss) has no effect.
			if (on_deck ~= "Small" and on_deck ~= "Big") or type(states) ~= "table"
				or rget(states, on_deck) ~= "Select" then
				return nil, CODE.ILLEGAL
			end
			if type(resolve_element("skip_blind")) ~= "table" then
				return nil, CODE.ELEMENT_MISSING
			end
			return true
		elseif t == "USE_CONSUMABLE" then
			return validate_use_consumable(action)
		elseif t == "REORDER_JOKERS" then
			return validate_reorder(action, "joker")
		elseif t == "REORDER_HAND" then
			return validate_reorder(action, "hand")
		end
		return nil, CODE.UNKNOWN_TYPE
	end

	function instance.validate(action, handle)
		local ok, result, code = pcall(function()
			if is_plain(action) == false then
				return nil, CODE.BAD_ACTION
			end
			local id = rget(action, "id")
			if type(id) ~= "string" or #id == 0 then
				return nil, CODE.BAD_ACTION
			end
			local capture, capture_code = capture_epoch()
			if capture == nil then
				return nil, capture_code or CODE.CONTROL_REQUIRED
			end
			local target, validate_code = validate_action(action)
			if target == nil then
				return nil, validate_code
			end
			last_validated = { id = id, epoch = capture.epoch, type = rget(action, "type") }
			return true
		end)
		if not ok then
			return nil, CODE.INTERNAL
		end
		return result, code
	end

	-- H3: clear the previous highlight and apply the requested one. Removal is
	-- done WITHOUT the force flag, so a blind-forced card (`forced_selection`)
	-- keeps its highlight (`CardArea:remove_from_highlighted`, cardarea.lua:187);
	-- play/discard callers pre-check that every forced card is part of the
	-- requested set. After adding, the actual highlighted set is compared to the
	-- requested set: `add_to_highlighted` silently drops an add once the area's
	-- highlight limit is reached (cardarea.lua:149-150), so a mismatch means the
	-- callback must not run (no latch, clean failure).
	local function apply_hand_selection(cards, require_exact)
		local hand = rget(G, "hand")
		if type(hand) ~= "table" then
			return nil, CODE.ELEMENT_MISSING
		end
		local remove = hand.remove_from_highlighted
		local add = hand.add_to_highlighted
		if type(remove) ~= "function" or type(add) ~= "function" then
			return nil, CODE.ELEMENT_MISSING
		end
		local highlighted = rget(hand, "highlighted")
		local count = dense_count(highlighted, MAX_SELECTION)
		if count == nil then
			return nil, CODE.ELEMENT_MISSING
		end
		for i = count, 1, -1 do
			local ok = pcall(remove, hand, rawget(highlighted, i))
			if not ok then
				return nil, CODE.ELEMENT_MISSING
			end
		end
		local current = {}
		local current_count = dense_count(highlighted, MAX_SELECTION)
		if current_count == nil then
			return nil, CODE.ELEMENT_MISSING
		end
		for i = 1, current_count do
			current[rawget(highlighted, i)] = true
		end
		if require_exact == true then
			local limit = rpath(hand, "config", "highlighted_limit")
			if is_nat(limit) and #cards > limit then
				return nil, CODE.ILLEGAL
			end
		end
		for i = 1, #cards do
			if current[cards[i]] ~= true then
				local ok = pcall(add, hand, cards[i])
				if not ok then
					return nil, CODE.ELEMENT_MISSING
				end
			end
		end
		if require_exact == true then
			local actual = rget(hand, "highlighted")
			local actual_count = dense_count(actual, MAX_SELECTION)
			if actual_count == nil or actual_count ~= #cards then
				return nil, CODE.CALLBACK_FAILED
			end
			local wanted = {}
			for i = 1, #cards do
				wanted[cards[i]] = true
			end
			for i = 1, actual_count do
				if wanted[rawget(actual, i)] ~= true then
					return nil, CODE.CALLBACK_FAILED
				end
			end
		end
		return true
	end

	local function element(card)
		return { config = { ref_table = card } }
	end

	local function invoke(name, args)
		local table_funcs = funcs()
		if type(table_funcs) ~= "table" then
			return nil, CODE.ELEMENT_MISSING
		end
		local callback = rawget(table_funcs, name)
		if type(callback) ~= "function" then
			return nil, CODE.ELEMENT_MISSING
		end
		local ok, result = pcall(callback, args)
		if not ok then
			return nil, CODE.CALLBACK_FAILED
		end
		-- An explicit `false` is the engine's own rejection (e.g. a `can_*`
		-- guard): pcall success alone is not a committed success.
		if result == false then
			return nil, CODE.CALLBACK_FAILED
		end
		return true
	end

	local function dispatch_commit(action, t, target)
		if t == "PLAY_CARDS" or t == "DISCARD_CARDS" then
			local applied, apply_code = apply_hand_selection(target, true)
			if applied == nil then
				return nil, apply_code
			end
			if t == "PLAY_CARDS" then
				return invoke("play_cards_from_highlighted")
			end
			return invoke("discard_cards_from_highlighted")
		elseif t == "SELECT_BLIND" then
			if pvp_blind_on_deck(G) then
				-- Route policy SELECT_BLIND through the real ready button so
				-- the server's startBlind drives the actual select_blind.
				local e = resolve_element("pvp_ready")
				if type(e) ~= "table" then
					return nil, CODE.ELEMENT_MISSING
				end
				return invoke("mp_toggle_ready", e)
			end
			local blind = resolve_action_blind(G)
			if blind == nil then
				return nil, CODE.ILLEGAL
			end
			return invoke("select_blind", { config = { ref_table = blind } })
		elseif t == "SKIP_BLIND" then
			local e = resolve_element("skip_blind")
			if type(e) ~= "table" then
				return nil, CODE.ELEMENT_MISSING
			end
			return invoke("skip_blind", e)
		elseif t == "SKIP_BOOSTER" then
			local e = nil
			if element_for ~= nil then
				local ok, value = pcall(element_for, "skip_booster")
				if ok and type(value) == "table" then
					e = value
				end
			end
			return invoke("skip_booster", e)
		elseif t == "BUY_ITEM" then
			return invoke("buy_from_shop", element(target))
		elseif t == "SELL_JOKER" or t == "SELL_CONSUMABLE" then
			return invoke("sell_card", element(target))
		elseif t == "REROLL" then
			return invoke("reroll_shop")
		elseif t == "LEAVE_SHOP" then
			return invoke("toggle_shop")
		elseif t == "BUY_VOUCHER" or t == "OPEN_BOOSTER" or t == "SELECT_BOOSTER_ITEM" then
			return invoke("use_card", element(target))
		elseif t == "USE_CONSUMABLE" then
			local refs = rget(action, "target_refs")
			local count = (refs ~= nil) and selection_bound(refs) or 0
			if count == nil then
				return nil, CODE.BAD_ACTION
			end
			if count > 0 then
				local cards = distinct_cards(G, refs, "target")
				if cards == nil then
					return nil, CODE.UNKNOWN_REF
				end
				local applied, apply_code = apply_hand_selection(cards, false)
				if applied == nil then
					return nil, apply_code
				end
				-- M3: the highlight-dependent clause of `can_use_consumeable`
				-- is only satisfiable now that the targets are highlighted; the
				-- real read-only predicate is the authority before committing.
				if call_predicate(target, "can_use_consumeable") ~= true then
					return nil, CODE.ILLEGAL
				end
			end
			return invoke("use_card", element(target))
		elseif t == "SELECT_TARGETS" then
			local applied, apply_code = apply_hand_selection(target, false)
			if applied == nil then
				return nil, apply_code
			end
			return true
		elseif t == "REORDER_JOKERS" or t == "REORDER_HAND" then
			-- L1: there is no discrete reorder callback in the engine; the
			-- drag/drop UI permutes the CardArea order and the engine's own
			-- `CardArea:move` re-aligns it (cardarea.lua:229,240). Commit the
			-- same permutation under the same revalidated revision, then run the
			-- real `CardArea:set_ranks` / `CardArea:align_cards` methods (via
			-- normal metatable lookup, not `rawget`, which is always nil on a
			-- real CardArea) so card ranks and layout follow the new order.
			local area = rget(G, target.area_key)
			local cards = rget(area, "cards")
			if dense_count(cards, MAX_SELECTION) ~= #target.cards then
				return nil, CODE.STALE_REVISION
			end
			for i = 1, #target.cards do
				cards[i] = target.cards[i]
			end
			local set_ranks = area.set_ranks
			if type(set_ranks) == "function" then
				local ok = pcall(set_ranks, area)
				if not ok then
					return nil, CODE.CALLBACK_FAILED
				end
			end
			local align = area.align_cards
			if type(align) == "function" then
				local aligned = pcall(align, area)
				if not aligned then
					return nil, CODE.CALLBACK_FAILED
				end
			end
			-- NEW-1: `set_ranks`/`align_cards` (or another engine/mod hook) can
			-- replace or re-sort `area.cards`, so the local `cards` table is not
			-- authoritative. Re-read the live area and require the exact
			-- validated order and length; otherwise report a clean failure so
			-- the decision loop's bounded error limit stops a reorder that never
			-- sticks instead of looping forever.
			local applied = rget(area, "cards")
			if dense_count(applied, MAX_SELECTION) ~= #target.cards then
				return nil, CODE.CALLBACK_FAILED
			end
			for i = 1, #target.cards do
				if rawget(applied, i) ~= target.cards[i] then
					return nil, CODE.CALLBACK_FAILED
				end
			end
			return true
		end
		return nil, CODE.UNKNOWN_TYPE
	end

	function instance.dispatch(action)
		local ok, result, code = pcall(function()
			if not is_plain(action) then
				return nil, CODE.BAD_ACTION
			end
			if revoked then
				return nil, CODE.REVOKED
			end
			if last_validated == nil then
				return nil, CODE.ILLEGAL
			end
			local id = rget(action, "id")
			if type(id) ~= "string" or id ~= last_validated.id then
				return nil, CODE.BAD_ACTION
			end
			local capture, capture_code = capture_epoch()
			if capture == nil then
				return nil, capture_code or CODE.STALE_REVISION
			end
			if capture.epoch ~= last_validated.epoch then
				return nil, CODE.STALE_REVISION
			end
			local target, validate_code = validate_action(action)
			if target == nil then
				return nil, validate_code
			end
			local t = rget(action, "type")
			-- Build the completion anchor from the pre-callback engine state, then
			-- run the commit. A synchronous effect (reroll cost, phase change,
			-- target removal) must be detected as completion, so attaching the
			-- anchor after the callback would wrongly wait for a second effect.
			-- The anchor is attached only on an explicit committed `true`; a
			-- `false`/throwing callback leaves no latch (clean failure).
			local anchor = build_pending(t, target)
			local committed, commit_code = dispatch_commit(action, t, target)
			if committed == true then
				-- H5: `G.FUNCS.use_card` removes the card from its area
				-- synchronously (button_callbacks.lua:2209) before doing anything
				-- else, and `check_use` can early-return (Ankh with full joker
				-- slots). If the anchored source is still in its area right after
				-- the callback, nothing was committed: report a clean failure and
				-- attach NO latch so the stall timer cannot fire on a no-op.
				local leave_area = USE_CARD_LEAVE[t]
				if leave_area ~= nil and type(target) == "table" and card_in_area(leave_area, target) then
					return nil, CODE.CALLBACK_FAILED
				end
				pending = anchor
			end
			return committed, commit_code
		end)
		if not ok then
			last_validated = nil
			return nil, CODE.INTERNAL
		end
		last_validated = nil
		return result, code
	end

	function instance.advance_ui()
		local ok, result, code = pcall(function()
			local allowed, gate_code = gate()
			if allowed == nil then
				return nil, gate_code
			end
			local step = adapter.step()
			if type(step) ~= "table" or step.control == nil then
				-- NEW-2: no control is pending, so any latched control is stale
				-- (e.g. the engine left ROUND_EVAL without the AI pressing
				-- cash-out). Clear it before reporting NO_CONTROL so the next
				-- `capture` can proceed instead of being blocked forever.
				last_control = nil
				return nil, CODE.NO_CONTROL
			end
			if step.control == "cash_out" then
				if type(rget(G, "round_eval")) ~= "table" then
					return nil, CODE.ILLEGAL
				end
				-- C2: resolve the real cash-out element from G (the injected
				-- port is preferred when it yields one, but production wires a
				-- nil-returning default). `G.FUNCS.cash_out` only writes
				-- `e.config.button`, so the source-backed element is the
				-- `round_eval` cash-out button (or a faithful minimal element).
				-- Build the anchor from the pre-callback phase first.
				local e = resolve_element("cash_out")
				if type(e) ~= "table" then
					return nil, CODE.ELEMENT_MISSING
				end
				local anchor = build_pending("CASH_OUT", nil)
				local committed, commit_code = invoke("cash_out", e)
				if committed == true then
					pending = anchor
				end
				return committed, commit_code
			end
			return nil, CODE.NO_CONTROL
		end)
		if not ok then
			return nil, CODE.INTERNAL
		end
		return result, code
	end

	function instance.capture()
		local ok, result, code = pcall(function()
			local allowed, gate_code = gate()
			if allowed == nil then
				return nil, gate_code
			end
			local step = adapter.step()
			if type(step) ~= "table" then
				return nil, CODE.CAPTURE_FAILED
			end
			if step.control ~= nil then
				last_control = step.control
				return nil, CODE.CONTROL_REQUIRED
			end
			local handle, capture_code = reader.capture(step.runtime, step.ui_view)
			if handle == nil then
				return nil, capture_code or CODE.CAPTURE_FAILED
			end
			last_control = nil
			return handle, step.epoch
		end)
		if not ok then
			return nil, CODE.INTERNAL
		end
		return result, code
	end

	function instance.last_control_state()
		return last_control
	end

	-- Pending/stall status for the runtime coordinator (decision loop). The loop
	-- owns the polling cadence; this module only reports the latch state and never
	-- sleeps or touches the engine's timers. A stall timeout is a terminal fault
	-- (`exec_stall_timeout`) until the trusted bootstrap calls `cancel()` (session
	-- reset) or `revoke()`.
	function instance.pending_status()
		if revoked then
			return CODE.REVOKED
		end
		if fault ~= nil then
			return fault
		end
		if pending == nil then
			return nil
		end
		return CODE.PENDING
	end

	function instance.cancel()
		local had = pending ~= nil or fault ~= nil
		pending = nil
		fault = nil
		if had then
			return true, CODE.CANCELED
		end
		return false, CODE.NO_PENDING
	end

	function instance.revoke()
		revoked = true
		pending = nil
		fault = nil
		return true, CODE.REVOKED
	end

	function instance.broker_ports()
		return {
			capture = function()
				return instance.capture()
			end,
			validate = function(action, handle)
				local ok = instance.validate(action, handle)
				if ok == true then
					return true
				end
				return false
			end,
			dispatch = function(action)
				local ok = instance.dispatch(action)
				return ok == true
			end,
			pending = function()
				return instance.pending_status()
			end,
			cancel = function()
				return instance.cancel()
			end,
			revoke = function()
				return instance.revoke()
			end,
			-- Descriptive only. The current broker keeps production dispatch
			-- disabled (M2 guarantee); `mode`/`production` are NOT an
			-- authorization. Enabling dispatch requires the separate reviewed
			-- capability-minting change in docs/ENGINE_ADAPTER.md §7.
			mode = "M3_PRODUCTION",
			production = true,
		}
	end

	function instance.describe()
		local codes = {}
		for key, value in next, CODE do
			codes[key] = value
		end
		return {
			role = ROLE,
			session = session,
			pending = instance.pending_status(),
			faulted = fault ~= nil,
			stall_timeout = stall_timeout,
			has_clock = clock ~= nil,
			codes = codes,
		}
	end

	return instance
end

return ProductionExecutor
