"""Windows listener proof using only our loopback socket and owned Python peer.

No Balatro, live files, external network or installed mods are used.
"""
from pathlib import Path
import os
import socket
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import launch_practice as lp

def main():
    assert os.name == 'nt', 'Windows native check'
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    listener = lp.MeasurementListener(port, mode='P2_CLOSE')
    peer = None
    try:
        started = listener.start()
        assert started.get('ok'), started
        code = (
            'import socket,sys; '
            's=socket.create_connection(("127.0.0.1",int(sys.argv[1])),timeout=20); '
            's.sendall(b\'{"action":"astra_native_probe"}\\n\'); '
            's.recv(1); s.close()'
        )
        peer = subprocess.Popen([getattr(sys, '_base_executable', sys.executable), '-I', '-c', code, str(port)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        listener.arm([peer.pid])
        deadline = time.monotonic() + 40
        while not listener._done.is_set() and time.monotonic() < deadline:
            time.sleep(0.1)
        assert listener._done.is_set(), 'listener deadline'
        state = listener.finish()
        assert state['peer_pid'] == peer.pid, state
        assert state['peer_is_owned_ai'] is True, state
        assert state['fin'] is True and state['sent_bytes'] == 0, state
        output, errors = peer.communicate(timeout=5)
        assert peer.returncode == 0, errors.decode(errors='replace')
        fields = listener.log_fields('astra-native-helper-only', 'P2_CLOSE')
        assert fields['received_bytes'] > 0, fields
        print('PASS real Windows both-family inventory, exact owned peer PID, FIN and zero sends')
    finally:
        listener.finish(timeout=2)
        if peer is not None:
            if peer.poll() is None:
                peer.kill()
            peer.communicate(timeout=5)

if __name__ == '__main__':
    main()
