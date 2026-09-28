"""A server-side tuple identifies the listener; peer ownership needs its reverse."""
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import launch_practice as lp

def main():
    class UnreadableHandle:
        def poll(self):
            raise OSError('synthetic query failure')
    owned = lp.OwnedProcess('ai', UnreadableHandle(), 12345, 1.0, 'synthetic.exe')
    try:
        running = owned.is_running()
    except OSError:
        pass  # Propagated uncertainty also refuses a closed-process claim.
    else:
        assert running is True, 'a failed retained-handle query cannot prove exit'
    print('PASS unreadable_owned_handle_does_not_prove_exit')
    commands = []
    def query(args, **kwargs):
        command = args[-1]
        commands.append(command)
        client_side = '-LocalPort 49123' in command and '-RemotePort 39123' in command
        return SimpleNamespace(returncode=0, stderr='', stdout='{"OwningProcess": %d}' % (12345 if client_side else 54321))
    with patch.object(lp.subprocess, 'run', query):
        pid = lp._default_tcp_owner(39123, 49123)
    assert pid == 12345, f'queried listener PID {pid} instead of AI peer PID: {commands}'
    print('PASS peer_pid_uses_client_side_endpoint_tuple')

if __name__ == '__main__':
    main()
