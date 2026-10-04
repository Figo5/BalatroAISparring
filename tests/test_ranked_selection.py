"""Direct Player selection preserves host ownership and independent validation."""
import copy
import tempfile
import test_ranked_draft as f
import test_practice_service as s

rd, ph = f.ranked_draft, f.practice_host


def catalog():
    value = f._catalog()
    value['decks'] = {key: {'center_key': 'b_' + key, 'name': key.title() + ' Deck'} for key in rd.AI_DECK_PREFERENCE}
    value['stakes'] = {key: {'index': index, 'max_index': 8} for key, index in [('white', 1), ('green', 3), ('black', 4), ('blue', 5), ('gold', 8)]}
    value['eligible_decks'] = ['b_' + key for key in value['decks']]
    return value


def selection(clock=None):
    return rd.RankedSelection(catalog(), {'mode': 'normal'}, 'generation', clock=clock or f.FakeClock())


def test_all_combinations_and_real_one_step_commitment():
    value = selection()
    assert len(value.pool) == 75 and len(set(value.pool)) == 75
    assert value.pool[0] == 'red~white'
    value.auto_ai()
    assert value.transcript == [] and value.current_actor() == 'human'
    assert not value.apply('ai', 'ai', 0, 'select', ['red~white'])['ok']
    assert not value.apply('human', 'ban', 0, 'ban', ['red~white'])['ok']
    assert not value.apply('human', 'unknown', 0, 'select', ['invented~white'])['ok']
    assert not value.apply('human', 'stale', 1, 'select', ['red~white'])['ok']
    assert value.apply('human', 'pick', 0, 'select', ['erratic~gold'])['ok']
    assert value.apply('human', 'pick', 0, 'select', ['erratic~gold'])['code'] == 'ranked_draft_replay'
    assert not value.apply('human', 'pick', 0, 'select', ['red~white'])['ok']
    assert value.selection['stake_index'] == 8
    public = value.public_commitment()
    assert public['profile_id'] == rd.DIRECT_PROFILE_ID
    assert public['transcript'] == [{'actor': 'human', 'operation': 'select', 'option_ids': ['erratic~gold']}]
    assert rd.commitment_from_public(public)['ok']
    for display, module in f.RUNTIMES:
        lua, config = f._load_lua(module)
        digest, code, final = config.validate_draft(f._to_lua(lua, public))
        assert (digest, code, final) == (public['digest'], 'ok', 'erratic~gold'), display
        for mutate in (
            lambda x: x.update(first_actor='ai'),
            lambda x: x['transcript'][0].update(actor='ai'),
            lambda x: x['transcript'][0].update(operation='ban'),
            lambda x: x['pool'].append(x['pool'][0]),
            lambda x: x.update(final='red~white'),
            lambda x: x['transcript'][0].update(option_ids=['unknown~white']),
            lambda x: x.update(profile_id=rd.DRAFT_PROFILE_ID),
        ):
            bad = copy.deepcopy(public)
            mutate(bad)
            assert not rd.commitment_from_public(bad)['ok']
            assert config.validate_draft(f._to_lua(lua, bad))[0] is None, display
    assert value.mark_consumed() and not value.mark_consumed()
    expired = selection(f.FakeClock())
    assert expired.apply('human', 'p', 0, 'select', ['red~white'])['ok']
    expired._clock.advance(rd.TTL_SECONDS + 1)
    assert not expired.mark_consumed()
    cancelled = selection()
    assert cancelled.cancel()['ok']
    assert not cancelled.apply('human', 'p', 0, 'select', ['red~white'])['ok']


def test_authenticated_host_selection_and_atomic_launch():
    with tempfile.TemporaryDirectory() as tmp:
        gate = {'ok': False}
        captured = []
        def factory(config, request):
            captured.append(copy.deepcopy(daemon._launch_snapshot))
            return f.FakeSupervisor()
        daemon = f._daemon(tmp, lambda: {'ok': gate['ok'], 'code': ph.CODE_OK}, factory)
        try:
            begin = daemon.handle_request(f._envelope(daemon, 'selection_begin', {'difficulty': 'competitive', 'pacing': 'normal', 'mode': 'normal', 'gauntlet': None}))
            assert begin['ok'], begin
            state = begin['draft']
            assert state['profile_id'] == rd.DIRECT_PROFILE_ID and state['required_count'] == 1
            assert state['operation'] == 'select' and state['banned'] == []
            draft_id = state['draft_id']
            action = {'draft_id': draft_id, 'expected_revision': 0, 'request_id': 'pick', 'operation': 'select', 'option_ids': ['red~white']}
            reply = daemon.handle_request(f._envelope(daemon, 'draft_action', action))
            assert reply['ok'] and reply['draft']['status'] == 'completed', reply
            assert not daemon._op_start(f._start_request(draft_id))['ok']
            assert daemon._completed_draft_snapshot(draft_id) is not None
            gate['ok'] = True
            assert daemon._op_start(f._start_request(draft_id))['code'] == ph.CODE_ACCEPTED
            assert len(captured) == 1
            assert captured[0]['selection']['deck_key'] == 'red'
            assert captured[0]['selection']['stake_index'] == 1
            assert captured[0]['draft']['profile_id'] == rd.DIRECT_PROFILE_ID
            assert daemon._completed_draft_snapshot(draft_id) is None
            assert not daemon._op_start(f._start_request(draft_id))['ok']
        finally:
            with daemon._lock: daemon._ticket = None
            daemon.stop(force=True)


def test_order_seed_metadata_stays_human_only_bounded_and_immutable():
    with tempfile.TemporaryDirectory() as tmp:
        service = s.make_service(tmp)
        session = s.Session(service)
        session.handshake()
        for seed in ('*', '**ABC', 'A*BC', '*A B', 'A\n', '*' + 'A' * 32):
            assert session.send('human', 'status', {'seed': seed})['code'] == s.ps.CODE_BAD_PAYLOAD
        assert session.send('ai', 'status', {'seed': '*9TPSLLA8'})['code'] == s.ps.CODE_BAD_ROLE
        assert session.send('human', 'status', {'seed': '*9TPSLLA8'})['ok']
        assert service._logger.seed == '*9TPSLLA8'
        assert session.send('human', 'status', {'seed': '*9TPSLLA8'})['ok']
        assert session.send('human', 'status', {'seed': '9TPSLLA8'})['code'] == s.ps.CODE_CONFIG_MISMATCH
        service.stop()


if __name__ == '__main__':
    tests = [v for k, v in list(globals().items()) if k.startswith('test_') and callable(v)]
    for case in tests:
        case()
        print('PASS', case.__name__)
