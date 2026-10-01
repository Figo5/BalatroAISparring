# Match history and post-match review

`tools/match_history.py` is a read-only report over the practice host's session
workspaces (`work/aisparring-host/sessions/<session>/`). It never launches or
touches Balatro, the live install, Mods, saves or the certificate, and it is not
a certificate-bound tool.

```
python tools/match_history.py                  # every match, then totals per difficulty
python tools/match_history.py --json           # the same, as JSON
python tools/match_history.py review <session> # one match in detail
```

The **history** view shows one row per session: difficulty, result (human
perspective, from the service's terminal summary), ante, lives, decisions,
errors and hand-off seconds. Hand-off seconds run from the `live_exited`
milestone to `roles_launched` in `host.json` timings. Totals per difficulty are
the matches played, AI and human wins, the AI win rate over decided matches,
mean ante and errors.

The **review** view is the foundation for post-match analysis:

- decisions by phase and by action type (including `START_TIMER` presses);
- the most common decision reasons, including `policy_no_action`;
- policy latency p50/p95/max;
- rejected-result codes from `results.jsonl`;
- the five slowest hand-off stages from `handoff.jsonl`;
- terminal abort rows (the service's `reason=code, errors=code` line), listed
  separately under `aborts` and not counted as decisions;
- a count of malformed lines, which are skipped rather than fatal.

Files over 64 MB, unreadable files and malformed `host.json` timings are
skipped. A session path must be a direct child of the root. Symlinked session
folders and symlinked log files are ignored.

Useful after the next local session (LV-5, LV-7): run `review` on each match to
see where hand-off time went and how the stronger policy behaved.

## LV-7 UI check (`review` → `ui_check`)

`review` also summarises the per-decision `ui` facts that the practice service
logs:

| Field | Meaning |
|---|---|
| `rows` | the play-phase rows to compare with screenshots, at most 200: tick, phase, hand size, blind requirement, current score and hand levels |
| `budget_errors` | decisions that ended with `policy_budget_exceeded`, i.e. the sandbox instruction budget. A service wall-clock timeout has its own code and is not counted here; it appears under `reasons` and `aborts` |
| `decisions_with_10_plus_cards` | decisions made with 10 or more cards in hand |
| `max_hand_size` | the largest hand seen |
| `latency_by_hand_size` | latency p50 / p95 / max, split into ≤ 9 and 10+ cards |

These are the LV-7 checks: UI values, large hands, zero budget errors.

## Tarot selection evidence (`review` → `tarot_selection`)

The practice service already logs, for a hand-targeted use, the allowlisted
`action.tarot` center, the `action.source_ref` and the ordered
`action.card_refs`. `review` now surfaces that evidence (it previously only
counted `USE_CONSUMABLE_ON_HAND` actions):

| Field | Meaning |
|---|---|
| `centers` | count of hand-targeted uses per allowlisted center, over every matching row (not just the surfaced list) |
| `uses` | total hand-targeted uses with an allowlisted center |
| `rows` | the detail list, at most 200, in log order |
| `rows_truncated` | `true` when more uses exist than are shown (i.e. `uses` > `len(rows)`) |
| `receipts` | how many rows correlated to a broker receipt: `matched` / `absent` / `ambiguous` / `invalid` |

Each row has:

| Field | Meaning |
|---|---|
| `sequence` | the decision row's `tick`, which the service sets to the decision sequence; `null` unless it is a valid positive integer (no `0`, bool, float, negative or oversized value) |
| `timestamp` / `phase` / `difficulty` | the decision's own values when safely available and bounded; `phase`/`difficulty` are `null` otherwise |
| `center` | one of the ten allowlisted Tarot centers |
| `source_ref` | `consumable:n` positional ref, or `null` |
| `card_refs` | the ordered `hand:n` targets, at most two |
| `targets` | number of targets shown, always 0-2; never inflated by malformed refs |
| `targets_truncated` | `true` only when the action carried more than two valid targets (explicit bounded indicator) |
| `broker_accepted` / `broker_code` | the matching result receipt's `accepted` / `code`, or `null` |
| `receipt_status` | `matched`, `absent`, `ambiguous` or `invalid` |

### Correlation and what the receipt proves

- The join key is the decision sequence: `decision.tick` = `result.sequence`.
  `result.tick` is the runtime tick and is **never** used to join.
- A unique receipt is only a unique correspondence when the decision sequence
  itself is unique. `receipt_status` is:
  - `matched` - the sequence is used by exactly one decision (of any action
    type) and exactly one in-session result row declares it, with a readable
    `accepted`/`code` payload;
  - `absent` - no in-session result row declares the sequence;
  - `ambiguous` - the sequence is used by more than one decision, or more than
    one in-session result row declares it (identical, conflicting, or one
    malformed). One broker receipt is never counted as proof for two uses;
  - `invalid` - the decision has no usable sequence, or its single result row's
    payload cannot be read (e.g. `accepted` is not a boolean). This is
    explicitly unknown, not acceptance.
- Result rows are counted per sequence *before* payload validation, so a
  malformed row cannot make a duplicated sequence look unique.
- **`broker_accepted` / `broker_code` are broker acceptance/commit receipts
  only.** They do **not** prove that the engine applied the Tarot effect or that
  the highlight was cleaned up. That proof is in the separate native/runtime
  event log and in human validation (`docs/HAND_TARGETS_DESIGN.md`,
  `docs/LOCAL_VALIDATION_QUEUE.md`).
- A decision or result row that declares a different `session` than the
  directory is not correlated into this session.

### Sanitisation and limits

- Only the ten hand-targeted centers are surfaced (`c_strength`, `c_death`,
  `c_lovers`, `c_chariot`, `c_justice`, `c_devil`, `c_star`, `c_moon`,
  `c_sun`, `c_world`). Any other or missing `action.tarot` value is dropped.
- Refs are canonical positive positional strings: `consumable:n` / `hand:n`
  with `n` in 1..999, ASCII digits, no leading zero, at most three digits.
  Zero, leading-zero, oversized, wrong-prefix or non-primitive values are
  dropped. At most two ordered targets are shown; `targets` is bounded to 2 and
  `targets_truncated` says whether more valid targets existed. No target is
  invented from a malformed extra ref.
- Timestamps must be numeric, finite and in `[0, 1e11]`. Range and type are
  checked before any float conversion, so a huge JSON integer cannot raise;
  bools, non-numbers, `NaN` and infinities are `null`. Phases are bounded text;
  a difficulty outside the known set is `null`.
- Arbitrary action fields (hidden/string/table payloads, `target_refs`,
  `order`, …) are never copied into a row.
- Rows without an allowlisted center - including legacy logs written before
  `action.tarot` existed - are tolerated and produce no row, so old logs keep
  working and `centers`/`uses` stay truthful.

This view reports only what the service logged. Buy/sell identities, wait
durations, economy or build progression and turning points are not logged and
are **not** derived here; they remain unavailable.
