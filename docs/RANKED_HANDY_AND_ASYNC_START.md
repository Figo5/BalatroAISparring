# Ranked practice: Handy and asynchronous match start

The Multiplayer approved-mods sheet (tab 914462836, accessed October 2, 2026)
explicitly approves Handy with its banned features disabled by Multiplayer:
https://docs.google.com/spreadsheets/d/1SR-Grf99e53-zODE8B7qGX53Jv1mNPqMVV9yFZGWv50/edit?gid=914462836

The staged inventory now pins Handy 2.0.6. Its controls remain available. The
actual Handy Multiplayer reset hook runs normally; before the first options
packet the host disables the lobby extension and fixes its speed, animation
skip and dangerous-action modes to 1, with no forced overrides. Both roles
verify the complete exact configuration and the mod's effective predicates.
The readiness fact is `handy_ranked_safe`, not a claim that Handy is absent.
Unknown keys, altered modes, enabled extensions and forced overrides refuse
readiness/configuration validation. The updater remains suppressed only inside
the owned staged copies; live Handy and personal saves are unchanged.

Pinned Multiplayer's lobby-start callback only sends an asynchronous start
request. The driver freezes host options immediately but does not report a
running match until the actual engine reaches RUN in its joined lobby. Neither
the old menu deck/stake nor a previous run's seed is checked as the new match.
Initialized mismatches still abort before policy actions.

Stock UIBox_button interprets a nil callback as exit_overlay_menu. Draft
controls therefore always retain their guarded controller callbacks. An
incomplete confirm leaves the draft open, explains the required count and
sends no action; stale/out-of-turn choices remain refused. Human choices and
gameplay must remain manual.

`tests/test_ranked_handy.py` executes functions from the pinned Handy source on
both Lua engines. The runtime regression delays the real run initialization
while an old, different menu selection exists. Certification proves isolation;
an attended first-blind/match-completion playtest remains required.
