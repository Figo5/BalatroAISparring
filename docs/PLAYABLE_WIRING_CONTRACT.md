# Frozen launcher / companion integration interface (Astra)

This resolves naming conflicts found while integrating the independently implemented modules. It elaborates the accepted local control architecture; it does not enable launch before review or P1.

## Environment
Use the existing launcher descriptor names, not parallel aliases:
- BALATRO_AI_ROLE: human or ai (from staging.role_environment). AIS_RUNTIME_ROLE is descriptive only.
- AISP_SESSION_ID, AISP_ROLE_CREDENTIAL, AISP_CONTROL_PORT, AISP_CONTENT_HASH, AISP_PROBE_NONCE.
- AISP_EXPECTED_ROLE_SAVE_ROOT and AISP_EXPECTED_ROLE_MODS_ROOT.
- AISP_MODE, AISP_DIFFICULTY, AISP_PACING, AISP_GAUNTLET.
Expected companion module root is `<expected Mods>/AISparring`; compare actual SMODS mod path exactly after normalization. Do not add AISP_ROLE, AISP_EXPECTED_SAVE_DIR, AISP_EXPECTED_MODS_ROOT, AISP_EXPECTED_MOD_ROOT aliases. Seed is obtained by the HUMAN coordinator from authenticated service SETUP only; AI engine receives its run seed through ordinary MP startGame. No seed in policy input. No env AISP_SEED, DECISION_BASE, AUTO_COORDINATE, LOG_ROOT needed. Use local defaults/verified paths and service metadata.

## Companion config
Installed live copy: `{ ai_enabled=true, companion={role='live', discovery_path=<repo/work/aisparring-host/practice_host.json>} }`.
Both staged copies: `{ ai_enabled=true, companion={role='staged'} }` with identical bytes, role determined by the verified environment. Repo default remains inert for regression fixtures. Installer changes only copied config, never repository source or other live mods.

## Deferred launcher attestation
Early Lovely startup probes are written before companion activation. The host waits for BOTH roles' fresh nonce/path/Steam/MP-loopback probes. Then it writes a session-bound attestation to each role's fixed path `<expected role save root>/aisparring-launcher-attestation.json`, outside Mods/code manifests. It must be created only after actual successful probe verification, using staging safe-write helpers. It contains schema aisparring.launcher_attestation.v1, ok=true, session, role, nonce, content_hash, control_port and verified expected roots, plus measured probe hashes. It contains no credential. Remove/rotate the old file before each role launch; never treat a previous session file as current.
The companion derives this exact path from the validated descriptor, not arbitrary network/user input. While missing, keep staged bootstrap in bounded pending state and poll nonblocking; do NOT mark boot permanently failed at first module load. No production capability, lobby creation/join or AI action before matching attestation + authenticated service hello. Deadline => graceful local failure. Match server may already listen locally, but no match starts before this gate.
This file is trusted host IPC, not a sandbox against other arbitrary trusted game code or same-user OS attackers. The restricted policy worker cannot read it. Full implementation remains subject to Claude review.

## Wire sequence
Python service has ONE monotonically increasing new-request counter per authenticated role. Lua transport allocates a global wire sequence across coordination, decisions, heartbeats and result receipts; private policy sequence maps to wire decision sequence. Poll repeats only the pending wire decision sequence. Do not weaken service anti-replay or use disjoint numeric ranges on wire.

## Evidence
Use immutable reusable certificate API in tools/isolation_certificate.py, never rebase old measurements. Per-session prepare/snapshot/record/revocation come from that API. Host gets fresh backup and Steam quiescence. No fake certificate, no live operation during development. All clients must use these same names and predicates; tests should connect real Lua serialization to the real Python parser.
