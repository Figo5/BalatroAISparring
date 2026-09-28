# Native staged test progress — September 28

The user closed Balatro before this test pass. Fresh process checks and hash-verified backups preceded actual staging and launches. The live installation, Mods and saves were not modified. Native artifacts and proprietary dumps remain in ignored local staging/work directories, outside Git.

| Phase | Actual result |
|---|---|
| P1A bootstrap | Passed; process exited; zero changed live roots. Receipt `7b66edf1800f5cfc932c7466ba82e33ae27cf0f3c9a4df1e7ff86587be9ed271`. |
| P1B Multiplayer load | Passed for both staged roles; owned processes ended; zero changed live roots. Receipt `0393150ffd20b8799d9db916e9e91487931338e883cc9ab457e48ec8b29d59d4`. |
| FULL_P1 | Refused before process creation: staged role manifest mismatch. |
| CRASH and P2 phases | Not started. |
| Match/gameplay/install | Not started. |

The expected patched socket dump was observed in both real staged roles at `Mods/lovely/dump/SMODS/Multiplayer/networking/socket.lua`.

## Concrete failure and repair

After the first real Multiplayer load, Lovely regenerated its separate **unpatched** `Mods/lovely/game-dump` cache. The immutable role manifest treated that cache as source. Both roles gained generated Multiplayer `core.lua` and `networking/socket.lua` entries and lost a generated Handy updater entry. No ordinary source-file changes were reported. The next launch correctly failed closed.

The failed session has no open ownership records and no remaining Balatro processes. A fresh backup comparison after the refusal passed with no live changes. The lockout remains recorded for explicit acknowledgement after the correction has passed review.

DeepSeek is correcting only the exact generated cache classification. Live snapshots/backups must remain complete, ordinary mod sources must remain immutable, and the separate fresh **patched** dump evidence remains mandatory. Native tests pause for independent checks and Claude review of this fix.

Astra independently verified the fix with 52/52 staging cases, 52/52 certificate cases, 48/48 installer cases and three backup/session contracts. An additional independent boundary check reproduced the failure before the patch, then passed across Mods, staged-role and bootstrap policies: generated-cache rewrites are ignored only in the exact output location, three source-change cases remain detectable, and complete backups still contain cache files. Tested source and suite hashes remained unchanged through these runs. Claude review remains pending.

## Build coverage correction

The first staging pass copied the existing installed mods but omitted the new companion package. Astra caught this before any match or installation. The verified `0.1.0-dev` package is now prepared in ignored `work/aisparring-package`; it has not been installed or copied into the staged roles yet. The final staged role trees will include its exact packaged bytes before repeating the phase measurements. Earlier receipts will remain diagnostic history, not proof for changed tools or mod contents.
