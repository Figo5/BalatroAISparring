"""One-shot orchestration around the reviewed first-install tool.
Only run after final Claude acceptance and successful seven-phase certification.
Default is read-only preflight. No saves are ever restored or overwritten.
"""
from pathlib import Path
import argparse,json,subprocess,sys,time
REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'tools'))
import staging,launch_practice as lp,install_companion as installer,isolation_certificate as ic

# The native certification runner's report for the reviewed commit. The upgrade
# refuses unless its source commit, package digest and certificate ID all equal
# the values this session actually verified, so a report from a different
# source or package can never authorize a live mutation.
NATIVE_REPORT=REPO/'work/local-ownership/native-certification/certificate.json'

def require_native_report(path,reviewed_commit,package_sha256,certificate_id):
    target=Path(path)
    if not target.is_file():
        raise RuntimeError('Native certification report missing: '+str(target))
    report=staging.read_json(target)
    problems=[]
    if not isinstance(report,dict):
        raise RuntimeError('Native certification report unreadable: '+str(target))
    if report.get('source_commit')!=reviewed_commit: problems.append('native_source_commit_mismatch')
    if report.get('package_sha256')!=package_sha256: problems.append('native_package_mismatch')
    if report.get('certificate_id')!=certificate_id: problems.append('native_certificate_mismatch')
    if problems:
        raise RuntimeError('Native certification report mismatch: '+','.join(problems))
    return report

def require(verdict):
    if not isinstance(verdict,dict) or verdict.get('ok') is not True:
        raise RuntimeError(verdict)
    return verdict

def no_game():
    enum=lp.default_enumerator()
    require(lp.check_live_balatro_closed(enum,staging.DEFAULT_INSTALL))
    require(lp.check_no_staged_session(enum,staging.DEFAULT_STAGING_ROOT,live_install_root=staging.DEFAULT_INSTALL))

def write(path,value):
    path.write_text(json.dumps(value,indent=2,default=str),encoding='utf-8')

def safe_write(path,value,errors=None):
    """Best-effort diagnostics write: a failure is reported but never raised."""
    try:
        write(path,value)
        return None
    except Exception as exc:
        message=type(exc).__name__+': '+str(exc)
        # The warning itself is best-effort: a broken stderr must never escape
        # (it would skip the rollback and replace the original failure).
        try:
            print('WARN upgrade evidence write failed: '+str(path)+' :: '+message,file=sys.stderr,flush=True)
        except Exception:
            pass
        if isinstance(errors,list):
            errors.append({'path':str(path),'error':message})
        return message

def outside_companion(snapshot):
    result={}
    for key,entry in snapshot['roots'].items():
        files=entry['files']
        if key=='appdata':
            files={k:v for k,v in files.items() if not k.startswith('Mods/AISparring/')}
        result[key]=files
    return result

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--acceptance',type=Path,required=True)
    parser.add_argument('--reviewed-commit',required=True)
    parser.add_argument('--native-report',type=Path,default=NATIVE_REPORT)
    parser.add_argument('--execute',action='store_true')
    args=parser.parse_args()
    tip=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO).decode().strip()
    if tip!=args.reviewed_commit: raise RuntimeError('Source commit differs from reviewed commit')
    if subprocess.check_output(['git','status','--porcelain'],cwd=REPO): raise RuntimeError('Tracked/untracked source changes require review')
    no_game()
    live=staging.live_roots();mods=Path(live['appdata'])/'Mods';target=mods/installer.TARGET_NAME
    mods,target=installer.resolve_install_target(mods,target,live=live,overlap_roots={
        'staging':staging.DEFAULT_STAGING_ROOT,'package':installer.DEFAULT_PACKAGE_ROOT,
        'backup':staging.DEFAULT_BACKUP_ROOT})
    staging.assert_no_links(mods,'live Mods')
    if target.resolve()!=staging.default_live_appdata().resolve()/'Mods'/'AISparring': raise RuntimeError('Unexpected live target')
    if not target.is_dir(): raise RuntimeError('Existing companion required for this upgrade procedure')
    package=require(installer.verify_package())
    acceptance=require(installer.load_acceptance(args.acceptance,package['digest']))
    certificate=require(ic.check_certificate(staging.DEFAULT_STAGING_ROOT,live=live))
    if acceptance['reference']['certificate_id']!=certificate['certificate_id']: raise RuntimeError('Review/certificate mismatch')
    manifest=staging.read_json(installer.DEFAULT_PACKAGE_ROOT/installer.PACKAGE_MANIFEST_NAME)
    expected,code=installer._live_files_from_verified_manifest(installer.DEFAULT_PACKAGE_ROOT,manifest['digest'],prefix='live/AISparring/')
    if code!='ok': raise RuntimeError(code)
    # Refuse archiving a companion changed since this session's recovery. The
    # recovered old manifest is bound to the recovered receipt's pinned package
    # digest: a later self-consistent repackage (old manifest and installed bytes
    # replaced together) recomputes a different digest and is refused, and a
    # missing/invalid pin can never bypass the gate. No digest logic is
    # duplicated here; the existing verified-manifest checker does it.
    recovered=staging.read_json(REPO/'work/local-ownership/recovery-state.json')
    receipt=recovered.get('installed_receipt') if isinstance(recovered,dict) else None
    old_manifest_path=receipt.get('package_manifest') if isinstance(receipt,dict) else None
    old_pinned_digest=receipt.get('package_sha256') if isinstance(receipt,dict) else None
    if not isinstance(old_manifest_path,str) or not old_manifest_path \
            or not isinstance(old_pinned_digest,str) or not old_pinned_digest:
        raise RuntimeError('Recovered package pin missing; investigate first')
    old_expected,old_code=installer._live_files_from_verified_manifest(
        Path(old_manifest_path).parent,old_pinned_digest,prefix='live/AISparring/')
    if old_code!='ok': raise RuntimeError('Recovered old package binding failed: '+str(old_code))
    old_hashes=staging.hash_tree(target)
    if old_hashes!=old_expected: raise RuntimeError('Installed companion changed since recovery; investigate first')
    # The native certificate report must describe exactly this reviewed source and
    # the package/certificate this session verified, before any live operation.
    require_native_report(args.native_report,args.reviewed_commit,manifest['digest'],certificate['certificate_id'])
    print(json.dumps({'ok':True,'execute':args.execute,'source_commit':tip,'target':str(target),'package_sha256':manifest['digest'],'certificate_id':certificate['certificate_id'],'old_files':len(old_hashes)}),flush=True)
    if not args.execute: return
    timestamp=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
    out=REPO/'work/local-ownership'/('upgrade-'+timestamp)
    if out.exists(): raise RuntimeError('Fresh upgrade evidence directory required')
    out.mkdir()
    no_game();before=ic.snapshot_live(live);write(out/'before.json',before)
    no_game();first=require(lp.create_live_backup(execute=True,label=timestamp+'-pre-upgrade'))
    require(lp.check_backup_evidence(staging.DEFAULT_BACKUP_ROOT,{k:Path(v) for k,v in live.items() if k in ('install','appdata') or k.startswith('steam_userdata/')}))
    write(out/'backup-before.json',first)
    write(out/'backup-before-manifest.json',staging.read_json(staging.DEFAULT_BACKUP_ROOT/lp.BACKUP_MANIFEST_NAME))
    archive_root=REPO/'backups'/'companion-archives'
    installer._assert_clean_root(REPO/'backups','backup archive anchor')
    staging.assert_no_links(REPO/'backups','backup archive anchor')
    archive_root.mkdir(exist_ok=True)
    archive=archive_root/(timestamp+'-AISparring')
    if not staging.is_within(REPO/'backups',archive,allow_root=False) or archive.exists(): raise RuntimeError('Unsafe archive destination')
    staging.assert_no_links(archive_root,'archive parent')
    # Protection begins BEFORE the first irreversible live step. The live rename
    # and the archive evidence write are inside this block, so an archive-evidence
    # failure restores the target instead of leaving it absent. `archived` records
    # whether the rename actually happened, so a failed rename never triggers an
    # unsafe restoration attempt.
    archived=False
    installed=False
    try:
        no_game()
        if staging.hash_tree(target)!=old_hashes: raise RuntimeError('Old companion changed before archival')
        target.rename(archive)
        archived=True
        write(out/'archive.json',{'source':str(target),'archive':str(archive),'files':old_hashes})
        if staging.hash_tree(archive)!=old_hashes: raise RuntimeError('Archive integrity failure')
        no_game();second=require(lp.create_live_backup(execute=True,label=timestamp+'-post-archive'))
        write(out/'backup-after-archive.json',second)
        write(out/'backup-after-archive-manifest.json',staging.read_json(staging.DEFAULT_BACKUP_ROOT/lp.BACKUP_MANIFEST_NAME))
        # Forward the already verified resolved live Mods root, owned target and
        # live mapping, using the installer's real keyword names. The installer
        # refuses a missing live_mods_root (mods_root_required): omitting these
        # made the actual upgrade fail safely after archiving the old companion.
        no_game();dry=installer.install_companion(acceptance_path=args.acceptance,live_mods_root=mods,target_dir=target,live=live,execute=False)
        write(out/'installer-dry-run.json',dry);require(dry)
        no_game();executed=installer.install_companion(acceptance_path=args.acceptance,live_mods_root=mods,target_dir=target,live=live,execute=True)
        require(executed)
        # The install is committed now; later diagnostics failures must never
        # roll back over the installed target.
        installed=True
        write(out/'installer-executed.json',executed)
        if staging.hash_tree(target)!=expected: raise RuntimeError('Installed/package hash mismatch')
        after=ic.snapshot_live(live);write(out/'after.json',after)
        if outside_companion(before)!=outside_companion(after): raise RuntimeError('A live root outside the companion changed; investigate without restoring saves')
        write(out/'verified.json',{'ok':True,'source_commit':tip,'package_sha256':manifest['digest'],'certificate_id':certificate['certificate_id'],'archive':str(archive),'install':executed})
        print('PASS verified installation: '+str(out),flush=True)
    except BaseException as error:
        # BaseException scope only around the protected archival/install block:
        # a Ctrl-C (or SystemExit) after the rename must still restore the
        # verified archive, and the original exception must survive. Failure
        # diagnostics are best-effort: they never prevent rollback or obscure
        # the original error.
        errors=[]
        safe_write(out/'failure.json',{'error':str(error),'installed':installed,'archived':archived,'archive':str(archive)},errors)
        rollback=[]
        if archived and not installed:
            if target.exists():
                # Never overwrite an existing target or remove partial installer
                # content; the archive stays safely intact.
                rollback.append('refused: target already present')
            else:
                try:
                    no_game()
                    staging.assert_no_links(mods,'rollback Mods')
                    if staging.hash_tree(archive)!=old_hashes:
                        raise RuntimeError('Refuse restoring changed archive')
                    archive.rename(target)
                    if staging.hash_tree(target)!=old_hashes:
                        raise RuntimeError('Rollback verification failed')
                    safe_write(out/'rollback.json',{'ok':True,'target':str(target),'files':old_hashes},errors)
                except BaseException as rollback_error:
                    rollback.append(type(rollback_error).__name__+': '+str(rollback_error))
        if rollback or errors:
            safe_write(out/'rollback-failure.json',{'rollback':rollback,'evidence':errors,'archived':archived,'installed':installed,'archive':str(archive)})
        # Preserve the original failure and its traceback.
        raise

if __name__=='__main__': main()
