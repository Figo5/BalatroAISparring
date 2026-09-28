# Engine adapter and production executor (`AISparring/integration`)

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: bounded implementation of `PLAYABLE_PLAN.md` chunk 2, **fixture-verified only**.
No live game capture, no game launch, no Mods write, no Git operation, no policy.
This is not a playability claim; the remaining wiring is listed in §9.

This revision implements the `docs/CLAUDE_ENGINE_REVIEW.md` repairs
(C1, C2, H1-H5, M1-M3, L1-L5). Each fix is source-derived from
`work/reference/game/*` (vanilla 1.0.1o) and `work/reference/smods-booster.toml` /
`work/reference/mp/*`; no predicate is faked and no new rule is approximated.

Owned by this chunk:

- `AISparring/integration/state_revision.lua` — trusted monotonic decision revision.
- `AISparring/integration/engine_adapter.lua` — trusted visible-view/certificate producer.
- `AISparring/integration/production_executor.lua` — authoritative legality + committed callbacks.
- `tests/run_engine.py` + `tests/engine/*` — static + Lua 5.1 / LuaJIT fixtures.
- this document.

It does **not** modify the accepted M2 modules (`ai/*`, `state_reader.lua`,
`action_broker.lua`), the mod bootstrap, or any live file.

## 1. Contract and data flow

```
engine (G/MP)                     ┌─ state_revision (monotonic epoch)
   │  rawget-only, fixed paths    │
   ▼                              ▼
engine_adapter.step() ── runtime + ui_view ──► state_reader.capture() ──► AIObservation handle
   │                                                                          │
   └─ control (cash_out)                                                      ▼
                                                               ai/actions.generate() candidates
                                                                              │
action_broker.issue()/submit() ── ports.{capture,validate,dispatch} ──► production_executor
                                                                              │
                                                       real G.FUNCS callbacks (committed commit)
```

- The **adapter** is a pure producer: it never calls an engine/UI callback, never
  mutates, and reads only a fixed `rawget` allowlist plus the two *pure, read-only*
  card predicates `Card:can_sell_card` and `Card:can_use_consumeable` (which read
  the live engine but never repaint UI or show alerts). Its correctness claim is
  "the values it attests are the ones the HUD would show in this phase".
- The **executor** is the only module that commits. It re-derives everything from
  the live engine, re-checks the revision immediately before the callback, and
  calls the *normal* Balatro/MP callback.
- The **revision** is a per-session, strictly increasing int32. `sync(fingerprint)`
  advances only on an observed decision-state change; `bump(reason)` is the forced
  trusted-hook path. Unobserved A→B→A remains a TCB limitation (documented in
  `STATE_READER.md` §3.1 and `M2_EXECUTION_BOUNDARY.md` §1.4), not something this
  module claims to detect.

All three modules are globals-free: no `require`/`dofile`, no `io`/`os`/`debug`,
no RNG, no `SMODS`/`Client`/`love`/`NFS`. The engine is reached only through the
injected ports.

## 2. Phases, enums and trusted non-policy control

`G.STATES` is resolved **by symbol name** at runtime; no numeric constant is
trusted. `SMODS_BOOSTER_OPENED` is accepted whatever value the loaded mod assigns.

| `G.STATES` symbol(s) | adapter phase | M2 observation phase |
|---|---|---|
| `BLIND_SELECT` | blind selection | `BLIND_SELECTION` |
| `SELECTING_HAND` (non-PvP) | hand selection | `PLAY_HAND` |
| `SELECTING_HAND` (`blind.pvp` truthy or `bl_mp_nemesis`) | PvP | `MULTIPLAYER_PVP` |
| `SELECTING_HAND` + active target context (injected) | target | `CONSUMABLE_SELECTION` |
| `SHOP` | shop | `SHOP` |
| `TAROT_PACK`/`SPECTRAL_PACK`/`PLANET_PACK`/`STANDARD_PACK`/`BUFFOON_PACK`/`SMODS_BOOSTER_OPENED` | pack | `BOOSTER_SELECTION` |
| `GAME_OVER` | terminal | `MATCH_COMPLETE` |
| `ROUND_EVAL` | **no M2 phase** | control `cash_out` |
| `BLIND_SELECT` + PvP blind on deck | blind selection | `BLIND_SELECTION` (policy `SELECT_BLIND`) |
| anything else | refused `engine_unsupported_state` | — |

`DISCARD` is a synonym of `PLAY_HAND` for the M2 phases (both are compatible with
engine `SELECTING_HAND`); the adapter emits `PLAY_HAND` and supplies both
`PLAY_CARDS` and `DISCARD_CARDS` certificates in that phase.

**UI progression (control).** The only non-policy control is `cash_out` for
`ROUND_EVAL`; the executor performs it through the real cash-out button
(`element_for("cash_out")`), never a fabricated empty context (`G.FUNCS.cash_out`
reads `e.config.button`).

**PvP readiness is a policy action, not a control.** When the on-deck blind is the
Multiplayer PvP blind (`round_resets.blind_choices[blind_on_deck] ==
"bl_mp_nemesis"`, or a `pvp_blind_choices` entry) the adapter emits the normal
`BLIND_SELECTION` view with a `SELECT_BLIND` certificate. The executor maps that
policy choice to the real ready button: `G.FUNCS.mp_toggle_ready(e)` with the
real element (the injected `element_for("pvp_ready")` when it yields one, or the
source-backed `G.blind_select_opts[string.lower(blind_on_deck)]:get_UIE_by_ID
("select_blind_button")` fallback whose `config.ref_table` is the blind config,
`mp/ui/game/blind_choice.lua:210-228`). It never calls `select_blind` directly for
a PvP blind: `mp_toggle_ready` retains the context and the server's `startBlind`
later invokes `G.FUNCS.select_blind(MP.GAME.next_blind_context)`
(`ui/game/functions.lua`, `networking/action_handlers.lua`).

- While `MP.GAME.ready_blind == true` (already ready, waiting for the human/server)
  the adapter emits **no** blind action at all (H4a) and the executor refuses a
  `SELECT_BLIND` (`exec_illegal`); the empty catalogue makes the decision loop back
  off and wait instead of selecting an action that would be refused three times.
- `SKIP_BLIND` is only emitted for the Small/Big blinds (H4b). Vanilla mounts a
  skip button — and a `tag_container` — only there; the boss blind's state is also
  `Select`, but `G.FUNCS.skip_blind` guards on `_tag` (`button_callbacks.lua:2754`)
  and a boss skip has no effect (the MP wrapper would still count it,
  `mp/ui/game/functions.lua:82-107`). The executor likewise only validates a
  Small/Big skip, and requires the `skip_blind` element to resolve.

## 3. Exact zone mappings

Entity refs are observation-local `zone:ordinal` strings. The producer binds
whole zones **positionally** (`record i ↔ engine ordinal i`) and subset zones by
explicit `ordinal`, exactly matching `state_reader.lua` §6. The executor reverses
the same mapping.

| view section | engine area | zone token | kind |
|---|---|---|---|
| `self.cards.hand` | `G.hand.cards` | `hand` | `card` |
| `self.cards.joker` | `G.jokers.cards` | `joker` | `joker` |
| `self.cards.consumable` | `G.consumeables.cards` | `consumable` | `consumable` |
| `shop.items` | `G.shop_jokers.cards` | `shop` | `card`/`joker`/`consumable` |
| `shop.boosters` | `G.shop_booster.cards` | `shop_booster` | `booster` |
| `shop.vouchers` | `G.shop_vouchers.cards` | `shop_voucher` | `voucher` |
| `booster.cards` | `G.pack_cards.cards` | `booster` | `card`/`joker`/`consumable` |
| `consumable_target.source` | `G.consumeables.cards[source.ordinal]` | `source` | `consumable` |
| `consumable_target.targets` | `G.hand.cards[p]` | `target` | `card` |

A `booster`-kind record inside `shop.items` fails the whole capture
(`engine_build_failed`) rather than being silently mixed in. Target records carry
one entry per hand position, so `target:p` always names engine hand ordinal `p`
(no aliasing); the reader additionally refuses duplicate ordinals.

Kind is derived from the engine ability set: `set == "Joker"` → `joker`,
truthy `ability.consumeable` (vanilla assigns the `center.config` table, so it is
**not** `== true`) → `consumable`, `set == "Booster"` → `booster`, else `card`.
`opened pack` contents only exist after `Card:open()`, so the adapter never
invents future pack/shop contents.

Face-down identity is redacted: a card is emitted with identity only when the raw
`facing == "front"` **and** `sprite_facing == "front"`; otherwise it is emitted as
`{face_down=true}` and the reader records `redacted=true`. Stone/`no_rank`/`no_suit`
base replacement is applied by the reader on top of the producer's attestation.
Candidate grouping mirrors this: only a face-up, unmasked card contributes a
rank/suit group, so hidden or Stone identity cannot change the catalogue (H2).

Opponent hands follow the exact rendered visibility: the adapter projects
`enemy.hands` only when the engine's `hands_text` string is the matching decimal
(`"3"` for 3), so the `"???"` mask (no `enemyInfo` yet) never leaks the raw
numeric field. Score/lives/location keep their existing reader gates.

## 4. Certificate generation (bounded, non-exhaustive)

The adapter builds the exact `certificates` catalog consumed by `ai/actions.lua`.
It uses non-effectful raw gates and the two **pure, read-only** engine card
predicates `Card:can_sell_card` and `Card:can_use_consumeable` (which only read the
live engine and never repaint UI or raise alerts). The **mutating** `G.FUNCS.can_*`
callbacks (`can_play`, `can_buy`, `can_discard`, `can_select_card`,
`can_skip_booster`, `check_for_buy_space`, …) are never called by the producer, not
even for one hypothetical candidate. Using the same predicates the executor uses is
what stops the adapter offering an action the executor would refuse (H4c).

| certificate | gate used by the producer (UI legitimacy) |
|---|---|
| `SELECT_BLIND` | `G.blind_select` present, and not (PvP blind on deck **and** `MP.GAME.ready_blind == true`) (H4a) |
| `SKIP_BLIND` | `blind_on_deck` is `Small`/`Big` and `round_resets.blind_states[blind_on_deck] == "Select"` (no boss skip, H4b) |
| `PLAY_CARDS` | `#hand ≥ 1`, `hands_left > 0`, `blind.block_play` falsy, `STOP_USE == 0`, controller unlocked, `G.play` empty |
| `DISCARD_CARDS` | same gates + `discards_left > 0` |
| `SELL_JOKER` | face-up and `Card:can_sell_card() == true` (area type `joker`, not eternal, tutorial/seed/ante clause — L4) |
| `SELL_CONSUMABLE` | same predicate on the `consumeables` area: vanilla `G.consumeables` is created with `config.type = 'joker'` (`game.lua:2239`) so `Card:can_sell_card` accepts consumables |
| `USE_CONSUMABLE` (empty target) | consumeable visible, no `ability.consumeable.max_highlighted`, and `Card:can_use_consumeable() == true` (mirrors Ankh's `check_use` too, H4c/H5) |
| `BUY_ITEM` | shop item kind `card`/`joker`/`consumable`, cost affordable, slot room for joker/consumable (`capacity_ok`) |
| `OPEN_BOOSTER` | item in `shop_booster`, kind `booster`, cost affordable |
| `BUY_VOUCHER` | `spendable >= cost` (including `cost = 0`) |
| `REROLL` | `reroll_cost == 0` or `spendable >= reroll_cost` |
| `LEAVE_SHOP` | phase `SHOP` |
| `SELECT_BOOSTER_ITEM` | pack present, `pack_choices > 0`, one ref; joker needs free slot room unless negative edition (L3); consumable requires `Card:can_use_consumeable() == true`, never a free slot (C1) |
| `SKIP_BOOSTER` | under `SMODS_BOOSTER_OPENED` the state alone is authoritative (H1, see below); otherwise pack first card present and (planet/standard/buffoon pack or hand non-empty or hand limit ≤ 0) |
| `REORDER_JOKERS` / `REORDER_HAND` | ≥ 2 visible cards in the area and no pinned card; reverse order plus each single adjacent swap (bounded, never a no-op) |
| `SELECT_TARGETS` | active target context (injected port only) |

Consumables in a pack are USED on selection, not stored, so their gate is
`Card:can_use_consumeable` (`button_callbacks.lua:2102`), never a free consumable
slot (C1). Without it, choosing Talisman/Deja Vu/Trance/Medium/Aura/Cryptid with
nothing highlighted crashes inside the queued event, and Judgement/Soul/Wraith can
over-fill the joker slots.

Under SMODS every mod booster is opened in the `SMODS_BOOSTER_OPENED` state and
SMODS extends `can_skip_booster` to that state (`smods-booster.toml:34-37`,
`124-126`). The opener (`SMODS.OPENED_BOOSTER`, which the adapter must not read)
owns the pack contents, so the state itself is the authoritative skip signal even
while `G.pack_cards` is (re)materializing; the vanilla pack states keep the
`G.pack_cards.cards[1]` guard (H1). A Buffoon/Celestial/Standard pack therefore
always offers an escape (H1) instead of leaving the AI with no legal action.

**Bounded, deterministic and structured.** The play/discard catalogue is built
from raw, non-effectful card fields only, in priority order: visible rank groups
(pairs/triples/quads) → two pair and full house → five-card straights over visible
ranks (Ace high and low) → five-card flushes → contiguous 3..`max_play` windows →
singletons → lexicographic pairs → contiguous 2-card windows. Each type has its
own cap, so the 28 lexicographic pairs of an 8-card hand can never starve the
3-5 card hands (M1). The whole catalogue is capped at `selection = 40` per action
type and `certificates = 120` overall, with reorders appended last so they never
starve the play/discard/shop catalogue. Rank/suit identity is taken only from
**face-up, unmasked** cards: a face-down or Stone/`replace_base_card`/`no_rank`/
`no_suit` card may still be selected positionally but never forms a rank or suit
group, so hidden identities cannot leak or change the policy-visible catalogue
(H2). The catalog is intentionally **non-exhaustive**; `ai/actions.lua` is the
authority on membership and the executor is the authority on legality.

## 5. Executor: committed callbacks and critical legality

`production_executor.factory` requires the exact injected role `ai_staged`, a
bounded session token, the adapter, the reader, the revision and live `G`/`MP`.

| action | committed callback | target resolution |
|---|---|---|
| `SELECT_BLIND` | `G.FUNCS.select_blind`, or `G.FUNCS.mp_toggle_ready` when a PvP blind is on deck | non-PvP: `G.P_BLINDS[round_resets.blind_choices[blind_on_deck]]` as `e.config.ref_table`; PvP: the PvP ready element (below), absent ⇒ `exec_element_missing`, and refused once `MP.GAME.ready_blind == true` |
| `SKIP_BLIND` | `G.FUNCS.skip_blind` | the `skip_blind` element (below); absent ⇒ `exec_element_missing`; only Small/Big (H4b) |
| `SKIP_BOOSTER` | `G.FUNCS.skip_booster` | optional `element_for("skip_booster")` (the callback ignores it) |
| `PLAY_CARDS` | `G.FUNCS.play_cards_from_highlighted` | highlight `hand:N` first (no callback arg) |
| `DISCARD_CARDS` | `G.FUNCS.discard_cards_from_highlighted` | highlight `hand:N` first |
| `BUY_ITEM` | `G.FUNCS.buy_from_shop` | `e.config.ref_table = shop card` |
| `SELL_JOKER` / `SELL_CONSUMABLE` | `G.FUNCS.sell_card` | `e.config.ref_table = joker` / `= consumable` |
| `REROLL` | `G.FUNCS.reroll_shop` | — |
| `BUY_VOUCHER` / `OPEN_BOOSTER` / `SELECT_BOOSTER_ITEM` | `G.FUNCS.use_card` | `e.config.ref_table`; the source must leave its area synchronously (below) |
| `LEAVE_SHOP` | `G.FUNCS.toggle_shop` | — |
| `USE_CONSUMABLE` | `G.FUNCS.use_card` | highlight `target:N` first, re-check `can_use_consumeable`, then `e.config.ref_table = consumable` |
| `SELECT_TARGETS` | none | sets the hand highlight only |
| `REORDER_JOKERS` / `REORDER_HAND` | none (the engine has no discrete reorder callback) | permutes the target `CardArea.cards` to the validated permutation, then `CardArea:set_ranks()` / `CardArea:align_cards()` via normal metatable lookup |
| cash out | `G.FUNCS.cash_out` | the cash-out element (below) (`advance_ui()`) |

**Trusted UI-element resolution (C2).** The executor prefers the injected
`element_for(name)` port but accepts only a real (non-nil table) result; the
production companion currently passes a default nil-returning function, so it falls
back to deriving the exact element from the injected `G` itself:

- `cash_out` → `G.round_eval:get_UIE_by_ID('cash_out_button')`
  (`common_events.lua:1071`). The real button must exist: `G.FUNCS.cash_out` reads
  the round tally (`G.GAME.current_round.dollars`,
  `button_callbacks.lua:2938`) as well as clearing `e.config.button`, so the
  executor never fabricates a minimal element — cash-out waits for the tally UI
  (absent ⇒ `exec_element_missing`);
- `skip_blind` → `{ UIBox = G.blind_select_opts[string.lower(blind_on_deck)] }`
  (the blind-choice UIBox that mounts `tag_container`, `button_callbacks.lua:2754`);
- `pvp_ready` → `G.blind_select_opts[string.lower(blind_on_deck)]:get_UIE_by_ID
  ("select_blind_button")` (whose `config.ref_table` is the blind config,
  `mp/ui/game/blind_choice.lua:210-228`).

Nothing beyond what the callback actually reads is fabricated.

`invoke` treats an explicit `false` returned by a callback as an engine rejection
(`exec_callback_failed`); only a `pcall`-clean, non-`false` return counts as a
committed success.

**Synchronous use-card commits (H5).** `G.FUNCS.use_card` removes the source from
its area synchronously (`button_callbacks.lua:2209`) and can early-return without
removing it when `Card:check_use` rejects (Ankh with full joker slots,
`card.lua:1581-1588`; `button_callbacks.lua:2163-2169`). For the use-card actions
(`USE_CONSUMABLE`, `SELECT_BOOSTER_ITEM`, `OPEN_BOOSTER`, `BUY_VOUCHER`) the
executor checks immediately after the callback that the anchored source left its
area; if it did not, the commit is a no-op and returns `exec_callback_failed`
with **no latch**, so the bounded stall timer can never fire on it. Validation also
mirrors the Ankh `check_use` and refuses the action up front.

**Forced selection (H3).** When a blind forces a card into the hand
(`ability.forced_selection`, e.g. Cerulean Bell), `CardArea:remove_from_highlighted`
ignores a non-forced removal (`cardarea.lua:187-188`). The executor therefore
clears the highlight **without** the force flag, requires every forced card to be
part of the requested selection (`exec_illegal` otherwise), and after adding
verifies that the actual highlighted set equals the requested set exactly — an add
silently dropped at the highlight limit (`cardarea.lua:149-150`) fails the commit
with `exec_callback_failed` before the callback runs. This keeps the forced rule
intact instead of bypassing it and clearing the flag.

**Deferred-action pending latch.** A committed callback is not always immediately
visible: vanilla `buy_from_shop` queues the actual remove/payment behind a ~0.1s
UI event and initially leaves the item and resources unchanged. After any
committed effectful action (`BUY_ITEM`, `REROLL`, `USE_CONSUMABLE`, sells,
plays/discards, blind/shop transitions, `cash_out`) the executor holds a
**pending latch**. While it is held, a fresh `capture`/`validate`/`dispatch`
returns `exec_pending` and no second commit can occur, so the same queued purchase
cannot be committed twice.

- Completion is **action-specific and anchored to the exact dispatched target**
  (engine table identity + expected area + phase), captured before the callback.
  A generic canonical/epoch change is **not** a release signal: an unrelated
  opponent lives/score update, own money income, or a `revision.bump` from another
  hook all change the fingerprint but do not complete the action.
  - purchases/sales/`USE_CONSUMABLE`: the anchored card must leave its expected
    area (`shop_jokers`/`jokers`/`consumeables`/`shop_vouchers`/`shop_booster`/
    `pack_cards`), or the phase must move on. Because a use-card removal is
    synchronous, such a latch completes on the very next gate;
  - `PLAY_CARDS`/`DISCARD_CARDS`: the selected hand cards must leave `G.hand`, or
    the phase must move on;
  - `SELECT_BLIND`: `MP.GAME.ready_blind == true` (PvP) or a phase change;
  - `SKIP_BLIND`: phase change or `blind_on_deck` change;
  - `SKIP_BOOSTER`/`LEAVE_SHOP`/`CASH_OUT`: a real phase transition;
  - `REROLL`: an actual shop-content generation change (shop card identities) or
    the anchored `reroll_cost` change — money alone is never enough.
  Money/canonical alone never completes an action.
- The window is bounded by an **injected monotonic clock** (`clock` port: a
  `{ now() }` table or a bare function) and `stall_timeout` (default 10.0s — a
  defensible ceiling long enough not to reject a legitimate consumable/card
  animation but short enough to bound a stuck commit). On
  expiry the latch does **not** release back to a usable executor (that would let
  the stale queued action be retried and duplicated): it latches a terminal fault
  (`exec_stall_timeout`). Every later `capture`/`validate`/`dispatch` keeps
  returning the fault until the trusted bootstrap calls `cancel()` (session reset)
  or `revoke()`. Without an injected clock there is no timeout and only a proven
  completion releases. The executor never sleeps and never touches the engine's
  MP timers.
- Same-state pure actions are exempt: `SELECT_TARGETS` (highlight only) and
  `REORDER_*` (synchronous permutation) never latch, so a legitimate reorder is not
  blocked indefinitely.
- A callback that returns `false` (or throws, or leaves a use-card source in
  place) sets no latch — a rejected/no-op commit leaves the executor free.

**API consumed by the runtime coordinator** (same shape as the broker lifecycle):
`instance.pending_status()` (also `broker_ports().pending`) returns `nil` when
free, `exec_pending` while a commit is in flight, `exec_stall_timeout` when the
latch is terminally faulted, or `exec_revoked` after revocation.
`instance.cancel()` (also `broker_ports().cancel`) clears a pending latch and a
stall fault — the trusted session reset — and `instance.revoke()` (also
`broker_ports().revoke`) clears both and permanently refuses further action
(`exec_revoked`).

`validate` performs the authoritative fresh check with non-effectful gates and,
only on the committed target, the *pure* engine predicates `Card:can_sell_card`
and `Card:can_use_consumeable`. The mutating UI predicates (`can_play`,
`can_buy`, `can_discard`, `can_open`, `can_reroll`, `check_for_buy_space`, …) are
**never** invoked — `check_for_buy_space` shows an alert, so the executor
replicates its raw slot arithmetic instead.

**Every committed action re-checks `gates_clear` (M2).** Buy, open-booster,
voucher, reroll, leave-shop, blind, skip and booster-select all validate
`STOP_USE == 0`, an unlocked controller and an empty `G.play` for themselves,
rather than relying on the blocked view having offered no actions. Targeted
consumables (`CONSUMABLE_SELECTION`) are implemented legally (M3): `validate`
resolves the targets and checks the raw highlight bounds
(`min_highlighted`/`mod_num`), and `dispatch` applies the highlights and only then
re-checks the real `Card:can_use_consumeable` before invoking `use_card` — the
predicate's highlight clause cannot be evaluated before the highlights exist.

Reorders (L1) reject any area containing a pinned card (the engine's
`CardArea:align_cards` forcibly re-sorts pinned jokers, `cardarea.lua:528`) and
commit via the real `CardArea:set_ranks` / `CardArea:align_cards` methods through
normal metatable lookup (a `rawget` of a method is always nil on a real CardArea).

`dispatch` refuses unless:
1. an action with the same `id` was freshly `validate`d by this executor;
2. no pending latch is held (`exec_pending` / `exec_stall_timeout` / `exec_revoked`);
3. a re-capture of the trusted revision immediately before the callback equals the
   validated revision (else `exec_stale_revision`);
4. the critical gates still hold at that instant (phase, resources, affordability,
   slot room, ref resolution, forced-selection inclusion).

Validation and dispatch run under `pcall`; no callback error, engine object or
path escapes — only bounded codes (`exec_*`).

## 6. State revision fingerprint

`EngineAdapter.step()` computes its revision fingerprint from
`codec.encode({ engine = decision_signature(), view = view })`, i.e. the produced
view **plus** the reader-owned decision fields the view itself does not carry
(money/`bankrupt_at`, `chips`, `STOP_USE`, `locked`, `ante`/`round`,
`hands_left`/`discards_left`/`hands_played`/`reroll_cost`, `blind_on_deck`,
`block_play`, `pack_choices`, MP lives/timer-started/ready and the opponent
visibility gates). Raw timers are deliberately **excluded** (they change every
frame, and timer projection is unwired), so a running clock does not invalidate
every decision. Exact observation-content equality is still enforced by the M2
broker's canonical comparison; the revision is the defence-in-depth change
signal, not an authorization. It is deliberately **not** used as a pending-latch
release signal (see §5): only an action-specific, target-anchored completion
predicate releases a latch.

**Timer projection is deliberately omitted.** `ui/game/timer.lua:413-500`
distinguishes `MP.GAME.nemesis_timer_started` (PvP) from `MP.GAME.timer_started`
(Major League normal non-PvP timers), and a consumed normal timer costs a life
without globally forbidding further play. The adapter therefore no longer
invents a `timer_expired` rule; it reports `timer_expired = false` (no adapter
veto) and leaves the engine's own timer and callbacks authoritative. The executor
still re-checks the real gates immediately before any committed callback.

**Discard bound (L2).** The real discard CardArea carries `card_limit = 500`
(`game.lua:2250`), which is not a discard bound. `context.max_discard` is taken
from the hand's highlight limit (`CardArea.highlighted_limit`, default 5,
`cardarea.lua:18`) capped at `max_play`, so the reader/actions/executor agree the
selection is at most the five cards the hand can highlight.

**Stall-clock contract (L5).** The pending latch is bounded by the injected
`clock` port only. That clock **must** advance with *game-active* time: a wall
clock keeps running while the game is paused, and window drag/suspend would cause
false `exec_stall_timeout` faults. The executor cannot derive a pause-aware clock
itself (it must not read the engine's timers), so supplying one is the runtime
worker's responsibility; until then the default `stall_timeout` is deliberately
generous. The per-action anchors and the 10s deadlock fail-closed behaviour are
unchanged.

## 7. Required broker extension contract (not implemented here)

The accepted `action_broker.lua` is unchanged. Its current behaviour for this
module is:

- `factory(observation, actions, ports)` needs `ports.capture -> handle, epoch`
  and `ports.validate(normalized, handle) -> true`. `ProductionExecutor.broker_ports()`
  supplies both, plus `capture`/`validate`/`dispatch` closures.
- In any non-fixture mode the broker returns `broker_executor_disabled` **without
  calling `ports.dispatch`** (M2 guarantee). Our ports declare
  `mode = "M3_PRODUCTION"`, `production = true`, and the broker therefore never
  dispatches — verified by `tests/engine/test_broker_gap.lua`.

To enable production dispatch, a future reviewed broker change must provide:

1. **A distinct production sentinel.** Accept `ports.mode == "M3_PRODUCTION"`
   (or an equivalent explicit production flag) as the *only* production opt-in.
   The M2 fixture sentinel `M2_FIXTURE_ONLY` must keep its current meaning and
   must never enable production dispatch.
2. **Dispatch only after the existing checks.** `ports.dispatch(validated)` must
   still run only after token identity, the start/end captures, epoch/canonical
   equality and `actions.validate` + `ports.validate` all pass.
3. **Revision hand-off (recommended).** Pass the validated revision (or the
   `handle`/epoch pair) to `ports.dispatch(validated, epoch)` so a future broker
   can assert the executor's immediate pre-callback re-check equals the epoch the
   broker itself validated. Today the executor re-captures the revision itself
   via the adapter, so this is a hardening option, not a correctness requirement.
4. **No new policy capability.** The extension must not let policy reach
   `dispatch`, `G.FUNCS`, `Client.send` or `MP.ACTIONS`. Dispatch stays reachable
   only from the broker's trusted submit phase.

Until that extension lands, `production_executor` is exercised directly by the
fixture suite (`tests/engine/test_executor.lua`) and end-to-end through the real
broker only up to `broker_executor_disabled`.

## 8. Fail-closed rules

- Missing/unreadable `ruleset` (from `MP.LOBBY.config.ruleset` or `MP.SP.ruleset`)
  ⇒ no view (`engine_build_failed`); `ruleset` is a required decision token.
- Unknown/ambiguous engine state ⇒ `engine_unsupported_state`.
- Missing engine area backing a requested zone, or a non-table card slot ⇒
  `engine_build_failed` / zone refusal.
- A `booster` in the generic shop zone ⇒ `engine_build_failed`.
- Unknown ref, wrong zone, phase mismatch, unaffordable purchase, full slots,
  `STOP_USE > 0`, controller locked, non-empty `G.play` ⇒ `exec_illegal` /
  `exec_unknown_ref`.
- Stale revision or an action not freshly validated ⇒ refused before any callback.
- Oversized/malformed arrays or unreadable revisions ⇒ refused, never truncated
  into a broader authority.

## 9. Remaining wiring (honest non-claims)

This chunk is **not playable** by itself. Still required before any real-engine
acceptance:

- **Broker production dispatch** per §7, followed by an end-to-end broker dispatch
  test against a fixture engine.
- **Launcher/trusted-UI integration.** The executor now derives the real
  `cash_out` button, `skip_blind` UIBox and PvP `select_blind_button` from the
  injected `G` when `element_for` yields nothing (C2), so skip and PvP ready no
  longer stop the AI and cash-out waits for the real tally button. The launcher
  still owns role/session provenance and stage-room binding: the adapter assumes
  the injected `G`/`MP` are the staged AI runtime and cannot authenticate that
  itself.
- **Timer projection.** `match.timer`/`opponent.timer` are intentionally omitted;
  the actual-visibility certificate (rendered HUD string) is not yet produced. The
  adapter also no longer derives any `timer_expired` veto (see §6): the engine's
  own timer and callbacks stay authoritative, and the executor re-checks real gates
  per action.
- **Required terminal signal.** `MP.GAME.won = true` followed by `win_game()` does
  not necessarily set `G.STATE = G.STATES.GAME_OVER`, so `MATCH_COMPLETE` cannot be
  the only stop condition. The runtime coordinator MUST stop the decision loop when
  either `MP.GAME.won == true` or the engine state is `GAME_OVER`. No observation
  field is added (M2 schema kept intact); the coordinator reads the signal directly.
- **Deck total and tags/owned vouchers** remain unsupported, as in M2.
- **Targeted consumables (`CONSUMABLE_SELECTION`)** are implemented legally (M3)
  **when** the trusted `target_selection()` port names the active source and its
  bounds; without that port the phase is refused (`engine_no_decision_state`). The
  port itself (the launcher/UI side that observes an active highlight phase) is
  still launcher work; until it is wired no targeted consumable is ever offered or
  committed.
- **Content-specific consumable eligibility** is delegated to the read-only
  `Card:can_use_consumeable` predicate (which the adapter and executor both call),
  including Ankh's `check_use` full-slot case. Any effect a Tarot cannot apply for
  reasons the predicate does not capture remains a residual risk.
- **Asynchronous policy timing.** The M2 broker requires the observation bytes at
  `issue` to equal those at `submit`. A live timer/opponent score can change inside
  an asynchronous decision window, so the orchestrator must either decide within
  the window, re-issue, or a reviewed broker change must widen the window. No such
  change is made here.
- **PvP ready/select ordering.** The adapter emits a normal `BLIND_SELECTION`
  while the on-deck blind is the PvP blind and not yet readied, and the executor
  maps policy `SELECT_BLIND` to `G.FUNCS.mp_toggle_ready` on the resolved PvP ready
  element, deliberately never calling `select_blind` before the server's
  `startBlind`. Derived from `ui/game/functions.lua` /
  `networking/action_handlers.lua`.
- **Reorders have no discrete callback.** `REORDER_JOKERS`/`REORDER_HAND` commit by
  permuting the target `CardArea.cards` and calling the real
  `CardArea:set_ranks()` / `CardArea:align_cards()`; areas containing a pinned card
  are refused (L1). This is a trusted-executor commit, not a `G.FUNCS` callback;
  verify on the staged runtime that no engine layout hook fights the reorder.
- **Stall clock (L5).** The bounded latch uses the injected clock; the runtime
  worker must supply a game-active (pause-aware) clock, otherwise pausing the game
  can cause a false `exec_stall_timeout`. Owned by the runtime worker, not here.
- **`blocked` is intentionally coarse.** It denies all candidates while
  `STOP_USE > 0`, the controller is locked or `G.play` is non-empty; the
  orchestrator is expected to retry on the next decision point when the UI
  unlocks. Per-action legality is still re-checked by the executor.
- **Stat: no live run.** Nothing here launches Balatro, loads Mods, writes files
  or sends network traffic; all evidence is fixture-only under Lua 5.1 and LuaJIT.

## 10. Tests

`python tests/run_engine.py --require-all` runs:

- static source checks: presence of the modules and guide; no forbidden
  `require`/`dofile`/`io`/`os`/`debug`/RNG/global tokens or forbidden raw fields
  in real code (comments/strings stripped); the adapter references **no** mutating
  `can_*` predicate; the executor references only the pure predicates and all
  committed callback names; the production sentinel and control states are present;
- `tests/engine/test_revision.lua`, `test_adapter.lua`, `test_executor.lua`,
  `test_pending.lua`, `test_broker_gap.lua` on both `lupa.lua51` and
  `lupa.luajit21`, loading the real
  `codec`/`observation`/`actions`/`state_reader`/`action_broker` and the three new
  modules, driven by a synthetic metatable-aware engine with recording callbacks.

Coverage includes: role/session/port binding; positive construction for hand,
shop, pack, PvP and terminal phases; face-down redaction; distinct shop zones;
non-adjacent pair candidates; masked opponent hands; bounded/deterministic
candidates; the `cash_out` control; PvP ready routed through `SELECT_BLIND`
(`mp_toggle_ready`); fail-closed missing ruleset/unknown state/booster-in-shop;
adapter never invoking mutating UI callbacks; executor validate/dispatch per action;
`SKIP_BOOSTER` dispatch; explicit-callback-`false` rejection; SELL_CONSUMABLE
dispatch; reorder permutations; stale-revision refusal with zero callbacks;
unaffordable purchases; missing-element refusal; and the broker's
`broker_executor_disabled` production behaviour. `test_pending.lua` adds the
deferred-action latch: a queued buy/use/reroll cannot be committed twice before
completion; an **unrelated opponent update, own money income and a
`revision.bump` do not release it**; the anchored target transition does; a
rejected callback leaves it free; the injected clock turns the bounded stall into
a **terminal fault** (`exec_stall_timeout`) that cannot be redispatch-retried
until `cancel()`/session reset; the cash-out latch blocks a duplicate; revoke/cancel
clear it; a same-state pure reorder is never latched; and a `use_card` no-op
(no synchronous removal) fails clean with no latch.

Review-repair coverage added: structured full-house/two-pair candidates survive the
cap and the face-down identity is catalogue-invariant (M1/H2); PvP-ready and
boss-blind blind actions are suppressed (H4a/H4b); pack consumables require
`can_use_consumeable` and negative pack jokers bypass full slots (C1/L3);
forced-selection inclusion and highlight-set equality (H3); the cash-out,
`skip_blind` and PvP-ready element fallbacks plus the no-`element_for` skip path
(C2); `gates_clear` on its own blocking a shop commit (M2); SMODS booster skipping
and metatable-resolved reorder methods (H1/L1); and targeted consumables validating
and committing through the post-highlight predicate check (M3).
