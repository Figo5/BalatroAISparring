# First-ante disconnect and direct deck selection

The October 4 failed session did not report a Lua crash. Sixty seconds after
Multiplayer started the match, the human bootstrap recorded `boot_seed_timeout`
and left its lobby. The AI received `stopGame`; the practice host subsequently
reported `practice_role_lost` and cleaned up both owned windows. Gameplay in the
detached Player window briefly continued through ante two before cleanup.

The pinned Multiplayer `TheOrder.toml` patch prefixes the initialized engine seed
with `*`. The audit validator previously accepted only letters, digits, underscores
and hyphens, so it could never report that real run seed. Both the Lua reader and
Python service now accept exactly one optional leading marker, with a nonempty
body and the existing 32-byte total bound. The marker is preserved as actual audit
identity; human-only, once-per-started-session and immutable-seed checks remain.
The seed never enters AIObservation or the policy worker.

The Player now chooses a deck and stake, confirms that combination, then starts
the AI match. The host publishes every measured eligible combination (bounded at
128), derives the canonical selection itself, and commits one real human `select`
operation under a separate profile and checksum domain. Both runtimes independently
validate its legality and equality with the actual Multiplayer configuration.
Authenticated control requests never carry an arbitrary launch deck/stake or seed.
The completed choice remains bound to settings and staged generation, expires,
can be cancelled, survives a failed pre-launch gate and can be consumed only once.

Targeted regressions execute the actual pinned The Order payload, coordinate both
real bootstraps through the real service beyond the former 60-second timeout,
check policy exports for seed leaks, compare Python/Lua commitments over all 75
production-shaped combinations, reject forged selections and exercise the actual
registered menu callbacks and host wire. Full source checks and fresh native
certification are required before installation. A new human playtest remains
necessary to verify the complete match in the game.
