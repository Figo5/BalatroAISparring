"""Failed Job closure cannot discard a still-live owned process or close its record."""
from pathlib import Path
from types import SimpleNamespace
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import practice_host as host

def main():
    writes = []
    owned = SimpleNamespace(role='human', pid=12345, is_running=lambda: True)
    def failed_close():
        raise OSError('synthetic failed Job close')
    session = SimpleNamespace(owned=[owned], close=failed_close,
                              is_running=lambda: [{'role':'human','pid':12345,'running':True}])
    sup = object.__new__(host.MatchSupervisor)
    sup.session = session
    sup.config = SimpleNamespace(require_certificate=True, staging_root=Path('synthetic'))
    sup.session_id = 'synthetic'
    sup._record_started = True
    sup._certificate_api = SimpleNamespace(record_session_failure=lambda *a, **kw: writes.append(kw))
    sup._stop_server = lambda: None
    sup._stop_service = lambda: None
    sup._finalize = lambda **kw: kw
    sup._finalize_refused_closure('session_closure_unproven')
    assert not writes, 'must not close record while owned human remains running'
    assert sup.session is session, 'must retain ownership until safe closure is proven'
    print('PASS failed_close_preserves_owned_process_and_open_record')

if __name__ == '__main__':
    main()
