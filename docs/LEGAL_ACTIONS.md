# Legal actions (`ai/actions.lua`) — M2 part 2

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: implementation documentation for `AISparring/ai/actions.lua`. Consumes
the implemented `AIObservation` (`docs/AI_OBSERVATION.md`). No reader, broker,
policy, executor, engine callback or runtime hook exists. Generated actions are
inert data; nothing here executes anything.

Read with `AGENTS.md`, `docs/MILESTONE_2_PLAN.md`, `docs/FAIRNESS.md`.

## 1. Purpose and trust boundary

`actions.lua` turns the **exact, trusted action-certificate catalog** already
stored in an observation into a bounded list of legal, plain action records, and
independently revalidates a caller's action against the current observation.

- It reads the observation **only** through `observation.export(handle)`. It uses
  no globals, no `require`, no integration/engine imports, no RNG, no filesystem
  or network.
- It accepts only handles owned by the specific `observation` passed to the
  factory; a foreign handle fails `export` and is reported as an unknown handle.
- The observation certificate catalog is produced by the trusted UI-equivalent
  adapter (TCB). This module never invents authority: a missing certificate means
  no action. The catalog is intentionally **non-exhaustive**; generated output is
  a safe certified subset, not parity with the game.

## 2. API

```
local Actions = dofile("AISparring/ai/actions.lua")
local actions = Actions.factory(observation, codec)   -- nil, code on bad inputs

local list, code = actions.generate(handle)           -- array of plain actions, or nil, code
local action, code = actions.validate(handle, candidate) -- normalized copy, or nil, code
```

- `generate` returns a plain array, deterministically sorted by action `id` and
  deduplicated by canonical identity, capped at 128 entries. It returns an empty
  list (not an error) when the phase has no context, the state is blocked or the
  timer has expired, the phase is `MATCH_COMPLETE`, or there is no certificate
  catalog. It returns `nil, code` only when the handle is not this observation's.
- `validate` returns an independent copy of the matching current candidate
  (never the caller's table) or `nil, code`.
- `actions.CODE` / `instance.CODE` expose the static error codes.

## 3. Action records and identity

Each generated action is a plain table with narrow, type-specific keys and an
`id`:

```
{ type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "<canonical>" }
```

- **`id` is the complete canonical encoding of the action content excluding
  `id`** (`codec.encode`), not a hash. Two actions are identical iff their
  canonical content is identical, independent of certificate input order.
- Certification metadata (`certified`) and `capacity_ok` are stripped; only the
  public action type and its exact refs/order remain.
- Possible keys: `type`, `id`, and per type `card_refs`, `item_ref`, `joker_ref`,
  `consumable_ref`, `voucher_ref`, `source_ref`, `target_refs`, `order`.
  No phase, resource, cost or callback data is embedded (the consumer derives
  those from the observation under the broker's fresh check).

## 4. Generation rules

Global gates (any false ⇒ empty list):

- `context.blocked == false` and `context.timer_expired == false` (the schema
  defaults both to `true`, so absence denies).
- phase is not `MATCH_COMPLETE`.
- a `certificates` section exists and every used entry has `certified = true`.

Phase allowlist per type:

| Type | Allowed phases |
|---|---|
| `SELECT_BLIND`, `SKIP_BLIND` | BLIND_SELECTION |
| `PLAY_CARDS`, `DISCARD_CARDS` | PLAY_HAND, DISCARD, MULTIPLAYER_PVP |
| `BUY_ITEM`, `REROLL`, `BUY_VOUCHER`, `OPEN_BOOSTER`, `LEAVE_SHOP` | SHOP |
| `SELECT_BOOSTER_ITEM`, `SKIP_BOOSTER` | BOOSTER_SELECTION |
| `SELECT_TARGETS` | CONSUMABLE_SELECTION |
| `USE_CONSUMABLE`, `SELL_JOKER`, `SELL_CONSUMABLE`, `REORDER_JOKERS` | all self-bearing phases (not MATCH_COMPLETE) |
| `REORDER_HAND` | PLAY_HAND, DISCARD, MULTIPLAYER_PVP, CONSUMABLE_SELECTION, BOOSTER_SELECTION |

Per-type filters:

- **PLAY_CARDS / DISCARD_CARDS:** phase in hand phases; `self.hand` present
  (i.e. `hand_visible` was certified); `self.hands > 0` (play) or
  `self.discards > 0` (discard); explicit `context.max_play` /
  `context.max_discard` present; non-empty selection, no duplicates, count within
  the limit; every ref exists in `self.hand`.
- **BUY_ITEM:** SHOP; `item_ref` in `shop.items`; not redacted; `kind` is one of
  `card`, `joker`, `consumable` (booster/voucher/unknown kinds denied); `cost`
  present; affordable (see §5). `kind = joker`/`consumable` additionally requires
  capacity (see §6). Card purchases need no Joker slot but still need the exact
  certificate.
- **OPEN_BOOSTER:** SHOP; `item_ref` in the separate **`shop.boosters`** zone
  (`shop_booster:N`) exclusively — never the generic `shop` zone; not redacted;
  `kind == "booster"`; `cost` present; affordable. Booster packs inside
  `shop.items` are rejected by the schema (`observation_invalid_entity`), so
  `BUY_ITEM` can never open a pack.
- **BUY_VOUCHER:** SHOP; `voucher_ref` in `shop.vouchers`; not redacted; `cost`
  present; voucher affordability.
- **REROLL:** SHOP; `shop.reroll_cost` present; affordable.
- **LEAVE_SHOP:** SHOP; exact certificate only.
- **SELL_JOKER / SELL_CONSUMABLE:** correct existing zone (`self.jokers` /
  `self.consumables`), entity not redacted, exact per-item certificate. Eternal /
  persistent engine gates are the trusted certificate's responsibility; this
  module never grants class-level sell authority.
- **SELECT_BOOSTER_ITEM:** BOOSTER_SELECTION; `booster.choices > 0`; exactly one
  `card_refs` entry (the callback selects one at a time); card exists in
  `booster.cards`; not redacted; Joker/consumable kinds require capacity (§6).
- **SKIP_BOOSTER:** BOOSTER_SELECTION; explicit certificate only — never inferred
  from pack contents. (No separate leave-booster action is representable;
  conservative denial.)
- **USE_CONSUMABLE:** `source_ref` in own `self.consumables`, not redacted.
  - Empty `target_refs`: allowed in any self-bearing phase; in
    `CONSUMABLE_SELECTION` it additionally requires a target context whose
    normalized `consumable_target.source_ref` equals `source_ref` and whose
    resolved `min_targets == 0` (explicit valid bounds), else denied.
  - Non-empty `target_refs`: only `CONSUMABLE_SELECTION` with
    `context.target_selection == true`; explicit `min_targets`/`max_targets`
    (from `consumable_target` or `context`) with count in range; the
    observation's normalized `consumable_target.source_ref` must be present and
    **equal** to `source_ref` (the `source` display entity is not authorization);
    every target ref exists in `consumable_target.targets`.
- **SELECT_TARGETS:** CONSUMABLE_SELECTION; `target_selection == true`; explicit
  min/max; the normalized `consumable_target.source_ref` must be present (binds
  this single source context); non-empty refs, each present in
  `consumable_target.targets`, no duplicates. No generic target eligibility is
  invented.
- **REORDER_JOKERS / REORDER_HAND:** `order` must be an exact full permutation of
  the current visible zone (`self.jokers` / `self.hand`): equal length, no
  missing/duplicate/nonexistent refs, correct zone. Denied in terminal/blocked
  states by the global gates.

## 5. Affordability

`spendable = self.money + self.credit_limit` (matching `dollars - bankrupt_at`),
using the observation's signed `money` and non-negative `credit_limit`.

- BUY_ITEM, OPEN_BOOSTER, REROLL: a free action (`cost <= 0`) is allowed even
  when `spendable` is negative (actual free-purchase semantics); otherwise
  `spendable >= cost`.
- BUY_VOUCHER: `spendable >= cost` **including `cost = 0`**, so at negative
  `spendable` a zero-cost voucher is denied (the voucher predicate differs).

Missing `money`/`credit_limit` ⇒ no action.

## 6. Capacity and slot exceptions

Buying/choosing a Joker or consumable **always** requires explicit
`cert.capacity_ok == true` first. Given that:

- a visible `edition == "negative"` on the item is the certified negative-edition
  exception and needs no slot comparison, or
- otherwise the normalized slot limit from `match` (`joker_slots` /
  `consumable_slots`) must be present **and** the owned list (`self.jokers` /
  `self.consumables`) must be present with count < the limit.

A missing owned list is *unknown capacity*, not zero, so it denies normal
purchases. A missing slot limit also denies. `capacity_ok = false` or an omitted
`capacity_ok` denies even a negative-edition item. Unsupported custom shared-slot
modes are not modeled; they fail closed (omitted) rather than inventing
replacement semantics. Card-kind purchases have no Joker-slot need but still
require the exact certificate.

## 7. Validation

`validate(handle, candidate)`:

1. Export the handle; foreign/unknown handle ⇒ `actions_unknown_handle`.
2. The candidate must be a plain table (no metatable); otherwise
   `actions_bad_action`.
3. `type` must be a known action type and the key set must be exactly that
   type's allowed keys plus `id`; extra keys ⇒ `actions_bad_action`.
4. `id` must be a non-empty string; otherwise `actions_bad_id`.
5. Ref/array fields must be plain, non-sparse, duplicate-free arrays (or valid
   single refs) with the required fields present; otherwise `actions_bad_action`.
6. The recomputed canonical encoding of the content must equal `id` exactly;
   otherwise `actions_id_mismatch`.
7. The id must equal one of the **current** generated candidates (regenerated
   from the freshly exported observation); otherwise `actions_not_certified`.
   The returned value is a fresh copy built from that candidate, never the
   caller's table.

Validation therefore rejects unknown keys, metatables/functions, sparse or
duplicated arrays, foreign/absent refs (no candidate match) and wrong ids, and it
re-checks phase/resources against the current observation.

## 8. Error codes

`ok`, `actions_bad_observation`, `actions_bad_codec`, `actions_unknown_handle`,
`actions_bad_action`, `actions_unknown_type`, `actions_bad_id`,
`actions_id_mismatch`, `actions_not_certified`, `actions_too_many`. Codes are
returned as values; no raw exception is raised, and no engine function is called.

`actions_too_many` is the explicit overflow invariant: generation returns it
instead of silently truncating when more than 128 unique candidates would be
produced. It is unreachable today because the certificate catalog is itself
capped at 128 and each certificate yields at most one candidate; the test suite
pins that invariant rather than relying on truncation.

## 9. Conservative denials and unsupported semantics

Deliberately **not** implemented, and hence denied rather than guessed:

- Any blanket/class authorization; only exact certificates yield actions.
- Unknown/custom certificate types, custom shared-slot modes, custom affordability
  predicates beyond the documented `spendable` model.
- Tag purchases, booster leaving, or any action class without a certificate type;
  booster packs mixed into `shop.items` (rejected by the schema) or addressed
  through the generic `shop` zone.
- Sell legality beyond "exact certificate + correct existing, non-redacted zone";
  eternal/persistent and other per-item engine gates are the certificate's duty.
- Exhaustive enumeration or parity claims: the catalog is fixture/UI-certified
  and may be incomplete.

The real authoritative engine predicate (e.g. `can_play`/`can_buy` fresh
validation) remains the broker's and is disabled; nothing here executes.

## 10. M2 test-driven corrections

- `observation.lua` context normalization now honors explicit `false` for
  `blocked`/`timer_expired` (see `docs/AI_OBSERVATION.md` §4.9).
- `actions.lua` no longer compares `consumable_target.source.id` to the
  certificate's `source_ref`: the target-context source entity carries a
  different zone (`source:1`) than own consumables (`consumable:N`), so the
  equality was unreachable and denied every non-empty USE_CONSUMABLE.
- Replaced with an explicit normalized `consumable_target.source_ref` (owned
  `consumable` zone, validated by `observation.lua`). Targeted `USE_CONSUMABLE`
  now requires `consumable_target.source_ref == cert.source_ref`;
  `SELECT_TARGETS` requires the bound context. The `source` display entity is
  retained but is not authorization.
- `capacity_ok` now requires explicit `cert.capacity_ok == true` **before** the
  negative-edition exception, and an omitted owned list denies normal purchases
  instead of being treated as count zero (Astrafinding).
- Review-directed schema correction: deck aggregates removed (visible `total`
  only), booster packs moved to a separate `shop.boosters`/`shop_booster:N` zone
  used exclusively by `OPEN_BOOSTER`, `BUY_ITEM` restricted to non-booster kinds.
- Empty-target `USE_CONSUMABLE` in `CONSUMABLE_SELECTION` now requires the bound
  source and `min_targets == 0`.
- Generation no longer silently truncates at 128; it returns `actions_too_many`
  (unreachable under the current 128-certificate cap, asserted by tests).
- Action error codes are private internal locals; `actions.CODE` and
  `instance.CODE` are copies, so mutating an exported table cannot change
  validation.

## 11. Schema note

No schema change was required. `USE_CONSUMABLE` binds targets to its own
`source_ref` via `consumable_target.source`. `SELECT_TARGETS` has no per-cert
source field, so it binds to the single `consumable_target` context section in
the observation; if multiple simultaneous target contexts are ever needed, a
narrow `source_ref` addition to the `SELECT_TARGETS` certificate should be made
in `observation.lua` and documented there.
