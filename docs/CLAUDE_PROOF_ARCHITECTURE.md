# Review: reusable P1 certificate plus per-session live diff (architecture gate only)

## Decision

**I approve the split in principle, subject to the conditions below.** It fits the accepted architecture and gates, and it matches what my earlier review already asked for:

- H6 said to compare live state against a fresh backup before each closed-game launch, and to use that as the "before" snapshot.
- The concurrent-mode section said a proof record should bind digests rather than live contents.

The integration plan's "record before/after hashes of live install and all live Balatro AppData; require zero changes" applies to the controlled bootstrap experiment. The gates never ask for P1 to be repeated before every match. Full P1 is a prerequisite for real practice matches, and a certificate meets that prerequisite as long as every match runs under a matching certificate *and* passes its own zero-diff check.

**What is approved:** the design only. **What is not:** any code or runtime claim.
- The current code does not implement this design (gaps below).
- No P1a, P1b, full P1, crash fixture or P2 evidence exists yet.
- Workers are still editing.

The actual diff and the first real certificate run each need their own review.

## How to frame it

The certificate proves a property of the staged artifact: where it writes, what it loads, and that Steam is off. Live AppData, profile and settings contents are not inputs to that property, because the certificate itself proves the staged runtime doesn't read them. So legitimate live changes cannot falsify the certificate. Each session's zero-diff check then re-tests the claim continuously. The certificate's one extra value is **permission to skip the ordered ramp-up** (no-MP bootstrap → dead-loopback MP → two runtimes). It is not a substitute for per-session measurement.

## (A) Certificate requirements

1. **Split it into two layers, each with its own invalidation.**
   - **Native layer (N):** exe hash, full staged install tree including Lovely `version.dll`, the Steam-disable/crash/startup guard patches, no Steam natives, the environment allowlist plus the *names* of any `AISP_*` variables, staging and role root paths, and the live-root paths they were proven disjoint from. P1a evidence covers this layer.
     - P1a ran on the bootstrap tree, so the certificate must assert that the bootstrap install digest equals **both** role install digests.
   - **Mods layer (M):** the role Mods tree digests (Multiplayer, SMODS, Handy, JokerDisplay, companion code, `.env`), the MP startup guard, network-suppression hashes, the endpoint host 127.0.0.1 with the fixed match port, and the server bind patch plus pinned commit. P1b and full P1 cover this layer.
   - A change to layer M only means re-running P1b and full P1. P1a can be reused only if layer N is byte-identical. Any change to layer N means re-running P1a, P1b and full P1.
2. **Bind the tools that control isolation, not just `staging.py`.**
   - `tool_sha256` currently covers only `staging.py` (`tools/staging.py:1931`).
   - Also bind every module that builds the environment, stages files, writes patches, spawns processes or binds endpoints: `launch_practice.py`, `prepare_server.py`, and the control-bind code in `practice_service.py`.
   - The certificate-check logic must itself be inside the bound surface.
   - Recommendation: move this isolation-critical code into its own module(s). Then everyday edits elsewhere won't invalidate the certificate, and nothing can be exempted by accident.
3. **Store the evidence as immutable copies, not references to files that change.**
   - `check_isolation_proof` currently re-reads the role probe files against the stored nonce (`staging.py:1972-1978`).
   - The next launch overwrites those probes with a new nonce, so the proof would break after one session even with zero live changes.
   - Fix: copy the P1a/P1b/full-P1 probe files and the raw before/after live manifests into `evidence/`, record their sha256 hashes, and verify those copies.
   - Never rewrite or rebase them. Revocation goes in a separate append-only record.
4. **Stop comparing live state at certificate-check time.** Remove the `current.live != proof.live` comparison (`staging.py:1970`). Live-content checking moves entirely to (B).
5. **Claim only what was measured.** The P1.6 crash/cleanup fixtures and P2 dead-port behaviour belong in the certificate, or it must be marked partial. The "Steam disabled" claim needs the positive API check that P1a requires, not just an unchanged-achievements observation.

### What may differ from the certificate

- Contents of live install, AppData and Steam userdata.
- Session ID, nonces and role credentials.
- The control port, provided the 127.0.0.1-only bind is enforced in bound code, the port range is validated, and it is passed through an allowlisted variable name.
- PIDs, timestamps, logs and dumps.
- Staged profile/unlock data (see "Live config/unlock changes" below).
- New Steam userdata profiles, but only if they are disjoint from staging and included in every session's backup and diff.

### What invalidates the certificate

- Any bound digest (layer N or M, or a tool hash).
- The match port or endpoint host.
- The staging root or role roots.
- The live install or AppData root paths.
- The Lovely version.
- The mutable-path list or its validators (see config.lua).
- The certificate schema.
- A live-diff failure in any session: this **revokes** the certificate, because it falsifies the claim.

## (B) Per-session requirements, all while the game is closed

1. **Transition:** the live PID exits naturally, nothing is killed, and the process check (full image paths) runs immediately before the snapshot and again before spawning.
2. **Quiescence:** Steam may write userdata or remote cache (cloud sync) for a while after the game quits. Take the before-snapshot only after two identical Steam-userdata hashes N seconds apart. Otherwise the check will trigger false lockouts.
3. **Fresh verified backup and before-state:**
   - Hash the source, copy it, check the copy matches the source, then recheck the game is closed.
   - Content-addressed dedup of identical bytes is fine, but the before-state manifest must be freshly computed from live every time.
   - It must be a **full byte manifest**. Right now `_live_state` hashes the install as `detect_versions` metadata only (`staging.py:1846`), which is not a byte diff.
   - Cover all Steam profiles' `2379780` folders and the remote cache.
   - Never overwrite earlier backups or the certificate's evidence.
4. **Before spawning:**
   - Recompute every certificate-bound digest from the current staged trees.
   - Restore declared mutable files to their canonical bytes (see config.lua).
   - Confirm no stale probes and no leftover staged processes.
   - Generate a fresh nonce.
5. **Attestation:** before any credential or match start, both roles must return probes with the session nonce, the correct save directory, a Lovely Mods directory inside the role root, `steam=nil`, and loopback plus the correct port.
6. **During the session:** if a live Balatro process appears, stop practice through the normal MP flow and terminate only launcher-owned processes. Mark the session **void**, not passed, and require explicit user acknowledgement before the next launch.
7. **After the run:**
   - Wait for the owned processes to exit, recheck the live game is closed, then rehash.
   - Any live byte difference means: persistent launch lockout, certificate revoked, diff saved.
   - Do **not** auto-restore live from backup. That is itself a live write and needs user approval.
   - Staged immutables may change only at declared mutable paths, and only if the change passes that path's validator.
8. **Append-only session record:** certificate ID, backup ID, before/after manifest digests, attestation digests and the verdict.

## Live config/unlock changes

- **Live settings, profile or unlock changes on their own need no restaging and no new P1.** P5 requires the two *staged* clients to match each other, not to match live.
- **Refreshing unlocks is optional and data-only.** It is allowed only while the game is closed, from the fresh *verified backup* (never from the running game or directly from live), using an allowlist of profile unlock files, with identical bytes in both roles. Those files stay outside the code manifest. It does not invalidate the certificate.
- **Never copy from live** `config/Multiplayer.jkr`, `.env` or other mod-config jkrs. Staged Multiplayer, Handy and SMODS settings stay canonical, pinned by the repo, and checked per launch.
- **Restaging Mods or versions from live is the user's choice.** A Mods change is layer M (re-run P1b and full P1). An exe, Lovely or install change means a new P1a as well. A live Steam update alone does not invalidate the certificate. The next session's backup simply covers the new bytes.

## `config.lua` "may be runtime-modified"

- **Treat it as unproven until a measured run shows the change and a source-level writer is identified.** SMODS normally persists mod config to `<save>/config/<id>.jkr`, not the mod's `config.lua`. I couldn't verify this without the source.
- **If it is proven**, do not exclude it with a name, depth or directory rule:
  - Exclude exactly one path from the M digest: the Multiplayer mod folder resolved by its JSON id, plus `/config.lua`.
  - Bind the canonical bytes' hash, and the mutable-path list itself, in the certificate.
  - Because `config.lua` is **executable Lua loaded at startup**, parsing it on its own is not enough. **Restore the canonical bytes before every launch** (a staging-only write) and verify the hash before spawning.
  - After the run, record the new hash as a diagnostic, and require that it still parses to 127.0.0.1 plus the fixed port. Otherwise lock out.
- **The same rule applies to any other runtime-written file:**
  - Pure outputs never loaded as code (`lovely/log`, `lovely/dump`) may be excluded by exact prefix, as they are now (`staging.py:452,462`).
  - Anything loaded at the next startup is restored to canonical bytes, not excluded.
  - Adding a mutable path is a certificate change that needs review.

## Smallest safe reusable workflow

1. **Once per layer-N/M content:** closed game → verified backup → P1a (bootstrap) → P1b → full P1 with two runtimes, plus crash/P2 fixtures → the record function writes the certificate with the immutable evidence copies.
2. **Every match:** live game quits normally → natural exit → Steam quiescence → fresh backup and full before-manifest → certificate recomputed and matched → canonical mutable files restored → spawn → nonce attestation from both roles → play → owned processes exit → after-manifest → zero diff, or lockout plus revocation.

Nothing I read contradicts "live Mods untouched until the final install gate" or "no concurrent live mode."
