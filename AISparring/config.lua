-- AI Sparring companion configuration.
--
-- The repository default is inert. `ai_enabled` stays false and the
-- `companion` descriptor carries no role, so `core.lua` publishes the Milestone
-- 1 scaffold status and loads no new module. The final installer rewrites the
-- *installed copy* of this file to enable exactly one companion configuration.
--
-- No credential, session, control port, seed, path override or policy source is
-- ever placed in this file: `role` and `discovery_path` are install-time
-- locations only (under the gitignored repository work/ tree). The live control
-- secret and the staged launcher descriptors are read from the practice-host
-- discovery marker / launcher environment, never from here. The staged
-- attestation file path is DERIVED from the launcher's expected role save root
-- (`<expected role save root>/aisparring-launcher-attestation.json`), so there is
-- no attestation-path override in the repository configuration.
--
--   role            = "live"   -> installed menu companion: reads the fixed
--                     `discovery_path` marker, talks to the already-running
--                     external practice host over loopback.
--   role            = "staged" -> staged runtime copy: reads the strict
--                     launcher environment descriptors (BALATRO_AI_ROLE,
--                     AISP_EXPECTED_ROLE_SAVE_ROOT/MODS_ROOT, ...) and drives the
--                     trusted RuntimeBootstrap.
--
-- See docs/COMPANION_BOOTSTRAP.md for the exact descriptors and ports.
return {
	ai_enabled = false,
	companion = {
		role = nil,
		discovery_path = nil,
	},
}
