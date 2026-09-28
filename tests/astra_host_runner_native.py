"""Independent native ownership check; launches only a hidden owned Python helper."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'tools'))
import practice_host as host


def hidden_popen(*args, **kwargs):
    kwargs['creationflags']=kwargs.get('creationflags',0) | subprocess.CREATE_NO_WINDOW
    return subprocess.Popen(*args,**kwargs)


def main():
    assert os.name == 'nt'
    owned=None
    with tempfile.TemporaryDirectory(prefix='aisp-owned-server-helper-') as temporary:
        folder=Path(temporary)
        marker=folder/'started.txt'
        executable=str(Path(sys._base_executable).resolve())
        command=[executable,'-c',"import pathlib,sys,time;pathlib.Path(sys.argv[1]).write_text('started');time.sleep(30)",str(marker)]
        env={key:os.environ[key] for key in ('SystemRoot','WINDIR','TEMP','TMP') if key in os.environ}
        try:
            owned=host.default_server_runner(command,folder,env,folder/'logs',popen=hidden_popen)
            assert owned.job is not None and owned.create_time is not None
            assert host._same_image_path(owned.image_path,executable)
            deadline=time.monotonic()+5
            while not marker.exists() and owned.handle.poll() is None and time.monotonic()<deadline:
                time.sleep(.02)
            assert marker.read_text()=='started'
            verdict=owned.terminate(timeout=3)
            assert verdict['terminated'] and owned.handle.poll() is not None,verdict
            print('PASS actual host server runner: suspended child, mandatory Job, retained creation time, exact native image path, owned cleanup')
            print('Only a hidden Python helper was launched/terminated; no game, live files or sockets touched')
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
