"""Native host launch + session-local DB check, original loopback server, no game."""
import os
from pathlib import Path
import socket
import sys
import tempfile
import time
sys.path.insert(0,str(Path(__file__).resolve().parent))
from astra_host_runner_native import host, hidden_popen, ROOT


def free_port():
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1',0))
        return reservation.getsockname()[1]


def main():
    assert os.name=='nt'
    owned=None
    with tempfile.TemporaryDirectory(prefix='aisp-server-runner-') as temporary:
        folder=Path(temporary)
        session=folder/'session'
        session.mkdir()
        config=host.default_config(ROOT,work_dir=folder,session_root=folder/'sessions',staging_root=folder/'staging',backup_root=folder/'backup',live_install_root=folder/'fake-install',live_appdata_root=folder/'fake-appdata',steam_root=folder/'fake-steam')
        verified=host.verify_server_adaptation(config)
        assert verified['ok'],verified.get('problems')
        node=verified['node_executable']
        assert Path(node).is_absolute()
        match=free_port()
        admin=free_port()
        while admin==match:
            admin=free_port()
        env=host.server_environment(config,match,admin,session_dir=session)
        try:
            owned=host.default_server_runner([node,str(config.server_root/host.SERVER_ENTRY)],session,env,folder/'logs',popen=hidden_popen)
            deadline=time.monotonic()+12
            verdict={}
            while time.monotonic()<deadline:
                assert owned.handle.poll() is None,'owned Node exited early'
                verdict=host.verify_local_listener(match,admin_port=admin,expected_pid=owned.pid,strict=True)
                if verdict['ok']:
                    break
                time.sleep(.05)
            assert verdict.get('ok'),verdict
            assert (session/'data'/'log_hashes.db').is_file(),'session-local database was not created'
            result=owned.terminate(timeout=3)
            assert result['terminated'] and owned.handle.poll() is not None,result
            print('PASS verified pinned Node via actual host runner; exact owning PID, both-family loopback inventory, no admin listener')
            print('PASS original server creates its database in the isolated session working directory; owned cleanup completed')
            print('No Balatro launch, installed files, save data or external connection used')
        finally:
            if owned is not None:
                if owned.job is not None:
                    owned.job.close()
                if owned.handle.poll() is None:
                    owned.handle.kill()
                owned.handle.wait(timeout=5)
    return 0

if __name__=='__main__':
    sys.exit(main())
