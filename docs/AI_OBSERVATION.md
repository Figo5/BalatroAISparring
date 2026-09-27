# AIObservation schema (implemented, M2 part 1, corrected)

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: implementation documentation for `AISparring/ai/codec.lua` and
`AISparring/ai/observation.lua`. No extractor, reader, legal-action generator,
broker, policy or runtime capture exists yet. This document describes only the
code that has actually been written, after the part-1 review corrections.

Read with `AGENTS.md`, `docs/MILESTONE_2_PLAN.md`, `docs/FAIRNESS.md` and
`docs/M2_SOURCE_MAP.md`. The two Lua files are pure modules: no `require`, no
globals, no engine access, explicit dependency injection.

## 0. Corrections applied in this revision

1. **Blanket affordance classes removed.** `sell.offered`, `play.offered`,
   `use.offered`, etc. would have been wildcard authority and could not certify a
   specific Joker (eternal/persistent), a specific forced card subset, or a
   specific consumable target. They are replaced by a bounded, exact
   action-certificate catalog: every candidate names its own refs/order and must
   be individually `certified = true`. No class-level authorization remains.
2. **Fixed interaction context** added (`blocked`, `timer_expired`,
   `max_play`, `max_discard`, `min_targets`, `max_targets`,
   `target_selection`). Uncertain booleans deny by default.
3. **Money is signed.** `money` is a signed bounded integer; the ambiguous
   `credit_available` is replaced by `credit_limit` (non-negative allowance equal
   to `-bankrupt_at`); spendable is `money + credit_limit`, matching
   `dollars - bankrupt_at`.
4. **Visibility must be positive.** Identity is copied only when
   `face_down = false` is explicit; otherwise the entity is `redacted`. Own hand
   is copied only in the permitted phases **and** with explicit
   `hand_visible = true`.
5. **Codec hardening.** The key scan is bounded before full traversal; the sort
   comparator is explicit byte-wise; array scans are bounded early.
6. **Constants are copied outward**, so callers mutating exported `PHASES`/`CODE`
   cannot change validation internals.

Face-down redaction remains mandatory and unchanged; the corrected source map
established that the earlier research assumption permitting identity inference
was false.

## 1. Modules and trust boundary

- `ai/codec.lua` returns a stateless `Codec` table. It encodes plain Lua values
  into a canonical, locale-independent string and derives a deterministic
  diagnostic checksum. It has no dependency on the game or on observation.
- `ai/observation.lua` returns `Observation`. `Observation.factory(codec)` builds
  an instance closed over its own private handle registry. The injected `codec`
  must expose `encode` and `hash_string` functions.

The **trusted visible-frame producer** is part of the trusted computing base
(TCB): it must emit only fields the human UI shows under the effective
ruleset/layer snapshot, and must set the explicit visibility/certification flags
from real evidence. This module re-validates shape, bounds, phase, ref existence
and zone eligibility, and fails closed on anything else. It cannot detect a
malicious producer. No raw callback, engine object, `G`/`MP` reference or hidden
identifier is read from the frame. Per-engine constraints (which specific card
subsets, targets, slot exceptions or shop actions are truly legal) live only in
exact certificates produced by the trusted UI-equivalent adapter; they are never
policy data and are never a permission to expose forbidden information.

## 2. Factory and handle API

```
local Observation = dofile("AISparring/ai/observation.lua")
local Codec = dofile("AISparring/ai/codec.lua")
local obs = Observation.factory(Codec)         -- nil, "observation_bad_codec" on bad codec

local handle, code = obs.observe(frame)        -- handle is opaque; code is static on failure
local plain, code = obs.export(handle)         -- independent deep copy (primitive tables only)
local canonical, code = obs.canonical(handle)  -- stored canonical string
local hash, code = obs.hash(handle)            -- stored diagnostic checksum
local same = obs.equal(h1, h2)                 -- canonical string equality
local is_handle = obs.is_handle(value)
local schema = obs.describe()                  -- copy of phases/fields/cert types/limits/codes
```

- The handle is a sealed table (`__metatable` fixed) used only as a key in a
  module-private weak-keyed registry. The registry lookup — not any property of
  the handle table — is authoritative, so adding fields (including via `rawset`)
  cannot forge a handle or attach data.
- `export` returns newly built tables; mutating it cannot affect the stored
  canonical content, canonical string or hash, all produced once at construction.
  `canonical`/`hash` never read caller-provided tables again.
- Exported `PHASES`, `CODE`, `describe()` and per-instance constants are deep
  copies; the validation-internal tables are private locals.
- Checksums are a **diagnostic equality aid only**: not cryptographic, never an
  authorization, authentication or freshness proof. Canonical-string equality is
  the exact-equality mechanism.

## 3. Canonical encoding (`Codec`)

Type-tagged, length-prefixed, locale-independent. No `tostring(table)`, no
floating format, no NaN/infinity, no memory addresses.

| Value | Encoding |
|---|---|
| boolean false/true | `b0` / `b1` |
| integer n (int32 range) | `i` + decimal + `;` (leading `-` for negatives) |
| string s | `s` + byte-length + `:` + raw bytes + `;` |
| array of n items | `a` + n + `:` + items in index order |
| map of k entries | `o` + k + `:` + entries sorted by encoded key |

- Keys may only be strings or int32 integers (else `codec_bad_key`); encoded keys
  carry a type tag, so `1` and `"1"` cannot collide.
- A table is an array only when every key is a positive integer and the keys are
  exactly `1..n`; otherwise it is a map. Map entries are sorted by an **explicit
  byte-wise comparator** (`byte_less` over `string.byte`), not Lua's
  locale-sensitive `<`.
- Integers are limited to `-2147483648 .. 2147483647`; fractional, NaN, infinite
  and out-of-range numbers fail (`codec_bad_number`). Decimal conversion is a
  manual divmod-10 loop.
- The initial key scan is **bounded early**: once more than `MAX_MAP` keys are
  seen the encode fails `codec_too_large` without reading their values. Array
  iteration is bounded by `MAX_ARRAY` before elements are encoded.
- Tables with metatables are rejected (`codec_bad_type`) without invoking any
  metamethod; cycles are rejected (`codec_cycle`).
- Bounds: depth 16, array 256, map 256, string 4096, nodes 8192, canonical string
  262144.
- `Codec.hash_string` is FNV-1a 32-bit using only exactly-representable double
  arithmetic (`mulmod32` splits operands), giving 8 lowercase hex digits and
  identical output on Lua 5.1 and LuaJIT.

## 4. Frame shape

`obs.observe(frame)` expects a plain (metatable-free) table:

```
frame = {
  schema_version = 1,
  phase = "<PHASE>",
  match = { ... },            -- required every phase
  self = { ... },             -- required except MATCH_COMPLETE
  opponent = { ... },         -- optional, only if certified
  shop = { ... },             -- SHOP only
  booster = { ... },          -- BOOSTER_SELECTION only
  consumable_target = { ... },-- CONSUMABLE_SELECTION only
  context = { ... },          -- interaction context (deny-by-default)
  certificates = { ... },     -- exact action certificates
}
```

Unknown keys at any level are ignored and never traversed. Sections not
permitted for the phase are ignored without traversal even if present. Raw
stale/future data (old hand in SHOP/BLIND_SELECTION, future shop/pack, deck
order) is not representable.

### 4.1 Phases

`BLIND_SELECTION`, `PLAY_HAND`, `DISCARD`, `SHOP`, `BOOSTER_SELECTION`,
`CONSUMABLE_SELECTION`, `MULTIPLAYER_PVP`, `MATCH_COMPLETE`.

| Phase | self | opponent | shop | booster | consumable_target | hand | context | certificates |
|---|---|---|---|---|---|---|---|---|
| BLIND_SELECTION | yes | yes | – | – | – | no | yes | yes |
| PLAY_HAND | yes | yes | – | – | – | yes* | yes | yes |
| DISCARD | yes | yes | – | – | – | yes* | yes | yes |
| SHOP | yes | yes | yes | – | – | no | yes | yes |
| BOOSTER_SELECTION | yes | yes | – | yes | – | yes* | yes | yes |
| CONSUMABLE_SELECTION | yes | yes | – | – | yes | yes* | yes | yes |
| MULTIPLAYER_PVP | yes | yes | – | – | – | yes* | yes | yes |
| MATCH_COMPLETE | no | no | – | – | – | no | no | no |

`*` hand is copied only when `self.hand_visible = true` is also present; the
reader will later set this flag from visibility evidence. `MATCH_COMPLETE`
exposes only `schema_version` + `phase` + `match`.

### 4.2 `match` (required)

`ruleset` (token, required), `blind` (display string), `timer` (display string,
may contain `>>`), `ante`, `round`, `lives`, `hands_per_round`,
`discards_per_round`, `hand_size`, `joker_slots`, `consumable_slots` (integers
`>= 0`). Fixed normalized rules fields supplied by the trusted producer.

### 4.3 `self`

| Field | Type |
|---|---|
| `money` | **signed** int (`-2147483648 .. 2147483647`); negative is legal |
| `credit_limit` | int `>= 0`; allowance equal to `-bankrupt_at` (was `credit_available`) |
| `hands` | int `>= 0` |
| `discards` | int `>= 0` |
| `current_score` | displayed string (display charset, <= 32) |
| `blind_requirement` | displayed string (display charset, <= 32) |
| `hand_visible` | bool; explicit visibility certificate for the hand |
| `hand` | ordered `card` array, only when phase permits **and** `hand_visible = true` |
| `jokers` | ordered `joker` array |
| `consumables` | ordered `consumable` array |
| `vouchers` | ordered `voucher` array |
| `tags` | ordered `tag` array |
| `deck` | aggregate, see below |

Spendable money is `money + credit_limit` (matching `dollars - bankrupt_at`);
it is deliberately not duplicated in the schema, as the sum can exceed int32 and
the generator computes it from the two bounded fields. Arrays are ordered as
displayed; ids are `zone:ordinal`. Sparse/ambiguous arrays are rejected.

`deck` carries **only the displayed `total` count**. `by_suit`, `by_rank` and any
ordered/ranked map are deliberately **unsupported in M2**: the UI preview counts
face-down (`wheel_flipped`) cards as unknown, so a rank/suit aggregate cannot be
populated without leaking hidden face-down identity. Such input keys are ignored
without traversal. A future certified deck-preview-equivalent spec (with an
explicit `unknown` bucket and the `wheel_flipped` rule) may add aggregates; until
then they are not representable.

### 4.4 `opponent` (opt-in)

Dropped unless `certified = true`. Permitted displayed fields: `displayed_score`
(display string), `hands` (int), `lives` (int), `location` (display string),
`timer` (display string). Nothing else is read; raw `real_score`, `last_timer`,
`pvpTimerOrder` or wire payloads are not representable.

### 4.5 `shop` (SHOP only)

`reroll_cost` (int), `items` (array of `shop_item`, <= 16), `vouchers` (array of
`voucher`, <= 16), `boosters` (array of `shop_item` with `kind = "booster"`,
<= 16, zone `shop_booster`).

Booster packs are a **separate dense array** (`shop.boosters`), matching the
engine's separate pack area. A `shop.items` entry with `kind = "booster"` is
rejected (`observation_invalid_entity`); packs must not be mixed into `items`.
`OPEN_BOOSTER` uses `item_ref` in the `shop_booster` zone exclusively and never
the generic `shop` zone.

### 4.6 `booster` (BOOSTER_SELECTION only)

`kind` (token, e.g. pack kind), `choices` (int), `skips` (int), `cards` (array of
`card`, <= 16). Face-down pack cards are redacted like any other face-down card.

### 4.7 `consumable_target` (CONSUMABLE_SELECTION only)

`source` (single `consumable` entity, required), `source_ref` (optional ref
string in the **owned `consumable` zone**, validated to exist in this
observation), `targets` (array of `card`, <= 16), `min_targets`/`max_targets`
(ints, `min <= max` when both present).

`source_ref` is the authorization binding for targeted consumable use: it names
the owned `self.consumables` entity the target context belongs to. The `source`
display record remains a `source:ordinal` entity and is **not** an authorization
identity. A targeted `USE_CONSUMABLE` certificate is only accepted when its
`source_ref` equals this normalized `source_ref`; `SELECT_TARGETS` binds to this
single context.

### 4.8 Entities

Entity fields are a fixed per-kind allowlist. Identity is derived from the
**visible zone ordinal only**: `id = zone .. ":" .. ordinal`. No input `id`,
engine id or `sort_ID` is ever read; unknown keys are ignored without traversal.

| Kind | Zones | Allowed fields |
|---|---|---|
| `card` | `hand`, `booster`, `target` | `kind`, `rank`, `suit`, `center`, `edition`, `seal`, `debuff`, `face_down` |
| `joker` | `joker` | `center`, `edition`, `seal`, `debuff`, `visible_text` |
| `consumable` | `consumable`, `source` | `center`, `edition`, `debuff`, `visible_text` |
| `shop_item` | `shop`, `shop_booster` | `kind`, `rank`, `suit`, `center`, `edition`, `seal`, `debuff`, `cost`, `sell_cost` |
| `voucher` | `shop_voucher` | `center`, `cost` |
| `tag` | `tag` | `center` |

- `kind`, `rank`, `suit`, `center`, `edition`, `seal` are bounded public token
  strings; `cost`/`sell_cost` are ints `>= 0`; `debuff`/`face_down` are bools.
  `visible_text` is bounded plain UI text (printable ASCII, <= 128 bytes), never
  an ability/config table.
- No `ability`, arbitrary config, counter, callback or nested engine table is
  representable.
- **Face-down / visibility:** identity fields are copied only when
  `face_down = false` is explicitly present. If `face_down` is `true`, absent, or
  non-boolean-typed (the latter rejected), the entity is emitted as
  `{ id, redacted = true }` with no identity fields, regardless of any poisoned
  properties supplied alongside. Missing visibility evidence never implies
  identity is visible.
- Duplicate observation-local ids are rejected. Since ids are ordinal-derived,
  duplicates indicate internal inconsistency/injection.

### 4.9 `context` (fixed interaction context)

Normalized from the trusted UI-equivalent adapter. Unknown keys are ignored.

| Field | Type / default |
|---|---|
| `blocked` | bool; default **true** (deny) — only explicit `false` clears it |
| `timer_expired` | bool; default **true** (deny) — only explicit `false` clears it |
| `target_selection` | bool; default **false** |
| `max_play` | int `>= 0`, optional |
| `max_discard` | int `>= 0`, optional |
| `min_targets`, `max_targets` | int `>= 0`, optional; `min <= max` enforced |

All uncertain booleans deny by default. If the whole section is absent, the
defaults above are materialized.

> **M2 test-driven fix:** the normalization previously used the
> `(b == false) and false or true` idiom, which evaluates to `true` even when
> `b` is explicitly `false`. It now uses `b ~= false`, so `blocked = false` /
> `timer_expired = false` are honored and only omitted/other values deny. This
> was caught by `tests/m2/test_actions.lua` (generation was always empty).

### 4.10 `certificates` (exact action catalog)

```
certificates = {
  version = 1,
  items = { { type = "PLAY_CARDS", certified = true, card_refs = { "hand:1", "hand:2" } }, ... },
}
```

- `items` is bounded to **128** entries. An unknown action `type` or a
  non-boolean `certified` is rejected (`observation_invalid_certificate`). Unknown
  certificate fields are **ignored without traversal** (the safer choice) and a
  `certified = false` entry is simply withheld (no action), never stored.
- Every certificate carries an exact `type` and, as appropriate, source/ref/card
  refs/target refs/order, plus optional `capacity_ok` for item-specific slot
  exceptions. **No certificate authorizes a class of actions**; there is no
  `offered` wildcard, no callbacks and no engine predicate.
- **Missing exact certification means no generated action.** The catalog may be
  incomplete by design: it is a safe subset of certified candidates, not an
  assertion of exhaustiveness. The future generator independently revalidates
  phase, resources, slots and limits, then enumerates/filters these exact
  certificates; it never invents authority from a class flag.
- All refs must exist in `state.refs` (entities present in this observation) and
  carry the eligible zone prefix. Refs are never exposed as hidden identifiers:
  they are the observation-local `zone:ordinal` strings defined in §4.8.

| Type | Required refs / arrays | Optional |
|---|---|---|
| `SELECT_BLIND`, `SKIP_BLIND` | – | – |
| `PLAY_CARDS` | `card_refs` (hand, non-empty) | – |
| `DISCARD_CARDS` | `card_refs` (hand, non-empty) | – |
| `BUY_ITEM` | `item_ref` (shop) | `capacity_ok` |
| `SELL_JOKER` | `joker_ref` (joker) | – |
| `SELL_CONSUMABLE` | `consumable_ref` (consumable) | – |
| `REROLL` | – | – |
| `BUY_VOUCHER` | `voucher_ref` (shop_voucher) | – |
| `OPEN_BOOSTER` | `item_ref` (shop_booster) | `capacity_ok` |
| `LEAVE_SHOP` | – | – |
| `SELECT_BOOSTER_ITEM` | `card_refs` (booster, non-empty) | `capacity_ok` |
| `SKIP_BOOSTER` | – | – |
| `USE_CONSUMABLE` | `source_ref` (consumable), `target_refs` (target, may be empty) | – |
| `SELECT_TARGETS` | `target_refs` (target, non-empty) | – |
| `REORDER_JOKERS` | `order` (joker, non-empty) | – |
| `REORDER_HAND` | `order` (hand, non-empty) | – |

- `card_refs`/`target_refs`/`order` are bounded arrays (<= 64) with **no
  duplicate refs within one selection** (`observation_duplicate_ref`). A
  ref of the wrong zone or not present fails `observation_invalid_target_ref`.
- Whether an `order` is complete/valid or an item is affordable is a
  generator/broker concern; the schema only carries the exact certified
  candidate. `BUY_ITEM` accepts only `card`/`joker`/`consumable` kinds;
  `OPEN_BOOSTER` is the only path to a pack and reads `shop.boosters`.

## 5. Validation rules and failure codes

- Input tables must be plain (`getmetatable(value) == nil`); metatable-bearing
  tables are rejected at the accessed boundary and metamethods are never
  invoked. `getmetatable` itself invokes nothing.
- All reads use `rawget`/`next` on already-plain tables; unknown fields are never
  read.
- Integers must be integral and in int32 bounds (signed for `money`, otherwise
  non-negative); displayed scores/timers are strings; no seeds, no RNG, no hidden
  ids.
- Bounds: hand/jokers/consumables 64, vouchers/tags/shop/shop_booster/booster/
  targets 16, certificate items 128, ref arrays 64, absolute array scan 256,
  token 64, display 32, visible text 128, ref 64.

Static codes: `ok`, `observation_bad_codec`, `observation_bad_frame`,
`observation_unknown_phase`, `observation_bad_version`,
`observation_missing_match`, `observation_missing_self`,
`observation_invalid_field`, `observation_invalid_entity`,
`observation_sparse_array`, `observation_too_large`,
`observation_duplicate_ref`, `observation_invalid_target_ref`,
`observation_invalid_certificate`, `observation_invalid_context`,
`observation_encode_failed`, `observation_unknown_handle`. Failures are returned
as codes; no raw exception is raised.

## 6. Deliberate exclusions

- All seeds/seed identifiers; engine ids, `sort_ID`, memory addresses, and any
  producer-supplied `id`.
- Face-down identity on any non-explicitly-visible card, regardless of poisoned
  fields.
- Ordered deck contents and `by_suit`/`by_rank` deck aggregates (unsupported
  until a UI-preview-equivalent spec with an `unknown` bucket exists), future
  shop/booster/pack contents, and stale hand data outside the permitted phases.
- Booster packs inside `shop.items` (they belong in the separate `shop.boosters`
  zone).
- Raw opponent fields (`real_score`, `last_timer`, inactive `pvpTimerOrder`,
  hidden location, wire/deck/Joker dumps).
- Functions, userdata, metatables, aliases, cycles, arbitrary ability/config
  tables, floating/NaN/infinite numbers.
- End-game private dumps in `MATCH_COMPLETE`.

## 7. Not implemented here

Handling of the certificate catalog (generator/enumeration), reader/consumer
helpers, the broker and revision tokens, trusted UI affordance adapters, the
restricted policy environment, and any real capture are out of scope and
unimplemented. Checksums grant no authority.
