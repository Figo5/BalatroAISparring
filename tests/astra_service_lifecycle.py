"""Astra's independent service wire/lifecycle contracts, synthetic files only."""
from pathlib import Path
import tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_practice_service as fixture


def abort_is_visible_to_host():
    with tempfile.TemporaryDirectory() as folder:
        service = fixture.make_service(folder)
        service.abort(fixture.ps.CODE_PRESTART_TIMEOUT)
        assert service.terminal_phase == fixture.ps.TERMINAL_CLOSED
        assert getattr(service, 'aborted', None) is True, 'real service must expose abort to host'
        service.close()


def resolved_seed_has_one_human_author():
    with tempfile.TemporaryDirectory() as folder:
        service = fixture.make_service(folder)
        wire = fixture.Session(service)
        wire.handshake()
        # The actual human runtime knows the resolved run seed only after START.
        first = wire.send('human', 'status', {'seed':'HUMAN123'})
        assert first['ok'] is True, first
        assert wire.send('ai', 'status', {'seed':'AISEED99'})['ok'] is False
        same = wire.send('ai', 'status', {'seed':'HUMAN123'})
        assert same['ok'] is False, 'AI may not author a seed report even when it guesses the same seed'
        assert wire.send('human', 'status', {'seed':'REWRITE9'})['ok'] is False
        service.close()


def terminal_summary_waits_for_receipt():
    with tempfile.TemporaryDirectory() as folder:
        service = fixture.make_service(folder)
        wire = fixture.Session(service)
        wire.handshake()
        response = wire.send('human', 'end', {'result':'draw'})
        assert response['ok']
        path = Path(folder) / 'logs' / 'summary.jsonl'
        rows = fixture.read_jsonl(path) if path.exists() else []
        assert not [row for row in rows if row.get('terminal')], 'human END alone must not write incomplete final summary'
        assert wire.send('ai', 'end', {'result':'draw'})['ok']
        service.close()
        rows = fixture.read_jsonl(path)
        terminal = [row for row in rows if row.get('terminal')]
        assert len(terminal) == 1, terminal
        assert terminal[0]['ai_end_received'] is True, terminal
        assert terminal[0]['result'] == 'draw', terminal



def terminal_session_rejects_first_seed():
    with tempfile.TemporaryDirectory() as folder:
        service=fixture.make_service(folder)
        wire=fixture.Session(service)
        wire.handshake()
        assert wire.send('human','end',{'result':'draw'})['ok']
        assert wire.send('ai','end',{'result':'draw'})['ok']
        late=wire.send('human','status',{'seed':'LATESEED'})
        assert late['ok'] is False, 'a closed session must not accept its first seed after its summary'
        service.close()


def main():
    cases=(abort_is_visible_to_host, resolved_seed_has_one_human_author, terminal_summary_waits_for_receipt, terminal_session_rejects_first_seed)
    failures=0
    for case in cases:
        try:
            case()
            print('PASS',case.__name__)
        except Exception as error:
            failures+=1
            print('FAIL',case.__name__,str(error))
    print(f'{len(cases)-failures}/{len(cases)} independent service contracts passed')
    return bool(failures)

if __name__ == '__main__':
    sys.exit(main())

