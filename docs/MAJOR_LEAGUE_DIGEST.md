# Major League configuration digest (Astra)

Host derives expected rules from pinned staged Multiplayer rulesets/majorleague.lua. The staged coordinator calls the real registry force_lobby_options and reads actual MP.LOBBY.config. No separate hardcoded rule values.

Digest input: ruleset ID, pipe, forced gamemode ID, then each forced config key in bytewise ascending order as pipe + key + equals + primitive value. Booleans use lowercase true/false, integers decimal; bounded strings may not contain pipes, equals or newlines. Hash with existing Codec.hash_string (FNV1a32, eight lowercase hex); Python uses the same algorithm. This is trusted configuration equality, not authentication. Content/probe/certificate boundaries stay separate.

The host helper may strictly parse the pinned primitive config assignments, rejecting any unsupported statement in the entire force_lobby_options body. Alternatively evaluate it in a restricted Lua environment with only a config stub. Derive the forced key set and gamemode from source. Expected registry ID is ruleset_mp_majorleague.

Service expected_config_digest is required before mark_attested. READY must equal it and both roles. SETUP may provide forced keys and expected digest; seed remains human-only. Runtime must compute actual values locally, never echo the expected digest. Reject drift and post-start config changes.
