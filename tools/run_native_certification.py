"""Consolidated native certification orchestrator. Run only after final review.

The runner is importable and side-effect free: the real work happens in
``main``. It is pinned to an explicit reviewed commit and refuses a wrong HEAD
or any tracked/untracked source change before it creates an attempt directory,
after packaging and again at the end. Every packaged module file in each live
and staged subtree (excluding only the generated top-level ``config.lua``) is
bound to the reviewed commit's Git blobs by exact relative file set, byte size
and SHA256, on top of the real package verification. An existing attempt
directory is never overwritten; failed evidence is preserved.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, shutil, sys, time

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))
import staging, launch_practice as lp, install_companion as installer, isolation_certificate as ic

ROOT = staging.DEFAULT_STAGING_ROOT
DEFAULT_OUT = REPO / "work" / "local-ownership" / "native-certification"
SOURCE_SUBTREE = installer.TARGET_NAME
CONFIG_NAME = installer.CONFIG_NAME


def git_bytes(repo, args):
    return subprocess.check_output(["git", *args], cwd=str(repo))


def git_head(repo):
    return git_bytes(repo, ["rev-parse", "HEAD"]).decode("utf-8", "replace").strip()


def git_status(repo):
    return git_bytes(repo, ["status", "--porcelain"]).decode("utf-8", "replace")


def require_reviewed_source(repo, commit, stage):
    """Refuse a wrong HEAD or any tracked/untracked change; read-only."""
    head = git_head(repo)
    if head != commit:
        raise RuntimeError("reviewed_commit_mismatch:%s:head=%s" % (stage, head))
    if git_status(repo).strip():
        raise RuntimeError("source_dirty:" + stage)


def reviewed_source_manifest(repo, commit):
    """Exact relative file set of ``AISparring/`` at ``commit`` with blob size+sha256.

    The recorded bytes are the commit's canonical blobs (what ``git cat-file``
    returns). A repository with ``core.autocrlf`` checked out converts line
    endings in the working tree, so the byte comparison also accepts a file whose
    ``git hash-object`` (with its path attributes) reproduces the reviewed blob.
    """
    listing = git_bytes(repo, ["ls-tree", "-r", commit, "--", SOURCE_SUBTREE]).decode("utf-8", "replace")
    manifest = {}
    for line in listing.splitlines():
        if not line.strip():
            continue
        meta, _, path = line.partition("\t")
        fields = meta.split()
        if len(fields) < 3:
            continue
        oid = fields[2]
        key = path[len(SOURCE_SUBTREE) + 1:] if path.startswith(SOURCE_SUBTREE + "/") else path
        data = git_bytes(repo, ["cat-file", "blob", oid])
        manifest[key] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "oid": oid}
    return manifest


def _git_blob_id(repo, rel, data):
    """The blob id git would store for ``data`` at ``AISparring/<rel>`` (filters applied)."""
    result = subprocess.run(
        ["git", "hash-object", "--path", SOURCE_SUBTREE + "/" + rel, "--stdin"],
        cwd=str(repo), input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "replace").strip()


def _relative_files(root):
    return {
        path.relative_to(root).as_posix(): path
        for path in sorted(Path(root).rglob("*"))
        if path.is_file()
    }


def bind_package_sources(package_root, expected_modules, repo, roles=installer.STAGED_ROLES):
    """Bind each live/staged subtree's module files to the reviewed Git blobs.

    Uses the established ``verify_package`` verdict *and* re-hashes the actual
    package bytes, so neither an unverified manifest nor an arbitrary ``ok``
    flag can stand in for the real file set. Only the generated top-level
    ``config.lua`` is allowed to differ from the reviewed blobs.
    """
    root = Path(package_root)
    expected = {rel: meta for rel, meta in expected_modules.items() if rel != CONFIG_NAME}
    problems = []
    verdict = installer.verify_package(root)
    if not isinstance(verdict, dict) or verdict.get("ok") is not True:
        problems.append("package_unverified:" + str(verdict.get("code") if isinstance(verdict, dict) else verdict))
    prefixes = ["live/%s/" % installer.TARGET_NAME]
    for role in roles:
        prefixes.append("staged/%s/%s/" % (role, installer.TARGET_NAME))
    for prefix in prefixes:
        subtree = root.joinpath(*prefix.strip("/").split("/"))
        files = _relative_files(subtree) if subtree.is_dir() else {}
        modules = {rel: path for rel, path in files.items() if rel != CONFIG_NAME}
        if set(modules) != set(expected):
            problems.append("file_set_mismatch:" + prefix)
            continue
        if CONFIG_NAME not in files:
            problems.append("config_missing:" + prefix)
        for rel, want in sorted(expected.items()):
            data = modules[rel].read_bytes()
            if len(data) == want["size"] and hashlib.sha256(data).hexdigest() == want["sha256"]:
                continue
            if _git_blob_id(repo, rel, data) == want["oid"]:
                continue
            problems.append("byte_mismatch:" + prefix + rel)
    problems = sorted(set(problems))
    return {
        "ok": not problems,
        "code": "ok" if not problems else "package_source_mismatch",
        "problems": problems,
        "modules": len(expected),
    }


def verify_final_package(package_root, original_digest, source_manifest, repo,
                         staging_root=None, expected_roles=None):
    """Final pin: the package must still be the reviewed one after the long run.

    Re-reads the package against the digest captured at packaging time (the
    established verified-manifest pin checker refuses a manifest that was swapped
    together with its files), re-runs the reviewed-source binding on the current
    bytes, and re-binds the staging area to the original immutable expected
    roles. A package replaced self-consistently during the run is refused here,
    before any successful certificate report can be written.
    """
    problems = []
    subset, code = installer._live_files_from_verified_manifest(package_root, original_digest)
    if code != "ok" or not subset:
        problems.append("package_pin:" + str(code))
    binding = bind_package_sources(package_root, source_manifest, repo)
    if not binding.get("ok"):
        problems.append("source_binding:" + binding.get("code", "mismatch"))
    if staging_root is not None and expected_roles is not None:
        staged = installer.package_staging_binding(staging_root, expected_roles)
        if not staged.get("ok"):
            problems.append("staged_binding:" + str(staged.get("code", "mismatch")))
    problems = sorted(set(problems))
    return {
        "ok": not problems,
        "code": "ok" if not problems else "final_package_mismatch",
        "problems": problems,
        "package_digest": original_digest,
    }


def no_game():
    enum = lp.default_enumerator()
    gate = lp.check_live_balatro_closed(enum, staging.DEFAULT_INSTALL)
    assert gate.get("ok"), gate
    gate = lp.check_no_staged_session(enum, ROOT, live_install_root=staging.DEFAULT_INSTALL)
    assert gate.get("ok"), gate


def run(out, repo, name, args):
    no_game()
    started = time.time()
    print("START " + name, flush=True)
    result = subprocess.run([sys.executable, *args], cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out / (name + ".json")).write_bytes(result.stdout)
    (out / (name + ".stderr.txt")).write_bytes(result.stderr)
    assert result.returncode == 0, {"step": name, "exit": result.returncode,
                                    "tail": result.stdout.decode("utf-8", "replace")[-3000:]}
    print("PASS " + name + " " + str(round(time.time() - started, 2)) + "s", flush=True)
    return json.loads(result.stdout.decode("utf-8-sig"))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Reviewed native certification orchestrator")
    parser.add_argument("--reviewed-commit", required=True, help="exact reviewed commit SHA")
    parser.add_argument("--repo", type=Path, default=REPO)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--ranked-dependencies", action="store_true", help="fixed minimal Ranked-compatible staged dependencies")
    args = parser.parse_args(argv)
    repo = Path(args.repo)
    out = Path(args.out)

    # Refuse a wrong/moved HEAD or any source change BEFORE any output, staging
    # root, native process or package mutation.
    require_reviewed_source(repo, args.reviewed_commit, "start")
    if out.exists():
        raise RuntimeError("Refuse to overwrite an existing attempt directory: " + str(out))
    source_manifest = reviewed_source_manifest(repo, args.reviewed_commit)
    out.mkdir(parents=True)

    no_game()
    assert not ROOT.exists(), "Fresh certification root required; never overwrite old evidence"
    assert not installer.DEFAULT_PACKAGE_ROOT.exists(), "Fresh package required"
    backup = run(out, repo, "backup-initial", ["tools/launch_practice.py", "backup", "--execute"])
    # Fresh private source copy excludes exactly our already-installed companion.
    # Other mods are copied from live and hash-checked. No live content is moved.
    live_mods = staging.default_live_appdata() / "Mods"
    private_mods = repo / "work" / "local-ownership" / "native-mods-source"
    assert not private_mods.exists(), "Refuse replacing private Mods source"
    staging.assert_no_links(live_mods, "live Mods source")

    def omit_companion(dirpath, names):
        return [installer.TARGET_NAME] if Path(dirpath).resolve() == live_mods.resolve() and installer.TARGET_NAME in names else []

    no_game()
    if args.ranked_dependencies:
        import ranked_deployment
        ranked_deployment.assemble(private_mods)
    else:
        shutil.copytree(live_mods, private_mods, ignore=omit_companion)
        expected = {k: v for k, v in staging.hash_tree(live_mods, staging.MODS_HASH_POLICY).items()
                    if not k.startswith(installer.TARGET_NAME + "/")}
        assert staging.hash_tree(private_mods, staging.MODS_HASH_POLICY) == expected, "Other Mods source differs from live"
    run(out, repo, "bootstrap-stage", ["tools/staging.py", "bootstrap"])
    run(out, repo, "role-stage", ["tools/staging.py", "stage", "--mods-source", str(private_mods)])
    if args.ranked_dependencies:
        no_game()
        ranked_deployment.install_injector(ROOT)
        (out / "ranked-dependencies.json").write_text(json.dumps({"pins_sha256":staging.sha256_file(ranked_deployment.PINS),
            "lovely_sha256":ranked_deployment.pins()["lovely_sha256"], "live_dependencies_changed":False}, indent=2))
    pack = run(out, repo, "package", ["tools/install_companion.py", "package"])
    assert installer.verify_package(installer.DEFAULT_PACKAGE_ROOT).get("ok")
    # Bind the packaged module files to the reviewed commit's blobs, on top of
    # the real package verification, before any measurement receipt.
    binding = bind_package_sources(installer.DEFAULT_PACKAGE_ROOT, source_manifest, repo)
    assert binding.get("ok"), binding
    (out / "source-binding.json").write_text(json.dumps({"source_commit": args.reviewed_commit,
        "source_blobs": source_manifest, "binding": binding}, indent=2))
    require_reviewed_source(repo, args.reviewed_commit, "post-package")
    # Finalize exact intended companion bytes BEFORE any measurement receipt.
    assert not list((ROOT / "evidence/receipts").glob("*.json"))
    assert not ic.list_open_records(ROOT)
    manifest = staging.read_json(installer.DEFAULT_PACKAGE_ROOT / installer.PACKAGE_MANIFEST_NAME)
    expected_roles = {}
    for role in ("human", "ai"):
        no_game()
        paths = staging.role_paths(ROOT, role)
        target = staging.assert_safe_write(ROOT, paths.mods / installer.TARGET_NAME, "final packaged companion")
        assert not target.exists(), "No existing staged companion may be replaced"
        source = installer.DEFAULT_PACKAGE_ROOT / "staged" / role / installer.TARGET_NAME
        staging.assert_no_links(source, "package source")
        subtree, code = installer._live_files_from_verified_manifest(
            installer.DEFAULT_PACKAGE_ROOT, manifest["digest"], prefix="staged/%s/%s/" % (role, installer.TARGET_NAME))
        assert code == "ok", code
        expected_roles[role] = subtree
        shutil.copytree(source, target)
        staging.finalize_role(ROOT, role)
        assert staging.verify_staged_role(ROOT, role)["ok"]
    assert installer.package_staging_binding(ROOT, expected_roles).get("ok")
    (out / "package-binding.json").write_text(json.dumps(
        {"package_sha256": manifest["digest"], "binding": installer.package_staging_binding(ROOT, expected_roles)}, indent=2))
    run(out, repo, "P1A", ["tools/launch_practice.py", "bootstrap", "--execute"])
    for phase in ("P1B", "FULL_P1", "CRASH", "P2_INITIAL", "P2_CLOSE", "P2_SILENT"):
        run(out, repo, "backup-" + phase, ["tools/launch_practice.py", "backup", "--execute"])
        run(out, repo, phase, ["tools/launch_practice.py", "measure", "--phase", phase])
    no_game()
    ids = ic.collect_phase_receipts(ROOT)
    live = staging.live_roots()
    built = ic.build_certificate(ROOT, receipt_ids=ids, live=live, port=8788)
    assert built.get("ok"), built
    checked = ic.check_certificate(ROOT, live=live)
    assert checked.get("ok"), checked
    assert installer.verify_package(installer.DEFAULT_PACKAGE_ROOT).get("ok")
    # Final pin against the digest captured at packaging time, plus a fresh
    # source binding and the original staged binding. A package (or manifest)
    # swapped during the long run must refuse before the report is written.
    final = verify_final_package(installer.DEFAULT_PACKAGE_ROOT, manifest["digest"], source_manifest,
                                 repo, staging_root=ROOT, expected_roles=expected_roles)
    assert final.get("ok"), final
    require_reviewed_source(repo, args.reviewed_commit, "end")
    report = {
        "receipts": ids,
        "build": built,
        "check": checked,
        "package_sha256": manifest["digest"],
        "source_commit": args.reviewed_commit,
        "source_blobs": source_manifest,
        "source_manifest_digest": staging._digest_of(source_manifest),
        "certificate_id": built.get("certificate_id"),
        "final_binding": final,
    }
    (out / "certificate.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps({k: report[k] for k in ("source_commit", "package_sha256", "certificate_id")}, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
