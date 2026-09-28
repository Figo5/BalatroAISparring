# Reviewed native failure-measurement design

Astra decision, September 28, 2026: adopt section 4 of `CLAUDE_ISOLATION_REREVIEW.md`. The earlier single-session P2 proposal is rejected. This changes measurement/evidence organization only; the accepted two-runtime architecture and pinned original Multiplayer adjudication remain unchanged.

Implement distinct `P2_INITIAL`, `P2_CLOSE`, and `P2_SILENT` phases, each AI-only after FULL_P1, with independent nonce, real backup binding, before/after live snapshots, retained ownership, closed-game checks and immutable hashed receipt. The certificate requires all three. Existing aggregate P2 evidence cannot substitute for them.

Use the reviewed exclusive 127.0.0.1-only, one-connection measurement listener for CLOSE/SILENT. Prove listener and accepted-peer PID ownership from the native TCP table. Never send bytes; close the listening socket after accepting. Record received-byte count/hash/action names and immutable listener events. The MATCH server and adjudication are unchanged.

Observer events must identify actual returned connect results, receive errors, keepalive pushes and each retry cycle's cause, attempts and final outcome. Recovered and unfinished cycles never prove exhausted retries. Use the exact coverage/time definitions in the review, with source-derived original timers and stated tolerance. Require full-line Lovely-faithful matching and all payload markers, plus exact patched socket dump evidence.

Astra accepts `closure_path=keepalive_fallback` when an actual recorded peer FIN and native receive error lead to bounded exhausted retry through the original keepalive path. This satisfies observed bounded failure handling without changing Multiplayer's `error == "close"` comparison. It must never be labelled `close_branch` unless that exact branch ran. This is not permission to infer behavior from fixtures.

Measurement end modes must be tool-owned, distinct from crash exit codes, settled after required evidence, and recorded with retained process ownership. CRASH additionally requires a fresh nonce-bound observation from the active original error handler for every role; nonzero exit alone is insufficient. Deadlines fail closed with cleanup and lockout. Implement the detailed N1-N10 fixes from the review in the same bounded measurement scope.

Required sequence: DeepSeek implementation, Astra source/fixture verification, Claude actual-diff re-review, then fresh process checks/backups and native measurements. No actual runtime copies, game launch, installation or live-file operations are authorized by this design decision alone. None has occurred.

## September 28 source-based measurement correction

Astra adopts the corrections in `CLAUDE_ISOLATION_AFTER_RESET_REREVIEW.md` F1–F4. Original Multiplayer closes its own client socket at keepalive expiry before the retry cycle. Record that peer EOF independently from how long the tool retains its connection: accept an expiry-time EOF only with the reviewed fifth-push/expiry/cycle timing, zero sends, no premature tool close/reset and tool hold through cycle end. Missing or early tool hold still fails. Original Multiplayer behavior is unchanged.

Retry-delay evidence must distinguish scheduled sleep from connect duration. Add the reviewed env-gated before-connect timestamp/marker and compare attempt start with previous end (or cycle start); retain durations separately. Re-derive listener coverage and peer binding from the copied log, and bind a fresh after-exit dead-port proof for P2_INITIAL. These corrections change measurement evidence, not MATCH architecture, original timers or policy access. DeepSeek implements; Astra verifies; Claude reviews F1–F4 before P2 native measurements.
