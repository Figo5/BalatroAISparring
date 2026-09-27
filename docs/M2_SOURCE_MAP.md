# Milestone 2 source map — normalized observations and legal actions

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: research only. No implementation, no game execution, no file outside this document changed.

This map gives the file:line evidence needed to build a **trusted observation extractor** and a
**trusted legal-action executor**. It does not design the schema and does not claim parity,
isolation or a working opponent. It covers: game phases; per-action legality
(play/discard/buy/reroll/sell/use/select/skip); MP score/hands visibility; opponent-location
gating; timer threshold, rounding and presence; own face-down hidden cards; hidden future shop/
booster contents; and the MP overrides/layers that change legality. It ends with the always-
forbidden fields, the narrowly permitted UI projections, and the authoritative legality check,
plus the fairness-critical gotchas.

## 0. Provenance and reference layout

All evidence is read from the ignored local working copies (not committed, not distributed):

- Pinned Multiplayer 0.5.5: `work/reference/mp/` (git working tree, `Multiplayer.json`, `core.lua`).
- Vanilla game subset (7 installed source files): `work/reference/game/`
  (`card.lua`, `cardarea.lua`, `game.lua`, `functions/button_callbacks.lua`,
  `functions/common_events.lua`, `functions/state_events.lua`, `functions/UI_definitions.lua`).

Paths below are relative to the repository root. Line numbers are from these pinned copies.
`G.STATES` / `G.STAGES` enum definitions live in a vanilla globals file that is **not** in this
7-file subset, so phase names are evidenced at their read/write sites only. The MP Lovely patch
`work/reference/mp/lovely/hud.toml` is cited for HUD presence; the rest of the upstream TCP tree
was not needed and was not inspected here.

Method: read-only `Read`/`Grep`/`Glob`. No game function was called or executed.

## 1. Game phases

| Phase | Evidence (write site) |
|---|---|
| Run start defaults to `BLIND_SELECT` | `game.lua:2024-2026` (`prep_stage(G.STAGES.RUN, saveTable.STATE or BLIND_SELECT)`) |
| BLIND_SELECT select → `new_round` | `functions/button_callbacks.lua:2540-2554` |
| `NEW_ROUND` / `DRAW_TO_HAND` | `game.lua:3197-3201` |
| `DRAW_TO_HAND` | `game.lua:2546-2547` |
| `SELECTING_HAND` | `game.lua:3236-3237` |
| Hand played → `HAND_PLAYED` | `functions/state_events.lua:468-469` |
| Discard → `DRAW_TO_HAND` | `functions/state_events.lua:438,442` |
| Pack states (`TAROT/PLANET/SPECTRAL/STANDARD/BUFFOON_PACK`) | `game/card.lua:1693-1705`; transitions `button_callbacks.lua:2180-2185` |
| `SHOP` | `button_callbacks.lua:2931` |
| `ROUND_EVAL` | `game.lua:3314` |
| Blind progression states `Select/Upcoming/Current/Skipped/Defeated` | `game.lua:1974-1975`, `state_events.lua:259-264,320-328` |
| `STATE == -1` / menu / sandbox stages | `game.lua:1188,1274,1380` |

Phase is a **single global `G.STATE`** plus a coarse `G.STAGE`. It is the correct top-level gate
for observation and for action dispatch, but it is not sufficient on its own (see §7, §9).

## 2. Per-action legality rules

Vanilla UI predicates and their real gates. These are the buttons the player sees; the executor
must revalidate (AGENTS.md: "revalidate phase, resources, card IDs, slots and action legality
immediately before normal game callbacks").

| Action | UI predicate (vanilla) | Real gate(s) worth revalidating |
|---|---|---|
| Play hand | `G.FUNCS.can_play` `button_callbacks.lua:2048-2056` | `#highlighted in 1..5`, `not G.GAME.blind.block_play`; MP adds `current_round.hands_left > 0` (`ui/game/functions.lua:38-46`); counts/state at `state_events.lua:450-475` |
| Discard | `G.FUNCS.can_discard` `button_callbacks.lua:2092-2100` | `current_round.discards_left > 0`, `#highlighted > 0`; consume site `state_events.lua:379-447` |
| Buy | `G.FUNCS.can_buy` `button_callbacks.lua:55-70`; `can_buy_and_use` `77-89`; `can_open` (booster) `111-119`; `can_redeem` (voucher) `96-104` | `cost > dollars - bankrupt_at` (and `cost>0`); buy space `G.FUNCS.check_for_buy_space` `button_callbacks.lua:2408`; buy body `2404-2443` |
| Reroll | `G.FUNCS.can_reroll` `button_callbacks.lua:2076-2090` | `(dollars-bankrupt_at) - current_round.reroll_cost >= 0` or `reroll_cost == 0`; body `2855-2910`; cost model `common_events.lua:2263` |
| Sell | `G.FUNCS.can_sell_card` `button_callbacks.lua:2122-2130` | `Card:can_sell_card` `card.lua:1640-1653`: area type `joker`, not `eternal`, `STOP_USE==0`, `G.play` empty, not tutorial; MP sticker override `objects/stickers/1_persistent.lua:38-49` |
| Use consumable | `G.FUNCS.can_use_consumeable` `button_callbacks.lua:2102-2110` | `Card:can_use_consumeable` `card.lua:1523-1579` (per-card target/hand checks, `STOP_USE`, `CONTROLLER.locked`, `G.play`); body `button_callbacks.lua:2155-2316` |
| Select card (pack/target) | `G.FUNCS.can_select_card` `button_callbacks.lua:2112-2120` | not Joker, or negative, or joker slots free |
| Skip blind | `G.FUNCS.skip_blind` `button_callbacks.lua:2740-2782` | increments `G.GAME.skips`, applies tag, advances `blind_on_deck`; MP wrapper `ui/game/functions.lua:32-36,82-107` |
| Skip booster | `G.FUNCS.can_skip_booster` `button_callbacks.lua:2132-2141`; body `2558-2563` | pack state + `G.pack_cards[1]` or hand non-empty; per-deck/booster overrides `objects/decks/01_indigo.lua:91-107`, `objects/boosters/standard_giga.lua:38-44` |
| Select blind | `G.FUNCS.select_blind` `button_callbacks.lua:2513-2556` | MP wrapper records ante_key/location and sends `playHand`/`newRound` `ui/game/functions.lua:58-80` |

MP wraps the same callbacks in `overrides/game.lua` (`sell_card:15`, `reroll_shop:29`,
`buy_from_shop:45`, `use_card:70`, `skip_booster:107`) purely for replay logging — they call the
vanilla function unchanged, so they do **not** add or remove legality. The legality-affecting MP
wrappers are the UI ones (`ui/game/functions.lua`) and the layer/bans system (§7).

Common non-obvious gates that `can_*` does not fully express and that must be revalidated:
`G.CONTROLLER.locked`, `G.CONTROLLER.locks.*`, `G.GAME.STOP_USE > 0`, `G.play` non-empty, and
per-card `ability`/target constraints. `G.FUNCS.can_play` in particular does **not** check
hands_left, `STOP_USE` or `G.play` — MP adds only the hands_left check.

**`can_*` callbacks are not pure predicates and must never be called speculatively.** They mutate
UI state as a side effect: `can_buy` sets `e.config.colour`/`e.config.button` and rewrites
`e.UIBox.alignment.offset.y` (`button_callbacks.lua:56-69`); `can_buy_and_use` toggles
`e.UIBox.states.visible` (`77-86`); `can_*` generally write colour/button (`2048-2141`). Card
predicates read engine state (`Card:can_sell_card` area/eternal `card.lua:1640-1653`;
`Card:can_use_consumeable` per-card `eligible_*` tables and hand/`G.play`/`STOP_USE` checks
`card.lua:1523-1579`), and under modded layers a UI/center read can run a layer override (e.g.
`polymorph_spam` wraps `generate_card_ui`/`localize`, `layers/polymorph_spam.lua:115-145`;
`Card:hover` mutates `config.center.alerted` and saves progress `card.lua:4316-4318`). The
observation extractor and any action generator must **not** invoke `can_*` on hypothetical
actions; only the committed-action executor may, and only against the real runtime.

## 3. MP score and hands visibility

- Opponent state lives in `MP.GAME.enemy` (`core.lua:220-237`), initialized masked:
  `score_text="0"`, `hands=4`, `hands_text="4"`, `info_received=false` (`core.lua:221-228`).
- `startBlind` resets enemy score/hands mask each blind and re-masks hands until first
  `enemyInfo` (`action_handlers.lua:340-358`).
- `enemyInfo` is the only source of opponent score/hands/skips/lives
  (`action_handlers.lua:360-475`): `hands` set at `471-473`, score ease at `391-442`,
  `info_received=true` at `441`; `p.noScore` suppresses score (`387`).
- `hide_score_until_played` defaults false (`core.lua:200-201`), set true only when the ruleset
  has `standard == true` (`ui/main_menu/play_button/play_button_callbacks.lua:113-117`), toggle
  in lobby (`ui/lobby/_lobby_options/options_tab.lua:87-89`), localized label
  (`localization/en-us.lua:1217`).
- Display masking: while `hide_score_until_played` and a PvP boss and
  `current_round.hands_played == 0`, `score_text` is forced to `"???"`
  (`ui/game/blind_hud.lua:200-224`); hands are always rendered from `enemy.hands_text`
  (`blind_hud.lua:34-47,200-202`).
- Enemy score is displayed via ease events and scaled (`blind_hud.lua:217-223`); the backing
  `MP.GAME.enemy.real_score` (`core.lua:222`, set `action_handlers.lua:440`) is the unmasked
  value and must not be projected.
- Cashout row substitutes enemy score (`ui/game/blind_hud.lua:165-184`).

**Projection rule:** an observation may show opponent `score_text` and `hands_text` exactly as
the HUD computes them, and must not carry `real_score`, `highest_score`, or raw message fields.

## 4. Opponent-location gating

- Config switch `enemy_location_disabled` (`core.lua:202`), forced true by Major League
  (`rulesets/majorleague.lua:27`).
- Incoming `enemyLocation` handler decodes and stores `MP.GAME.enemy.location*`
  (`action_handlers.lua:689-717`); skip sound gated by the switch (`466-469`).
- Rendering only when not disabled: `ui/game/enemy_location.lua:199-207` (show),
  `208-216` (hide/round-score view), `242-245` (`mp_setup_hover_enemy_location_display`
  returns early when disabled); call sites gate too: `ui/game/game_state.lua:335,347`.
- Note the anti-leak coupling: the *only* legitimate thing Major League's disabled location may
  expose is the timer-action eligibility it causes (INTEGRATION_PLAN §Rules). The timer
  eligibility itself is `MP.UI.can_timer_opponent()` (`ui/game/timer.lua:3-17`).

**Projection rule:** when disabled, do not project `enemy.location`; expose only the eligibility
predicate (or its consequence), never the raw location/type/blind strings.

## 5. Timers — threshold, rounding, presence

- Sources of truth: local `MP.GAME.timer` (`core.lua:249`), server-synced value overwritten only
  when not local (`action_handlers.lua:1061-1064,1080-1083`), opponent `enemy.last_timer` from
  `dataSync` (`action_handlers.lua:852-856`). `MP.timer_is_local()` chooses which
  (`lib/ruleset_utils.lua:26-32`).
- Bases: `MP.UTILS.timer_base` / `pvp_timer_base` apply ruleset multipliers
  (`lib/ruleset_utils.lua:5-24`); defaults `timer_base_seconds=150`,
  `timer_increment_seconds=60`, `timer_display_threshold=0` (`core.lua:179-203`).
- Threshold: display clamps any value above `timer_display_threshold` down to the threshold and
  formats integer if `> 9.95` else one decimal (`ui/game/timer.lua:160-174`). Threshold also
  gates the pending-start and matching-skip paths, not the timer's mere presence:
  `ui/game/timer.lua:472-482` (pending threshold start), `540-552` (skip diff path with
  threshold > 0), `ui/game/lobby_info.lua:233`.
- Presence is **not** established by `MP.LOBBY.config.timer` alone. The HUD timer node is
  injected only when `MP.LOBBY.code and (not MP.LOBBY.config.disable_live_and_timer_hud)` and
  the returned `timer_hud()` is non-nil, which additionally requires `config.timer`
  (`lovely/hud.toml:38`; `ui/game/timer.lua:34-35`). `disable_live_and_timer_hud` is forced true
  by Survival (`ui/main_menu/play_button/play_button_callbacks.lua:121-125`) and gates the
  live/timer HUD elsewhere (`ui/game/game_state.lua:362`, `ui/game/round.lua:6,38`,
  `ui/game/functions.lua:343`). Speedlatro replaces the string with `">>"` while its real value
  lives in `MP.speedlatro_timer.real` (`ui/game/timer.lua:84-85`;
  `layers/speedlatro_timer.lua:84-108`).
- The opponent-timer display (`enemy.last_timer` with threshold clamp and `%.1f` formatting) is
  rendered **only inside the hover tooltip** created by `G.FUNCS.set_timer_box`
  (`ui/game/timer.lua:161-174,333-350`); it is not a persistent HUD readout.
- Start/pause protocol: `MP.ACTIONS.start_ante_timer` / `pause_ante_timer`
  (`action_handlers.lua:1359-1386`), inbound handlers `1033-1089`; `pvpTimerOrder` controls who
  may start (`action_handlers.lua:444-460`; `ui/game/timer.lua:3-17,19-32`).
- Expiry: `ui/game/timer.lua:484-498` — PvP timer fails PvP; pressure/no-anim consumes
  `timer_forgiveness` first, then `MP.ACTIONS.fail_timer()`. Hand-played increments
  (`ui/game/timer.lua:582-608`) use `pvp_timer_hand_played_increment_seconds` (layer default 10,
  `layers/pvp_timer.lua:1-3`) or `timer_hand_played_increment_seconds` (pressure default 15,
  `layers/pressure_timer.lua:13-14`). Multipliers: `no_anim_timer` 2/3 (`layers/no_anim_timer.lua:4`),
  `pressure_timer` speedup ×2, base ×2 (`layers/pressure_timer.lua:9-10`),
  `speedlatro_timer` ×2 (`layers/speedlatro_timer.lua:7`).
- Major League forces `timer_base_seconds=180`, `timer_forgiveness=0`,
  `timer_display_threshold=180` (`rulesets/majorleague.lua:22-30`).

**Projection rule:** the raw `MP.GAME.timer` / `enemy.last_timer` values may be consumed **only
inside the trusted projection**, which emits the resulting threshold-clamped, rounded display
string **if the actual HUD/tooltip availability certificate below is satisfied** — the raw value is
never exported. `pvpTimerOrder` is likewise never exported; only the active UI eligibility
consequence (`MP.UI.can_timer_opponent()`, `ui/game/timer.lua:3-17`) may be. Do not exclude timers
wholesale (INTEGRATION_PLAN §Rules).

**Actual-visibility certificate (prerequisite for any timer projection):** the value may be
projected only when the current phase/context proves the same readout is on screen — lobby code
present, `disable_live_and_timer_hud` false, `config.timer` true, the timer HUD injected
(`lovely/hud.toml:38`; `ui/game/timer.lua:34-35`), and for the opponent tooltip, hover active
(`ui/game/timer.lua:333-350`). This prevents both presence leaks (showing a value the HUD would
not) and precision leaks (showing more digits than the clamped/rounded display).

## 6. Own hidden face-down cards and hidden future contents

Own face-down cards (identity is **not** owner-visible; must be redacted):

- Cards carry `facing` / `sprite_facing` (`card.lua:52-54`), flipped in place
  (`card.lua:4113-4121`); sprite swap at `card.lua:4357,4539-4540`.
- **Ownership does not make a face-down card visible.** `Card:hover` builds the inspectable
  tooltip (`generate_UIBox_ability_table` / `card_h_popup`) **only when `self.facing == 'front'`**
  (`card.lua:4315-4326`). A face-down hand card therefore exposes no name/rank/suit/ability to the
  player through the UI.
- Face-down hand cards are preserved: `CardArea:emplace` keeps a `stay_flipped` card face-down in
  `G.hand` and marks `card.ability.wheel_flipped = true` (`cardarea.lua:32-43`); stay-flip comes
  from the blind and from `G.GAME.modifiers.flipped_cards` on draw
  (`common_events.lua:402-408`, `cardarea.lua:600-604`); boss sprite-back at `game.lua:1458`.
- `wheel_flipped` drives the deck-preview `?` tally, i.e. the UI itself treats these cards as
  unknown (`UI_definitions.lua:513-531,3264`).

Because the raw Card objects still carry a populated `base` and `ability` even when drawn
face-down, the observation layer must treat own hand cards as **poisoned**: derive visibility
from `facing == 'front'` (after the stay-flip/wheel rules), and redact identity/rank/suit/ability
for any card that is face-down, regardless of what the raw fields contain. The accepted
integration plan explicitly forbids exposing hidden face-down identity.

Hidden future contents:

- **Booster pack contents do not exist until opened.** `Card:open()` creates them into
  `G.pack_cards` via `create_card(...)` (`card.lua:1681-1710` state + size; `1721-1794` content
  generation; `1788-1790` emplace). Before open, only the pack key/size is known
  (`G.GAME.pack_size`, `card.lua:1693-1707`). `G.GAME.pack_choices` controls multi-pick
  (`card.lua:1709`; consumed at `button_callbacks.lua:2273-2279`).
- **Shop offerings are generated, not stored ahead.** `create_card_for_shop`
  (`UI_definitions.lua:742-800`) polls pseudorandom rates per slot; initial fill
  `game.lua:3111-3112`; refresh `common_events.lua:1100-1114`; **reroll regenerates**
  `button_callbacks.lua:2872-2887`. Vouchers are polled separately
  (`get_next_voucher_key` `common_events.lua:1901`; assigned `game.lua:2178`, `state_events.lua:263`).
- The owner's current shop is visible, but future rerolls and unopened pack contents are
  seed-derived and must not be projected as if known.
- Deck order: `G.deck.cards` is the ordered draw pile and **must not** enter observations;
  shuffled at cashout (`button_callbacks.lua:2918`).

**Projection rule:** project own hand cards by their **UI-visible** identity only — face-up
(`facing == 'front'`) cards by name/rank/suit; face-down cards redacted as unknown. Deck order,
unopened pack contents and all future shop/reroll results are unknown and must not be projected.

## 7. MP overrides/layers that change legality (not only vanilla)

Ban resolution: `MP.ApplyBans()` unions ruleset, gamemode and deck bans into
`G.GAME.banned_keys`, then runs layer `on_apply_bans` hooks (documented in `mp/agents.md`,
`layers/_layers.lua:120-136`). `banned_silent` hides without UI.

Legality/scoring-affecting layers and overrides (each must be evaluated *after* layer
application, never assumed vanilla):

| Layer / file | Effect on legality or scoring |
|---|---|
| `layers/standard.lua:1-33` | bans/replaces vanilla jokers/consumables, sets `standard=true` |
| `layers/ban_mutators.lua:10-20` | bans enhancements/jokers |
| `layers/economy_mutators.lua:6-34` | changes costs/interest/discard tax/blind rewards (game_modifiers) |
| `layers/shop_mutators.lua:1-3`, `layers/experimental.lua:41-42` | `change_shop_size(1)` |
| `layers/shared_pockets.lua:1-20,23-46` | jokers/consumables/hand share slots (huge card_limit hack); bans `j_stencil` |
| `layers/eeeee.lua:8-22` | ~40% of RNG poll keys fixed per ante (seed divergence from choices) |
| `layers/polymorph_spam.lua:95-111` | rewrites joker/consumable abilities each blind; `perma_debuff` for banned |
| `layers/no_red_seals.lua:15-21` | `Card:set_seal` refuses Red |
| `layers/score_instability.lua:9-70` | rebalances chips/mult at `final_scoring_step` |
| `layers/glass_cannon.lua:12-19` | ×4 mult at `final_scoring_step` |
| `layers/speedlatro_timer.lua:84-108,118-159` | per-round local countdown; overwrites `MP.GAME.timer=999` |
| `layers/no_anim_timer.lua`, `pressure_timer.lua` | timer multipliers |
| `layers/smallworld.lua:2-144` | random pool cull; bans cascade to voucher requirements/tag replacements |
| `layers/sandbox.lua:116,162-176` | parallel joker pool, idol ban, silent vanilla bans |
| `layers/classic.lua:3`, `wraith_rework.lua:3` | enhancement/consumable reworks |
| `gamemodes/attrition.lua:13-33` | bans mr_bones/luchador/matador/chicot, ante vouchers, `tag_boss`, `bl_wall`, `bl_final_vessel`; boss→`bl_mp_nemesis` from `pvp_start_round` |
| `rulesets/*` | compose layers + `force_lobby_options` (e.g. Major League §5; Sandbox `rulesets/sandbox.lua:7-12`) |
| `objects/stickers/1_persistent.lua:38-49` | `mp_sell_price` changes `can_sell_card`/cost |

Cost/price side-effects also in `card.lua:383` (`couponed` → cost 0 in shop) and
`card.lua:1800-1807` (inflation).

**Consequence:** bans and reworks can replace a vanilla key with a reworked key and silently ban
the original; the action layer must read `G.GAME.banned_keys` and the *active* card centers, not
a hardcoded vanilla pool.

## 8. Always forbidden, narrowly permitted UI projection, and authoritative legality

**A. Always forbidden — never exposed, by any certificate or extractor.** These are not
"permitted if certified"; they are out of boundary by design:

- Game seeds and any seed-derived future state.
- Future order/results: deck order and hidden draws, unopened pack contents, future shop/reroll
  results, future RNG (`G.deck.cards`, `Card:open` generation §6, `create_card_for_shop` §6).
- Private opponent state: `enemy.real_score`, `enemy.highest_score`, `enemy.last_timer` raw,
  `pvpTimerOrder` / `MP.GAME.pvp_timer_order/activated` raw, opponent `hands` before
  `info_received`, opponent `spent_in_shop`/sells/private spend, mod hash and hardware ids.
- Hidden face-down identity of own cards (§6).

A "trusted engine-certified affordance" cannot legitimize any of the above; it only proves that a
value that is already legitimately player-visible is being read correctly.

**B. Narrowly permitted UI projection — only with an actual-visibility certificate.** Project
exactly what the HUD/tooltip would show in the current phase, no more:

- Own **face-up** hand identity and own highlight selection; own jokers/consumables; own dollars;
  `hands_left`/`discards_left`; own blind state; own acted markers
  (`functions/state_events.lua:480-481`). Face-down own cards redacted (§6).
- Own current shop offerings (`G.shop_jokers` cards) and already-opened pack contents
  (`G.pack_cards`).
- Opponent `score_text`/`hands_text` after §3 masking, and opponent `skips`/`lives` after
  `enemyInfo` (§3), plus `enemy.location` only when not disabled (§4).
- Timer display after threshold clamp/rounding, **and only** under the §5 actual-visibility
  certificate; raw `timer`/`last_timer` are consumed inside projection and never exported.
- Phase (`G.STATE`/`G.STAGE`) at the write sites in §1.

**C. Authoritative legality — evaluated in the real runtime, never reimplemented, never called
speculatively.** The complete gate for each action (play/discard/buy/reroll/sell/use/select/skip)
includes `block_play`, `STOP_USE`, controller locks, `G.play` occupancy, per-card consumeable
targets, `check_for_buy_space`, slots, and post-layer bans/reworks (§7). The only safe affordance
is "ask the loaded game whether action X with target Y is currently legal" inside the trusted
executor, immediately before calling the vanilla callback. `can_*` callbacks are not pure
predicates (§2) and must **not** be invoked by the extractor or by any action generator on
hypothetical actions.

## 9. Fairness-critical gotchas (short list)

1. `can_play`/`can_discard`/`can_buy`/... are **UI colouring predicates, not gates**, and they
   mutate UI state. Real gates include `blind.block_play`, `hands_left`, `STOP_USE`,
   `CONTROLLER.locked`, `G.play` occupancy, `check_for_buy_space`, per-card consumeable targets.
   Revalidate in the executor; never call `can_*` speculatively from the extractor/generator.
2. Opponent score is masked to `"???"` while `hide_score_until_played` and
   `current_round.hands_played == 0`; the server also withholds. Never project `real_score`.
3. Opponent `hands` is masked (`info_received=false`) until the first `enemyInfo` of a blind;
   `startBlind` resets it. Do not leak stale values.
4. Major League disables opponent location and clamps the timer to 180; only the timer-action
   **eligibility** may be exposed, never the location strings.
5. A timer may be projected only under the §5 actual-visibility certificate (`MP.LOBBY.code`,
   `not disable_live_and_timer_hud`, `config.timer`, HUD injected, hover for the opponent
   tooltip). `config.timer` alone does not prove the readout is on screen. Raw `timer`/
   `last_timer` are consumed inside projection only, emitted at the clamped/rounded precision;
   no presence or precision leak. Speedlatro's real value lives outside `MP.GAME.timer`.
6. `pvpTimerOrder` decides who may start the timer. It is a fairness-sensitive field; project
   the eligibility, not the raw order.
7. Own face-down cards are **not** owner-visible (`Card:hover` gates the tooltip on
   `facing == 'front'`, `card.lua:4315`); hand cards can stay face-down (`cardarea.lua:32-43`,
   wheel-flipped). Redact their identity even though `base`/`ability` are populated. Deck order
   and all future contents are unknown: booster contents are created only at `Card:open()`;
   shops only at generation/reroll.
8. Bans/layers can replace a vanilla card with a reworked key and silently ban the original; a
   hardcoded vanilla action/pool model is wrong. Evaluate post-`ApplyBans`.
9. `shared_pockets`, `eeeee`, `polymorph_spam`, `no_red_seals`, `score_instability`,
   `glass_cannon`, and the economy mutators change slots, RNG, card abilities, seals, scoring
   and costs. Legality and observation must reflect the active layer chain.
10. Same seed is not identical offers after divergent choices/opponent-triggered RNG; do not
    treat deterministic generation as omniscience (INTEGRATION_PLAN §Rules).
11. An engine-certified affordance never legitimizes the always-forbidden class (§8A: seeds,
    future order/results, private opponent state, hidden face-down identity). A certificate only
    proves a legitimately visible value is read faithfully; it is not a permission to widen the
    boundary.

## 10. Mapping path and next step

Path for M2 fidelity work:

1. Observation: `G.STATE`/`G.STAGE` (§1) → own visible state (§6 face-down redaction, §8B) →
   opponent projection (`MP.GAME.enemy` via §3/§4 masking) → timer projection
   (`MP.GAME.timer`/`enemy.last_timer` via §5 certificate, §8B) → active-context snapshot
   (`MP.current_ruleset()`, `MP.active_layer_chain()`, §7). Never touch §8A fields.
2. Actions: one executor entry point per §2 action that re-runs the engine predicate and then
   calls the vanilla callback; never call `Client.send`/`MP.ACTIONS` from policy.
3. Both must be validated against the **real loaded runtime** in the M2 observation/action proof
   gate (INTEGRATION_PLAN §Required prototype gates #5), not against this static map.

This document contains source evidence only. It adds no schema, no extractor, no executor and no
architecture change. No existing file was modified.

## 11. Correction addendum — historical design vs final M2 implementation

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27. This addendum only
records where the **historical design** in §1–§10 was corrected or narrowed by the **final M2
implementation** after Claude review (`docs/CLAUDE_M2_REVIEW.md`). The historical evidence
above is retained; where it conflicts with this addendum, the addendum and the implemented
code win. No line numbers above were rewritten.

1. **Timers — no raw fallback (supersedes the §5 projection rule and §8B "displayed timer"
   wording).** §5 proposed a trusted threshold-clamp/rounding projection of the raw
   `MP.GAME.timer` / `enemy.last_timer`. The final reader does **not** project raw timer values:
   it emits only the exact certified rendered display string for the local and opponent timers,
   under the §5 actual-visibility certificate plus `MP.LOBBY.config.timer`,
   `disable_live_and_timer_hud ~= true` and a lobby code. `enemy.last_timer` is never read and
   the schema has no raw-timer field or reader-side formatting helper. The §5 threshold/`%.1f`
   research remains evidence about the HUD, not a permitted data path.
2. **Deck aggregates — total only (supersedes the §6/§8B rank/suit deck-preview reading).**
   The historical map allowed projecting "legitimately known public" deck composition. §6 itself
   records that the UI shows face-down `wheel_flipped` cards as `?` (unknown), which the
   `by_suit`/`by_rank` schema could not represent. The final schema's `read_deck` accepts only
   `total`, and the reader neither reads nor emits `by_suit`/`by_rank`. `G.deck.cards`/draw
   order remains always forbidden; a deck-preview aggregate stays unsupported until a certified
   spec with an unknown bucket and the `wheel_flipped` rule exists.
3. **Pack phase enum — real `*_PACK` names plus `SMODS_BOOSTER_OPENED` (§1 wording).** Vanilla
   uses `G.STATES.TAROT_PACK`, `SPECTRAL_PACK`, `PLANET_PACK`, `STANDARD_PACK` and
   `BUFFOON_PACK` (`work/reference/game/card.lua:1693-1705`). Steamodded 0.26.829.0 adds
   `SMODS_BOOSTER_OPENED` (declared `work/reference/smods-booster.toml:101`, assigned to
   `G.STATE` at `:36`). The reader resolves these **by symbol name**, never by a magic number
   such as `999`; the old short names (`TAROT`, `SPECTRAL`, `PLANET`, `STANDARD`, `BUFFOON`) are
   not recognized and are refused `reader_unsupported_state`.
4. **Shop booster packs — distinct area and zone (§6/§8B).** Packs live in `G.shop_booster.cards`,
   not `G.shop_jokers.cards`. The pure schema binds `shop.boosters` to the `shop_booster` zone
   (`shop_booster:N`) and rejects `kind == "booster"` inside `shop.items`; the reader projects
   `shop.boosters` from `G.shop_booster.cards` with its own positional facing check, and
   `OPEN_BOOSTER.item_ref` uses the new zone.
5. **Opponent PvP score masking — engine-derived (§3).** §3's `"???"` mask condition
   (`hide_score_until_played` + PvP boss + `hands_played == 0`) is decided from the engine, not a
   caller boolean: `G.GAME.blind.config.blind.key == "bl_mp_nemesis"` or `G.GAME.blind.pvp`
   (`objects/blinds/nemesis.lua:32-35`). A view `pvp_context = false` can unmask only when the
   engine proves a non-PvP blind; the mask is unconditional in phase `MULTIPLAYER_PVP` while
   `hands_played == 0`, and an unknown/unreadable blind masks. `enemy.real_score` is never read.
6. **Consumable target binding.** `consumable_target.source_ref` (`consumable:N`) is derived by
   the reader from `source.ordinal`; target refs bind to explicit engine ordinals, and duplicate
   engine ordinals across target records are refused so two refs cannot alias one engine card.
7. **Epoch semantics.** The runtime `epoch` is a trusted, non-negative, strictly increasing
   revision of the captured AI decision state (including A→B→A change-backs), not a frame or
   snapshot counter; a fresh session starts a fresh broker. An unobserved ABA cannot be detected
   by the reader alone and requires the trusted producer/launcher revision. See
   `docs/STATE_READER.md` §3.1 and `docs/M2_EXECUTION_BOUNDARY.md`.

All of the above fail closed and add no engine callback, RNG, network or filesystem path.
