# Isolation source corrections — September 28

Scope: reviewed F1–F4 and adjacent F5–F11 from `CLAUDE_ISOLATION_AFTER_RESET_REREVIEW.md`, using the adopted corrections in `P2_MEASUREMENT_PROPOSAL.md`. DeepSeek V4.1 Flash High implemented the changes. Astra inspected the production diff and independently ran the checks below. Claude re-review is still required; this document is not native game acceptance.

The silent listener records peer EOF independently from tool-side release. Evidence requires expiry-timed EOF and a hold through retry completion. The observer records connection start/end separately so actual connection latency is excluded from retry sleep gaps. Certificate validation re-parses copied listener evidence and requires a post-exit dead-port proof. The pinned Multiplayer protocol, timeouts, retry schedule and close comparison remain unchanged.

| Independent check | Result |
|---|---|
| Certificate | 50/50 |
| Launcher, including bounded probe timeout and rejection | 61/61 |
| Staging | 48/48 |
| Measurement lifecycle | 11/11 |
| Source observer, Lua 5.1 and LuaJIT | 6/6 reported cases, both runtimes |
| Shared host interface | 87/87 |
| Shared installer interface | 48/48 |
| Backup/session contracts | 3/3 |
| Attestation producer/consumer | 8/8 |
| Independent evidence rejection checks | 10/10 |
| Windows CLOSE listener: owned peer PID, graceful FIN, zero sends | PASS |
| Windows SILENT listener: peer EOF distinct from tool release, zero sends | PASS |
| Windows unused-port probe: three actual refused connections | PASS |

The two Windows listener checks use owned Python peers and sockets, cleaned up afterward. They neither launch Balatro nor prove game phase completion. Astra adapted the silent-listener negative fixture to the new start-time schema and expiry EOF semantics, added a passing positive control, and retained the missing/early tool-hold rejection assertions.

Astra also found a real Windows probe issue: the old 0.5-second probe timeout expired before an actual refusal arrived (measured approximately 1.03 seconds). DeepSeek increased only the tool probe's bounded wait to three seconds; game socket timeouts remain unchanged. The independent native retest observed three actual refusals at 1.026/1.006/1.008 seconds, both address families absent and no timeout claims. The launcher tests retain timeout rejection. The listener implementation was unchanged by this timeout correction.

No actual Balatro runtime copies, backups, launches, installation or live-file changes have occurred. P1A, P1B, FULL_P1, CRASH and all three P2 phases remain real-game gates. The first Multiplayer-enabled native dump must confirm the socket dump path. MATCH, complete gameplay, installation and user playability remain pending.
