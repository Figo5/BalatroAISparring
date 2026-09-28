"""Independent certificate evidence checks using temporary synthetic trees only."""
import sys
import tempfile
from pathlib import Path

import test_isolation_certificate as fixture


def unrelated_text_is_not_runtime_evidence():
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        staged = fixture._stage_all(root)
        phases = fixture._phases(staged)
        junk = root / "unrelated.txt"
        junk.write_text("This is not a game probe, process trace, or live-file manifest.")
        for phase in phases.values():
            phase["evidence_files"] = {"unrelated": junk}
        result = fixture._build(staged, tools_root=root, phases=phases)
        assert not result["ok"], "certificate accepted unrelated text as all five measured phases"


def main():
    failures = 0
    for case in (unrelated_text_is_not_runtime_evidence, preparation_requires_verified_backup):
        try:
            case()
        except Exception as error:
            print(f"FAIL {case.__name__}: {error}")
            failures += 1
        else:
            print(f"PASS {case.__name__}")
    return bool(failures)


def preparation_requires_verified_backup():
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        staged = fixture._stage_all(root)
        result = fixture.ic.prepare_session(
            staged["staging_root"], live=staged["live_map"],
            session_id="no-backup", port=fixture.PORT, closed_check=lambda: True,
        )
        assert not result["ok"], "session preparation accepted without any verified backup"


if __name__ == "__main__":
    sys.exit(main())
