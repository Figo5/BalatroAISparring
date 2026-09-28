"""Actual certificate writer -> companion reader contract, with synthetic files only."""
from pathlib import Path
import importlib
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests")]
import isolation_certificate as ic
import staging
import test_isolation_certificate as fixtures


def main():
    original = ic.write_launcher_attestation
    count = 0

    def checked(staging_root, **kwargs):
        nonlocal count
        result = original(staging_root, **kwargs)
        if not result.get("ok"):
            return result
        roles = ic.certificate_or_empty(staging_root, "mods_layer", "roles")
        for role, filename in result["attestations"].items():
            paths = staging.role_paths(staging_root, role)
            descriptor = {
                "role": role, "session": kwargs["session_id"], "nonce": kwargs["nonce"],
                "control_port": kwargs["control_port"],
                "content_hash": roles[role]["role_parity_digest"],
                "save_root": str(paths.data / "Balatro"), "mods_root": str(paths.mods),
            }
            for runtime in ("lua51", "luajit21"):
                lua = importlib.import_module("lupa." + runtime).LuaRuntime(
                    unpack_returned_tuples=True, register_eval=False, register_builtins=False
                )
                host = lua.execute((ROOT / "AISparring/integration/companion_host.lua").read_text(encoding="utf-8"))
                codec = lua.execute((ROOT / "work/reference/offline/smods-json.lua").read_text(encoding="utf-8"))
                blob = codec.decode(Path(filename).read_text(encoding="utf-8"))
                expected = lua.table_from(descriptor)
                verdict, code = host.check_attestation(blob, expected)
                assert verdict is not None and verdict["ok"] is True, (role, runtime, code)
                expected["nonce"] = "wrong-nonce"
                refused, _ = host.check_attestation(blob, expected)
                assert refused is None, (role, runtime, "wrong nonce accepted")
                count += 2
                print(f"PASS {runtime}/{role}: actual writer accepted; changed nonce refused")
        return result

    ic.write_launcher_attestation = checked
    try:
        fixtures.test_launcher_attestation_derives_inputs_and_writes_atomically()
    finally:
        ic.write_launcher_attestation = original
    assert count == 8, count
    print("8 producer/consumer checks passed; synthetic certificate and temporary files only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
