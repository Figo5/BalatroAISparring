-- Trusted real-engine UI-view / certificate producer (AI staged runtime only).
--
-- The adapter turns ONE staged engine reference plus a trusted decision-context
-- awareness into the exact `runtime` + `ui_view` inputs expected by
-- `AISparring/integration/state_reader.lua` and the `AISparring/ai/*` schema.
--
-- Design constraints (docs/M2_SOURCE_MAP.md, docs/STATE_READER.md,
-- docs/M2_EXECUTION_BOUNDARY.md, docs/PLAYABLE_PLAN.md chunk 2):
--
--   * Globals-free. The engine is reached only through the injected ports and
--     fixed-path `rawget` reads, plus the *pure* read-only card predicates
--     `Card:can_sell_card` and `Card:can_use_consumeable` (used to stop the
--     catalogue offering an action the executor would refuse). No mutating
--     `can_*` UI callback (which repaints buttons / shows alerts), RNG, network,
--     log or filesystem access: those are never called here, not even for
--     hypothetical candidates.
--   * Fail closed. A field that cannot be read/attested is omitted; a required
--     decision context (ruleset, phase, an engine area backing a requested zone)
--     that cannot be proven fails the whole capture instead of guessing.
--   * Bounded, non-exhaustive candidate generation. The certificate catalog is a
--     bounded subset of UI-legitimate candidates built from visible hand/shop/
--     pack positions using only non-effectful raw gates. Compositeness lives in
--     the executor, never here.
--   * Always-forbidden data is never read: seeds, `G.deck`/draw order, deck
--     rank/suit aggregates, future shop/reroll/pack contents, `enemy.real_score`,
--     `enemy.highest_score`, raw `enemy.last_timer`/`timer`/`pvpTimerOrder`,
--     hidden face-down identity.
--
-- UI progression states that have no M2 observation phase (ROUND_EVAL cashout)
-- are reported as trusted non-policy `control` values; the production executor
-- performs them against the real UI element. PvP readiness is NOT a control: a
-- PvP blind on deck is a normal BLIND_SELECTION view whose policy SELECT_BLIND
-- the executor maps to the real ready button (`mp_toggle_ready`), leaving the
-- server's startBlind to invoke select_blind.

local EngineAdapter = {}

EngineAdapter.CODE = {
	OK = "engine_ok",
	BAD_PORTS = "engine_bad_ports",
	BAD_ROLE = "engine_bad_role",
	BAD_SESSION = "engine_bad_session",
	BAD_CODEC = "engine_bad_codec",
	BAD_REVISION = "engine_bad_revision",
	BAD_ENGINE = "engine_bad_engine",
	UNSUPPORTED_STATE = "engine_unsupported_state",
	NO_DECISION_STATE = "engine_no_decision_state",
	BUILD_FAILED = "engine_build_failed",
	REVISION_FAILED = "engine_revision_failed",
	INTERNAL = "engine_internal_error",
}

EngineAdapter.CONTROL = {
	CASH_OUT = "cash_out",
}

local CODE = EngineAdapter.CODE
local CONTROL = EngineAdapter.CONTROL

local ROLE = "ai_staged"
local SCHEMA_VERSION = 1

local LIMITS = {
	hand = 64,
	jokers = 64,
	consumables = 64,
	shop = 16,
	shop_booster = 16,
	vouchers = 16,
	booster = 16,
	targets = 16,
	scan = 256,
	max_play = 5,
	certificates = 120,
	selection = 40,
	token = 64,
	display = 32,
}

EngineAdapter.LIMITS = LIMITS
EngineAdapter.SCHEMA_VERSION = SCHEMA_VERSION

local PHASES = {
	BLIND_SELECTION = true,
	PLAY_HAND = true,
	DISCARD = true,
	SHOP = true,
	BOOSTER_SELECTION = true,
	CONSUMABLE_SELECTION = true,
	MULTIPLAYER_PVP = true,
	MATCH_COMPLETE = true,
}

local PHASE_ALLOWS_HAND = {
	BLIND_SELECTION = false,
	PLAY_HAND = true,
	DISCARD = true,
	SHOP = false,
	BOOSTER_SELECTION = true,
	CONSUMABLE_SELECTION = true,
	MULTIPLAYER_PVP = true,
	MATCH_COMPLETE = false,
}

-- Engine symbol by name; resolved at runtime so no numeric constant is trusted.
local ENGINE_SYMBOLS = {
	{ symbol = "BLIND_SELECT", phase = "BLIND_SELECTION" },
	{ symbol = "SELECTING_HAND", phase = "HAND_SELECT" },
	{ symbol = "SHOP", phase = "SHOP" },
	{ symbol = "TAROT_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "SPECTRAL_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "PLANET_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "STANDARD_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "BUFFOON_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "SMODS_BOOSTER_OPENED", phase = "BOOSTER_SELECTION" },
	{ symbol = "GAME_OVER", phase = "MATCH_COMPLETE" },
	{ symbol = "ROUND_EVAL", phase = "ROUND_EVAL_CONTROL" },
}

-- Terminal signal contract. `MP.GAME.won = true` followed by `win_game()` does
-- not necessarily set `G.STATE = G.STATES.GAME_OVER`, so the adapter cannot rely
-- on `MATCH_COMPLETE` alone to end a match. The runtime coordinator MUST stop the
-- decision loop explicitly when either `MP.GAME.won == true` or the engine state
-- is `GAME_OVER`; the `MATCH_COMPLETE` view remains a valid extra terminal signal
-- but is not guaranteed. No observation field is added for this (M2 schema kept
-- intact); the signal is read by the trusted coordinator, not by policy.

local TOKEN_PATTERN = "^[0-9A-Za-z_%.-]+$"
local DISPLAY_PATTERN = "^[0-9A-Za-z_%.,%%+%-/:<> ]+$"
local DIGIT = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }

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

-- Protected NORMAL indexing. A rawget only sees raw fields, but real engine
-- values are frequently computed by a metatable (`CardArea.config.card_limit`
-- is served by `__index` over `card_limits`, cardarea.lua:13-28) or inherited
-- from a class table. `rget` would read nil for those.
local function nget(obj, key)
	if type(obj) ~= "table" or key == nil then
		return nil
	end
	local ok, value = pcall(function()
		return obj[key]
	end)
	if not ok then
		return nil
	end
	return value
end

-- Real `CardArea` card limit, read through the config metatable.
local function area_limit(area)
	local config = nget(area, "config")
	local limit = nget(config, "card_limit")
	if is_nat(limit) then
		return limit
	end
	return nil
end

-- Room for one more card in `area` for the SPECIFIC `card`, mirroring the real
-- `G.FUNCS.check_for_buy_space` predicate (button_callbacks.lua:2444-2453,
-- which also drives SMODS `can_select_card`): `#area.cards + 1 +
-- card.ability.extra_slots_used <= area.config.card_limit +
-- card.ability.card_limit`. The UI callback is never called (it shows an
-- alert); only its raw arithmetic is reproduced. Returns nil when the card's
-- ability data is unavailable/not numeric so the caller can fall back.
local function buy_room(count, limit, card)
	local ability = rget(card, "ability")
	if type(ability) ~= "table" then
		return nil
	end
	local extra = nget(ability, "extra_slots_used")
	local bonus = nget(ability, "card_limit")
	if extra ~= nil and not is_nat(extra) then
		return nil
	end
	if bonus ~= nil and not is_nat(bonus) then
		return nil
	end
	return count + (1 + (extra or 0)) <= limit + (bonus or 0)
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

local function display_of(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	if string.match(value, DISPLAY_PATTERN) == nil then
		return nil
	end
	return value
end

local function dec_string(n)
	if n <= 0 then
		return "0"
	end
	local reversed = {}
	while n > 0 do
		local q = math.floor(n / 10)
		local r = n - q * 10
		reversed[#reversed + 1] = DIGIT[r + 1]
		n = q
	end
	local out = {}
	for i = #reversed, 1, -1 do
		out[#out + 1] = reversed[i]
	end
	return table.concat(out)
end

-- Dense, bounded 1..n array scan (same shape rule as the reader).
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

-- Returns the raw dense card array (or nil, code) for a top-level G area.
local function area_cards(G, area_key, limit)
	local area = rget(G, area_key)
	local cards = rget(area, "cards")
	local count = dense_count(cards, limit)
	if count == nil then
		return nil, nil
	end
	return cards, count
end

local function engine_pvp_boss(G)
	local blind = rpath(G, "GAME", "blind")
	if type(blind) ~= "table" then
		return nil
	end
	local pvp = rget(blind, "pvp")
	if pvp ~= nil and pvp ~= false then
		return true
	end
	local key = rpath(blind, "config", "blind", "key")
	if key == "bl_mp_nemesis" then
		return true
	end
	if type(key) == "string" and #key > 0 then
		return false
	end
	return nil
end

local function derive_engine_symbol(G)
	local states = rget(G, "STATES")
	if type(states) ~= "table" then
		return nil, CODE.UNSUPPORTED_STATE
	end
	local state = rget(G, "STATE")
	if not is_int(state) then
		return nil, CODE.UNSUPPORTED_STATE
	end
	local found = nil
	for i = 1, #ENGINE_SYMBOLS do
		local entry = ENGINE_SYMBOLS[i]
		local value = rget(states, entry.symbol)
		if is_int(value) and value == state then
			if found ~= nil and found ~= entry.phase then
				return nil, CODE.UNSUPPORTED_STATE
			end
			found = entry.phase
		end
	end
	if found == nil then
		return nil, CODE.UNSUPPORTED_STATE
	end
	return found
end

local function spendable_of(G)
	local game = rget(G, "GAME")
	local dollars = rget(game, "dollars")
	local bankrupt = rget(game, "bankrupt_at")
	if not is_int(dollars) or not is_int(bankrupt) then
		return nil
	end
	return dollars - bankrupt
end

local function edition_type(card)
	local edition = rget(card, "edition")
	if type(edition) ~= "table" then
		return nil
	end
	local kind = rget(edition, "type")
	if type(kind) == "string" then
		return kind
	end
	-- Edition tables built by the engine always set `.type`, but fail closed.
	if rget(edition, "negative") == true then
		return "negative"
	end
	return nil
end

local function center_key(card)
	local center = rpath(card, "config", "center")
	return token_of(rget(center, "key"), LIMITS.token)
end

local function ability_set(card)
	local ability = rget(card, "ability")
	local set = rget(ability, "set")
	if type(set) == "string" then
		return set
	end
	return nil
end

local function is_consumeable(card)
	-- Vanilla sets `self.ability.consumeable = center.config` (a table); mods may
	-- use any truthy value, so follow engine truthiness rather than `== true`.
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

local function is_face_up(card)
	return rget(card, "facing") == "front" and rget(card, "sprite_facing") == "front"
end

local function base_rank(card)
	local base = rget(card, "base")
	return token_of(rget(base, "value"), 8)
end

local function base_suit(card)
	local base = rget(card, "base")
	return token_of(rget(base, "suit"), 8)
end

-- Pure engine predicate call on one committed/attested card. Only the read-only
-- `Card:can_sell_card` / `Card:can_use_consumeable` predicates are consulted; the
-- mutating UI `can_*` callbacks (which repaint the button and show alerts) are
-- never invoked. Method resolution goes through normal metatable indexing.
local function call_predicate(card, name)
	if type(card) ~= "table" then
		return nil
	end
	local predicate = card[name]
	if type(predicate) ~= "function" then
		return nil
	end
	local ok, result = pcall(predicate, card)
	if not ok then
		return nil
	end
	return result
end

-- Rank/suit identity used for candidate grouping. A card contributes identity
-- only when it is face-up AND its base identity is not masked (Stone /
-- replace_base_card / no_rank / no_suit), mirroring the reader's `center_masks`.
-- A face-down or identity-masked card still appears positionally (a legal play)
-- but never shapes a rank/suit group, so hidden identities cannot leak through
-- the catalogue.
local function grouping_identity(card)
	if not is_face_up(card) then
		return nil, nil
	end
	local stone = rget(rget(card, "ability"), "effect") == "Stone Card"
	local center = rpath(card, "config", "center")
	local replace, no_rank, no_suit = false, false, false
	if type(center) == "table" then
		local function flag(name)
			local value = rawget(center, name)
			return value ~= nil and value ~= false
		end
		replace = flag("replace_base_card")
		no_rank = flag("no_rank")
		no_suit = flag("no_suit")
	end
	if stone or replace then
		return nil, nil
	end
	local rank = no_rank and nil or base_rank(card)
	local suit = no_suit and nil or base_suit(card)
	return rank, suit
end

local function seal_of(card)
	local seal = rget(card, "seal")
	if type(seal) == "string" then
		return token_of(seal, 32)
	end
	return nil
end

local function debuff_of(card)
	local debuff = rget(card, "debuff")
	if type(debuff) == "boolean" then
		return debuff
	end
	return nil
end

local function put(target, key, value)
	if value ~= nil then
		target[key] = value
	end
end

-- Per-kind `shown` attestation. A field is copied by the reader only when the
-- flag is exactly true; a field the adapter does not attest simply stays out.
local SHOWN = {
	card = { kind = true, rank = true, suit = true, center = true, edition = true, seal = true, debuff = true },
	joker = { center = true, edition = true, seal = true, debuff = true },
	consumable = { center = true, edition = true, debuff = true },
	shop_item = { kind = true, rank = true, suit = true, center = true, edition = true, seal = true, debuff = true, cost = true, sell_cost = true },
	voucher = { center = true, cost = true },
}

local function shown_copy(kind)
	local source = SHOWN[kind]
	local out = {}
	for key in next, source do
		out[key] = true
	end
	return out
end

local function redacted()
	return { face_down = true }
end

-- Playing-card record for hand/booster/target zones.
local function build_play_card(card)
	if not is_face_up(card) then
		return redacted()
	end
	local record = { face_down = false, shown = shown_copy("card") }
	record.kind = "card"
	put(record, "center", center_key(card))
	put(record, "rank", base_rank(card))
	put(record, "suit", base_suit(card))
	put(record, "edition", token_of(edition_type(card), 32))
	put(record, "seal", seal_of(card))
	put(record, "debuff", debuff_of(card))
	return record
end

local function build_joker(card)
	if not is_face_up(card) then
		return redacted()
	end
	local record = { face_down = false, shown = shown_copy("joker") }
	put(record, "center", center_key(card))
	put(record, "edition", token_of(edition_type(card), 32))
	put(record, "seal", seal_of(card))
	put(record, "debuff", debuff_of(card))
	return record
end

local function build_consumable(card)
	if not is_face_up(card) then
		return redacted()
	end
	local record = { face_down = false, shown = shown_copy("consumable") }
	put(record, "center", center_key(card))
	put(record, "edition", token_of(edition_type(card), 32))
	put(record, "debuff", debuff_of(card))
	return record
end

local function build_shop_item(card)
	if not is_face_up(card) then
		return redacted()
	end
	local record = { face_down = false, shown = shown_copy("shop_item") }
	put(record, "kind", token_of(item_kind(card), 32))
	put(record, "center", center_key(card))
	put(record, "rank", base_rank(card))
	put(record, "suit", base_suit(card))
	put(record, "edition", token_of(edition_type(card), 32))
	put(record, "seal", seal_of(card))
	put(record, "debuff", debuff_of(card))
	local cost = rget(card, "cost")
	if is_nat(cost) then
		record.cost = cost
	end
	local sell_cost = rget(card, "sell_cost")
	if is_nat(sell_cost) then
		record.sell_cost = sell_cost
	end
	return record
end

local function build_voucher(card)
	if not is_face_up(card) then
		return redacted()
	end
	local record = { face_down = false, shown = shown_copy("voucher") }
	put(record, "center", center_key(card))
	local cost = rget(card, "cost")
	if is_nat(cost) then
		record.cost = cost
	end
	return record
end

local function build_zone(cards, count, builder)
	local out = {}
	for i = 1, count do
		local card = rawget(cards, i)
		if type(card) ~= "table" then
			return nil
		end
		out[#out + 1] = builder(card)
	end
	return out
end

-- Card-area slot room, mirroring the real `check_for_buy_space` raw predicate
-- without calling the UI callback (which shows an alert as a side effect). The
-- specific card's `ability.extra_slots_used` / `ability.card_limit` are honoured
-- when readable; otherwise the negative-edition rule is the fallback.
local function slot_room(G, area_key, card, negative)
	local area = rget(G, area_key)
	local cards = rget(area, "cards")
	local count = dense_count(cards, LIMITS.scan)
	local limit = area_limit(area)
	if count == nil or limit == nil then
		return nil
	end
	if type(card) == "table" then
		local room = buy_room(count, limit, card)
		if room ~= nil then
			return room
		end
	end
	if negative then
		return count < limit + 1
	end
	return count < limit
end

local function int_field(value)
	if is_nat(value) then
		return value
	end
	return nil
end

-- Bounded, primitive-only signature of the decision-relevant engine fields that
-- are consumed by the reader but are not part of the adapter view (money,
-- resources, phase gates, MP visibility gates). The view alone would miss them,
-- so the trusted revision fingerprint is computed over `signature + view`.
-- Raw timers are deliberately excluded: they change every frame and are not part
-- of the emitted observation (timer projection is unwired).
local function decision_signature(G, MP)
	local sig = {}
	local function put_int(key, value)
		if is_int(value) then
			sig[key] = value
		end
	end
	local function put_bool(key, value)
		if type(value) == "boolean" then
			sig[key] = value
		end
	end
	local function put_str(key, value)
		if type(value) == "string" and #value > 0 and #value <= 64 then
			sig[key] = value
		end
	end
	local game = rget(G, "GAME")
	put_int("dollars", rget(game, "dollars"))
	put_int("bankrupt_at", rget(game, "bankrupt_at"))
	put_int("chips", rget(game, "chips"))
	put_int("stop_use", rget(game, "STOP_USE"))
	put_int("ante", rpath(game, "round_resets", "ante"))
	put_int("round", rget(game, "round"))
	put_int("pack_choices", rget(game, "pack_choices"))
	put_str("blind_on_deck", rget(game, "blind_on_deck"))
	put_bool("block_play", rpath(game, "blind", "block_play"))
	local current_round = rget(game, "current_round")
	put_int("hands_left", rget(current_round, "hands_left"))
	put_int("discards_left", rget(current_round, "discards_left"))
	put_int("hands_played", rget(current_round, "hands_played"))
	put_int("reroll_cost", rget(current_round, "reroll_cost"))
	put_bool("locked", rget(rget(G, "CONTROLLER"), "locked"))
	local mp_game = rget(MP, "GAME")
	put_int("lives", rget(mp_game, "lives"))
	put_bool("timer_started", rget(mp_game, "timer_started"))
	put_bool("ready_blind", rget(mp_game, "ready_blind"))
	local enemy = rget(mp_game, "enemy")
	put_bool("info_received", rget(enemy, "info_received"))
	put_str("score_text", rget(enemy, "score_text"))
	put_str("hands_text", rget(enemy, "hands_text"))
	put_int("enemy_lives", rget(enemy, "lives"))
	return sig
end

local function build_match(G, MP)
	local lobby = rget(MP, "LOBBY")
	local config = rget(lobby, "config")
	local ruleset = rget(config, "ruleset")
	if type(ruleset) ~= "string" then
		ruleset = rget(rget(MP, "SP"), "ruleset")
	end
	local projected = token_of(ruleset, LIMITS.token)
	if projected == nil then
		return nil
	end
	local match = { ruleset = projected }
	local blind_key = rget(rget(rget(rget(rget(G, "GAME"), "blind"), "config"), "blind"), "key")
	put(match, "blind", display_of(blind_key, LIMITS.display))
	local lives = rget(rget(MP, "GAME"), "lives")
	put(match, "lives", int_field(lives))
	local resets = rpath(G, "GAME", "round_resets")
	put(match, "hands_per_round", int_field(rget(resets, "hands")))
	put(match, "discards_per_round", int_field(rget(resets, "discards")))
	put(match, "hand_size", int_field(area_limit(rget(G, "hand"))))
	put(match, "joker_slots", int_field(area_limit(rget(G, "jokers"))))
	put(match, "consumable_slots", int_field(area_limit(rget(G, "consumeables"))))
	return match
end

local function build_self(G, phase, hand_cards)
	local out = {}
	local game = rget(G, "GAME")
	local chips = rget(game, "chips")
	if type(chips) == "number" and chips == chips and chips ~= math.huge and chips ~= -math.huge then
		local floor = math.floor(chips)
		if floor >= 0 then
			out.current_score = dec_string(floor)
		end
	end

	local cards = {}
	local jokers, joker_count = area_cards(G, "jokers", LIMITS.jokers)
	local consumeables, consume_count = area_cards(G, "consumeables", LIMITS.consumables)
	if jokers == nil or consumeables == nil then
		return nil
	end
	local joker_records = build_zone(jokers, joker_count, build_joker)
	local consumable_records = build_zone(consumeables, consume_count, build_consumable)
	if joker_records == nil or consumable_records == nil then
		return nil
	end
	cards.joker = joker_records
	cards.consumable = consumable_records
	local hand_visible = false
	if PHASE_ALLOWS_HAND[phase] == true and hand_cards ~= nil then
		local hand_records = build_zone(hand_cards, #hand_cards, build_play_card)
		if hand_records == nil then
			return nil
		end
		cards.hand = hand_records
		hand_visible = true
	end
	out.hand_visible = hand_visible
	out.cards = cards
	return out
end

local function build_opponent(G, MP)
	local enemy = rpath(MP, "GAME", "enemy")
	if type(enemy) ~= "table" then
		return nil
	end
	local info = rget(enemy, "info_received")
	if info ~= true then
		return nil
	end
	local config = rpath(MP, "LOBBY", "config")
	local out = { certified = true }
	local has = false
	local score = display_of(rget(enemy, "score_text"), LIMITS.display)
	if score ~= nil then
		out.score_visible = true
		out.displayed_score = score
		has = true
	end
	local hands = rget(enemy, "hands")
	if is_nat(hands) and hands <= 99 then
		-- The opponent's hands are only as visible as the rendered `hands_text`
		-- string ("???" while masked until an enemyInfo arrives). Mirror that
		-- exact visibility: emit a count only when the text is the matching
		-- decimal, never the raw numeric field alone.
		local hands_text = rget(enemy, "hands_text")
		if type(hands_text) == "string" and string.match(hands_text, "^%d+$") ~= nil then
			local parsed = tonumber(hands_text)
			if is_nat(parsed) and parsed == hands then
				out.hands_visible = true
				out.hands = parsed
				has = true
			end
		end
	end
	local lives = rget(enemy, "lives")
	if is_nat(lives) then
		out.lives_visible = true
		out.lives = lives
		has = true
	end
	if rget(config, "enemy_location_disabled") == false then
		local location = display_of(rget(enemy, "location"), LIMITS.display)
		if location ~= nil then
			out.location_visible = true
			out.location = location
			has = true
		end
	end
	if not has then
		return nil
	end
	return out
end

local function build_context(G, phase)
	local game = rget(G, "GAME")
	local stop_use = rget(game, "STOP_USE")
	local locked = rget(rget(G, "CONTROLLER"), "locked")
	local play = rget(rget(G, "play"), "cards")
	local play_count = dense_count(play, LIMITS.scan)
	if play_count == nil then
		if play == nil then
			play_count = 0
		else
			return nil
		end
	end
	local blocked = false
	if is_int(stop_use) and stop_use > 0 then
		blocked = true
	end
	if locked ~= nil and locked ~= false then
		blocked = true
	end
	if play_count > 0 and PHASE_ALLOWS_HAND[phase] == true then
		blocked = true
	end

	-- Timer eligibility is intentionally NOT projected. `ui/game/timer.lua`
	-- (413-500) distinguishes `MP.GAME.nemesis_timer_started` (PvP) from
	-- `MP.GAME.timer_started` (Major League normal timers), and a consumed normal
	-- timer costs a life without globally forbidding further play. Rather than
	-- invent an expiry rule from an unverified field, the adapter reports
	-- `timer_expired = false` (no adapter veto) and leaves the engine's own timer
	-- and callbacks authoritative; the executor still re-checks the real gates
	-- immediately before any committed action. Field is kept for schema fidelity.
	local timer_expired = false

	-- The real discard CardArea carries `card_limit = 500` (game.lua:2250) and is
	-- not the discard bound: the hand's highlight limit is. Discarding is capped
	-- by how many cards the hand can highlight (`CardArea.highlighted_limit`,
	-- default 5, cardarea.lua:18) and by the play limit.
	local max_discard = int_field(rpath(G, "hand", "config", "highlighted_limit")) or LIMITS.max_play
	if max_discard > LIMITS.max_play then
		max_discard = LIMITS.max_play
	end
	return {
		blocked = blocked,
		timer_expired = timer_expired,
		target_selection = false,
		max_play = LIMITS.max_play,
		max_discard = max_discard,
	}
end

local function build_shop(G)
	local shop = {}
	local items, item_count = area_cards(G, "shop_jokers", LIMITS.shop)
	if items == nil then
		return nil
	end
	local item_records = build_zone(items, item_count, build_shop_item)
	if item_records == nil then
		return nil
	end
	for i = 1, #item_records do
		if item_records[i].kind == "booster" then
			-- A pack must never appear in the generic shop zone (schema rejects).
			return nil
		end
	end
	shop.items = item_records

	local boosters, booster_count = area_cards(G, "shop_booster", LIMITS.shop_booster)
	if boosters ~= nil then
		local booster_records = build_zone(boosters, booster_count, build_shop_item)
		if booster_records == nil then
			return nil
		end
		shop.boosters = booster_records
	end
	local vouchers, voucher_count = area_cards(G, "shop_vouchers", LIMITS.vouchers)
	if vouchers ~= nil then
		local voucher_records = build_zone(vouchers, voucher_count, build_voucher)
		if voucher_records == nil then
			return nil
		end
		shop.vouchers = voucher_records
	end
	put(shop, "reroll_cost", int_field(rpath(G, "GAME", "current_round", "reroll_cost")))
	return shop
end

local function build_booster(G)
	local cards, count = area_cards(G, "pack_cards", LIMITS.booster)
	if cards == nil then
		return nil
	end
	local records = build_zone(cards, count, build_play_card)
	if records == nil then
		return nil
	end
	local booster = { cards = records }
	put(booster, "choices", int_field(rpath(G, "GAME", "pack_choices")))
	put(booster, "skips", int_field(rpath(G, "GAME", "skips")))
	return booster
end

local function build_consumable_target(G, hand_cards, target)
	local source_ordinal = rget(target, "source_ordinal")
	if not is_int(source_ordinal) or source_ordinal < 1 or source_ordinal > LIMITS.consumables then
		return nil
	end
	local consumeables, consume_count = area_cards(G, "consumeables", LIMITS.consumables)
	if consumeables == nil or source_ordinal > consume_count then
		return nil
	end
	local source_card = rawget(consumeables, source_ordinal)
	if type(source_card) ~= "table" then
		return nil
	end
	local source_record = build_consumable(source_card)
	-- The reader derives `source_ref` from `source.ordinal`; a redacted source
	-- carries no ordinal and would fail closed, so require a visible source.
	if source_record.face_down ~= false then
		return nil
	end
	source_record.ordinal = source_ordinal
	local out = {
		source = source_record,
		source_ref = "consumable:" .. dec_string(source_ordinal),
	}
	local min_targets = rget(target, "min_targets")
	local max_targets = rget(target, "max_targets")
	put(out, "min_targets", int_field(min_targets))
	put(out, "max_targets", int_field(max_targets))
	if hand_cards ~= nil then
		-- One target record per hand position so the observation-local
		-- `target:p` id equals the engine hand ordinal `p` (no aliasing).
		local targets = {}
		for i = 1, #hand_cards do
			local record = build_play_card(rawget(hand_cards, i))
			record.ordinal = i
			targets[#targets + 1] = record
		end
		out.targets = targets
	end
	return out
end

local function byte_less(a, b)
	local na, nb = #a, #b
	local n = na < nb and na or nb
	for i = 1, n do
		local ba = string.byte(a, i)
		local bb = string.byte(b, i)
		if ba ~= bb then
			return ba < bb
		end
	end
	return na < nb
end

-- Visible-rank numeric order used only to detect five-card straights over the
-- ranks the HUD actually shows. Nothing outside this table is read.
local RANK_VALUE = {
	["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6, ["7"] = 7,
	["8"] = 8, ["9"] = 9, ["10"] = 10, ["Jack"] = 11, ["Queen"] = 12,
	["King"] = 13, ["Ace"] = 14,
}

-- Bounded, deterministic selections of hand ordinals, ordered so that useful
-- 3-5 card hands reach the catalogue before the pair enumeration can fill the
-- cap. Priority:
--   1. visible rank groups (pairs / triples / quads);
--   2. two pair and full house over visible ranks;
--   3. five-card straights over visible ranks (Ace high and low);
--   4. five-card flush candidates over visible suits;
--   5. contiguous 3..max_k windows (positional multi-card plays/discards);
--   6. singletons;
--   7. lexicographic pairs (so simple non-adjacent pairs are always visible);
--   8. contiguous 2-card windows.
-- Each type is independently capped, so 28 lexicographic pairs of an 8-card
-- hand can never starve the structured hands. Rank/suit identity comes only
-- from face-up, unmasked cards (`grouping_identity`): a face-down or
-- Stone/no_rank/no_suit card appears positionally but never groups, so hidden
-- identities cannot change or leak through the policy-visible catalogue.
local function hand_selections(cards, count, max_k, cap)
	local out = {}
	local seen = {}
	local function add(selection)
		if #out >= cap then
			return false
		end
		local key = table.concat(selection, ",")
		if seen[key] then
			return false
		end
		seen[key] = true
		out[#out + 1] = selection
		return true
	end
	local function add_type(list, limit)
		local added = 0
		for i = 1, #list do
			if added >= limit then
				return
			end
			if add(list[i]) then
				added = added + 1
			end
		end
	end

	local ranks = {}
	local rank_order = {}
	local suits = {}
	local suit_order = {}
	for i = 1, count do
		local rank, suit = grouping_identity(rawget(cards, i))
		if rank ~= nil then
			local group = ranks[rank]
			if group == nil then
				group = {}
				ranks[rank] = group
				rank_order[#rank_order + 1] = rank
			end
			group[#group + 1] = i
		end
		if suit ~= nil then
			local group = suits[suit]
			if group == nil then
				group = {}
				suits[suit] = group
				suit_order[#suit_order + 1] = suit
			end
			group[#group + 1] = i
		end
	end
	table.sort(rank_order, byte_less)
	table.sort(suit_order, byte_less)

	-- 1. rank groups, largest multiplicity first.
	local rank_groups = {}
	for k = 1, #rank_order do
		local group = ranks[rank_order[k]]
		if #group >= 2 and #group <= max_k then
			rank_groups[#rank_groups + 1] = group
		end
	end
	table.sort(rank_groups, function(a, b)
		if #a ~= #b then
			return #a > #b
		end
		return a[1] < b[1]
	end)
	add_type(rank_groups, 12)

	-- 2. two pair and full house.
	local pair_groups, triple_groups = {}, {}
	for k = 1, #rank_order do
		local group = ranks[rank_order[k]]
		if #group == 2 then
			pair_groups[#pair_groups + 1] = group
		elseif #group == 3 then
			triple_groups[#triple_groups + 1] = group
		end
	end
	if max_k >= 4 then
		local two_pair = {}
		for a = 1, #pair_groups - 1 do
			for b = a + 1, #pair_groups do
				two_pair[#two_pair + 1] = {
					pair_groups[a][1], pair_groups[a][2], pair_groups[b][1], pair_groups[b][2],
				}
			end
		end
		add_type(two_pair, 8)
	end
	if max_k >= 5 then
		local full_house = {}
		for a = 1, #triple_groups do
			for b = 1, #pair_groups do
				full_house[#full_house + 1] = {
					triple_groups[a][1], triple_groups[a][2], triple_groups[a][3],
					pair_groups[b][1], pair_groups[b][2],
				}
			end
		end
		add_type(full_house, 8)
	end

	-- 3. straights of five over visible ranks (Ace high and Ace low).
	if max_k >= 5 then
		local by_value = {}
		for k = 1, #rank_order do
			local value = RANK_VALUE[rank_order[k]]
			if value ~= nil and by_value[value] == nil then
				by_value[value] = ranks[rank_order[k]][1]
			end
		end
		if by_value[14] ~= nil and by_value[1] == nil then
			by_value[1] = by_value[14]
		end
		local straights = {}
		local starts = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
		for s = 1, #starts do
			local run = {}
			local complete = true
			for step = 0, 4 do
				local ordinal = by_value[starts[s] + step]
				if ordinal == nil then
					complete = false
					break
				end
				run[#run + 1] = ordinal
			end
			if complete then
				straights[#straights + 1] = run
			end
		end
		add_type(straights, 8)
	end

	-- 4. flush candidates (first five of a visible suit).
	if max_k >= 5 then
		local flushes = {}
		for k = 1, #suit_order do
			local group = suits[suit_order[k]]
			if #group >= 5 then
				flushes[#flushes + 1] = { group[1], group[2], group[3], group[4], group[5] }
			end
		end
		add_type(flushes, 4)
	end

	-- 5. contiguous positional windows for k = 3..max_k.
	for k = 3, max_k do
		local windows = {}
		local last = count - k + 1
		for start = 1, last do
			local selection = {}
			for offset = 0, k - 1 do
				selection[#selection + 1] = start + offset
			end
			windows[#windows + 1] = selection
		end
		add_type(windows, 12)
	end

	-- 6. singletons.
	local singles = {}
	for i = 1, count do
		singles[#singles + 1] = { i }
	end
	add_type(singles, 64)

	-- 7. lexicographic pairs (last, so they cannot starve the hands above).
	local pairs = {}
	for i = 1, count - 1 do
		for j = i + 1, count do
			pairs[#pairs + 1] = { i, j }
		end
	end
	add_type(pairs, 20)

	return out
end

local function ref(zone, ordinal)
	return zone .. ":" .. dec_string(ordinal)
end

local function build_hand_selection_refs(selection)
	local refs = {}
	for i = 1, #selection do
		refs[#refs + 1] = ref("hand", selection[i])
	end
	return refs
end

local function certificate_builder()
	local items = {}
	local function add(item)
		if #items >= LIMITS.certificates then
			return
		end
		items[#items + 1] = item
	end
	return { items = items, add = add }
end

-- Engine ordinals (1-based) of blind-forced hand cards. A forced card cannot be
-- un-highlighted (`CardArea:remove_from_highlighted`, cardarea.lua:187-188), so
-- a play/discard that omits one is a selection the executor refuses. Read only
-- the raw `ability.forced_selection` flag; hidden identities are never touched.
local function forced_hand_ordinals(G)
	local cards, count = area_cards(G, "hand", LIMITS.hand)
	if cards == nil then
		return nil
	end
	local out = {}
	for i = 1, count do
		local card = rawget(cards, i)
		if type(card) == "table" and rget(rget(card, "ability"), "forced_selection") == true then
			out[#out + 1] = i
		end
	end
	return out
end

local function selection_has_forced(selection, forced)
	if forced == nil or #forced == 0 then
		return true
	end
	local present = {}
	for i = 1, #selection do
		present[selection[i]] = true
	end
	for i = 1, #forced do
		if present[forced[i]] ~= true then
			return false
		end
	end
	return true
end

local function cert_play_discard(builder, t, hand_cards, max_k, forced)
	local cap = LIMITS.selection
	local selections = hand_selections(hand_cards, #hand_cards, max_k, cap)
	for i = 1, #selections do
		-- H3 alignment: never offer a selection the executor must refuse because
		-- it omits a forced card. The executor still re-checks the same rule.
		if selection_has_forced(selections[i], forced) then
			builder.add({ type = t, certified = true, card_refs = build_hand_selection_refs(selections[i]) })
		end
	end
end

-- Vanilla `Card:can_sell_card` (card.lua:1640) is the exact UI gate: area type
-- `joker` (game.lua:2239 gives `G.consumeables` that type), not eternal, and the
-- tutorial/seed/ante condition (`G.SETTINGS.tutorial_complete or
-- G.GAME.pseudorandom.seed ~= 'TUTORIAL' or ante > 1`). The adapter must not read
-- the seed itself, so it consults the read-only engine predicate on each
-- candidate instead of approximating the tutorial clause; the executor
-- re-checks the same predicate on the committed card. Only face-up cards are
-- offered.
local function cert_sell_area(builder, G, area_key, limit, zone, cert_type, ref_field)
	local cards, count = area_cards(G, area_key, limit)
	if cards == nil then
		return
	end
	for i = 1, count do
		local card = rawget(cards, i)
		if type(card) == "table" and is_face_up(card) and call_predicate(card, "can_sell_card") == true then
			builder.add({ type = cert_type, certified = true, [ref_field] = ref(zone, i) })
		end
	end
end

local function cert_sell_jokers(builder, G)
	cert_sell_area(builder, G, "jokers", LIMITS.jokers, "joker", "SELL_JOKER", "joker_ref")
end

local function cert_sell_consumables(builder, G)
	cert_sell_area(builder, G, "consumeables", LIMITS.consumables, "consumable", "SELL_CONSUMABLE", "consumable_ref")
end

local function needs_targets(card)
	local consumeable = rget(rget(card, "ability"), "consumeable")
	if type(consumeable) ~= "table" then
		return true
	end
	return rawget(consumeable, "max_highlighted") ~= nil
end

-- `Card:check_use` (card.lua:1581-1588) makes `G.FUNCS.use_card` a no-op for an
-- Ankh while the joker area is full. The real engine sets `ability.name` from the
-- center (`Card:set_ability`, card.lua:278) and stamps each center with its key
-- (`game.lua:814-815`), so Ankh is identified by its engine name or its real
-- center key `c_ankh` (`G.P_CENTERS.c_ankh.name == "Ankh"`, game.lua:581).
local function is_ankh(card)
	if rget(rget(card, "ability"), "name") == "Ankh" then
		return true
	end
	return rget(rpath(card, "config", "center"), "key") == "c_ankh"
end

-- True when the engine's real `check_use` slot predicate lets this card commit.
local function check_use_ok(G, card)
	if not is_ankh(card) then
		return true
	end
	local jokers = rget(G, "jokers")
	local jcount = dense_count(rget(jokers, "cards"), LIMITS.jokers)
	local jlimit = area_limit(jokers)
	return jcount ~= nil and jlimit ~= nil and jcount < jlimit
end

local function cert_use_consumables(builder, G)
	local consumeables, count = area_cards(G, "consumeables", LIMITS.consumables)
	if consumeables == nil then
		return
	end
	for i = 1, count do
		local card = rawget(consumeables, i)
		-- Offer only consumables the engine's own read-only predicate accepts
		-- (empty-target ones: a highlighted-target consumable is validated by
		-- the executor's post-highlight check). This stops the adapter offering
		-- an action the executor would then refuse (H4c): e.g. Ankh with full
		-- joker slots, Aura/Familiar with nothing highlighted, Emperor with full
		-- consumable slots.
		local offered = type(card) == "table" and is_face_up(card) and not needs_targets(card)
			and call_predicate(card, "can_use_consumeable") == true
		if offered and not check_use_ok(G, card) then
			-- Ankh with full joker slots: `use_card` is a no-op (`check_use`),
			-- so it must not be offered (H4c/H5).
			offered = false
		end
		if offered then
			builder.add({
				type = "USE_CONSUMABLE",
				certified = true,
				source_ref = ref("consumable", i),
				target_refs = {},
			})
		end
	end
end

-- Bounded "meaningful" reorders. There is no discrete reorder callback in the
-- engine (Multiplayer logs drag/drop by diffing CardArea order), so the
-- executor commits the same area-order permutation the drag would produce. To
-- keep the catalogue small and useful, only the reverse order and each single
-- adjacent swap are offered: every entry is a non-no-op permutation.
local REORDER_SWAP_LIMIT = 16

local function cert_reorders(builder, G, zone, area_key, limit)
	local cards, count = area_cards(G, area_key, limit)
	if cards == nil or count < 2 then
		return
	end
	for i = 1, count do
		local card = rawget(cards, i)
		if type(card) == "table" and rget(card, "pinned") == true then
			-- The engine's own `CardArea:align_cards` forcibly re-sorts pinned
			-- jokers (cardarea.lua:528), so a permutation that moves one is not
			-- authoritative. Offer only permutations the engine will honour.
			return
		end
	end
	local seen = {}
	local function add_order(ordinals)
		local refs = {}
		for i = 1, count do
			refs[i] = ref(zone, ordinals[i])
		end
		local key = table.concat(ordinals, ",")
		if seen[key] then
			return
		end
		seen[key] = true
		builder.add({ type = "REORDER_" .. string.upper(zone == "joker" and "JOKERS" or "HAND"), certified = true, order = refs })
	end
	if zone ~= "joker" and zone ~= "hand" then
		return
	end
	local base = {}
	for i = 1, count do
		base[i] = i
	end
	local reversed = {}
	for i = 1, count do
		reversed[i] = count + 1 - i
	end
	add_order(reversed)
	local swaps = count - 1
	if swaps > REORDER_SWAP_LIMIT then
		swaps = REORDER_SWAP_LIMIT
	end
	for i = 1, swaps do
		base[i], base[i + 1] = base[i + 1], base[i]
		add_order(base)
		base[i], base[i + 1] = base[i + 1], base[i]
	end
end

local function cert_shop(builder, G)
	local spendable = spendable_of(G)
	local items, item_count = area_cards(G, "shop_jokers", LIMITS.shop)
	if items == nil then
		return
	end
	for i = 1, item_count do
		local card = rawget(items, i)
		if type(card) == "table" and is_face_up(card) then
			local kind = item_kind(card)
			local cost = rget(card, "cost")
			if (kind == "card" or kind == "joker" or kind == "consumable") and is_nat(cost) then
				local affordable = cost <= 0 or (spendable ~= nil and spendable >= cost)
				if affordable then
					local item_ref = ref("shop", i)
					if kind == "joker" then
						local room = slot_room(G, "jokers", card, edition_type(card) == "negative")
						if room == true then
							builder.add({ type = "BUY_ITEM", certified = true, item_ref = item_ref, capacity_ok = true })
						end
					elseif kind == "consumable" then
						local room = slot_room(G, "consumeables", card, edition_type(card) == "negative")
						if room == true then
							builder.add({ type = "BUY_ITEM", certified = true, item_ref = item_ref, capacity_ok = true })
						end
					else
						builder.add({ type = "BUY_ITEM", certified = true, item_ref = item_ref })
					end
				end
			end
		end
	end

	local boosters, booster_count = area_cards(G, "shop_booster", LIMITS.shop_booster)
	if boosters ~= nil then
		for i = 1, booster_count do
			local card = rawget(boosters, i)
			if type(card) == "table" and is_face_up(card) and item_kind(card) == "booster" then
				local cost = rget(card, "cost")
				if is_nat(cost) and (cost <= 0 or (spendable ~= nil and spendable >= cost)) then
					builder.add({ type = "OPEN_BOOSTER", certified = true, item_ref = ref("shop_booster", i) })
				end
			end
		end
	end

	local vouchers, voucher_count = area_cards(G, "shop_vouchers", LIMITS.vouchers)
	if vouchers ~= nil then
		for i = 1, voucher_count do
			local card = rawget(vouchers, i)
			if type(card) == "table" and is_face_up(card) then
				local cost = rget(card, "cost")
				if is_nat(cost) and spendable ~= nil and spendable >= cost then
					builder.add({ type = "BUY_VOUCHER", certified = true, voucher_ref = ref("shop_voucher", i) })
				end
			end
		end
	end

	local reroll = rpath(G, "GAME", "current_round", "reroll_cost")
	if is_nat(reroll) and (reroll <= 0 or (spendable ~= nil and spendable >= reroll)) then
		builder.add({ type = "REROLL", certified = true })
	end
	builder.add({ type = "LEAVE_SHOP", certified = true })
end

-- True when the on-deck blind is the Multiplayer PvP blind. Mirrors the
-- executor's routing: `round_resets.blind_choices[on_deck] == "bl_mp_nemesis"`
-- or a `pvp_blind_choices[on_deck]` entry. In that context `SELECT_BLIND` maps
-- to the real ready button, never to vanilla `select_blind`.
local function pvp_blind_on_deck(G)
	local game = rget(G, "GAME")
	local on_deck = rget(game, "blind_on_deck")
	if type(on_deck) ~= "string" then
		return false
	end
	local resets = rget(game, "round_resets")
	if rget(rget(resets, "blind_choices"), on_deck) == "bl_mp_nemesis" then
		return true
	end
	local pvp_choice = rget(rget(resets, "pvp_blind_choices"), on_deck)
	return pvp_choice ~= nil and pvp_choice ~= false
end

local function cert_blind(builder, G, MP)
	local blind_select = rget(G, "blind_select")
	if type(blind_select) == "table" then
		-- H4a: once the AI has readied (waiting for the human/server), do not
		-- offer a further SELECT_BLIND. An empty catalogue makes the decision
		-- loop back off and wait instead of selecting an action the executor
		-- deterministically refuses.
		local ready = rget(rget(MP, "GAME"), "ready_blind") == true
		if not (pvp_blind_on_deck(G) and ready) then
			builder.add({ type = "SELECT_BLIND", certified = true })
		end
	end
	local game = rget(G, "GAME")
	local on_deck = rget(game, "blind_on_deck")
	local states = rpath(game, "round_resets", "blind_states")
	-- H4b: vanilla only mounts a skip button (and a `tag_container`) on the
	-- Small/Big blinds; the boss blind's state is `Select` too, but a skip there
	-- has no effect (`skip_blind` guards on `_tag`). Limit skips to Small/Big.
	if (on_deck == "Small" or on_deck == "Big")
		and type(states) == "table" and rget(states, on_deck) == "Select" then
		builder.add({ type = "SKIP_BLIND", certified = true })
	end
end

local STATE_BLOCKING = {
	HAND_PLAYED = true,
	DRAW_TO_HAND = true,
	PLAY_TAROT = true,
}

local function consumable_use_available(G)
	local state = rget(G, "STATE")
	local states = rget(G, "STATES")
	local blocked = false
	for symbol in next, STATE_BLOCKING do
		local value = rget(states, symbol)
		if is_int(value) and value == state then
			blocked = true
		end
	end
	return not blocked
end

local function cert_booster(builder, G)
	local cards, count = area_cards(G, "pack_cards", LIMITS.booster)
	if cards == nil then
		return
	end
	local choices = rpath(G, "GAME", "pack_choices")
	if is_int(choices) and choices > 0 then
		for i = 1, count do
			local card = rawget(cards, i)
			if type(card) == "table" and is_face_up(card) then
				local kind = item_kind(card)
				local card_ref = ref("booster", i)
				if kind == "joker" then
					-- L3: this build's `can_select_card` (button_callbacks.lua:
					-- 2135-2145) allows a joker only when `#G.jokers.cards <
					-- card_limit + (ability.card_limit - ability.extra_slots_used)`
					-- (exactly `buy_room`); a negative joker fits one over the
					-- limit, not unconditionally. The negative-edition rule is only
					-- the fallback when ability data is unreadable.
					if slot_room(G, "jokers", card, edition_type(card) == "negative") == true then
						builder.add({ type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { card_ref }, capacity_ok = true })
					end
				elseif kind == "consumable" then
					-- C1: a consumable in a pack is USED on selection, not
					-- stored, so the gate is the engine's own
					-- `Card:can_use_consumeable` (button_callbacks.lua:2102) --
					-- never a free-slot check. Without it, picking a
					-- highlight-required Tarot (Talisman/Aura/Cryptid/...) with
					-- nothing highlighted crashes inside the queued event, and
					-- Judgement/Soul/Wraith can over-fill the joker slots. B:
					-- the same `check_use` slot predicate that refuses a held
					-- Ankh also applies to a pack Ankh (its `use_card` no-op).
					if call_predicate(card, "can_use_consumeable") == true and check_use_ok(G, card) then
						builder.add({ type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { card_ref } })
					end
				else
					builder.add({ type = "SELECT_BOOSTER_ITEM", certified = true, card_refs = { card_ref } })
				end
			end
		end
	end
	local state = rget(G, "STATE")
	local states = rget(G, "STATES")
	local function state_is(symbol)
		local value = rget(states, symbol)
		return is_int(value) and value == state
	end
	local hand = rget(G, "hand")
	local hand_first = rget(rget(hand, "cards"), 1)
	local hand_limit = area_limit(hand)
	local pack_first = type(rawget(cards, 1)) == "table"
	-- H1/A: SMODS routes every mod booster through `SMODS_BOOSTER_OPENED` and
	-- extends `can_skip_booster` to that state (smods-booster.toml:124-126), but
	-- the real UI still requires a pack card FIRST (`G.pack_cards.cards[1]`,
	-- button_callbacks.lua:2133). After opening, the booster leaves the play area
	-- and its cards are created a beat later (card.lua:1721-1790), so a
	-- state-only skip would let the AI skip a paid pack before any card appears.
	-- Keep the pack-card guard for every state, SMODS included.
	local skippable = pack_first and (state_is("SMODS_BOOSTER_OPENED")
		or state_is("PLANET_PACK") or state_is("STANDARD_PACK")
		or state_is("BUFFOON_PACK") or hand_first ~= nil
		or (is_nat(hand_limit) and hand_limit <= 0))
	if skippable then
		builder.add({ type = "SKIP_BOOSTER", certified = true })
	end
end

local function cert_targets(builder, G, hand_cards, target)
	local source_ordinal = rget(target, "source_ordinal")
	if not is_int(source_ordinal) then
		return
	end
	local source_ref = ref("consumable", source_ordinal)
	local min_targets = rget(target, "min_targets")
	local max_targets = rget(target, "max_targets")
	local min_value = is_nat(min_targets) and min_targets or 0
	local max_value = is_nat(max_targets) and max_targets or 0
	if min_value <= 0 then
		builder.add({ type = "USE_CONSUMABLE", certified = true, source_ref = source_ref, target_refs = {} })
	end
	if hand_cards == nil or max_value < 1 then
		return
	end
	for i = 1, #hand_cards do
		local target_ref = ref("target", i)
		if min_value <= 1 then
			builder.add({ type = "USE_CONSUMABLE", certified = true, source_ref = source_ref, target_refs = { target_ref } })
		end
		builder.add({ type = "SELECT_TARGETS", certified = true, target_refs = { target_ref } })
	end
end

local function build_certificates(G, MP, phase, context, hand_cards, target)
	if context.blocked == true or context.timer_expired == true then
		return { version = SCHEMA_VERSION, items = {} }
	end
	local builder = certificate_builder()
	if phase == "MATCH_COMPLETE" then
		return { version = SCHEMA_VERSION, items = {} }
	end
	local game = rget(G, "GAME")

	if phase == "BLIND_SELECTION" then
		cert_blind(builder, G, MP)
	elseif phase == "SHOP" then
		cert_shop(builder, G)
		cert_sell_jokers(builder, G)
		cert_sell_consumables(builder, G)
		if consumable_use_available(G) then
			cert_use_consumables(builder, G)
		end
	elseif phase == "BOOSTER_SELECTION" then
		cert_booster(builder, G)
	elseif phase == "PLAY_HAND" or phase == "DISCARD" or phase == "MULTIPLAYER_PVP" then
		local hands_left = rpath(game, "current_round", "hands_left")
		local discards_left = rpath(game, "current_round", "discards_left")
		local block_play = rget(rget(game, "blind"), "block_play")
		if hand_cards ~= nil and #hand_cards > 0 then
			local forced = forced_hand_ordinals(G)
			if is_int(hands_left) and hands_left > 0 and (block_play == nil or block_play == false) then
				cert_play_discard(builder, "PLAY_CARDS", hand_cards, LIMITS.max_play, forced)
			end
			if is_int(discards_left) and discards_left > 0 then
				cert_play_discard(builder, "DISCARD_CARDS", hand_cards, LIMITS.max_play, forced)
			end
		end
		cert_sell_jokers(builder, G)
		cert_sell_consumables(builder, G)
		if consumable_use_available(G) then
			cert_use_consumables(builder, G)
		end
	elseif phase == "CONSUMABLE_SELECTION" then
		if target ~= nil then
			cert_targets(builder, G, hand_cards, target)
		end
		cert_sell_jokers(builder, G)
		cert_sell_consumables(builder, G)
	end

	-- Lowest priority: meaningful reorders (never starve the play/discard/shop
	-- catalogue above; silently dropped once the certificate cap is reached).
	cert_reorders(builder, G, "joker", "jokers", LIMITS.jokers)
	if hand_cards ~= nil then
		cert_reorders(builder, G, "hand", "hand", LIMITS.hand)
	end

	return { version = SCHEMA_VERSION, items = builder.items }
end

local function build_view(G, MP, phase, hand_cards, target)
	local view = { schema_version = SCHEMA_VERSION, phase = phase }
	local match = build_match(G, MP)
	if match == nil then
		return nil
	end
	view.match = match

	if phase == "MATCH_COMPLETE" then
		return view
	end

	local self_view = build_self(G, phase, hand_cards)
	if self_view == nil then
		return nil
	end
	view.self = self_view

	local opponent = build_opponent(G, MP)
	if opponent ~= nil then
		view.opponent = opponent
	end

	local engine_pvp = engine_pvp_boss(G)
	if engine_pvp ~= nil then
		view.recognition = { pvp_context = engine_pvp }
	end

	if phase == "SHOP" then
		local shop = build_shop(G)
		if shop == nil then
			return nil
		end
		view.shop = shop
	elseif phase == "BOOSTER_SELECTION" then
		local booster = build_booster(G)
		if booster == nil then
			return nil
		end
		view.booster = booster
	elseif phase == "CONSUMABLE_SELECTION" then
		if target == nil then
			return nil
		end
		local consumable_target = build_consumable_target(G, hand_cards, target)
		if consumable_target == nil then
			return nil
		end
		view.consumable_target = consumable_target
	end

	local context = build_context(G, phase)
	if context == nil then
		return nil
	end
	if target ~= nil then
		context.target_selection = true
		local min_targets = rget(target, "min_targets")
		if is_nat(min_targets) then
			context.min_targets = min_targets
		end
		local max_targets = rget(target, "max_targets")
		if is_nat(max_targets) then
			context.max_targets = max_targets
		end
	end
	view.context = context
	view.certificates = build_certificates(G, MP, phase, context, hand_cards, target)
	return view
end

function EngineAdapter.factory(ports)
	if type(ports) ~= "table" then
		return nil, CODE.BAD_PORTS
	end
	local role = rawget(ports, "role")
	if role ~= ROLE then
		return nil, CODE.BAD_ROLE
	end
	local session = token_of(rawget(ports, "session"), LIMITS.token)
	if session == nil then
		return nil, CODE.BAD_SESSION
	end
	local codec = rawget(ports, "codec")
	if type(codec) ~= "table" or type(codec.encode) ~= "function" then
		return nil, CODE.BAD_CODEC
	end
	local revision = rawget(ports, "revision")
	if type(revision) ~= "table" or type(revision.sync) ~= "function" or type(revision.current) ~= "function" then
		return nil, CODE.BAD_REVISION
	end
	local G = rawget(ports, "G")
	local MP = rawget(ports, "MP")
	if type(G) ~= "table" or type(MP) ~= "table" then
		return nil, CODE.BAD_ENGINE
	end
	local target_selection = rawget(ports, "target_selection")
	if target_selection ~= nil and type(target_selection) ~= "function" then
		return nil, CODE.BAD_PORTS
	end

	local instance = {}

	local function engine_symbol()
		return derive_engine_symbol(G)
	end

	local function hand_cards_for(phase)
		if PHASE_ALLOWS_HAND[phase] ~= true then
			return nil
		end
		local cards, count = area_cards(G, "hand", LIMITS.hand)
		if cards == nil then
			return nil, CODE.BUILD_FAILED
		end
		return cards, count
	end

	local function step_impl()
		local symbol_phase, state_code = engine_symbol()
		if symbol_phase == nil then
			return nil, state_code
		end

		if symbol_phase == "ROUND_EVAL_CONTROL" then
			local epoch = revision.sync("control:" .. CONTROL.CASH_OUT .. ":" .. session)
			if is_int(epoch) == false then
				return nil, CODE.REVISION_FAILED
			end
			return { control = CONTROL.CASH_OUT, epoch = epoch }
		end

		local target = nil
		local phase = symbol_phase
		if symbol_phase == "HAND_SELECT" then
			if target_selection ~= nil then
				local ok, value = pcall(target_selection)
				if ok and type(value) == "table" then
					target = value
				end
			end
			if target ~= nil then
				phase = "CONSUMABLE_SELECTION"
			elseif engine_pvp_boss(G) == true then
				phase = "MULTIPLAYER_PVP"
			else
				phase = "PLAY_HAND"
			end
		end
		if phase == nil or PHASES[phase] ~= true then
			return nil, CODE.UNSUPPORTED_STATE
		end

		local hand_cards, hand_count = hand_cards_for(phase)
		if hand_cards == nil and hand_count ~= nil then
			return nil, hand_count
		end

		local view = build_view(G, MP, phase, hand_cards, target)
		if view == nil then
			return nil, CODE.BUILD_FAILED
		end

		local ok_encode, canonical = pcall(codec.encode, { engine = decision_signature(G, MP), view = view })
		if not ok_encode or type(canonical) ~= "string" then
			return nil, CODE.BUILD_FAILED
		end
		local epoch = revision.sync(canonical)
		if is_int(epoch) == false then
			return nil, CODE.REVISION_FAILED
		end
		view.epoch = epoch
		local runtime = { role = ROLE, epoch = epoch, G = G, MP = MP }
		return { runtime = runtime, ui_view = view, epoch = epoch }
	end

	function instance.step()
		local ok, result, code = pcall(step_impl)
		if not ok then
			return nil, CODE.INTERNAL
		end
		return result, code
	end

	function instance.describe()
		local codes = {}
		for key, value in next, CODE do
			codes[key] = value
		end
		local phases = {}
		for key in next, PHASES do
			phases[key] = true
		end
		return {
			schema_version = SCHEMA_VERSION,
			role = ROLE,
			session = session,
			phases = phases,
			controls = { cash_out = CONTROL.CASH_OUT },
			limits = {
				hand = LIMITS.hand, jokers = LIMITS.jokers, consumables = LIMITS.consumables,
				shop = LIMITS.shop, shop_booster = LIMITS.shop_booster, vouchers = LIMITS.vouchers,
				booster = LIMITS.booster, targets = LIMITS.targets, certificates = LIMITS.certificates,
				selection = LIMITS.selection, max_play = LIMITS.max_play,
			},
			codes = codes,
		}
	end

	return instance
end

return EngineAdapter
