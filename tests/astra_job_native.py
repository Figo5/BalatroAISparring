"""Exercise suspended launch/Job ownership with one harmless owned Python helper.

Never enumerates, opens, launches, or terminates Balatro. Cleanup uses only the
Popen handle and Job created in this test.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import launch_practice as launcher


def main():
    assert os.name == "nt", "Native Job acceptance requires Windows"
    job = launcher.JobObject.create()
    assert job is not None, "Job Object creation failed"
    process = None
    with tempfile.TemporaryDirectory(prefix="aisp-job-check-") as temporary:
        marker = Path(temporary) / "owned-helper-started.txt"
        try:
            process = subprocess.Popen(
                [sys.executable, "-c", "import pathlib,sys,time;pathlib.Path(sys.argv[1]).write_text('started');time.sleep(30)", str(marker)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=launcher.CREATE_SUSPENDED | subprocess.CREATE_NO_WINDOW,
            )
            owned = launcher.OwnedProcess("native-fixture", process, process.pid, None, sys.executable, job=job)
            assert not marker.exists(), "Helper ran before being assigned to its Job"
            assert job.assign(process), "Job assignment failed"
            created = launcher.read_owned_create_time(owned)
            assert isinstance(created, float) and abs(created - time.time()) < 15, "Retained-handle identity unavailable"
            assert launcher._resume_process(process), "Owned process could not resume"
            deadline = time.monotonic() + 5
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            assert marker.read_text() == "started", "Resumed helper did not execute"
            result = owned.terminate(timeout=3)
            assert result["terminated"] and process.poll() is not None, result
            print("PASS native suspended launch -> Job assignment -> retained-handle identity -> resume")
            print("PASS owned Job cleanup; only this test's harmless Python helper was terminated")
        finally:
            job.close()
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
