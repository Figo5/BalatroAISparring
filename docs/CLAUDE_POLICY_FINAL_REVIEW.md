Review captured 2026-09-28. Actual invocation: `claude-opus-5-5 --effort high`; read-only tools. Reviewed HEAD `bbf61bf43f1a8be93ac71cc9ca7c0b96a670be8f`. The reviewer cannot introspect CLI effort, but the orchestrator set High explicitly.

# Re-review: baseline policy, action broker and decision loop (HEAD bbf61bf)

**Reviewer:** Claude Opus 5.5 (`claude-opus-5-5`). I can't see the effort setting, so I can't confirm it is High.

**How I reviewed:** read-only. I read the actual current sources rather than relying on the docs or test assertions. I also read the neighbouring code the loop depends on: the adapter's candidate output, the action generator, the executor's gate/capture/advance and reorder code, the bootstrap wiring, the transport cancel and the service's cancel handler. I made no edits, ran no commands and used no agents. Plan mode asked for a plan file and an exit step, but this session has no Write or ExitPlanMode tool, so the whole review is here.

## Status of prior findings

| ID | Status | Evidence in current code |
|---|---|---|
| H1: cash-out latch deadlock | Closed | While the control is latched, the loop falls through to capture (`decision_loop.lua:927-940`), and the latch has a 30s deadline (`:865-877`). |
| H2: failed advance aborts in about 3 frames | Closed | A failed advance is now a bounded wait via `register_transient`, not an error (`:911-921`). |
| H3: waits capped at about 3s | Closed | Waits are bounded by 120s of wall-clock time with a 0.25s backoff (`:99-110`). |
| H4: consumable targeting loop | Closed | `SELECT_TARGETS` only survives the generator when `min_targets ≤ 1` (`actions.lua:550-556`). In that case the adapter also emits a targeted `USE` (`engine_adapter.lua:1478-1481`), which scores 50000 against 200 (`baseline_policy.lua:719-739`). |
| M1: reorder oscillation | Superseded by a new design | Reorders are allowed again, but only when they strictly reduce "inversions" against a fixed target order (`:822-915`). That count always goes down, so a cycle is impossible, and anchored and position-sensitive jokers are never moved. Residual risk: see NEW-1. |
| M2: "no action" counted as an error | Closed | `policy_no_action` backs off without counting as an error (`decision_loop.lua:637-661`). |
| M3: timeout after a scheduled submit | Closed | Polling and the timeout stop once a submit is scheduled (`:947-955`), and `pacing ≥ timeout` is rejected (`:261`). |
| L1–L6 | Closed | L5 is now wired: `get_revision` comes from `revision.current()` (`runtime_bootstrap.lua:849-851`). |
| N1: policy sells whenever SELL is the only option | Closed | `sell_score` only scores `SELL_JOKER` in `SHOP`, never `SELL_CONSUMABLE` (`:938-991`). The sale needs a full board, the same recognised joker offered with an upgrade edition (foil/holo/polychrome), and enough cash to buy it while keeping the reserve. One sale un-fills the board, so a second sale can't follow. Tests expect no action at `test_choices.lua:217-261` and `test_shop_upgrade.lua`. |
| N2: abandoned decision blocks the service | Closed | The transport now sends `decide_cancel` over the wire before clearing its slot (`control_transport.lua:438-466, 679-693`). The service cancels only the exact job named (`practice_service.py:1855-1884`). The loop timeout is now 15.25s, above the service's 10s (`runtime_bootstrap.lua:81, 325`). Tests: `test_runtime_bootstrap.lua:249` and `test_practice_service.py:583-638`. |
| N3: failed advance skipped the cooldown | Mostly closed | The cooldown is now respected before advancing (`decision_loop.lua:905`). One residual is left (NEW-2). |
| N4: fatal executor faults treated as waits | Closed | The broker passes `exec_stall_timeout` and `exec_revoked` through (`action_broker.lua:79-82, 277-280`). The loop stops and revokes immediately on either (`decision_loop.lua:715-722, 833-838`). |
| N5: missing wait/revision hooks | Wired | Both hooks are wired (`runtime_bootstrap.lua:849-854`). Whether the real wait signal (`mp_wait_state`) behaves correctly still needs a real-engine check. |
| N6: no throttle on repeated "no action" | Closed | Backoff doubles while the state is unchanged, capped at 2s, and resets when the state moves (`:108, 637-661`). |

**Other checks, all OK:**
- **Determinism and hidden information:** the policy template has no RNG and no `pairs`. It reads only exported, non-redacted fields and breaks ties by id bytes. The only `%` in the template is the single `%s` placeholder.
- **Stale state and A→B→A:** the broker rechecks the epoch and the full observation at submit and again before dispatch (`action_broker.lua:384-449`). Raw timers are excluded from the state fingerprint (`engine_adapter.lua:578-580`), so there is no per-frame staleness churn.
- **Legal fallback:** every phase has a scored way forward.
  - `LEAVE_SHOP` is always offered.
  - `SELECT_BLIND` is always offered.
  - In booster packs, either a select or a skip is offered.
  - `PLAY` is available whenever hands remain.

## New findings

No Critical or High code defects remain in this scope.

**NEW-1 — Medium (becomes High if a staged check shows the engine ignores the reorder). A reorder that doesn't take effect traps the AI in the shop with no limit.**
- **Where:** `production_executor.lua:1471-1502` and `:83-99` (REORDER isn't in the list of actions that wait for a visible effect), together with `baseline_policy.lua:50, 64, 109`.
- **Failure:** a reorder scores 105–115, which beats `LEAVE_SHOP` at 90–100. Dispatch returns `true` without checking that the new order stuck. If `align_cards`, the Multiplayer mod or another mod re-sorts the jokers:
  - the next observation is identical;
  - the policy picks the same reorder again;
  - each "successful" submit resets every error and wait counter.

  The result is an endless loop in the shop that starts roughly 4 policy workers per second and never aborts.
- **Minimal fix:** after `set_ranks`/`align_cards`, check `cards[i] == target.cards[i]` for every position and return `CALLBACK_FAILED` if any differ. The loop's existing 3-error limit then bounds the failure. Add a test where the fake area reverts the order.

**NEW-2 — Low. A stale cash-out state can stop the loop from ever capturing.**
- **Where:** `decision_loop.lua:893-926` and `production_executor.lua:1570-1573`.
- **Failure:** `last_control` is only cleared by a successful capture. Suppose the engine leaves the round-evaluation screen without the AI pressing cash-out. Every time the cooldown expires, the loop tries to advance before it tries to capture. The advance returns `exec_no_control`, so capture never runs, and the match ends with a transient-wait error after 120s. The comment at `:898-904` says capture runs in this case, but it doesn't.
- **Mitigation already present:** the runtime's own game-over/win check runs before the loop (`runtime_bootstrap.lua:1403-1418`).
- **Minimal fix:** in `advance_ui`, when `step.control == nil`, also set `last_control = nil` before returning `NO_CONTROL`.

**NEW-3 — Low. A failed wire cancel costs error budget.**
- **Where:** `control_transport.lua:679-693` and `decision_loop.lua:459-465`.
- **Failure:** if the cancel frame can't be pushed, the transport keeps its pending slot but the loop has already forgotten it. The next request gets `transport_busy`, which counts as an error, and three in a row stop the match.
- **Fix:** have the loop retry `transport.cancel` before its next request, or let `request` cancel a stale slot it owns.

**Latent (not reachable in production today):**
- **Multi-target consumables:** in `CONSUMABLE_SELECTION` with `min_targets ≥ 2`, the policy returns no action forever, backing off up to 2s, with no way out. This can't happen yet because nothing wires `target_selection` in production. Before wiring it, add a multi-target `USE` or a cancel candidate.
- **Terminal stop:** `finish_terminal` doesn't call `on_stop`. This is harmless because the bootstrap detects game over independently from the same `GAME_OVER` signal.

## Checks that belong to the real-engine gates (not code defects)

- Whether the engine actually keeps a reorder (see NEW-1).
- The cash-out button element being ready when the loop presses it.
- Whether the executor's 10s stall timeout is long enough for real commits.
- Whether the `ready_blind`/PvP wait signals match what the live Multiplayer mod does.
- Executor refusals caused by a missing UI element (for example for blind selection) count as dispatch errors, and three in a row end the match. This needs observing in the engine.

## Verdict

**Approved for controlled staged testing** in this scope (policy, broker, loop). No Critical or High safety, legality, fairness or basic-playability defects remain in the code. This is not runtime, installation or playable approval.

I recommend landing the NEW-1 postcondition check before the staged runs, or at least watching for a stuck shop during them. NEW-2 and NEW-3 can go in the next pass.
