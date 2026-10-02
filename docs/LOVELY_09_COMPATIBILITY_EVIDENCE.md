# Lovely 0.9 staging compatibility evidence

Architecture evidence only. No injector has been installed or executed in this development generation, and no new native certificate exists yet.

The [official Lovely 0.9.0 release](https://github.com/ethangreen-dev/lovely-injector/releases/tag/v0.9.0) corresponds to source commit 91759da5702618c3b940fbbe8135954414c0ef34. The official Windows x64 archive was downloaded from that release into ignored work/ranked-audit/dependencies.

| Artifact | SHA-256 |
|---|---|
| lovely-x86_64-pc-windows-msvc.zip | 40b994a055ee75e5f2aba81e7ae06f2c17460e18cc346483089921899fadd1f7 |
| extracted version.dll | ccfed59e4d245b7802c684fc86708e0a937f584d6e07d1ecc11e8eae22f9fc1a |

The extracted DLL is 4,344,320 bytes. Hashes describe the downloaded artifacts and do not substitute for native loading evidence.

The pinned [0.9.0 core source](https://github.com/ethangreen-dev/lovely-injector/blob/91759da5702618c3b940fbbe8135954414c0ef34/crates/lovely-core/src/lib.rs#L110) reads LOVELY_MOD_DIR before falling back to the operating system data directory. Its ordinary command line also supports an explicit mod-dir override at line 141. The existing per-role environment mapping can therefore select isolated Mods roots without changing the DLL or compatibility checks.

The same source places logs below the selected mod directory at lovely/log (line 149). At initialization it clears/recreates lovely/dump and lovely/game-dump within that mod directory (lines 202–216). The [dump writer](https://github.com/ethangreen-dev/lovely-injector/blob/91759da5702618c3b940fbbe8135954414c0ef34/crates/lovely-core/src/dump.rs#L126) joins the selected Mods path and those exact directory names. The Windows loader also accepts disable-console (lovely-win/src/lib.rs:75), as the existing launcher does.

There is an evidence distinction from 0.10: at core lib.rs:321–322, **0.9 writes the patched buffer to both game-dump and dump**; dump additionally carries patch-debug metadata. Existing 0.10 comments describing game-dump as unpatched must not be carried into the new generation. Continue to bind the canonical patched dump path under lovely/dump, and document both versions' actual behavior. Do not broaden generated-directory exclusions or accept a same-basename file elsewhere.

Before acceptance, staging must record the actual DLL hash for bootstrap and both roles, verify reported native Lovely version, the real Ranked disable check, exact mod/log/dump paths, suppression markers in the actual patched dump, forbidden-network behavior and closed-game save/Steam isolation. The new Steamodded 1620a and companion package must load on this exact injector. All seven native phases and exact-package review remain required; old 0.10 certification cannot establish the new injector's behavior.
