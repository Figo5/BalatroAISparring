# Trusted state reader (`AISparring/integration/state_reader.lua`)

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: bounded M2 implementation, post-Claude-review corrections. Fixture-only and **unwired**
from mod startup. No live game capture, no engine callbacks, no RNG/network/logs/filesystem, no
M1 changes. Real role/epoch/view provenance binding is still a launcher prerequisite (see §9).

Read with `AGENTS.md`, `docs/MILESTONE_2_PLAN.md`, `docs/FAIRNESS.md`,
`docs/M2_SOURCE_MAP.md` (source evidence, including its correction addendum) and
`docs/AI_OBSERVATION.md` (the schema it feeds). Tests live in `tests/reader/` and run through
`tests/run_reader.py`.

This document describes only `AISparring/integration/state_reader.lua`. It does **not** own
`AISparring/ai/observation.lua`, `AISparring/ai/codec.lua`, `AISparring/ai/actions.lua`, the
action broker or the policy worker, and it does not edit them; it consumes their current
contract (e.g. the `shop_booster` zone, `consumable_target.source_ref`, and total-only deck).

## 1. Purpose and trust boundary

The reader is the narrow, trusted adapter that turns **one** staged runtime reference plus
**one** trusted UI-visible projection into a single `AIObservation`:

```
runtime wrapper (role + epoch + G + MP)  ─┐
                                          ├─> state_reader.capture() ─> observation.observe(frame) ─> opaque handle
trusted ui_view projection (same epoch)  ─┘
```

- `capture` reads a small, fixed set of engine primitives with `rawget` and copies a bounded
  set of fields from the trusted view. It never traverses arbitrary engine trees, never calls
  engine/UI methods or callbacks, never reads RNG, network, logs or the filesystem, and never
  retains a frame.
- The frame built by `capture` is handed **immediately** to `observation.observe`, which is the
  only sanitizer and the only producer of the canonical record. `capture` returns only the
  opaque observation handle (or `nil, code`). It never returns the frame, engine card, UI
  record or G/MP reference.
- The **legitimate producer's ability to lie is TCB**, not a policy capability. This module can
  prove shape, phase compatibility, epoch agreement, engine-card backing, facing, field
  attestation, PvP-boss state and config gating. It cannot authenticate an arbitrary external UI
  view; that is the launcher/integration's job and is currently unwired
  (`docs/MILESTONE_2_PLAN.md` §Scope).

Phase is the top-level gate (`M2_SOURCE_MAP.md` §1). The reader derives it from the live
`G.STATE`/`G.STATES` enum (never from a hardcoded integer) and refuses any view whose declared
normalized phase is not compatible with that derived state.

## 2. API

```lua
local StateReader = dofile("AISparring/integration/state_reader.lua")
local reader = StateReader.factory(observation)          -- nil, "reader_bad_observation"
local handle, code = reader.capture(runtime, ui_view)    -- handle, or nil, bounded code
reader.CODE, reader.LIMITS, reader.SCHEMA_VERSION
reader.describe()                                        -- copy of phases/zones/limits/codes
```

`observation` is the already-implemented `AISparring/ai/observation.lua`; only
`observation.observe` is required, and `observation.is_handle` is used when present. Codes are
returned as values; no raw exception escapes `capture` (the observer call is `pcall`-bounded).

Static codes:

`reader_bad_observation`, `reader_bad_runtime`, `reader_bad_role`, `reader_bad_epoch`,
`reader_epoch_mismatch`, `reader_bad_view`, `reader_unsupported_state`,
`reader_phase_mismatch`, `reader_entity_mismatch`, `reader_observe_failed`.

## 3. Runtime input contract (trusted wrapper)

`runtime` must be a plain (metatable-free) table built by trusted integration:

| Field | Requirement |
|---|---|
| `role` | exactly `"ai_staged"`. Anything else (human, menu, unknown) is refused `reader_bad_role`. |
| `epoch` | int32 integer `>= 0`. Missing, negative or non-integer refused `reader_bad_epoch`. |
| `G` | table reference to the staged engine globals. May carry a metatable; only `rawget` is used. |
| `MP` | table reference to the staged Multiplayer globals. May carry a metatable; only `rawget` is used. |

### 3.1 Epoch semantics (M3)

The epoch is a **trusted, non-negative, monotonically increasing revision of the captured AI
decision state**, not a frame counter, wall clock, observation hash or reused snapshot counter.
Contract:

- A fresh session starts a **fresh broker** and a fresh epoch series; epochs are not shared
  across sessions.
- The epoch **strictly increases on every decision-relevant state change** of the captured AI
  runtime, **including an A→B→A change-back**. Two captures that return to the same visible
  content must still carry different epochs if any decision-relevant state changed in between.
- The reader only *validates* that an epoch is a non-negative int32 and that the view epoch
  equals the runtime epoch. It does not generate the epoch and cannot itself detect an
  **unobserved** ABA (a change and change-back that happened between two captures): that requires
  the trusted producer/launcher revision to advance on every state change, which is a broker and
  launcher responsibility (`docs/M2_EXECUTION_BOUNDARY.md`, `docs/FAIRNESS.md`).
- A monotonic counter that only tracks captured frames or reuses a snapshot counter is
  insufficient and must not be used as the epoch.

## 4. UI-view input contract (trusted projection, same epoch)

`ui_view` must be a plain (metatable-free) table produced by the trusted UI-equivalent
authority for the **same epoch**. Unknown keys are ignored and never traversed. The reader
consumes only the fields below.

```
ui_view = {
  epoch  = <int >= 0>,             -- must equal runtime.epoch, else reader_epoch_mismatch
  phase  = <normalized phase>,     -- must be compatible with G.STATE, else reader_phase_mismatch
  recognition = { pvp_context = true|false },  -- optional; only a proven non-PvP engine lets it unmask

  match = {                        -- required for observation.match.ruleset
    ruleset = "<token>",           -- required token (e.g. ruleset id)
    blind = "<display>",
    blind_disabled = true|false,   -- optional; strict bool, only with blind, must equal G.GAME.blind.disabled
    timer = "<display>", timer_visible = true,   -- timer copied only under §4.2 gate
    lives = int, hands_per_round = int, discards_per_round = int,
    hand_size = int, joker_slots = int, consumable_slots = int,
  },

  self = {
    hand_visible = true|false,     -- explicit certificate; hand identity copied only when true
    current_score = "<display>", blind_requirement = "<display>",
    cards = {
      hand = { <card record>, ... },                 -- positional
      joker = { <joker record>, ... },               -- positional
      consumable = { <consumable record>, ... },     -- positional
    },
    deck = { total = int },        -- total ONLY; by_suit/by_rank unsupported and never read
    hand_levels = {                -- optional; only allowlisted hand tokens (copy_hand_levels)
      pair = { level = int, chips = int, mult = int,
               played_this_round = int },  -- optional, 0..1000, round phases only; else reader_bad_view
    },
    owned_vouchers = { "v_...", ... },     -- optional, see below
  },

  opponent = {                     -- opt-in; dropped unless certified == true
    certified = true,
    score_visible = bool, hands_visible = bool, lives_visible = bool,
    location_visible = bool, timer_visible = bool,
    displayed_score = "<display>", hands = int, lives = int, location = "<display>",
    timer = "<display>",           -- exact certified rendered string only (no raw fallback)
  },

  shop = {
    reroll_cost = int,
    items = { <shop_item record>, ... },         -- kind must not be "booster"
    boosters = { <shop_item record>, ... },      -- packs; refs are shop_booster:N
    vouchers = { <voucher record>, ... },
  },
  booster = { kind = "<token>", choices = int, skips = int, cards = { <card record>, ... } },
  consumable_target = {
    source = { ordinal = <1-based consumeables index>, <record> },
    targets = { { ordinal = <1-based hand index>, <record> }, ... },
    min_targets = int, max_targets = int,
  },

  context = { blocked = bool, timer_expired = bool, target_selection = bool,
              max_play = int, max_discard = int, min_targets = int, max_targets = int },
  certificates = { version = 1, items = { { type = "...", certified = true, ... }, ... } },
}
```

Entity record (per zone; `shown` is the **per-field attestation**):

```
{
  ordinal = <int, subset zones only>,     -- target/source records name the engine ordinal
  face_down = false,                      -- MUST be exactly false; missing/non-false redacts
  shown = { center=true, rank=true, suit=true, edition=true, seal=true, kind=true,
            debuff=true, cost=true, sell_cost=true, visible_text=true },
  center="<token>", rank="<token>", suit="<token>", kind="<token>",
  edition="<token>", seal="<token>", debuff=bool,
  cost=int, sell_cost=int, visible_text="<printable ASCII>",
}
```

`schema_version` is owned by the reader (`1`) and is not read from `ui_view`.

### 4.1 Phase derivation and compatibility

`G.STATES` symbols are resolved **at runtime by name** and compared with `G.STATE`. No numeric
state constant is hardcoded (in particular, `SMODS_BOOSTER_OPENED` is looked up by name, never
the literal `999`).

| Engine symbol(s) (`G.STATES`) | Derived engine context | Compatible `ui_view.phase` |
|---|---|---|
| `BLIND_SELECT` | blind | `BLIND_SELECTION` |
| `SELECTING_HAND` | hand selection | `PLAY_HAND`, `DISCARD`, `CONSUMABLE_SELECTION`, `MULTIPLAYER_PVP` |
| `SHOP` | shop | `SHOP` |
| `TAROT_PACK`, `SPECTRAL_PACK`, `PLANET_PACK`, `STANDARD_PACK`, `BUFFOON_PACK`, `SMODS_BOOSTER_OPENED` | pack | `BOOSTER_SELECTION` |
| `GAME_OVER` | terminal | `MATCH_COMPLETE` |
| anything else (including the old short names `TAROT`/`SPECTRAL`/`PLANET`/`STANDARD`/`BUFFOON`) | unsupported | refused `reader_unsupported_state` |

The vanilla pack enums are `*_PACK` (`work/reference/game/card.lua:1693-1705`), and Steamodded
0.26.829.0 adds `SMODS_BOOSTER_OPENED` (declared at `work/reference/smods-booster.toml:101`,
assigned to `G.STATE` at `:36`). Both are resolved by symbol name; a modded enum value is
accepted whatever integer it holds.

`CONSUMABLE_SELECTION` is a UI subcontext of `SELECTING_HAND` (target selection while choosing
a hand), exactly as documented in `M2_SOURCE_MAP.md` §1/§2. If the same `G.STATE` value matches
two symbols with **different** derived contexts (ambiguous enum), the state is refused
`reader_unsupported_state`.

### 4.2 Cross-field staleness and timer gating

`capture` denies a view that mixes phases (`reader_phase_mismatch`):

- `shop` present only in `SHOP`; `booster` only in `BOOSTER_SELECTION`; `consumable_target`
  only in `CONSUMABLE_SELECTION`.
- `SHOP`/`BOOSTER_SELECTION`/`CONSUMABLE_SELECTION` require their section to be present/plain.
- `MATCH_COMPLETE` emits only `schema_version`, `phase` and `match`; no old hand/opponent/
  shop/pack/context/certificates are carried forward.
- `epoch` must equal the runtime's epoch (`reader_epoch_mismatch`).

Timers are never copied generically:

- `match.timer` is copied only when `match.timer_visible == true` **and**
  `MP.LOBBY.config.timer == true`, `disable_live_and_timer_hud ~= true` and a non-empty
  `MP.LOBBY.code` are present. There is no bypass path.
- `opponent.timer` is copied only when `opponent.timer_visible == true` under the same config
  gates. Only the exact certified rendered display string is used; there is no raw
  `last_timer` fallback and no reader-side timer formatting.

## 5. Engine reads (complete allowlist)

All engine access is `rawget`-only and fixed-path; metatables are never invoked and arbitrary
fields are never traversed.

| Read | Source evidence |
|---|---|
| `G.STATE`, `G.STATES` (by symbol name) | phase gate, `M2_SOURCE_MAP.md` §1; `card.lua:1693-1705`; `smods-booster.toml:36,101` |
| `G.GAME.dollars` | signed `self.money`; §8B own dollars |
| `G.GAME.bankrupt_at` → `credit_limit = -bankrupt_at` | spendable model, §2/§8B; omitted if positive/out of range |
| `G.GAME.current_round.hands_left`, `.discards_left` | only in hand-bearing phases; §2 gates |
| `G.GAME.round_resets.ante`, `G.GAME.round` | displayed ante/round; §1 |
| `G.GAME.current_round.hands_played` | PvP score-masking gate; §3 |
| `G.GAME.blind.pvp`, `G.GAME.blind.config.blind.key` | engine PvP-boss derivation (M2); `nemesis.lua:32-35` |
| `G.GAME.blind.disabled` | cross-check for `match.blind_disabled` (never trusted from the view); `docs/BLIND_DISABLED_DESIGN.md` |
| `G.hand.cards`, `G.jokers.cards`, `G.consumeables.cards`, `G.shop_jokers.cards`, `G.shop_booster.cards`, `G.shop_vouchers.cards`, `G.pack_cards.cards` | existence/facing/masking backing only |
| `card.facing`, `card.sprite_facing` | face-up gate; `M2_SOURCE_MAP.md` §6 (`card.lua:52-54`) |
| `card.ability.effect` | Stone Card rank/suit masking (`m_stone` enhancement) |
| `card.config.center.no_rank`, `.no_suit`, `.replace_base_card` | base-replacement rank/suit masking; §6 |
| `MP.GAME.enemy.info_received`, `.score_text`, `.hands_text` | opponent projection, §3 |
| `MP.LOBBY.code`, `MP.LOBBY.config.hide_score_until_played`, `.enemy_location_disabled`, `.timer`, `.disable_live_and_timer_hud` | visibility certificates, §3/§4/§5 |

Never read: seeds, `G.deck`/draw order, deck `by_suit`/`by_rank` aggregates, future
shops/packs/rerolls, `enemy.real_score`, `enemy.highest_score`, `enemy.last_timer`, raw
`enemy.location`/location structs, `pvpTimerOrder`, opponent decks/jokers/shops, logs, mod
hashes, hardware ids, arbitrary config or `card.base`.

## 6. Entity projection rules

Identity is taken **only** from the trusted view record and only when the reader can prove the
corresponding engine card is actually the visible one:

1. The engine area for the zone must exist and be a clean dense array whose ordinal count
   equals the view record count for whole zones (`reader_entity_mismatch` otherwise).
2. The engine card at that ordinal must be a table (`reader_entity_mismatch` otherwise).
3. `record.face_down` must be **exactly `false`**. Missing, `true` or any non-boolean value
   redacts the entity, regardless of the other fields.
4. The card's raw `facing == "front"` **and** `sprite_facing == "front"` are required. Any other
   value (including missing) forces redaction, even if the view is poisoned.
5. A field is copied only when `record.shown[field] == true` (exact `true`; unknown flags deny).
6. Rank/suit are omitted when the raw card is a Stone Card (`ability.effect == "Stone Card"`)
   or when the raw center marks `replace_base_card`/`no_rank`/`no_suit` — even when the view
   attests and supplies them.
7. Values are copied through fixed token-format/int/bool/printable-text checks; anything else
   is omitted (fail closed), never widened.

Redacted entities are emitted as `{ face_down = true }` so `observation.observe` records
`redacted = true`. Face-up entities stay at a stable `zone:ordinal`, so ordinals never shift.

Zones supported: `hand`, `target`, `booster` (kind `card`); `joker`; `consumable`/`source`;
`shop` and `shop_booster` (`shop_item`); `shop_voucher` (`voucher`). `self.jokers`/
`self.consumables` come from `self.cards.joker`/`self.cards.consumable`; shop items, shop
boosters, vouchers and pack cards come from their phase sections. `shop.boosters` binds to the
distinct `G.shop_booster.cards` area with its own positional facing check and `shop_booster:N`
refs; `OPEN_BOOSTER.item_ref` uses that zone. Shop `items` must not contain `kind = "booster"`
(the schema rejects it).

### 6.1 Positional bindings (real mapper future)

The reader does not hold engine object identity across calls. Whole zones bind by **position**
(record `i` ↔ engine ordinal `i`). Subset zones (`target`, `source`) bind by an explicit
`record.ordinal`. The reader rejects two target records that name the **same engine ordinal**
(`reader_entity_mismatch`), so `target:1` and `target:2` can never alias one engine card. A
real mapper that decides which engine card is at a UI slot, and the reverse (action refs back
to engine targets), is future work; until then `ordinal` must be supplied by the trusted
producer and is validated only for bound/plausibility, not authentic identity.

For `consumable_target`, the reader derives and emits `source_ref = "consumable:<ordinal>"`
from `source.ordinal`, binding the target context to the own-consumable zone ref used by
`USE_CONSUMABLE`.

## 7. Opponent projection

Nothing is projected from `MP.GAME.enemy` merely because it exists. Every field needs the
matching explicit HUD certificate, and the engine masking gates must pass:

- `displayed_score`: needs `score_visible = true` **and** `enemy.info_received == true`. Masking
  is enforced first, using the **engine's** PvP-boss state (never a caller boolean alone):
  - If `hide_score_until_played` is not proven `false`, the config is unknown ⇒ mask.
  - If `hands_played` is not a non-negative integer ⇒ mask.
  - If `hands_played == 0`: in phase `MULTIPLAYER_PVP` the score is masked **unconditionally**;
    otherwise it is unmasked only when the view says `recognition.pvp_context == false` **and**
    the engine proves a non-PvP blind. Proof of PvP follows Lua truthiness exactly as MP's
    `is_pvp_boss()` (`... or blind.pvp`) does: any non-nil, non-false `G.GAME.blind.pvp` value
    (including `0`, `""`, a table or a function) is PvP; the value is compared only and never
    invoked or traversed. Non-PvP is proven only when `blind.pvp` is `nil`/`false` **and**
    `G.GAME.blind.config.blind.key` is a nonempty string other than `"bl_mp_nemesis"`. An empty,
    non-string or missing key, or a missing/unreadable blind ⇒ mask.
  - An actual PvP boss (`key == "bl_mp_nemesis"` or any truthy `blind.pvp`) ⇒ mask even if the
    view claims non-PvP.
  A stale/poisoned `score_text` cannot revive a masked score. `enemy.real_score` is never read.
- `hands`: needs `hands_visible = true` and `info_received == true`; value comes from the
  certified view integer or, failing that, strict decimal parsing of `enemy.hands_text`. Raw
  pre-`info_received` `enemy.hands` is never used.
- `lives`: needs `lives_visible = true` and `info_received == true`; only the current visible
  projection is used.
- `location`: needs `location_visible = true` **and** `MP.LOBBY.config.enemy_location_disabled
  == false`; otherwise omitted (no raw private location).
- `timer`: needs `timer_visible = true`, the §4.2 config gates, and a certified rendered
  display string. `enemy.last_timer` is never read.

If no opponent field is certified, the opponent section is dropped entirely.

## 8. Context and certificates

`context` and `certificates` are copied from the trusted view (for the same epoch) and handed to
`observation.observe`, which performs the actual allowlist, bound, ref-existence and
certification validation. The reader **never calls `can_*`** or any engine predicate, and never
invents or widens an affordance. Missing context becomes the schema's deny-by-default
(`blocked = true`, `timer_expired = true`). Missing/absent certificates yield no actions. Fresh
engine validation remains the broker's responsibility and is disabled in M2.

## 9. Supported subset, limits and honest non-claims

Deliberately unsupported or unproven (denied, omitted or refused rather than guessed):

- **Unwired.** Nothing constructs a real `ui_view`; no launcher binds role/epoch/view
  provenance. The reader is exercised through fixtures only. It must not be described as
  authenticating an arbitrary UI view, and no live capture, game launch or Mod write occurs.
- **Deck rank/suit aggregates are unsupported.** Only the on-screen deck `total` is projected.
  `by_suit`/`by_rank` are neither read nor emitted: the UI preview shows face-down
  (`wheel_flipped`) cards as `?` and has no unknown bucket, so a rank/suit aggregate cannot
  represent what the player sees and would leak hidden face-down identity (M2_SOURCE_MAP §6).
- **Tags** (`self.tags`) are not projected (no engine-card backing path is defined).
- **Owned vouchers** (`self.vouchers`) are projected from the adapter's plain
  `owned_vouchers` key list (`copy_owned_vouchers`, docs/OWNED_VOUCHERS_DESIGN.md):
  - at most 32 strings matching `^v_[a-z0-9_]+$` (≤ 32 bytes), strictly
    increasing bytewise;
  - anything else is `reader_bad_view` (fail-closed);
  - each record is `{ face_down = false, center = key }`, with no engine
    binding;
  - no action targets them: `BUY_VOUCHER` accepts only `shop_voucher` refs;
  - a `vouchers` field in the view is ignored.

  This is the AI's own Run Info voucher list, reviewed against
  `docs/FAIRNESS.md` (own, human-visible run information).
- **Opponent deck/jokers/shop, future shop/reroll/pack contents, seeds and deck order** are
  never read.
- **Timers** are copied only as exact certified rendered strings; the reader performs no timer
  formatting, clamping or raw-value projection.
- **PvP score masking** is decided by the engine blind (and phase), never by a lone view flag.
- **Modded oversized zones** (e.g. a hand above 64, shared-slot hacks) fail closed with
  `reader_entity_mismatch` rather than truncating.
- **Localized/rendered glyphs** must not be used as token identity: `rank`/`suit`/`center` are
  engine token keys, not display glyphs. A glyph or unknown token is omitted by the fixed-format
  checks.
- **Match-complete** exposes only the schema's terminal shape; no end-game private dumps.
- `state_reader.lua` references no game globals (`G`, `MP`, `SMODS`, `Client`, `love`, `NFS`),
  no `require`/`dofile`/`debug`/`io`/`os`, and no RNG. It takes all engine references only
  through the injected runtime wrapper.

## 10. Tests

`tests/run_reader.py` runs every `tests/reader/test_*.lua` under both Lua 5.1 and LuaJIT 2.1
(lupa) with `--require-all`, loading the actual `codec.lua`, `observation.lua` and
`state_reader.lua`. Coverage includes:

- positive construction for every supported phase, all six real pack states (including
  `SMODS_BOOSTER_OPENED` resolved by name), `consumable_target` source binding, and distinct
  `shop.boosters`/`shop_booster:N`;
- wrong role, missing role, negative/fractional/mismatched/negative-view epoch;
- unknown and ambiguous engine state, and refusal of the old pack short names;
- facing, flip, missing facing flags, Stone Card and `no_rank`/`no_suit`/`replace_base_card`
  masking, absent/partial `shown`;
- engine-metatable canaries, hidden poison non-traversal, and a **`rawget` spy** (I3) that
  proves no forbidden raw field (`G.deck`, seeds, `real_score`, `last_timer`,
  `pvp_timer_order`, …) is read on a tracked engine object, with a control read that is
  detected;
- repeated-capture mutation isolation, export isolation and cross-capture no-cache;
- engine-derived PvP score masking: unknown blind, proven non-PvP unmask, actual nemesis/`pvp`
  boss mask, unconditional `MULTIPLAYER_PVP` phase mask, and contradictory-view regression;
- `info_received`, hands, location and rendered-only timer gates;
- deck `total`-only projection and the face-down/deck-maps non-leak regression;
- stale shop/hand/pack views, oversized and malformed views, duplicate target ordinals.

No game or live runtime is executed.

## 11. Deliberate exclusions vs. the schema

The reader consumes the pure schema as it currently stands: total-only `deck`,
`consumable_target.source_ref` (derived here from `source.ordinal`), and the `shop_booster`
zone for `shop.boosters`/`OPEN_BOOSTER`, and owned vouchers as plain keys (§ above). Any future addition (tags, additional
zones, a certified deck-preview aggregate with an unknown bucket) must update both this
document and `docs/AI_OBSERVATION.md`, and be re-reviewed against `docs/FAIRNESS.md`.
