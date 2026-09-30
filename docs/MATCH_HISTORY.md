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
