"""Native listener inventory check using only this process's loopback sockets."""
import os
from pathlib import Path
import socket
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import practice_host as host


def main():
    assert os.name == "nt", "Native listener acceptance requires Windows"
    probe = host.WindowsTcpTableProbe()
    count = 0
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserved_admin:
        reserved_admin.bind(("127.0.0.1", 0))
        admin_port = reserved_admin.getsockname()[1]
        for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
            with socket.socket(family, socket.SOCK_STREAM) as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                listener.bind((address, 0))
                listener.listen(1)
                port = listener.getsockname()[1]
                measured = probe.probe(port)
                assert measured["listening"] and address in measured["addresses"], measured
                assert os.getpid() in measured["pids"], measured
                result = host.verify_local_listener(port, admin_port, probe=probe, expected_pid=os.getpid())
                assert result["ok"], result
                rejected = host.verify_local_listener(port, admin_port, probe=probe, expected_pid=os.getpid() + 100_000_000)
                assert not rejected["ok"] and "match_listener_not_owned" in rejected["problems"], rejected
                count += 1
                print(f"PASS native {address}: exact listener address, owning PID, inactive admin, wrong-owner refusal")
            assert not probe.probe(port)["listening"], "Owned socket remained open"
    print(f"{count} native loopback checks passed; all owned sockets closed; no game started")
    return 0


if __name__ == "__main__":
    sys.exit(main())
