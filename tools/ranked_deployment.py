"""Pinned minimal Ranked dependencies and independently bound native profile evidence.

No live dependency/save writes. Preparation uses the existing suspended/owned
launcher, never constructs a game runtime, and unlocks only through game UI.
"""
from pathlib import Path
import argparse, json, secrets, shutil, subprocess, sys, time
import staging
import launch_practice as lp
import ruleset_contract

REPO = Path(__file__).resolve().parents[1]
PINS = REPO / 'docs/RANKED_DEPENDENCIES_V1.json'
POLICY = staging.HashPolicy(exclude_dirnames=('.git', '.github', '__pycache__'))
DLL = REPO / 'work/ranked-audit/dependencies/version-0.9.0.dll'
REPORT = 'aisparring-ranked-preparation.json'
READY = 'ranked-profile-ready.json'
REQUIRED = ('release_mode', 'debug_disabled', 'animations_normal', 'handy_disabled',
            'content_unlocked', 'unlock_check', 'advertised_unlocked', 'game_speed_ok', 'tutorial_ready')
APPROVED = {'Steamodded-1.0.0~BETA': '1620a', 'Lovely': '0.9.0',
            'Multiplayer': '0.5.5', 'AISparring-0.1.0': 'dev',
            'lovely-compat-aisparring-staging': '0.0.0'}

def pins():
    return json.loads(PINS.read_text(encoding='utf-8'))

def verify_sources():
    p = pins()
    if p['schema'] != 'aisparring.ranked_dependencies.v1': raise RuntimeError('ranked_dependency_schema')
    for spec in p['sources'].values():
        source = staging.assert_within(REPO / 'work', REPO / spec['path'])
        staging.assert_no_links(source, 'Ranked dependency')
        if staging.hash_tree(source, POLICY) != spec['files']: raise RuntimeError('ranked_dependency_drift')
    if staging.sha256_file(DLL) != p['lovely_sha256']: raise RuntimeError('ranked_injector_drift')
    return p

def assemble(destination):
    """Copy only fixed reviewed file sets, refusing replacement or extra files."""
    p = verify_sources()
    dest = staging.assert_safe_write(REPO / 'work', destination, 'Ranked private dependencies')
    if dest.exists(): raise RuntimeError('ranked_dependency_target_exists')
    for name, spec in p['sources'].items():
        for rel in spec['files']:
            target = staging.assert_safe_write(dest, dest / name / rel)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / spec['path'] / rel, target)
        if staging.hash_tree(dest / name) != spec['files']: raise RuntimeError('ranked_dependency_copy_mismatch')
    return dest

def install_injector(root, roles=('bootstrap', 'human', 'ai')):
    """Only fresh staged installs before their manifests/receipts are finalized."""
    p = verify_sources()
    if list((Path(root) / 'evidence/receipts').glob('*.json')): raise RuntimeError('ranked_injector_after_measurement')
    enum = lp.default_enumerator()
    if not lp.check_live_balatro_closed(enum, staging.DEFAULT_INSTALL)['ok']: raise RuntimeError('live_balatro_running')
    if not lp.check_no_staged_session(enum, root, staging.DEFAULT_INSTALL)['ok']: raise RuntimeError('staged_balatro_running')
    for role in roles:
        paths = staging.bootstrap_paths(root) if role == 'bootstrap' else staging.role_paths(root, role)
        target = staging.assert_safe_write(root, paths.install / 'version.dll')
        if (paths.install / 'dwmapi.dll').exists(): raise RuntimeError('ranked_conflicting_injector')
        _retire_previous_injector(root, paths, p['previous_winmm_sha256'])
        shutil.copyfile(DLL, target)
        if staging.sha256_file(target) != p['lovely_sha256']: raise RuntimeError('ranked_injector_copy_mismatch')
        if role == 'bootstrap':
            # Preserve the bootstrap's own policy and exact expected patch data.
            old = staging.read_json(paths.root / staging.MANIFEST_NAME)
            old['files'] = staging.hash_tree(paths.root, staging.policy_from_dict(old['policy']))
            staging.write_json(paths.root / staging.MANIFEST_NAME, old, staging_root=root)
        else:
            staging.finalize_role(root, role)

def _retire_previous_injector(root, paths, expected_hash):
    """Archive only the recognized copied 0.10 DLL, never the live DLL."""
    previous = staging.assert_safe_write(root, paths.install / 'winmm.dll')
    if not previous.exists(): return
    if staging.sha256_file(previous) != expected_hash: raise RuntimeError('ranked_previous_injector_unknown')
    archive = staging.assert_safe_write(root, Path(root) / 'evidence/injector-replacement' / paths.role / 'winmm.dll')
    if archive.exists(): raise RuntimeError('ranked_injector_archive_exists')
    archive.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(previous, archive)
    if staging.sha256_file(archive) != expected_hash: raise RuntimeError('ranked_injector_archive_mismatch')
    previous.unlink()

def generation(root):
    return staging._digest_of({role: staging._role_immutable_state(root, role) for role in staging.ROLES})

def validate_report(report, role, nonce):
    if report.get('schema') != 'aisparring.ranked_preparation.v1': raise RuntimeError('ranked_preparation_schema')
    if report.get('nonce') != nonce or report.get('role') != role: raise RuntimeError('ranked_preparation_identity')
    if report.get('mods') != APPROVED: raise RuntimeError('ranked_preparation_inventory')
    if any(report.get(key) is not True for key in REQUIRED): return False
    result = ruleset_contract.build_ranked_catalog(report.get('catalog'), report.get('catalog'))
    if not result.get('ok'): raise RuntimeError('ranked_preparation_catalog')
    return True

def load_ready(root):
    """Host-owned evidence only. Refuse stale source, staged code or role parity."""
    root = Path(root)
    record = staging.read_json(root / 'evidence' / READY)
    if record.get('schema') != 'aisparring.ranked_profile_ready.v1': raise RuntimeError('ranked_profiles_unprepared')
    if record.get('generation') != generation(root): raise RuntimeError('ranked_preparation_generation_drift')
    if record.get('pins_sha256') != staging.sha256_file(PINS): raise RuntimeError('ranked_preparation_pins_drift')
    catalogs = {}
    for role in staging.ROLES:
        if not staging.verify_staged_role(root, role).get('ok'): raise RuntimeError('ranked_preparation_staging_drift')
        evidence = record['roles'][role]
        path = staging.assert_within(root / 'evidence', root / evidence['path'])
        if staging.sha256_file(path) != evidence['sha256']: raise RuntimeError('ranked_preparation_evidence_drift')
        measured = staging.read_json(path)
        if measured.get('native') is not True or measured.get('clean_exit') is not True or not measured.get('zero_live_diff'):
            raise RuntimeError('ranked_preparation_unmeasured')
        if not validate_report(measured['report'], role, measured['nonce']): raise RuntimeError('ranked_profile_not_unlocked')
        catalogs[role] = measured['report']['catalog']
    if not ruleset_contract.build_ranked_catalog(catalogs['human'], catalogs['ai']).get('ok'):
        raise RuntimeError('ranked_catalog_role_parity')
    return {'ranked_catalog': catalogs['human'], 'ranked_guest_catalog': catalogs['ai'], 'ranked_generation': record['generation']}

def prepare(role, root):
    root = Path(root)
    # A valid seven-phase certificate is required for interactive preparation.
    # This deliberately cannot substitute a fake preparation for certification.
    plan = lp.build_launch_plan(staging_root=root, port=8788)
    if not plan.get('may_launch'): raise RuntimeError('profile_preparation_blocked:' + ','.join(plan['blocked']))
    plan['roles'] = {role: plan['roles'][role]}
    paths = staging.role_paths(root, role)
    nonce = secrets.token_hex(16)
    out = staging.assert_safe_write(root, root / 'evidence/profile-preparation' / nonce)
    out.mkdir(parents=True)
    before = staging.measure_isolation_state(root)
    expected_generation = generation(root)
    report_path = paths.data / 'Balatro' / REPORT
    if report_path.exists():
        shutil.copyfile(report_path, out / 'previous-report.json')
        staging.assert_safe_write(root, report_path).unlink()
    def spawn(*args, **kwargs):
        kwargs['env'] = dict(kwargs['env'], AISP_PROFILE_PREPARE='1')
        return subprocess.Popen(*args, **kwargs)
    session = lp._spawn_verified(plan, spawn, lp.read_owned_create_time, lp.default_enumerator(),
                                 staging.DEFAULT_INSTALL, root, nonce=nonce)
    if not session.ok: raise RuntimeError(session.code)
    print(json.dumps({'state':'profile_preparation_open', 'role':role, 'pid':session.records[0].pid}), flush=True)
    try:
        previous = None
        while any(item.is_running() for item in session.owned):
            if report_path.is_file():
                try:
                    report = staging.read_json(report_path)
                    ready = validate_report(report, role, nonce)
                    state = (ready, report.get('content_unlocked'), report.get('advertised_unlocked'))
                    if state != previous:
                        print(json.dumps({'role':role,'ready_after_restart':ready,'unlocked_now':state[1],
                                          'advertised_unlocked':state[2]}), flush=True)
                        previous = state
                except (ValueError, OSError): pass  # atomic reader retry while game writes
            time.sleep(0.5)
        codes = [item.handle.poll() for item in session.owned]
        if codes != [0]: raise RuntimeError('profile_preparation_not_clean_exit')
        report = staging.read_json(report_path)
        ready = validate_report(report, role, nonce)
        after = staging.measure_isolation_state(root)
        if before['live'] != after['live'] or before['roles'] != after['roles']:
            raise RuntimeError('profile_preparation_isolation_changed')
        probes = staging.collect_role_probes(paths, nonce, session.spawn_time, require_mp=True, expected_port=8788)
        if not probes['ok']: raise RuntimeError('profile_preparation_probe_unproven:' + ','.join(probes['problems']))
        measured = {'native':True,'clean_exit':True,'zero_live_diff':True,'nonce':nonce,'generation':expected_generation,
                    'records':session.to_dict()['records'],'report':report,'before':before,'after':after,'probes':probes}
        evidence_path = out / 'measurement.json'
        staging.write_json(evidence_path, measured, staging_root=root)
        if ready:
            ready_path = root / 'evidence' / READY
            record = staging.read_json(ready_path) if ready_path.exists() else {'schema':'aisparring.ranked_profile_ready.v1', 'roles':{}}
            if record.get('generation') not in (None, expected_generation): raise RuntimeError('ranked_preparation_generation_changed')
            record.update(generation=expected_generation, pins_sha256=staging.sha256_file(PINS))
            record['roles'][role] = {'path':evidence_path.relative_to(root).as_posix(),'sha256':staging.sha256_file(evidence_path)}
            staging.write_json(ready_path, record, staging_root=root)
        print(json.dumps({'role':role,'clean_exit':True,'ready_after_restart':ready,'evidence':str(evidence_path)}), flush=True)
    finally:
        session.close()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('sources', 'prepare', 'ready'))
    parser.add_argument('--role', choices=staging.ROLES)
    parser.add_argument('--staging-root', type=Path, default=staging.DEFAULT_STAGING_ROOT)
    args = parser.parse_args()
    if args.command == 'sources':
        p = verify_sources(); print(json.dumps({'ok':True,'files':sum(len(s['files']) for s in p['sources'].values())}))
    elif args.command == 'prepare':
        if args.role is None: parser.error('--role required')
        prepare(args.role, args.staging_root)
    else:
        ready = load_ready(args.staging_root); print(json.dumps({'ok':True,'generation':ready['ranked_generation']}))
    return 0

if __name__ == '__main__': raise SystemExit(main())
