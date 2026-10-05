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

-- The pinned opponent-score visibility rule, shared by the pre-reader view and
-- the revision signature so a masked score can never reach either surface.
--
-- Multiplayer masks the opponent's rendered score while the AI has not yet
-- played a hand in a PvP blind (`ui/game/blind_hud.lua:203-216`), and the reader
-- separately refuses to project a masked `score_text` (`state_reader.lua`). If
-- `decision_signature` or `build_opponent` read the raw `score_text` first, a
-- masked score change would move the epoch and leak into the canonical string
-- even though the final observation omits it.
--
-- This mirrors the reader's exact rule, conservatively staying masked whenever a
-- factor is unreadable:
--   * `hide_score_until_played == false` never masks;
--   * a non-boolean value is treated as masking;
--   * with a numeric `hands_played == 0` the score is shown only for a proven
--     non-PvP phase and a proven non-PvP engine blind.
local function opponent_score_presentable(G, MP, phase)
	local hide_score = rpath(MP, "LOBBY", "config", "hide_score_until_played")
	if hide_score == false then
		return true
	end
	if hide_score ~= true then
		return false
	end
	local hands_played = rpath(G, "GAME", "current_round", "hands_played")
	if not is_int(hands_played) or hands_played < 0 then
		return false
	end
	if hands_played > 0 then
		return true
	end
	if phase == "MULTIPLAYER_PVP" then
		return false
	end
	return engine_pvp_boss(G) == false
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

-- Whether the AI's OWN visible countdown is actually ticking. This mirrors the
-- pinned Multiplayer timer gating (ui/game/timer.lua:400-475) rather than a
-- generic flag:
--   * under `pvp_timer` (Ranked, a PvP boss) the own timer ticks only while the
--     OPPONENT is timering the AI (`nemesis_timer_started`); `timer_started`
--     (the AI timering the opponent) must NOT start the cap;
--   * a PvP blind under any other timer does not run the own countdown at all;
--   * otherwise the own timer runs while `timer_started or nemesis_timer_started`.
-- It reads only the AI's own public flags; it never reads the opponent timer and
-- never modifies any timer.
local function own_timer_active(G, MP)
	local game = rget(MP, "GAME")
	local nemesis = rget(game, "nemesis_timer_started") == true
	local started = rget(game, "timer_started") == true
	if engine_pvp_boss(G) == true then
		local is_layer = rget(MP, "is_layer_active")
		local pvp_timer = true
		if type(is_layer) == "function" then
			local ok, value = pcall(is_layer, "pvp_timer")
			if ok and type(value) == "boolean" then
				pvp_timer = value
			end
		end
		if pvp_timer then
			return nemesis
		end
		return false
	end
	return started or nemesis
end

-- The AI's OWN visible active countdown, or nil when the AI's own timer is not
-- ticking. `MP.GAME.timer` is the exact number the local timer HUD shows; the
-- opponent timer (`MP.GAME.enemy.*`) is never read and no timer is modified.
local function own_timer_remaining(G, MP)
	local game = rget(MP, "GAME")
	if type(game) ~= "table" then
		return nil
	end
	if not own_timer_active(G, MP) then
		return nil
	end
	local timer = rget(game, "timer")
	if type(timer) ~= "number" or timer ~= timer or timer == math.huge or timer == -math.huge then
		return nil
	end
	if timer <= 0 then
		return 0
	end
	local floored = math.floor(timer)
	if floored < 0 then
		floored = 0
	end
	if floored > 2147483647 then
		floored = 2147483647
	end
	return floored
end

-- The engine readiness gate, split into two kinds. It is a pure read: it never
-- captures, advances the revision or builds policy data.
--
-- HARD: the exact action gates the executor already enforces
-- (`production_executor.gates_clear`: `G.GAME.STOP_USE`, `G.CONTROLLER.locked`,
-- an in-flight `G.play.cards` animation) plus an unrecognised state. These mean
-- the AI genuinely cannot act yet; the loop bounds them with its transient window.
--
-- SOFT: pause and an open overlay. These do NOT stop the Multiplayer timer: the
-- pinned `ui/game/timer.lua:454-465` only pauses while animations play AND
-- `interactive` is false AND there is no menu/pause. A recovered network blip
-- shows a Multiplayer informational overlay ("Reconnected…", "Opponent
-- reconnected…", a server error) that the AI cannot dismiss, so treating it as a
-- fatal hold would wrongly abort the match. Soft states gate the AI's visible
-- THINKING time only (the loop freezes the dwell and, after a bounded grace, acts
-- under the overlay).
--
-- A hard gate always wins over a soft one, so an overlay can never hide a genuine
-- stuck lock.
local function readiness_gate(G)
	local stop_use = rpath(G, "GAME", "STOP_USE")
	if is_int(stop_use) and stop_use > 0 then
		return "hard"
	end
	local locked = rget(rget(G, "CONTROLLER"), "locked")
	if locked ~= nil and locked ~= false then
		return "hard"
	end
	local play = rpath(G, "play", "cards")
	local play_count = dense_count(play, LIMITS.scan)
	if play_count == nil then
		if rget(G, "play") ~= nil then
			return "hard"
		end
		play_count = 0
	end
	if play_count > 0 then
		return "hard"
	end
	if rget(rget(G, "SETTINGS"), "paused") == true then
		return "soft"
	end
	if rget(G, "OVERLAY_MENU") ~= nil then
		return "soft"
	end
	return "ready"
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
local function grouping_identity(card, smeared)
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
	if smeared then
		if suit == "Diamonds" then suit = "Hearts" end
		if suit == "Clubs" then suit = "Spades" end
	end
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

-- M4: the effective public X-multiplier of an OWN playing-card enhancement, as
-- an integer in hundredths (100..10000). The engine stores it on
-- `card.ability.x_mult`, copied from `center.config.Xmult` by
-- `Card:set_ability` (pinned card.lua:288), so Standard's reworked Glass (1.5)
-- and vanilla/Major League Glass (2) are both readable from the AI's own card.
-- Only a strict allowlist of enhancements is projected, so this never widens the
-- schema to arbitrary card types; a debuffed card shows no ability, so it is not
-- projected.
local CARD_XMULT_CENTERS = { m_glass = true }
local CARD_XMULT_MIN = 100
local CARD_XMULT_MAX = 10000

local function card_xmult(card, center)
	if type(center) ~= "string" or CARD_XMULT_CENTERS[center] ~= true then
		return nil
	end
	if rget(card, "debuff") == true then
		return nil
	end
	local value = rget(rget(card, "ability"), "x_mult")
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	local scaled = math.floor(value * 100 + 0.5)
	if scaled < CARD_XMULT_MIN or scaled > CARD_XMULT_MAX then
		return nil
	end
	return scaled
end

-- Playing-card record for hand/booster/target zones.
local function public_chip_bonus(card)
	if rget(card, "debuff") == true then return nil end
	local ability = rget(card, "ability")
	local bonus, permanent = rget(ability, "bonus"), rget(ability, "perma_bonus")
	if bonus == nil and permanent == nil then return nil end
	bonus, permanent = bonus or 0, permanent or 0
	if not is_nat(bonus) or not is_nat(permanent) or bonus + permanent > 100000 then return nil end
	return bonus + permanent
end

local function build_play_card(card)
	if not is_face_up(card) then
		return redacted()
	end
	local record = { face_down = false, shown = shown_copy("card") }
	record.kind = "card"
	local center = center_key(card)
	put(record, "center", center)
	put(record, "rank", base_rank(card))
	put(record, "suit", base_suit(card))
	put(record, "edition", token_of(edition_type(card), 32))
	put(record, "seal", seal_of(card))
	put(record, "debuff", debuff_of(card))
	local bonus = public_chip_bonus(card)
	if bonus ~= nil then record.bonus_chips = bonus end
	local xmult = card_xmult(card, center)
	if xmult ~= nil then
		record.xmult = xmult
		record.shown.xmult = true
	end
	return record
end

-- Owned scaling Jokers: the current value the card text shows ("Currently
-- +X Mult"), and the per-hand growth step where it grows while a hand scores
-- (docs/SCALING_VALUES_DESIGN.md). The state reader keeps an identical table
-- and recomputes the value from the engine card.
local SCALING_CURRENT = {
	j_swashbuckler = { "mult", { "mult" } },
	j_green_joker = { "mult", { "mult" }, { "extra", "hand_add" } },
	j_ride_the_bus = { "mult", { "mult" }, { "extra" } },
	j_trousers = { "mult", { "mult" }, { "extra" } },
	j_flash = { "mult", { "mult" } },
	j_red_card = { "mult", { "mult" } },
	j_ceremonial = { "mult", { "mult" } },
	j_runner = { "chips", { "extra", "chips" }, { "extra", "chip_mod" } },
	j_square = { "chips", { "extra", "chips" }, { "extra", "chip_mod" } },
	j_wee = { "chips", { "extra", "chips" }, { "extra", "chip_mod" } },
	j_castle = { "chips", { "extra", "chips" } },
	j_hologram = { "xmult", { "x_mult" } },
	j_constellation = { "xmult", { "x_mult" } },
	j_campfire = { "xmult", { "x_mult" } },
	j_glass = { "xmult", { "x_mult" } },
	j_madness = { "xmult", { "x_mult" } },
	j_lucky_cat = { "xmult", { "x_mult" } },
}

-- Integer projection: mult/chips/step 0..100000; xmult in hundredths,
-- 100..1000000 (the codec carries integers only).
local function scaling_number(value, kind)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if kind == "xmult" then
		value = math.floor(value * 100 + 0.5)
		if value < 100 or value > 1000000 then
			return nil
		end
		return value
	end
	if value % 1 ~= 0 or value < 0 or value > 100000 then
		return nil
	end
	return value
end

local function scaling_current(card)
	local key = rpath(card, "config", "center", "key")
	local spec = type(key) == "string" and SCALING_CURRENT[key] or nil
	if spec == nil then
		return nil
	end
	local ability = rget(card, "ability")
	local path = spec[2]
	local value = scaling_number(rpath(ability, path[1], path[2]), spec[1])
	if value == nil then
		return nil
	end
	local out = { kind = spec[1], value = value }
	if spec[3] ~= nil then
		local step = scaling_number(rpath(ability, spec[3][1], spec[3][2]), "step")
		if step == nil then
			return nil
		end
		out.step = step
	end
	return out
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
	-- A debuffed card shows "All abilities are disabled", not its value.
	local current = debuff_of(card) == false and scaling_current(card) or nil
	if current ~= nil then
		record.current = current
		record.shown.current = true
	end
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
local function decision_signature(G, MP, phase)
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
	put_bool("blind_disabled", rpath(game, "blind", "disabled"))
	local back_name = rpath(game, "selected_back", "name")
	if type(back_name) == "string" then
		put_bool("score_balanced", back_name == "Plasma Deck")
		put_str("draw_profile", back_name == "Checkered Deck" and "checkered" or (back_name == "Abandoned Deck" and "abandoned" or (back_name == "Erratic Deck" and "unknown" or "standard")))
	end
	local current_round = rget(game, "current_round")
	put_int("hands_left", rget(current_round, "hands_left"))
	put_int("discards_left", rget(current_round, "discards_left"))
	put_int("hands_played", rget(current_round, "hands_played"))
	put_int("reroll_cost", rget(current_round, "reroll_cost"))
	put_bool("locked", rget(rget(G, "CONTROLLER"), "locked"))
	local mp_game = rget(MP, "GAME")
	put_int("lives", rget(mp_game, "lives"))
	put_bool("timer_started", rget(mp_game, "timer_started"))
	-- Being timered changes what the AI can do (the button is no longer lit),
	-- so it must move the epoch.
	put_bool("nemesis_timer_started", rget(mp_game, "nemesis_timer_started"))
	put_bool("ready_blind", rget(mp_game, "ready_blind"))
	local enemy = rget(mp_game, "enemy")
	local info_received = rget(enemy, "info_received")
	put_bool("info_received", info_received)
	-- Only a score the reader would actually project may move the epoch. While
	-- Multiplayer masks it, the raw `score_text` must not appear in the
	-- signature or the canonical string (the reader drops it from the view, so
	-- an ungated signature would move the epoch for a value no observation
	-- carries).
	if info_received == true and opponent_score_presentable(G, MP, phase) then
		put_str("score_text", rget(enemy, "score_text"))
	end
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
	local blind_display = display_of(blind_key, LIMITS.display)
	put(match, "blind", blind_display)
	-- Chicot / Luchador disable the boss (shown on screen); only alongside a
	-- blind (docs/BLIND_DISABLED_DESIGN.md).
	local disabled = rpath(G, "GAME", "blind", "disabled")
	if blind_display ~= nil and type(disabled) == "boolean" then
		match.blind_disabled = disabled
	end
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

-- Engine poker-hand names (G.GAME.hands keys) to observation tokens.
local HAND_LEVEL_KEYS = {
	["High Card"] = "high_card", ["Pair"] = "pair", ["Two Pair"] = "two_pair",
	["Three of a Kind"] = "three", ["Straight"] = "straight", ["Flush"] = "flush",
	["Full House"] = "full_house", ["Four of a Kind"] = "four",
	["Straight Flush"] = "straight_flush", ["Five of a Kind"] = "five",
	["Flush House"] = "flush_house", ["Flush Five"] = "flush_five",
}

-- The AI's own redeemed vouchers, as Run Info shows them: keys of
-- `G.GAME.used_vouchers` whose value is true and whose `G.P_CENTERS` entry is
-- a Voucher. Bytewise sorted, at most OWNED_VOUCHERS keys, at most
-- OWNED_VOUCHER_SCAN entries inspected. Fail-soft: nil when unreadable or
-- empty (docs/OWNED_VOUCHERS_DESIGN.md).
local OWNED_VOUCHERS = 32
local OWNED_VOUCHER_SCAN = 256

local function bytes_before(a, b)
	local n = math.min(#a, #b)
	for i = 1, n do
		local x, y = string.byte(a, i), string.byte(b, i)
		if x ~= y then
			return x < y
		end
	end
	return #a < #b
end

local function owned_voucher_keys(G)
	local used = rpath(G, "GAME", "used_vouchers")
	local centers = rget(G, "P_CENTERS")
	if type(used) ~= "table" or type(centers) ~= "table" then
		return nil
	end
	local keys = {}
	local scanned = 0
	for key, value in next, used do
		scanned = scanned + 1
		if scanned > OWNED_VOUCHER_SCAN then
			break
		end
		if value == true and type(key) == "string" and #key <= 32 and string.find(key, "^v_[a-z0-9_]+$") ~= nil
			and rget(rget(centers, key), "set") == "Voucher" then
			keys[#keys + 1] = key
		end
	end
	if #keys == 0 then
		return nil
	end
	table.sort(keys, bytes_before)
	if #keys > OWNED_VOUCHERS then
		-- Only extra modded/Multiplayer keys can exceed the bound: keep the
		-- interest-cap vouchers the policy models, then the first in byte order.
		local kept = {}
		for i = 1, #keys do
			if keys[i] == "v_money_tree" or keys[i] == "v_seed_money" then
				kept[#kept + 1] = keys[i]
			end
		end
		for i = 1, #keys do
			if #kept >= OWNED_VOUCHERS then
				break
			end
			if keys[i] ~= "v_money_tree" and keys[i] ~= "v_seed_money" then
				kept[#kept + 1] = keys[i]
			end
		end
		table.sort(kept, bytes_before)
		keys = kept
	end
	return keys
end

-- Phases inside a round, where `played_this_round` is current. Booster
-- selection happens in the shop, where it is last round's; consumable
-- selection is left out too (no play decision needs it there).
local ROUND_PHASES = { PLAY_HAND = true, DISCARD = true, MULTIPLAYER_PVP = true }

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
	-- The displayed "score at least" of a normal blind (the blind UI shows
	-- `G.GAME.blind.chips`). Only for a blind positively identified as non-PvP:
	-- a PvP blind's target is the opponent's (possibly masked) score, and
	-- Multiplayer overwrites a finished non-PvP blind with -1, which is dropped.
	-- Public poker-hand levels, as Run Info shows them: only hands the UI
	-- lists (`visible ~= false`; secret hands appear once discovered).
	local hands = rget(game, "hands")
	if type(hands) == "table" then
		local levels = nil
		for engine_name, name in next, HAND_LEVEL_KEYS do
			local entry = rget(hands, engine_name)
			-- Run Info lists a hand only when `visible` is true.
			if type(entry) == "table" and rget(entry, "visible") == true then
				local level = int_field(rget(entry, "level"))
				local hand_chips = int_field(rget(entry, "chips"))
				local hand_mult = int_field(rget(entry, "mult"))
				-- Same bound as the observation schema (a modded runaway level is
				-- dropped, never allowed to reject the whole frame).
				if level ~= nil and level <= 100000 and hand_chips ~= nil and hand_mult ~= nil then
					levels = levels or {}
					levels[name] = { level = level, chips = hand_chips, mult = hand_mult }
					-- The AI's own hands this round (The Eye / The Mouth), only
					-- while a hand is being played: elsewhere the counts are stale
					-- (docs/HAND_HISTORY_DESIGN.md).
					local played = int_field(rget(entry, "played_this_round"))
					if ROUND_PHASES[phase] == true and played ~= nil and played >= 0 and played <= 1000 then
						levels[name].played_this_round = played
					end
				end
			end
		end
		if levels ~= nil then
			out.hand_levels = levels
		end
	end
	out.owned_vouchers = owned_voucher_keys(G)
	-- Only while a hand is being played: outside the blind (shop, blind
	-- select) the previous blind's value is not what the UI is showing.
	if PHASE_ALLOWS_HAND[phase] == true and engine_pvp_boss(G) == false then
		local need = rpath(game, "blind", "chips")
		if type(need) == "number" and need == need and need ~= math.huge and need > 0 then
			out.blind_requirement = dec_string(math.floor(need))
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

local function build_opponent(G, MP, phase)
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
	-- Gate the pre-reader view with the same visibility rule the reader applies,
	-- so a masked score never enters the canonical revision string.
	if opponent_score_presentable(G, MP, phase) then
		local score = display_of(rget(enemy, "score_text"), LIMITS.display)
		if score ~= nil then
			out.score_visible = true
			out.displayed_score = score
			has = true
		end
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
--   0. (The Psychic only) rank groups and two pair padded to five cards
--      (visible-rank kickers first, then other cards by position);
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
local function hand_selections(cards, count, max_k, cap, pad, smeared, minimum, shortcut)
	local out = {}
	local seen = {}
	local function add(selection)
		if #out >= cap then
			return false
		end
		-- Order-insensitive key: the same card set is one play whatever the
		-- order it was built in (e.g. a padded pair that equals a full house).
		local sorted = {}
		for i = 1, #selection do
			sorted[i] = selection[i]
		end
		table.sort(sorted)
		local key = table.concat(sorted, ",")
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
	local rank_values = {}
	for i = 1, count do
		local rank, suit = grouping_identity(rawget(cards, i), smeared)
		if rank ~= nil then
			rank_values[i] = RANK_VALUE[rank]
		end
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

	-- 0. (The Psychic only) rank groups and two pair padded to five cards with
	-- the highest other visible-rank cards, then any other card by position,
	-- so a scoring five-card play exists.
	if pad and max_k >= 5 then
		local kickers = {}
		for i = 1, count do
			if rank_values[i] ~= nil then
				kickers[#kickers + 1] = i
			end
		end
		table.sort(kickers, function(a, b)
			if rank_values[a] ~= rank_values[b] then
				return rank_values[a] > rank_values[b]
			end
			return a < b
		end)
		-- Then any other card by position (Stone, face-down): the order depends
		-- only on which identities are visible, never on hidden ones.
		for i = 1, count do
			if rank_values[i] == nil then
				kickers[#kickers + 1] = i
			end
		end
		local function padded(base)
			local used = {}
			local out_sel = {}
			for i = 1, #base do
				used[base[i]] = true
				out_sel[#out_sel + 1] = base[i]
			end
			for i = 1, #kickers do
				if #out_sel >= 5 then
					break
				end
				if not used[kickers[i]] then
					out_sel[#out_sel + 1] = kickers[i]
				end
			end
			return #out_sel == 5 and out_sel or nil
		end
		local bases = {}
		local pairs_list = {}
		for k = 1, #rank_order do
			local group = ranks[rank_order[k]]
			if #group >= 2 and #group <= 4 then
				bases[#bases + 1] = group
				if #group == 2 then
					pairs_list[#pairs_list + 1] = group
				end
			end
		end
		for a = 1, #pairs_list - 1 do
			for b = a + 1, #pairs_list do
				bases[#bases + 1] = { pairs_list[a][1], pairs_list[a][2], pairs_list[b][1], pairs_list[b][2] }
			end
		end
		local five = {}
		for i = 1, #bases do
			local sel = padded(bases[i])
			if sel ~= nil then
				five[#five + 1] = sel
			end
		end
		add_type(five, 10)
	end

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

	-- Native Four Fingers / Shortcut candidates use only visible rank groups.
	if minimum == 4 or shortcut then
		local by_value = {}
		for k = 1, #rank_order do
			local value = RANK_VALUE[rank_order[k]]
			if value ~= nil then by_value[value] = ranks[rank_order[k]][1] end
		end
		by_value[1] = by_value[14]
		local straights = {}
		for low = 1, 14 do
			local run, gap = {}, 0
			for rv = low, 14 do
				if by_value[rv] ~= nil then
					run[#run + 1], gap = by_value[rv], 0
					if #run >= minimum and #run <= max_k then
						local candidate = {}
						for i = 1, #run do candidate[i] = run[i] end
						straights[#straights + 1] = candidate
					end
					if #run >= max_k then break end
				else
					gap = gap + 1
					if not shortcut or gap > 1 then break end
				end
			end
		end
		add_type(straights, 8)
	else
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

	end
	-- 4. flush candidates: the five highest-ranked cards of a visible suit
	-- (ties by hand position), not merely the first five in hand order.
	if max_k >= (minimum or 5) then
		local flushes = {}
		for k = 1, #suit_order do
			local group = suits[suit_order[k]]
			if #group >= (minimum or 5) then
				local sorted = {}
				for g = 1, #group do
					sorted[g] = group[g]
				end
				table.sort(sorted, function(a, b)
					local ra, rb = rank_values[a] or 0, rank_values[b] or 0
					if ra ~= rb then
						return ra > rb
					end
					return a < b
				end)
				local top = {}
				for i = 1, math.min(5, #sorted) do top[i] = sorted[i] end
				table.sort(top)
				flushes[#flushes + 1] = top
				if #group > 5 then
					flushes[#flushes + 1] = { group[1], group[2], group[3], group[4], group[5] }
				end
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

-- A card worth keeping on its own: any edition, seal or enhancement.
local function is_valuable(card)
	if rget(card, "edition") ~= nil or rget(card, "seal") ~= nil then
		return true
	end
	local key = rpath(card, "config", "center", "key")
	return type(key) == "string" and string.sub(key, 1, 2) == "m_"
end

-- Discard-specific candidates: throw away what does not belong to a visible
-- draw, lowest ranks first, never more than `max_k` and never a valuable card.
-- Every candidate is still an ordinary visible-hand selection; the policy
-- chooses among them and the executor re-checks the real discard gate.
local function discard_selections(cards, count, max_k, cap, smeared)
	local out = {}
	local seen = {}
	local function add(selection)
		if #selection == 0 or #selection > max_k or #out >= cap then
			return
		end
		local sorted = {}
		for i = 1, #selection do
			sorted[i] = selection[i]
		end
		table.sort(sorted)
		local key = table.concat(sorted, ",")
		if seen[key] then
			return
		end
		seen[key] = true
		out[#out + 1] = sorted
	end
	local info = {}
	local rank_count = {}
	local suit_members = {}
	local suit_order = {}
	for i = 1, count do
		local card = rawget(cards, i)
		local rank, suit = grouping_identity(card, smeared)
		local value = rank ~= nil and RANK_VALUE[rank] or nil
		info[i] = { value = value, suit = suit, keep = is_valuable(card) }
		if value ~= nil then
			rank_count[value] = (rank_count[value] or 0) + 1
		end
		if suit ~= nil then
			if suit_members[suit] == nil then
				suit_members[suit] = {}
				suit_order[#suit_order + 1] = suit
			end
			local list = suit_members[suit]
			list[#list + 1] = i
		end
	end
	table.sort(suit_order, byte_less)
	-- Lowest-value first; unreadable (stone/face-down) cards are never offered.
	local function cheapest(excluded, limit)
		local pool = {}
		for i = 1, count do
			local entry = info[i]
			if not excluded[i] and not entry.keep and entry.value ~= nil then
				pool[#pool + 1] = i
			end
		end
		table.sort(pool, function(a, b)
			if info[a].value ~= info[b].value then
				return info[a].value < info[b].value
			end
			return a < b
		end)
		local picked = {}
		for i = 1, #pool do
			if #picked >= limit then
				break
			end
			picked[#picked + 1] = pool[i]
		end
		return picked
	end
	-- 1. Flush draws: keep every card of one suit with >= 3 visible cards.
	for k = 1, #suit_order do
		local members = suit_members[suit_order[k]]
		if #members >= 3 and #members < 5 then
			local keep = {}
			for m = 1, #members do
				keep[members[m]] = true
			end
			add(cheapest(keep, max_k))
		end
	end
	-- 2. Made groups: keep every rank that appears at least twice.
	local grouped = {}
	local has_group = false
	for i = 1, count do
		local value = info[i].value
		if value ~= nil and (rank_count[value] or 0) >= 2 then
			grouped[i] = true
			has_group = true
		end
	end
	if has_group then
		add(cheapest(grouped, max_k))
		add(cheapest(grouped, 3))
	end
	-- 3. Straight draws: four distinct ranks inside a window of five (Ace low
	-- and high); keep one card per rank of the best (highest) window.
	local by_value = {}
	for i = 1, count do
		local value = info[i].value
		if value ~= nil and by_value[value] == nil then
			by_value[value] = i
		end
	end
	if by_value[14] ~= nil then
		by_value[1] = by_value[14]
	end
	for low = 10, 1, -1 do
		local keep = {}
		local present = 0
		for v = low, low + 4 do
			if by_value[v] ~= nil then
				keep[by_value[v]] = true
				present = present + 1
			end
		end
		if present >= 4 then
			add(cheapest(keep, max_k))
			break
		end
	end
	-- 4. Plain junk: the lowest 1..max_k unmatched cards.
	for n = max_k, 1, -1 do
		add(cheapest(grouped, n))
	end
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

-- L2 (docs/CLAUDE_BATCH3_REVIEW.md): the lowest-priority reorders must not be
-- silently dropped when targeted Tarots plus the play/discard catalogue fill the
-- certificate cap. A few slots are reserved for them: ordinary certificates stop
-- at the cap minus the reserve, and only reorders may use the last slots. The
-- 120 cap, the play/discard selection capacity and the Tarot bounds are all
-- unchanged. The realistic worst case (12 cards, 8 Jokers, three held Tarots:
-- 40 + 40 + 11 + 24 = 115 ordinary certificates) stays under the reduced cap, so
-- no Tarot candidate is lost.
local REORDER_RESERVE = 4

local function certificate_builder(reserve)
	local items = {}
	local limit = LIMITS.certificates
	local ordinary_limit = limit - (reserve or 0)
	local function append(item)
		if #items >= limit then
			return false
		end
		items[#items + 1] = item
		return true
	end
	local function add(item)
		if #items >= ordinary_limit then
			return false
		end
		return append(item)
	end
	return { items = items, add = add, add_reserved = append }
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

local function visible_rule(G, center)
	local cards, count = area_cards(G, "jokers", LIMITS.jokers)
	if cards ~= nil then
		for i = 1, count do
			local card = rawget(cards, i)
			if is_face_up(card) and rget(card, "debuff") ~= true and center_key(card) == center then
				return true
			end
		end
	end
	return false
end

local function cert_play_discard(builder, t, hand_cards, max_k, forced, pad, smeared, minimum, shortcut)
	local cap = LIMITS.selection
	local selections = hand_selections(hand_cards, #hand_cards, max_k, cap, pad, smeared, minimum, shortcut)
	if t == "DISCARD_CARDS" then
		-- Targeted discards first, then the generic selections, same total cap.
		local targeted = discard_selections(hand_cards, #hand_cards, max_k, 12, smeared)
		local merged = {}
		local seen = {}
		for _, list in ipairs({ targeted, selections }) do
			for i = 1, #list do
				local sorted = {}
				for j = 1, #list[i] do
					sorted[j] = list[i][j]
				end
				table.sort(sorted)
				local key = table.concat(sorted, ",")
				if not seen[key] and #merged < cap then
					seen[key] = true
					merged[#merged + 1] = list[i]
				end
			end
		end
		selections = merged
	end
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

-- Targeted Tarots used on highlighted hand cards in the hand phase
-- (docs/HAND_TARGETS_DESIGN.md, v1 scope). Only these centers; the target
-- counts come from the engine card, and the executor re-checks the engine's
-- own `can_use_consumeable` after highlighting. Targets are face-up cards with
-- a visible identity, and a target the effect would not change is skipped.
local HAND_TAROTS = {
	c_strength = "rank", c_death = "pair",
	c_lovers = "m_wild", c_chariot = "m_steel", c_justice = "m_glass", c_devil = "m_gold",
	c_star = "Diamonds", c_moon = "Clubs", c_sun = "Hearts", c_world = "Spades",
}
local HAND_TAROT_LIMIT = 8
local HAND_TAROT_TOTAL = 24

local function target_bounds(card)
	local consumeable = rget(rget(card, "ability"), "consumeable")
	if type(consumeable) ~= "table" then
		return nil
	end
	local mod_num = rawget(consumeable, "mod_num")
	local max_h = rawget(consumeable, "max_highlighted")
	local max_value = is_nat(mod_num) and mod_num or (is_nat(max_h) and max_h or nil)
	local min_h = rawget(consumeable, "min_highlighted")
	return is_nat(min_h) and min_h or 1, max_value
end

local function cert_hand_tarots(builder, G, hand_cards)
	-- A blind-forced card (Cerulean Bell) would join every highlight: v1 offers
	-- no targeted use then.
	local forced = forced_hand_ordinals(G)
	if forced == nil or #forced > 0 or hand_cards == nil then
		return
	end
	local consumeables, count = area_cards(G, "consumeables", LIMITS.consumables)
	if consumeables == nil then
		return
	end
	local visible = {}
	for j = 1, #hand_cards do
		local card = rawget(hand_cards, j)
		local rank, suit = grouping_identity(card)
		if rank ~= nil and suit ~= nil and debuff_of(card) == false then
			visible[#visible + 1] = { ordinal = j, rank = rank, suit = suit, base = center_key(card) == "c_base" }
		end
	end
	local total = 0
	for i = 1, count do
		local card = rawget(consumeables, i)
		local key = type(card) == "table" and rpath(card, "config", "center", "key") or nil
		local effect = type(key) == "string" and HAND_TAROTS[key] or nil
		local min_value, max_value = target_bounds(card)
		if effect ~= nil and is_face_up(card) and debuff_of(card) == false and max_value ~= nil then
			local source_ref = ref("consumable", i)
			local added = 0
			local function add(refs)
				if added < HAND_TAROT_LIMIT and total < HAND_TAROT_TOTAL then
					if builder.add({ type = "USE_CONSUMABLE_ON_HAND", certified = true, source_ref = source_ref, card_refs = refs }) ~= false then
						added = added + 1
						total = total + 1
					end
				end
			end
			if effect == "pair" then
				-- Death: the left card (lower ordinal) becomes a copy of the right.
				if min_value <= 2 and max_value >= 2 then
					for a = 1, #visible do
						for b = a + 1, #visible do
							local x, y = visible[a], visible[b]
							if x.rank ~= y.rank or x.suit ~= y.suit then
								add({ ref("hand", x.ordinal), ref("hand", y.ordinal) })
							end
						end
					end
				end
			elseif min_value <= 1 and max_value >= 1 then
				for a = 1, #visible do
					local v = visible[a]
					local useful = effect == "rank" or (string.sub(effect, 1, 2) == "m_" and v.base)
						or (string.sub(effect, 1, 2) ~= "m_" and v.suit ~= effect)
					if useful then
						add({ ref("hand", v.ordinal) })
					end
				end
			end
		end
	end
end

-- Bounded "meaningful" reorders. There is no discrete reorder callback in the
-- engine (Multiplayer logs drag/drop by diffing CardArea order), so the
-- executor commits the same area-order permutation the drag would produce. To
-- keep the catalogue bounded, offer reverse/adjacent orders and public copy
-- Joker placements. Every entry is a non-no-op permutation.
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
		local changed = false
		for i = 1, count do
			refs[i] = ref(zone, ordinals[i])
			changed = changed or ordinals[i] ~= i
		end
		if not changed then return end
		local key = table.concat(ordinals, ",")
		if seen[key] then
			return
		end
		seen[key] = true
		local add = builder.add_reserved or builder.add
		add({ type = "REORDER_" .. string.upper(zone == "joker" and "JOKERS" or "HAND"), certified = true, order = refs })
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
	-- Public centers only; hidden Joker identities cannot shape the catalog.
	-- Small rows fit the existing reserved action slots and policy work bound.
	if zone == "joker" and count <= 8 then
		for i = 1, count do
			local c = cards[i]
			local center = is_face_up(c) and rget(c, "debuff") ~= true and center_key(c) or nil
			if center == "j_blueprint" or center == "j_brainstorm" then
				for target = 1, count do
					if target ~= i and is_face_up(cards[target]) then
						local rest = {}
						for j = 1, count do
							if j ~= target and (center ~= "j_blueprint" or j ~= i) then rest[#rest + 1] = j end
						end
						if center == "j_brainstorm" then
							table.insert(rest, 1, target); add_order(rest)
						else
							local front = { i, target }
							for j = 1, #rest do front[#front + 1] = rest[j] end
							add_order(front)
							rest[#rest + 1], rest[#rest + 2] = i, target; add_order(rest)
						end
					end
				end
			end
		end
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

-- The real Multiplayer timer button is usable: the lobby runs the timer, this
-- runtime has not already started it (a second press would *pause* it,
-- ui/game/timer.lua:18-31), and the real gate `MP.UI.can_timer_opponent()`
-- (timer.lua:3-17) says yes. That gate is exactly what lights the button for a
-- human (`set_timer_box`), so the certificate reveals nothing the UI does not.
-- Called protected; any failure means "not available".
local function timer_button_available(MP)
	if rpath(MP, "LOBBY", "config", "timer") ~= true then
		return false
	end
	-- The button is only mounted in a lobby whose live/timer HUD is shown
	-- (mp lovely/hud.toml:38: `MP.LOBBY.code and not disable_live_and_timer_hud`).
	local code = rpath(MP, "LOBBY", "code")
	if type(code) ~= "string" or #code == 0 then
		return false
	end
	if rpath(MP, "LOBBY", "config", "disable_live_and_timer_hud") == true then
		return false
	end
	local mp_game = rget(MP, "GAME")
	if rget(mp_game, "timer_started") == true then
		return false
	end
	local timer_value = rget(mp_game, "timer")
	if type(timer_value) ~= "number" or not (timer_value > 0) then
		return false
	end
	local gate = rget(rget(MP, "UI"), "can_timer_opponent")
	if type(gate) ~= "function" then
		return false
	end
	local ok, allowed = pcall(gate)
	return ok and allowed == true
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
		elseif timer_button_available(MP) then
			-- While readied at the PvP blind, the only real choice is whether to
			-- press the Multiplayer timer on the opponent.
			builder.add({ type = "START_TIMER", certified = true })
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
	local builder = certificate_builder(REORDER_RESERVE)
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
				-- The Psychic (public boss key, not disabled): pad plays to five.
				local psychic = rpath(game, "blind", "config", "blind", "key") == "bl_psychic"
					and rget(rget(game, "blind"), "disabled") ~= true
				cert_play_discard(builder, "PLAY_CARDS", hand_cards, LIMITS.max_play, forced, psychic, visible_rule(G, "j_smeared"), visible_rule(G, "j_four_fingers") and 4 or 5, visible_rule(G, "j_shortcut"))
			end
			if is_int(discards_left) and discards_left > 0 then
				cert_play_discard(builder, "DISCARD_CARDS", hand_cards, LIMITS.max_play, forced, nil, visible_rule(G, "j_smeared"), visible_rule(G, "j_four_fingers") and 4 or 5, visible_rule(G, "j_shortcut"))
			end
		end
		cert_sell_jokers(builder, G)
		cert_sell_consumables(builder, G)
		if consumable_use_available(G) then
			cert_use_consumables(builder, G)
			if phase ~= "DISCARD" then
				cert_hand_tarots(builder, G, hand_cards)
			end
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

	local opponent = build_opponent(G, MP, phase)
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

		local ok_encode, canonical = pcall(codec.encode, { engine = decision_signature(G, MP, phase), view = view })
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

	-- Trusted, side-effect-free pre-capture phase probe for the thinking dwell
	-- (H2). It reads only the engine symbol (a pure state read) and the AI's own
	-- public timer; it never advances the revision, never builds an observation
	-- and never exposes a handle, canonical content, opponent data or any
	-- policy field. The decision loop uses it ONLY to decide whether it may
	-- capture and how long to dwell; it is never policy input.
	function instance.probe()
		local ok, value = pcall(function()
			local symbol_phase = derive_engine_symbol(G)
			if symbol_phase == nil then
				return { ready = false, block = "hard" }
			end
			if symbol_phase == "ROUND_EVAL_CONTROL" then
				return { ready = true, phase = "ROUND_EVAL_CONTROL" }
			end
			local phase = symbol_phase
			if symbol_phase == "HAND_SELECT" then
				if engine_pvp_boss(G) == true then
					phase = "MULTIPLAYER_PVP"
				else
					phase = "PLAY_HAND"
				end
			end
			if PHASES[phase] ~= true then
				return { ready = false, block = "hard" }
			end
			-- L-a: the terminal phase is resolved BEFORE the readiness gate. A real
			-- GAME_OVER/win screen is itself an overlay (or may be paused), so a
			-- gated probe would otherwise hide MATCH_COMPLETE from terminal_probe.
			if phase == "MATCH_COMPLETE" then
				return { ready = true, phase = "MATCH_COMPLETE" }
			end
			local gate = readiness_gate(G)
			if gate == "hard" then
				return { ready = false, phase = phase, block = "hard" }
			end
			if gate == "soft" then
				return { ready = false, phase = phase, block = "soft" }
			end
			return { ready = true, phase = phase, timer_remaining = own_timer_remaining(G, MP) }
		end)
		if not ok or type(value) ~= "table" then
			return { ready = false, block = "hard" }
		end
		return value
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
