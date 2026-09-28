"""Real Windows peer EOF is distinct from release by the measurement listener.

Owned Python peer and loopback only. No Balatro or live files.
"""
from pathlib import Path
import os
import socket
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import launch_practice as lp

def until(predicate, message):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(message)

def main():
    assert os.name == 'nt'
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    listener = lp.MeasurementListener(port, mode='P2_SILENT')
    peer = None
    try:
        started = listener.start()
        assert started.get('ok'), started
        code = ('import socket,sys; '
                's=socket.create_connection(("127.0.0.1",int(sys.argv[1])),timeout=20); '
                's.sendall(b\'{"action":"astra_silent_probe"}\\n\'); '
                'sys.stdin.readline(); s.close()')
        peer = subprocess.Popen([getattr(sys, '_base_executable', sys.executable), '-I', '-c', code, str(port)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        listener.arm([peer.pid])
        until(lambda: listener._state.get('peer_is_owned_ai') is True, 'owned peer not verified')
        peer.stdin.write(b'close\n')
        peer.stdin.flush()
        until(lambda: listener._state.get('peer_eof') is True, 'peer EOF not observed')
        assert listener._state.get('open_until') is None, 'peer EOF must not claim tool release'
        assert not listener._state.get('closed') and not listener._state.get('fin'), listener._state
        # Production event times are recorded to six decimal places.
        release = round(time.time(), 6)
        state = listener.finish()
        assert state.get('open_until') >= release, (release, state)
        assert state.get('open_until') >= state.get('eof_time'), state
        assert not state.get('peer_reset') and state.get('sent_bytes') == 0, state
        peer.wait(timeout=5)
        assert peer.returncode == 0
        print('PASS native SILENT peer EOF retained independently of tool release, zero sends')
    finally:
        listener.finish(timeout=2)
        if peer is not None:
            if peer.poll() is None:
                peer.kill()
            peer.communicate(timeout=5)

if __name__ == '__main__':
    main()
