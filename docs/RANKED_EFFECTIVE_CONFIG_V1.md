# Ranked effective configuration v1

Architecture specification; no implementation/native acceptance is implied. This schema replaces the flat Major League digest for the new Ranked generation. Runtime reads actual engine values; the host independently derives expected values. Neither accepts a caller-supplied configuration or digest as evidence.

## Authoritative sources and fail-closed derivation

Pin by SHA-256 each staged Multiplayer authority file: core.lua, config.lua, rulesets/ranked.lua, rulesets/_rulesets.lua, layers/_layers.lua, layers/standard.lua, layers/ranked.lua, layers/pvp_timer.lua, lib/ruleset_utils.lua, ui/main_menu/play_button/play_button_callbacks.lua, ui/lobby/lobby.lua, networking/action_handlers.lua, and the selected deck/stake registration authorities. Pin approved dependency manifests and the actual injector bytes through staging/certificate measurements. Production pins come from the reviewed dependency generation and must not be replaced by a menu/role request, arbitrary stage manifest or automatic re-recording. Tests may inject their own fixture pins only through explicit test ports unavailable in production.

Parse the actual defaults table and selected layer literal tables with strict bounded syntax. The ruleset must declare exactly the ordered layers standard, ranked, pvp_timer and separately force gamemode_mp_attrition; attrition is a gamemode, not a fourth ruleset layer. Reject unsupported syntax or source byte drift before deriving values. For the pinned start_lobby callback, the reviewed derivations are: multiplayer_jokers follows resolved multiplayer_content; hide_score_until_played follows resolved standard; modifier_layers is the actual empty modifier serialization; disable_live_and_timer_hud is false for attrition; forced_config is the real forcing function's true result. The callback copies cocktail from mod config; the boot event in pinned ZZ_cocktail.lua creates a default Cocktail composition even when Cocktail is not selected. Canonical cocktail is the bounded string of one 1 per eligible deck followed by H, derived from pinned get_cocktail_decks eligibility against both measured role catalogs. Require exact parity and refuse edited composition. Cocktail remains excluded from the draft pool. Pin staged mod config weekly as absent and cocktail as this actual default; derive host and guest expectations separately because host nil values are not sent and guest retains its load-time values. Sleeve and challenge stay at the source-validated ordinary defaults.

Expected deck key/name and stake key/index come from the host-owned completed draft and a catalog validated against both staged roles. Registration-order-sensitive stakes require an independently verified mapping; if a mapping cannot be derived safely from the pinned sources, omit that combination rather than guessing. No live profile determines the pool. Both actual role catalogs must agree before readiness; each selected deck name must map to exactly one actual Back center, refusing ambiguous names. Spectral+ support is conditional on proving its mapping and maximum-stake eligibility; the UI must state the local supported pool accurately.

## Enumerated lobby fields

Every listed key is read after options arrive and checked again before start. Values below are derived from the pinned source, not a substitute for that source. A missing required primitive is an error; explicitly nil fields use a typed nil value. Additional unknown config keys fail closed, except an enumerated engine-only transient allowlist justified by actual source and separately reviewed.

| Key | Type | Expected derivation |
|---|---|---|
| gold_on_life_loss | bool | true default |
| no_gold_on_round_loss | bool | false default |
| death_on_round_loss | bool | true default |
| different_seeds | bool | false default |
| the_order | bool | true Ranked force |
| starting_lives | int | 4 default |
| pvp_start_round | int | 2 default |
| timer_base_seconds | int | 150 default |
| timer_increment_seconds | int | 60 default |
| pvp_countdown_seconds | int | 3 default |
| showdown_starting_antes | int | 3 default |
| weekly | nil | absent after real reset |
| custom_seed | string | random for normal, trusted gauntlet mapping for gauntlet |
| different_decks | bool | false |
| random_loadout | bool | false |
| back | string | actual name mapped from drafted deck key |
| sleeve | string | sleeve_casl_none ordinary default |
| stake | int | actual index mapped from drafted stake key |
| challenge | string | empty ordinary default |
| cocktail | string | actual boot-generated default: one 1 per eligible deck, then H; identical measured role eligibility |
| multiplayer_jokers | bool | true resolved multiplayer_content |
| timer | bool | true default |
| timer_forgiveness | int | 0 default |
| forced_config | bool | true actual forcing result |
| preview_disabled | bool | false default |
| legacy_smallworld | bool | false default |
| hide_score_until_played | bool | true resolved standard |
| enemy_location_disabled | bool | false default |
| timer_display_threshold | int | 0 default |
| modifier_layers | string | empty actual modifier serialization |
| disable_live_and_timer_hud | bool | false actual attrition derivation |
| pvp_timer_base_seconds | nil | no lobby override |
| pvp_timer_hand_played_increment_seconds | nil | no lobby override |
| normal_bosses | nil | no nemesis replacement |
| timer_hand_played_increment_seconds | nil | no ordinary hand timer override |
| timer_base_multiplier | nil | no lobby multiplier override |
| preview_calculate_delay | nil | no Preview delay override |
| preview_calculate_cost | nil | no Preview cost override |

## Resolved engine fields and readiness gates

Include ruleset key, forced gamemode, declared layer order (standard, ranked, pvp_timer), actual active_layer_chain order (standard, ranked, pvp_timer, standard_ranked with no modifiers), standard=true, multiplayer_content=true, actual empty modifier list, resolved PvP base 60 and hand increment 10, effective ordinary base 150, effective timer multipliers 1, and is_disabled=false. Read the same expressions the engine consumes: lobby override if present, otherwise resolved layer scalar and ordinary fallback. Both optional override keys are checked above, so an injected override cannot disappear from the binding. The two PvP values are engine-layer properties, not invented forced lobby keys.

Readiness evidence additionally requires exact compatible Steamodded, the measured official Lovely artifact, release mode, debug disabled, supported speed no greater than 4x, normal animations and forbidden Handy features disabled, exact permitted mod inventory, all_unlocked and applicable centers/blinds/tags unlocked, and Multiplayer's own unlock_check true. Unlock first-use profiles in a dedicated preparation launch, wait for save/events and cleanly exit, then restart for matchmaking: generate_hash runs once per boot. Require own MP.MOD_STRING's parsed unlocked field to be true and peer config.unlocked == true before readiness. Never call generate_hash manually to repair advertising. Report each role's actual MP.INTEGRATIONS.Preview fact and enforce the approved inventory. Each role verifies its own permitted speed; they may choose different legal speeds. Profile names/progress/history, credentials, raw seeds and hidden game state must never be policy inputs or public diagnostics. The trusted gauntlet seed, if used in canonical internal config, stays entirely behind the policy firewall.

## Typed canonical binding

Domain prefix is `aisparring.ranked_effective_config.v1`. Use a fixed enumerated field order (or bytewise sorted names with a tested identical rule) and explicit type tags: nil, boolean, integer, bounded string, and ordered string-list. Nil differs from empty string; booleans differ from string spellings. Strings exclude separators/control characters and are length-bounded. Integers are finite, exact and bounded; no floats/NaN/infinity where the schema requires integers. Normalize a numeric wire string only for the enumerated numeric field where the engine also consumes it numerically (notably stake). Boolean wire values must have gone through the real Multiplayer boolean parse and be actual booleans. Reject every other type mismatch. Host and Lua parity fixtures include nil, empty strings, booleans, stake wire strings, invalid types and reordered layers.

Retain the existing Codec FNV1a-32 primitive only with this new domain-separated canonical input and strict trusted-source/file binding. It is an equality checksum, not a cryptographic authentication mechanism. The authenticated control channel and immutable SHA-256 source/native certificate remain the authority. Do not change the meaning of the legacy major_league_digest field silently; use a new schema/version throughout setup, readiness and reporting.

## Draft and post-start binding

Include the draft profile id, first actor, ordered public pool, ordered legal transcript and final choice. Actors are host-derived human/AI roles, never request input. The host validates the completed transcript; each runtime validates that same bounded public transcript and derives its checksum independently, then matches its final deck/stake against the actual lobby. Do not merely echo an expected digest from SETUP. Only the completed host-owned draft can reserve a launch, once, with atomic consumption after all pre-acknowledgement gates pass and before launch acknowledgement; a failed version/certificate/pre-quit gate preserves the draft, while later launch failure cannot relaunch the consumed draft. Draft TTL is 1800 seconds measured by host monotonic time, with no extension from requests. Cancellation/expiry/restart void unconsumed drafts.

The default published-rules profile has nine combinations and bans 1,2,2, followed by one pick from four remaining; preserve the user's supplied middle counts. Any explicit later user override is a separate named profile. Profile invariant: remaining count at each stage equals pool size minus prior bans, each required count fits, and the final choice is a single remaining combination. A universal two-finalists invariant would contradict this default and is rejected.

Use the scoped post-reset/pre-force wrapper so the first lobby-options message carries the drafted selection. Host and guest both map actual keys/names/indices and refuse any MAX_STAKE clamp, missing center, random_loadout or different_decks. Re-check before READY and START. Once the game actually initializes, each role verifies the selected back's actual center key and G.GAME.stake against the draft, before AI policy activation; a loading frame is retried boundedly, while a real mismatch aborts honestly. No forged state, rules logic replacement or gameplay seed-based draft preference is permitted.

## Required evidence

File mutation causes derivation failure; actual host/guest wire-normalized digests agree; modifier/timer/deck/stake/transcript tampering fails; both real compatibility checks pass; pre-quit checks name incompatible dependencies; post-start actual back/stake agree. Required additional evidence: Cocktail default parity across both roles, legitimate unlock preparation/restart and advertised unlock parity, pre-acknowledgement gate failures preserve the draft, normal_bosses and every override injection fail closed, host/guest nil expectations are derived separately, and the staged install tree has no dwmapi.dll (Lovely 0.9 refuses it). Existing hidden-information, isolation and legal dispatch checks remain mandatory. A new native certificate and exact-package review are required before installation.
