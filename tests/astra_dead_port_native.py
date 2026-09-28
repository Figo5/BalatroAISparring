"""Actual Windows refused-loopback probe; no game, server, or live files."""
from pathlib import Path
import json
import os
import socket
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import launch_practice as lp


def main():
    assert os.name == 'nt', 'Windows native check'
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    evidence = lp._default_port_probe(port)
    print(json.dumps(evidence, sort_keys=True))
    assert evidence['listener_absent'] == {'ipv4': True, 'ipv6': True}, evidence
    assert evidence['refused'] is True and evidence['timed_out'] is False, evidence
    assert evidence['attempts'] == evidence['refused_attempts'] == 3, evidence
    assert evidence['timed_out_attempts'] == 0 and evidence['error'] is None, evidence
    print('PASS native unused-loopback port: three actual refusals, no timeout claims')


if __name__ == '__main__':
    main()
