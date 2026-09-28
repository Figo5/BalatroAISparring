"""Independent fail-closed measurement-listener checks; no real socket or thread."""
from pathlib import Path
import os
import sys
import threading
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'tools'))
import launch_practice as launcher

class FakeSocket:
    def __init__(self): self.closed=False
    def setsockopt(self,*args): pass
    def bind(self,endpoint): assert endpoint==('127.0.0.1',39123)
    def listen(self,*args): pass
    def close(self): self.closed=True

class FakeSockets:
    AF_INET=2
    SOCK_STREAM=1
    SOL_SOCKET=1
    SO_EXCLUSIVEADDRUSE=4
    def __init__(self): self.instance=FakeSocket()
    def socket(self,*args): return self.instance

class NoThreads:
    Event=threading.Event
    class Thread:
        def __init__(self,*args,**kwargs): pass
        def start(self): pass
        def join(self,*args,**kwargs): pass


def main():
    failures=0
    for name,inventory in [('unavailable_or_empty',[]),('foreign_owner',[{'pid':os.getpid()+1000000}])]:
        sockets=FakeSockets()
        listener=launcher.MeasurementListener(39123,mode='P2_CLOSE',inventory=lambda port:inventory,socket_mod=sockets,threading_mod=NoThreads)
        try:
            result=listener.start()
            assert result.get('ok') is False, f'{name} cannot positively prove the tool owns the listener: {result}'
            assert sockets.instance.closed,'refused listener must be closed'
            print('PASS',name)
        except Exception as error:
            failures+=1
            print('FAIL',name,str(error))
    class BrokenFin:
        def settimeout(self,*args): pass
        def recv(self,*args): raise TimeoutError('drain complete')
        def shutdown(self,*args): raise OSError('shutdown did not succeed')
        def close(self): pass
    class Accepted:
        def settimeout(self,*args): pass
        def accept(self): return BrokenFin(),('127.0.0.1',49123)
        def close(self): pass
    sockets=FakeSockets()
    sockets.SHUT_WR=1
    listener=launcher.MeasurementListener(39123,mode='P2_CLOSE',owner_lookup=lambda *args:12345,socket_mod=sockets,threading_mod=NoThreads)
    listener._server=Accepted()
    listener.arm([12345])
    try:
        listener._serve()
        assert listener._state.get('fin') not in (True,'true'), 'failed shutdown cannot be recorded as successful FIN'
        fields=listener.log_fields('synthetic-nonce','P2_CLOSE')
        assert fields.get('fin') not in (True,'true')
        print('PASS failed_fin_is_not_claimed')
    except Exception as error:
        failures+=1
        print('FAIL failed_fin_is_not_claimed',str(error))
    return bool(failures)

if __name__=='__main__':
    sys.exit(main())
