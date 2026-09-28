#!/usr/bin/env python3
"""Staged practice launcher: fail-closed gates, owned-process cleanup, no live writes.

This tool plans and verifies a two-role staged bootstrap (human practice + AI
practice). It never launches while native isolation is unproven, never writes to
the live Balatro installation or live %AppData%\\Balatro, and never terminates a
process by executable name alone.

Containment rules enforced here:
- a launch is refused while any staged ``Balatro.exe`` is already running, so two
  sessions cannot share a save directory or port;
- rollback only ever touches processes this launcher spawned, tracked by the exact
  ``Popen`` handle / Windows Job Object plus the recorded create time and image
  path, and the image path must resolve inside the staging root;
- a successful spawn returns a live ``LaunchSession`` that retains those exact
  handles; the CLI supervises until every owned process exits (or an explicit
  timeout), and the outer practice host keeps the session for the match. Handles are
  never serialized;
- cleanup reopens the process once with a native handle, revalidates create time and
  image path on that same handle, and terminates that handle, so no PID-reuse window
  remains;
- the user's live game is identified by full image path and is never a target, so
  the parent game is never killed;
- process enumeration fails closed: a ``Balatro`` process whose path cannot be read
  aborts the launch instead of being silently skipped;
- on Windows every child starts suspended and is owned by a Job Object before it may
  run: there is no unsuspended ``Popen`` retry, and a launch is refused outright when
  the mandatory Job Object cannot be created, so a wrapper that rejects
  ``creationflags`` fails closed instead of starting an unsupervised process;
- ``build_bootstrap_plan`` gates on pre-run bootstrap preflight, not on post-run
  probe evidence, so a first bootstrap is not deadlocked on its own output. The
  post-run evidence check is a separate, nonce- and time-bound step.

``execute_*`` never trusts a caller-supplied ``may_launch``: the plan is re-derived
from disk immediately before spawning.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import staging  # noqa: E402
import isolation_certificate  # noqa: E402

BACKUP_MANIFEST_NAME = "BACKUP_MANIFEST.json"
BACKUP_ENTRY_SCHEMA = "aisparring.backup_entry.v1"
BACKUP_SCHEMA = "aisparring.backup_manifest.v1"
SESSION_SCHEMA = "aisparring.launch_session.v1"
START_TIME_TOLERANCE = 2.0
PROBE_NONCE_VAR = "AISP_PROBE_NONCE"
BALATRO_NAMES = frozenset({"balatro", "balatro.exe"})

# Strict, typed per-role session descriptor. The outer practice host supplies
# exactly these six extra child-environment values; they cannot redirect a role's
# paths, Lovely/Steam settings or the measured isolation proof state. The session
# id, credential, content hash and probe nonce are opaque bounded tokens; the
# control port is a validated loopback int; the expected save root is checked
# against the role's staged save directory, never used as a redirect.
SESSION_ENV_KEYS = {
    "session_id": "AISP_SESSION_ID",
    "role_credential": "AISP_ROLE_CREDENTIAL",
    "control_port": "AISP_CONTROL_PORT",
    "content_hash": "AISP_CONTENT_HASH",
    "probe_nonce": "AISP_PROBE_NONCE",
    "expected_role_save_root": "AISP_EXPECTED_ROLE_SAVE_ROOT",
    "expected_role_mods_root": "AISP_EXPECTED_ROLE_MODS_ROOT",
    "mode": "AISP_MODE",
    "difficulty": "AISP_DIFFICULTY",
    "pacing": "AISP_PACING",
    "gauntlet": "AISP_GAUNTLET",
}
SESSION_ENV_FIELDS = tuple(SESSION_ENV_KEYS)
# One shared, colon-free session grammar with the certificate module (NM7).
SESSION_ID_PATTERN = isolation_certificate.SESSION_ID_RE
SESSION_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_.:+/=-]{16,256}$")
SESSION_HASH_PATTERN = re.compile(r"^[A-Za-z0-9:._-]{8,256}$")
_SESSION_PROTECTED_PREFIXES = ("STEAM", "SDL", "LOVELY", "PYTHON")

# Trusted setup enums delivered through the typed descriptor. They are validated
# against these exact values so a role cannot inject arbitrary configuration; the
# secret gauntlet seed is never here and is served by the authenticated service
# ``setup`` op instead.
DESCRIPTOR_MODES = ("normal", "gauntlet")
DESCRIPTOR_DIFFICULTIES = ("rookie", "competitive", "major_league")
DESCRIPTOR_PACING = ("instant", "normal")
DESCRIPTOR_GAUNTLET = ("Test1", "Test2", "Test3", "Test4", "Test5")

PROCESS_TERMINATE = 0x0001
PROCESS_SET_QUOTA = 0x0100
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
SYNCHRONIZE = 0x00100000
CREATE_SUSPENDED = 0x00000004
WAIT_OBJECT_0 = 0x00000000
STILL_ACTIVE = 259
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000

ISO_RE = re.compile(
    r"^(?P<body>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(?P<frac>\d+))?(?P<tz>Z|[+-]\d{2}:?\d{2})?$"
)

_WIN_KERNEL32 = None


@dataclass(frozen=True)
class ProcessInfo:
    pid: int
    create_time: float
    image_path: str
    name: str = ""


@dataclass(frozen=True)
class ProcessRecord:
    role: str
    pid: int
    create_time: float
    image_path: str
    session_id: str
    exe_sha256: str = ""


@dataclass(frozen=True)
class SessionDescriptor:
    """Typed per-role control descriptor, not an arbitrary environment dict.

    The outer practice host builds one of these per staged role. Only the six
    values in :data:`SESSION_ENV_KEYS` reach the child; the descriptor carries no
    path, Lovely, Steam or proof override, and the launcher rejects anything that
    is not an instance of this exact type.
    """

    role: str
    session_id: str
    role_credential: str
    control_port: int
    content_hash: str
    probe_nonce: str
    expected_role_save_root: str
    expected_role_mods_root: str
    mode: str
    difficulty: str
    pacing: str
    gauntlet: str


def session_env_overrides(descriptor: "SessionDescriptor") -> dict:
    """The exact allowlisted environment mapping for one descriptor."""
    return {
        "AISP_SESSION_ID": descriptor.session_id,
        "AISP_ROLE_CREDENTIAL": descriptor.role_credential,
        "AISP_CONTROL_PORT": str(int(descriptor.control_port)),
        "AISP_CONTENT_HASH": descriptor.content_hash,
        "AISP_PROBE_NONCE": descriptor.probe_nonce,
        "AISP_EXPECTED_ROLE_SAVE_ROOT": descriptor.expected_role_save_root,
        "AISP_EXPECTED_ROLE_MODS_ROOT": descriptor.expected_role_mods_root,
        "AISP_MODE": descriptor.mode,
        "AISP_DIFFICULTY": descriptor.difficulty,
        "AISP_PACING": descriptor.pacing,
        "AISP_GAUNTLET": descriptor.gauntlet,
    }


def session_env_collisions(paths) -> list:
    """Defensive drift alarm: no session key may shadow a protected role value."""
    protected = {str(key).upper() for key in staging.role_environment_overrides(paths)}
    collisions: list = []
    for field, name in SESSION_ENV_KEYS.items():
        upper = name.upper()
        if upper in protected or upper.startswith(_SESSION_PROTECTED_PREFIXES):
            collisions.append(f"{field}:{name}")
    return collisions


def session_descriptor_problems(descriptor, paths, nonce: str, expected_session_id: str = None) -> list:
    """Bounded problems for a descriptor bound to ``paths`` and the session nonce."""
    problems: list = []
    if not isinstance(descriptor, SessionDescriptor):
        return ["session_descriptor_required"]
    if descriptor.role != getattr(paths, "role", None):
        problems.append("session_descriptor_role_mismatch")
    if not isinstance(descriptor.session_id, str) or not SESSION_ID_PATTERN.match(descriptor.session_id):
        problems.append("session_descriptor_bad_session")
    elif expected_session_id is not None and descriptor.session_id != expected_session_id:
        problems.append("session_descriptor_session_mismatch")
    credential = descriptor.role_credential
    if not isinstance(credential, str) or not SESSION_TOKEN_PATTERN.match(credential):
        problems.append("session_descriptor_bad_credential")
    if isinstance(descriptor.control_port, bool) or not isinstance(descriptor.control_port, int):
        problems.append("session_descriptor_bad_control_port")
    elif not (1 <= descriptor.control_port <= 65535):
        problems.append("session_descriptor_bad_control_port")
    if not isinstance(descriptor.content_hash, str) or not SESSION_HASH_PATTERN.match(descriptor.content_hash):
        problems.append("session_descriptor_bad_content_hash")
    if not isinstance(descriptor.probe_nonce, str) or not SESSION_ID_PATTERN.match(descriptor.probe_nonce):
        problems.append("session_descriptor_bad_probe_nonce")
    elif descriptor.probe_nonce != nonce:
        problems.append("session_descriptor_nonce_mismatch")
    expected = descriptor.expected_role_save_root
    if not isinstance(expected, str) or not _same_path(expected, Path(paths.data) / "Balatro"):
        problems.append("session_descriptor_bad_save_root")
    expected_mods = descriptor.expected_role_mods_root
    if not isinstance(expected_mods, str) or not _same_path(expected_mods, Path(paths.mods)):
        problems.append("session_descriptor_bad_mods_root")
    if descriptor.mode not in DESCRIPTOR_MODES:
        problems.append("session_descriptor_bad_mode")
    if descriptor.difficulty not in DESCRIPTOR_DIFFICULTIES:
        problems.append("session_descriptor_bad_difficulty")
    if descriptor.pacing not in DESCRIPTOR_PACING:
        problems.append("session_descriptor_bad_pacing")
    if descriptor.mode == "gauntlet":
        if descriptor.gauntlet not in DESCRIPTOR_GAUNTLET:
            problems.append("session_descriptor_bad_gauntlet")
    elif descriptor.gauntlet != "":
        problems.append("session_descriptor_bad_gauntlet")
    if session_env_collisions(paths):
        problems.append("session_env_collision")
    return problems


class ProcessEnumerator:
    def list(self) -> list:
        raise NotImplementedError


class UnavailableProcessEnumerator(ProcessEnumerator):
    def __init__(self, reason: str = "process_enumeration_unavailable") -> None:
        self.reason = reason

    def list(self) -> list:
        raise staging.StagingError(self.reason)


POWERSHELL_ENUMERATION = (
    "Get-Process -ErrorAction SilentlyContinue | ForEach-Object { "
    "$s=$null; try { $s=$_.StartTime.ToUniversalTime().ToString('o') } catch {}; "
    "$p=$null; try { $p=$_.Path } catch {}; "
    "[PSCustomObject]@{ pid=$_.Id; name=$_.ProcessName; path=$p; start=$s } } | "
    "ConvertTo-Json -Compress"
)


def is_balatro_name(name) -> bool:
    return str(name or "").strip().lower() in BALATRO_NAMES


def process_is_balatro(info: ProcessInfo) -> bool:
    if getattr(info, "name", ""):
        return is_balatro_name(info.name)
    return Path(info.image_path or "").name.lower() in BALATRO_NAMES


def parse_process_json(text: str) -> list:
    """Parse ``Get-Process`` JSON. Fail closed for a Balatro process with no path."""
    text = (text or "").strip()
    if not text:
        return []
    try:
        parsed = json.loads(text)
    except ValueError as error:
        raise staging.StagingError("process_enumeration_unparsable", str(error))
    if isinstance(parsed, dict):
        parsed = [parsed]
    results: list = []
    for item in parsed:
        if not isinstance(item, Mapping):
            continue
        pid = item.get("pid")
        if not isinstance(pid, int):
            continue
        name = str(item.get("name") or "")
        path = item.get("path") or ""
        path = str(path)
        balatro = is_balatro_name(name) or Path(path).name.lower() in BALATRO_NAMES
        if balatro and not path:
            raise staging.StagingError(
                "process_enumeration_incomplete",
                f"pid {pid} is named Balatro but has no readable image path",
            )
        start = item.get("start")
        try:
            create_time = parse_iso_epoch(start) if start else 0.0
        except ValueError:
            create_time = 0.0
        results.append(
            ProcessInfo(pid=pid, create_time=create_time, image_path=path, name=name)
        )
    return results


class PowerShellProcessEnumerator(ProcessEnumerator):
    """Best-effort Windows enumeration of pid/name/path/start time. Fails closed."""

    def __init__(self, timeout: float = 20.0) -> None:
        self.timeout = timeout

    def list(self) -> list:
        try:
            completed = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command", POWERSHELL_ENUMERATION],
                capture_output=True,
                text=True,
                timeout=self.timeout,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise staging.StagingError("process_enumeration_failed", str(error))
        if completed.returncode != 0:
            raise staging.StagingError(
                "process_enumeration_failed",
                (completed.stderr or "").strip()[:200] or f"exit {completed.returncode}",
            )
        return parse_process_json(completed.stdout or "")


def default_enumerator() -> ProcessEnumerator:
    if os.name == "nt":
        return PowerShellProcessEnumerator()
    return UnavailableProcessEnumerator("process_enumeration_unsupported_platform")


def parse_iso_epoch(value: str) -> float:
    match = ISO_RE.match(value.strip())
    if not match:
        raise ValueError(value)
    fraction = (match.group("frac") or "")[:6].ljust(6, "0")
    zone = match.group("tz") or "+00:00"
    if zone == "Z":
        zone = "+00:00"
    elif ":" not in zone:
        zone = zone[:3] + ":" + zone[3:]
    return datetime.fromisoformat(f"{match.group('body')}.{fraction}{zone}").timestamp()


def _same_path(first, second) -> bool:
    if not first or not second:
        return False
    try:
        left = os.path.normcase(str(Path(first).resolve()))
        right = os.path.normcase(str(Path(second).resolve()))
    except OSError:
        return os.path.normcase(str(first)) == os.path.normcase(str(second))
    return left == right


def is_live_install_path(image_path, live_install_root) -> bool:
    if not image_path:
        return False
    path = Path(image_path)
    if path.name.lower() != "balatro.exe":
        return False
    root = Path(live_install_root)
    if _same_path(path, root / "Balatro.exe"):
        return True
    return staging.is_within(root, path, allow_root=False)


def _win_kernel32():
    global _WIN_KERNEL32
    if os.name != "nt":
        return None
    if _WIN_KERNEL32 is not None:
        return _WIN_KERNEL32
    try:
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateJobObjectW.restype = wintypes.HANDLE
        kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        kernel32.SetInformationJobObject.restype = wintypes.BOOL
        kernel32.SetInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel32.TerminateJobObject.restype = wintypes.BOOL
        kernel32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.CloseHandle.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.TerminateProcess.restype = wintypes.BOOL
        kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel32.WaitForSingleObject.restype = wintypes.DWORD
        kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel32.GetExitCodeProcess.restype = wintypes.BOOL
        kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel32.GetProcessTimes.restype = wintypes.BOOL
        kernel32.GetProcessTimes.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
        ]
        kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
        kernel32.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD),
        ]
        _WIN_KERNEL32 = kernel32
    except Exception:
        _WIN_KERNEL32 = False
    return _WIN_KERNEL32 or None


class _JobBasicLimitInformation(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64),
        ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", ctypes.c_uint32),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", ctypes.c_uint32),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", ctypes.c_uint32),
        ("SchedulingClass", ctypes.c_uint32),
    ]


class _IoCounters(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_uint64),
        ("WriteOperationCount", ctypes.c_uint64),
        ("OtherOperationCount", ctypes.c_uint64),
        ("ReadTransferCount", ctypes.c_uint64),
        ("WriteTransferCount", ctypes.c_uint64),
        ("OtherTransferCount", ctypes.c_uint64),
    ]


class _JobExtendedLimitInformation(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", _JobBasicLimitInformation),
        ("IoInfo", _IoCounters),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


def _process_handle_value(popen_handle):
    value = getattr(popen_handle, "_handle", None)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


class JobObject:
    """Windows Job Object with kill-on-close, so owned processes are never orphaned."""

    def __init__(self, handle=None) -> None:
        self._handle = handle
        self.assigned = 0

    @classmethod
    def create(cls):
        kernel32 = _win_kernel32()
        if kernel32 is None:
            return None
        try:
            handle = kernel32.CreateJobObjectW(None, None)
            if not handle:
                return None
            job = cls(handle)
            if not job._set_kill_on_close():
                job.close()
                return None
            return job
        except Exception:
            return None

    def _set_kill_on_close(self) -> bool:
        kernel32 = _win_kernel32()
        if kernel32 is None or not self._handle:
            return False
        info = _JobExtendedLimitInformation()
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        return bool(
            kernel32.SetInformationJobObject(
                self._handle,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                ctypes.byref(info),
                ctypes.sizeof(info),
            )
        )

    def assign(self, popen_handle) -> bool:
        kernel32 = _win_kernel32()
        if kernel32 is None or not self._handle:
            return False
        target = _process_handle_value(popen_handle)
        opened = False
        if target is None:
            pid = getattr(popen_handle, "pid", None)
            if pid is None:
                return False
            target = kernel32.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, False, int(pid))
            if not target:
                return False
            opened = True
        try:
            ok = bool(kernel32.AssignProcessToJobObject(self._handle, target))
        except Exception:
            ok = False
        finally:
            if opened:
                kernel32.CloseHandle(target)
        if ok:
            self.assigned += 1
        return ok

    def terminate(self, exit_code: int = 1) -> bool:
        kernel32 = _win_kernel32()
        if kernel32 is None or not self._handle:
            return False
        try:
            return bool(kernel32.TerminateJobObject(self._handle, int(exit_code)))
        except Exception:
            return False

    def close(self) -> None:
        kernel32 = _win_kernel32()
        if kernel32 is not None and self._handle:
            try:
                kernel32.CloseHandle(self._handle)
            except Exception:
                pass
        self._handle = None


@dataclass
class OwnedProcess:
    role: str
    handle: object
    pid: int
    create_time: Optional[float]
    image_path: str
    exe_sha256: str = ""
    job: Optional[object] = None

    def is_running(self) -> bool:
        try:
            return self.handle.poll() is None
        except Exception:  # noqa: BLE001
            # A failed retained-handle query is uncertainty, not proof of exit.
            # Claiming "exited" here would let a live owned process be treated as
            # gone; fail closed by treating an unreadable handle as still running.
            return True

    def _wait(self, timeout: float) -> None:
        try:
            self.handle.wait(timeout=timeout)
        except Exception:
            pass

    def terminate(self, timeout: float = 10.0, exit_code: int = 1) -> dict:
        if self.job is not None:
            try:
                self.job.terminate(exit_code)
            except TypeError:
                self.job.terminate()
            except Exception:
                pass
        self._wait(timeout)
        if self.is_running():
            try:
                self.handle.kill()
            except Exception:
                pass
            self._wait(timeout)
        terminated = not self.is_running()
        if self.job is not None:
            try:
                self.job.close()
            except Exception:
                pass
            self.job = None
        return {"role": self.role, "pid": self.pid, "terminated": terminated}


def _terminate_owned_handles(owned: Sequence[OwnedProcess], on_terminate=None, exit_code: int = 1) -> list:
    """Terminate only launcher-owned handles. Never a bare, unverified PID.

    ``exit_code`` is the tool-owned end code written through the Job Object, so the
    measured exit code is a deliberate tool decision (N2/N3), never the ambiguous
    TerminateJobObject default.
    """
    actions: list = []
    for process in reversed(list(owned)):
        action = process.terminate(exit_code=exit_code)
        if on_terminate is not None:
            try:
                on_terminate(process)
            except Exception:  # noqa: BLE001
                pass
        actions.append(action)
    return actions


class LaunchSession:
    """Retained live ownership of a successful spawn: Popen handles + Job Objects.

    Handles are held only in-process and are never serialized. ``to_dict`` yields
    the JSON-safe view (records, nonce, spawn time, session file). A supervising
    host must keep this object alive for the match and call ``close`` at session
    end; the kill-on-close Job Object then guarantees no staged child is orphaned.
    """

    def __init__(
        self,
        session_id: str,
        staging_root,
        records: Sequence[ProcessRecord],
        owned: Sequence[OwnedProcess],
        nonce: str,
        spawn_time: float,
        session_file=None,
        code: str = "launched",
        blocked: Optional[Sequence[str]] = None,
        rollback: Optional[Mapping] = None,
        extra: Optional[Mapping] = None,
    ) -> None:
        self.session_id = session_id
        self.staging_root = Path(staging_root)
        self.records = list(records)
        self.owned = list(owned)
        self.nonce = nonce
        self.spawn_time = spawn_time
        self.session_file = Path(session_file) if session_file else None
        self.code = code
        self.blocked = list(blocked or ())
        self.rollback = dict(rollback) if rollback else None
        self.extra = dict(extra) if extra else {}
        # Tool-owned end (N2/N3): set by ``supervise_session`` when it ends a run
        # after the required evidence has settled. Never inferred from an exit code.
        self.end_mode = None
        self.end_code = None
        self.ended_unix = None

    @property
    def ok(self) -> bool:
        return self.code == "launched"

    @property
    def handles(self) -> tuple:
        return tuple(self.owned)

    def is_running(self) -> list:
        return [{"role": item.role, "pid": item.pid, "running": item.is_running()} for item in self.owned]

    def poll(self) -> list:
        return self.is_running()

    def terminate(self, timeout: float = 10.0, exit_code: int = 1) -> list:
        return _terminate_owned_handles(self.owned, None, exit_code=exit_code)

    def close(self) -> None:
        for item in self.owned:
            if item.job is not None:
                try:
                    item.job.close()
                except Exception:
                    pass
                item.job = None

    def to_dict(self) -> dict:
        payload = dict(self.extra)
        payload.update(
            {
                "ok": self.ok,
                "code": self.code,
                "session_id": self.session_id,
                "staging_root": str(self.staging_root),
                "records": [asdict(record) for record in self.records],
                "nonce": self.nonce,
                "spawn_time": self.spawn_time,
            }
        )
        if self.session_file is not None:
            payload["session_file"] = str(self.session_file)
        if self.blocked:
            payload["blocked"] = list(self.blocked)
        if self.rollback is not None:
            payload["rolled_back"] = bool(self.rollback.get("rolled_back"))
            payload["termination"] = list(self.rollback.get("termination", []))
        return payload

    def __getitem__(self, key):
        return self.to_dict()[key]

    def get(self, key, default=None):
        return self.to_dict().get(key, default)

    def __contains__(self, key) -> bool:
        return key in self.to_dict()


def supervise_session(
    session: LaunchSession,
    timeout: Optional[float] = None,
    poll_interval: float = 1.0,
    on_tick: Optional[Callable[[list], None]] = None,
    unexpected_check: Optional[Callable[[list], dict]] = None,
    settle: Optional[Callable[[list], bool]] = None,
    end_mode: Optional[str] = None,
    end_code: Optional[int] = None,
) -> dict:
    """Block while retaining the exact handles until owned processes exit or settle.

    Keeps the Job Objects and Popen handles alive for the whole run. N2/N3: when a
    ``settle`` callback reports that the required evidence has settled, the tool ends
    the run itself with a distinct ``end_code`` (never 0, never the default 1) and
    records the end mode and time on the session. On timeout it terminates only the
    owned staged handles (never the parent game) and reports ``supervision_timeout``.
    R2: an ``unexpected_check`` callback is polled on every tick; if it reports a
    live/foreign Balatro, only the owned staged handles are terminated and the run is
    voided with ``unexpected_balatro_running``.
    """
    if not isinstance(session, LaunchSession) or not session.ok:
        return {"ok": False, "code": "not_a_live_session"}
    if not session.owned:
        return {"ok": False, "code": "no_owned_handles"}
    deadline = None if timeout is None else time.time() + timeout
    while True:
        statuses = session.is_running()
        if on_tick is not None:
            on_tick(statuses)
        if unexpected_check is not None:
            try:
                verdict = unexpected_check(statuses)
            except Exception:  # noqa: BLE001
                verdict = {"ok": False, "code": "unexpected_check_failed"}
            if isinstance(verdict, Mapping) and verdict.get("ok") is False:
                return {
                    "ok": False,
                    "code": verdict.get("code") or "unexpected_balatro_running",
                    "statuses": statuses,
                    "conflict": dict(verdict),
                    "termination": session.terminate(),
                }
        if settle is not None:
            try:
                settled = bool(settle(statuses))
            except Exception:  # noqa: BLE001
                settled = False
            if settled and any(item["running"] for item in statuses):
                # The tool owns the end: terminate the Job with the phase's code.
                actions = session.terminate(exit_code=end_code if isinstance(end_code, int) else 1)
                session.end_mode = end_mode
                session.end_code = end_code
                session.ended_unix = int(time.time())
                return {
                    "ok": True,
                    "code": "supervision_ended",
                    "end_mode": end_mode,
                    "end_code": end_code,
                    "statuses": statuses,
                    "termination": actions,
                }
        if not any(item["running"] for item in statuses):
            return {"ok": True, "code": "supervision_exited", "statuses": statuses}
        if deadline is not None and time.time() >= deadline:
            return {
                "ok": False,
                "code": "supervision_timeout",
                "statuses": statuses,
                "termination": session.terminate(),
            }
        time.sleep(poll_interval)


def read_process_create_time(pid: int):
    """Exact OS process creation time (epoch seconds), or None if unavailable."""
    kernel32 = _win_kernel32()
    if kernel32 is None:
        return None
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not handle:
        return None
    try:
        return _create_time_from_handle(handle)
    finally:
        kernel32.CloseHandle(handle)


def _win_ntdll():
    if os.name != "nt":
        return None
    try:
        from ctypes import wintypes

        ntdll = ctypes.WinDLL("ntdll", use_last_error=True)
        ntdll.NtResumeProcess.restype = ctypes.c_long
        ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]
        return ntdll
    except Exception:  # noqa: BLE001
        return None


def _resume_process(popen_handle) -> bool:
    """Resume a process created with CREATE_SUSPENDED via the retained handle."""
    handle = _process_handle_value(popen_handle)
    if handle is None:
        return False
    ntdll = _win_ntdll()
    if ntdll is None:
        return False
    try:
        return int(ntdll.NtResumeProcess(handle)) == 0
    except Exception:  # noqa: BLE001
        return False


def _create_time_from_handle(handle):
    kernel32 = _win_kernel32()
    if kernel32 is None or not handle:
        return None
    try:
        from ctypes import wintypes
    except Exception:  # noqa: BLE001
        return None
    creation = wintypes.FILETIME()
    exit_time = wintypes.FILETIME()
    kernel = wintypes.FILETIME()
    user = wintypes.FILETIME()
    ok = kernel32.GetProcessTimes(
        handle,
        ctypes.byref(creation),
        ctypes.byref(exit_time),
        ctypes.byref(kernel),
        ctypes.byref(user),
    )
    if not ok:
        return None
    ticks = (creation.dwHighDateTime << 32) | creation.dwLowDateTime
    if ticks == 0:
        return None
    return (ticks / 1e7) - 11644473600.0


def read_owned_create_time(owned_process):
    """Read create time from the *retained* Popen handle, never by reopening a PID."""
    handle = _process_handle_value(getattr(owned_process, "handle", None))
    if handle is None:
        return None
    return _create_time_from_handle(handle)


class NativeProcessHandle:
    """A single opened native process handle: identity is read and used on it.

    Cleanup reopens the process once, reads create time and image path from that
    same handle, and terminates that handle, so there is no PID-reuse window
    between identity check and kill.
    """

    def __init__(self, handle, pid: int) -> None:
        self._handle = handle
        self.pid = int(pid)

    @classmethod
    def open(cls, pid: int, access: int = None):
        kernel32 = _win_kernel32()
        if kernel32 is None:
            return None
        if access is None:
            access = PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE
        handle = kernel32.OpenProcess(access, False, int(pid))
        if not handle:
            return None
        return cls(handle, pid)

    def create_time(self):
        if not self._handle:
            return None
        return _create_time_from_handle(self._handle)

    def image_path(self):
        kernel32 = _win_kernel32()
        if kernel32 is None or not self._handle:
            return None
        buffer = ctypes.create_unicode_buffer(32768)
        size = ctypes.c_uint32(len(buffer))
        if not kernel32.QueryFullProcessImageNameW(self._handle, 0, buffer, ctypes.byref(size)):
            return None
        return buffer.value or None

    def terminate(self, timeout: float = 10.0) -> bool:
        kernel32 = _win_kernel32()
        if kernel32 is None or not self._handle:
            return False
        if not kernel32.TerminateProcess(self._handle, 1):
            return False
        if kernel32.WaitForSingleObject(self._handle, int(timeout * 1000)) != WAIT_OBJECT_0:
            return False
        code = ctypes.c_uint32()
        if not kernel32.GetExitCodeProcess(self._handle, ctypes.byref(code)):
            return False
        return code.value != STILL_ACTIVE

    def close(self) -> None:
        kernel32 = _win_kernel32()
        if kernel32 is not None and self._handle:
            kernel32.CloseHandle(self._handle)
        self._handle = None


def terminate_verified_record(record: ProcessRecord, timeout: float = 10.0, open_handle=None) -> dict:
    """Revalidate identity on one reopened native handle, then terminate it."""
    opener = open_handle or NativeProcessHandle.open
    native = opener(int(record.pid))
    if native is None:
        return {"terminated": False, "reason": "handle_open_failed"}
    try:
        create_time = native.create_time()
        image_path = native.image_path()
        if create_time is None:
            return {"terminated": False, "reason": "handle_create_time_unavailable"}
        if not record.create_time or abs(create_time - record.create_time) > START_TIME_TOLERANCE:
            return {"terminated": False, "reason": "handle_create_time_mismatch"}
        if not _same_path(image_path, record.image_path):
            return {"terminated": False, "reason": "handle_image_mismatch"}
        if Path(record.image_path).name.lower() != "balatro.exe":
            return {"terminated": False, "reason": "handle_not_balatro"}
        terminated = native.terminate(timeout)
        return {"terminated": bool(terminated), "reason": "ok" if terminated else "handle_terminate_failed"}
    finally:
        native.close()


def owned_match(record: ProcessRecord, info: ProcessInfo) -> bool:
    if info.pid != record.pid:
        return False
    if not _same_path(info.image_path, record.image_path):
        return False
    if record.create_time and info.create_time:
        if abs(info.create_time - record.create_time) > START_TIME_TOLERANCE:
            return False
    else:
        return False
    return True


def check_live_balatro_closed(enumerator: ProcessEnumerator, live_install_root=None) -> dict:
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    try:
        processes = enumerator.list()
    except staging.StagingError as error:
        return {
            "ok": False,
            "code": error.code,
            "problems": [error.code],
            "live_pids": [],
        }
    live_pids = [info.pid for info in processes if is_live_install_path(info.image_path, live_install_root)]
    return {
        "ok": not live_pids,
        "code": "ok" if not live_pids else "live_balatro_running",
        "problems": [] if not live_pids else ["live_balatro_running"],
        "live_pids": live_pids,
    }


def check_no_staged_session(
    enumerator: ProcessEnumerator,
    staging_root,
    live_install_root=None,
    ignore_pids=None,
) -> dict:
    """Refuse a launch while any non-owned Balatro.exe is running (M4 + NM3).

    Any Balatro-named process that is not the user's installed game is a conflict:
    one already inside staging is a duplicate session, and one anywhere else
    (another Steam library, a copied exe) is an unowned/foreign runtime. A Balatro
    process with an unreadable image path already failed enumeration closed.
    """
    staging_root = Path(staging_root)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    ignore = {int(pid) for pid in (ignore_pids or ())}
    try:
        processes = enumerator.list()
    except staging.StagingError as error:
        return {"ok": False, "code": error.code, "pids": [], "problems": [error.code]}
    staged_pids: list = []
    foreign_pids: list = []
    for info in processes:
        if info.pid in ignore:
            continue
        if not process_is_balatro(info):
            continue
        if is_live_install_path(info.image_path, live_install_root):
            continue
        if staging.is_within(staging_root, info.image_path, allow_root=False):
            staged_pids.append(info.pid)
        else:
            foreign_pids.append(info.pid)
    if staged_pids:
        code = "staged_session_running"
    elif foreign_pids:
        code = "foreign_balatro_running"
    else:
        code = "ok"
    return {
        "ok": not staged_pids and not foreign_pids,
        "code": code,
        "pids": sorted(staged_pids + foreign_pids),
        "staged_pids": sorted(staged_pids),
        "foreign_pids": sorted(foreign_pids),
        "problems": [] if code == "ok" else [code],
    }


def known_folder_appdata() -> Optional[Path]:
    if os.name != "nt":
        return None
    try:
        from ctypes import wintypes

        class _GUID(ctypes.Structure):
            _fields_ = [
                ("Data1", ctypes.c_uint32),
                ("Data2", ctypes.c_uint16),
                ("Data3", ctypes.c_uint16),
                ("Data4", ctypes.c_ubyte * 8),
            ]

        guid = _GUID(
            0x3EB685DB,
            0x65F9,
            0x4CF6,
            (ctypes.c_ubyte * 8)(0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D),
        )
        shell32 = ctypes.WinDLL("shell32", use_last_error=True)
        ole32 = ctypes.WinDLL("ole32", use_last_error=True)
        shell32.SHGetKnownFolderPath.restype = ctypes.c_long
        shell32.SHGetKnownFolderPath.argtypes = [
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_wchar_p),
        ]
        ole32.CoTaskMemFree.argtypes = [ctypes.c_void_p]
        ptr = ctypes.c_wchar_p()
        result = shell32.SHGetKnownFolderPath(ctypes.byref(guid), 0, None, ctypes.byref(ptr))
        if result != 0 or not ptr.value:
            return None
        try:
            return Path(ptr.value)
        finally:
            ole32.CoTaskMemFree(ptr)
    except Exception:
        return None


def resolve_live_appdata(explicit=None) -> Path:
    """Live %AppData%\\Balatro resolved from the Windows known folder, not child env."""
    if explicit:
        return Path(explicit)
    known = known_folder_appdata()
    if known is not None:
        return known / "Balatro"
    return staging.default_live_appdata()


def find_steam_userdata_apps(steam_root=None, appid=None) -> list:
    """Every Steam profile containing the Balatro app dir (Low finding: not just the first)."""
    appid = appid or staging.STEAM_APPID
    base = Path(steam_root) if steam_root else Path(staging.STEAM_ROOT_DEFAULT)
    userdata = base if base.name.lower() == "userdata" else base / "userdata"
    if not userdata.is_dir():
        return []
    found: list = []
    for child in sorted(userdata.iterdir()):
        if not child.is_dir():
            continue
        app = child / appid
        if app.is_dir():
            found.append(app)
    return found


def live_source_map(install_root, appdata_root, steam_root=None) -> dict:
    sources = {"install": Path(install_root), "appdata": Path(appdata_root)}
    for app_dir in find_steam_userdata_apps(steam_root):
        sources[f"steam_userdata/{app_dir.parent.name}"] = app_dir
    return sources


def _steam_natives_in(install_root) -> list:
    install = Path(install_root)
    if not install.is_dir():
        return []
    found = [
        child.name
        for child in install.iterdir()
        if child.name.lower() in staging.STEAM_NATIVE_FILES
    ]
    return sorted(found)


def _role_paths_for(staging_root, role: str):
    if role in (getattr(staging, "BOOTSTRAP_ROLE", "bootstrap"), "bootstrap"):
        return staging.bootstrap_paths(staging_root)
    return staging.role_paths(staging_root, role)


def _env_problems(paths, env: Mapping) -> list:
    problems: list = []
    lovely = env.get("LOVELY_MOD_DIR")
    if not lovely:
        problems.append("lovely_mod_dir_missing")
    elif not staging.is_within(paths.root, lovely, allow_root=True):
        problems.append("lovely_mod_dir_outside_role")
    appdata = env.get("APPDATA")
    if not appdata:
        problems.append("appdata_missing")
    elif not staging.is_within(paths.root, appdata, allow_root=True):
        problems.append("appdata_outside_role")
    for key in sorted(env):
        upper = str(key).upper()
        if upper == "LOVELY_MOD_DIR":
            continue
        if upper.startswith(("STEAM", "SDL", "LOVELY", "PYTHON")):
            problems.append(f"inherited:{key}")
    return problems


def _role_environment_result(paths):
    """Fresh allowlisted environment plus any pinning problems. None if unavailable."""
    try:
        env = staging.role_environment(paths)
    except Exception:
        return None
    if env is None:
        return None
    return env, _env_problems(paths, env)


def _env_gate(staging_root, role: str) -> dict:
    paths = _role_paths_for(staging_root, role)
    result = _role_environment_result(paths)
    if result is None:
        return {"ok": False, "code": "role_environment_unavailable", "role": role, "problems": ["role_environment_unavailable"]}
    _env, problems = result
    return {
        "ok": not problems,
        "code": "ok" if not problems else "role_environment_unsafe",
        "role": role,
        "problems": problems,
    }


def _live_roots_map(install_root, appdata_root, steam_root, extra_live_roots=None) -> dict:
    return staging.live_roots(
        install_root=install_root,
        appdata_root=appdata_root,
        steam_root=steam_root,
        custom_roots=extra_live_roots,
    )


def _overlap_gate(staging_root, install_root=None, appdata_root=None, steam_root=None, extra_live_roots=None, roots=None) -> dict:
    if roots is None:
        roots = _live_roots_map(install_root, appdata_root, steam_root, extra_live_roots)
    try:
        staging.assert_no_overlap(staging_root, roots)
    except staging.StagingError as error:
        return {"ok": False, "code": error.code, "detail": error.message}
    return {"ok": True, "code": "ok", "roots": {key: str(value) for key, value in roots.items()}}


def _api_gate(staging_root, function_name: str, *args) -> dict:
    function = getattr(staging, function_name, None)
    if function is None:
        return {
            "ok": False,
            "code": "staging_api_missing",
            "function": function_name,
            "problems": [f"staging.{function_name}_missing"],
        }
    try:
        result = function(staging_root, *args)
    except staging.StagingError as error:
        return {"ok": False, "code": error.code, "problems": [error.code]}
    if not isinstance(result, dict):
        return {"ok": False, "code": "staging_api_invalid", "function": function_name}
    result.setdefault("ok", False)
    result.setdefault("code", "ok" if result["ok"] else "staging_api_failed")
    return result


def _exe_binding(executable: Path):
    manifest_path = Path(executable).parent.parent / staging.MANIFEST_NAME
    if not manifest_path.is_file():
        return None
    try:
        manifest = staging.read_json(manifest_path)
    except (OSError, ValueError):
        return None
    entry = (manifest.get("files") or {}).get("install/Balatro.exe")
    return entry.get("sha256") if isinstance(entry, dict) else None


def _exe_binding_gate(staging_root, roles: Sequence[str]) -> dict:
    problems: list = []
    for role in roles:
        executable = _role_paths_for(staging_root, role).exe()
        if not executable.is_file():
            problems.append(f"{role}:exe_missing")
            continue
        binding = _exe_binding(executable)
        if binding is None:
            problems.append(f"{role}:binding_missing")
            continue
        if binding != staging.sha256_file(executable):
            problems.append(f"{role}:hash_mismatch")
    return {
        "ok": not problems,
        "code": "ok" if not problems else "exe_binding_incomplete",
        "problems": problems,
    }


def cleanup_session(
    session_file,
    enumerator: ProcessEnumerator,
    live_install_root=None,
    terminate: Optional[Callable[[ProcessRecord], dict]] = None,
    staging_root=None,
) -> dict:
    terminate = terminate or terminate_verified_record
    if staging_root is None:
        return {"ok": False, "code": "staging_root_required", "actions": []}
    staging_root = Path(staging_root)
    session_path = Path(session_file)
    if not staging.is_within(staging_root, session_path, allow_root=True):
        return {"ok": False, "code": "session_outside_staging", "actions": []}
    try:
        payload = staging.read_json(session_path)
    except (OSError, ValueError) as error:
        return {"ok": False, "code": "session_unreadable", "detail": str(error), "actions": []}
    records: list = []
    for item in payload.get("records", []):
        try:
            record = ProcessRecord(**item)
        except TypeError:
            return {"ok": False, "code": "session_record_invalid", "actions": []}
        if Path(record.image_path).name.lower() != "balatro.exe" or not staging.is_within(
            staging_root, record.image_path, allow_root=False
        ):
            return {
                "ok": False,
                "code": "session_record_outside_staging",
                "record": asdict(record),
                "actions": [],
            }
        records.append(record)
    try:
        processes = enumerator.list()
    except staging.StagingError as error:
        return {"ok": False, "code": error.code, "actions": [], "records": len(records)}
    live_root = live_install_root or staging.DEFAULT_INSTALL
    actions: list = []
    for record in records:
        matched = [info for info in processes if owned_match(record, info)]
        if not matched:
            actions.append({"role": record.role, "pid": record.pid, "action": "skip", "reason": "not_owned"})
            continue
        for info in matched:
            if is_live_install_path(info.image_path, live_root):
                actions.append(
                    {"role": record.role, "pid": info.pid, "action": "refused", "reason": "live_install_path"}
                )
                continue
            outcome = terminate(record)
            terminated = bool(outcome.get("terminated"))
            actions.append(
                {
                    "role": record.role,
                    "pid": info.pid,
                    "action": "terminated" if terminated else "refused",
                    "reason": outcome.get("reason", ""),
                }
            )
    return {"ok": True, "code": "cleanup_done", "actions": actions, "records": len(records)}


def write_session(
    staging_root,
    session_id: str,
    records: Sequence[ProcessRecord],
    nonce: Optional[str] = None,
    spawn_time: Optional[float] = None,
) -> Path:
    if not SESSION_ID_PATTERN.match(str(session_id)):
        raise staging.StagingError("bad_session_id", str(session_id))
    target = staging.assert_within(staging_root, Path(staging_root) / "sessions" / f"{session_id}.json")
    if target.exists():
        raise staging.StagingError("session_exists", str(target))
    payload = {
        "schema": SESSION_SCHEMA,
        "session_id": session_id,
        "records": [asdict(record) for record in records],
    }
    if nonce is not None:
        payload["nonce"] = nonce
    if spawn_time is not None:
        payload["spawn_time"] = spawn_time
    return staging.write_json(target, payload)


def build_launch_plan(
    staging_root=None,
    port: int = 8788,
    live_install_root=None,
    backup_root=None,
    enumerator: Optional[ProcessEnumerator] = None,
    session_id: Optional[str] = None,
    live_appdata_root=None,
    steam_root=None,
    extra_live_roots: Optional[Sequence] = None,
    require_certificate: bool = True,
) -> dict:
    staging_root = Path(staging_root or staging.DEFAULT_STAGING_ROOT)
    backup_root = Path(backup_root or staging.DEFAULT_BACKUP_ROOT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    appdata_root = resolve_live_appdata(live_appdata_root)
    enumerator = enumerator or default_enumerator()
    session_id = session_id or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    sources = live_source_map(live_install_root, appdata_root, steam_root)
    live_map = _live_roots_map(live_install_root, appdata_root, steam_root, extra_live_roots)

    endpoints = staging.verify_staged_endpoints(staging_root, port=port)
    steam_guard = {role: staging.check_steam_guard(staging_root, role, live=live_map) for role in staging.ROLES}
    role_verifies = {role: staging.verify_staged_role(staging_root, role) for role in staging.ROLES}
    env_gates = {role: _env_gate(staging_root, role) for role in staging.ROLES}
    gates = {
        "live_balatro_closed": check_live_balatro_closed(enumerator, live_install_root),
        "no_staged_session": check_no_staged_session(enumerator, staging_root, live_install_root),
        "overlap": _overlap_gate(staging_root, roots=live_map),
        "staged_endpoints": endpoints,
        "staged_roles": {
            "ok": all(item.get("ok") for item in role_verifies.values()),
            "code": "ok" if all(item.get("ok") for item in role_verifies.values()) else "staged_role_unproven",
            "roles": role_verifies,
        },
        "exe_binding": _exe_binding_gate(staging_root, staging.ROLES),
        "role_environment": {
            "ok": all(item["ok"] for item in env_gates.values()),
            "code": "ok" if all(item["ok"] for item in env_gates.values()) else "role_environment_unsafe",
            "roles": env_gates,
        },
        "backup_evidence": check_backup_evidence(backup_root, sources),
    }
    if require_certificate:
        gates["isolation_proof"] = staging.check_isolation_proof(staging_root, live=live_map)
        gates["steam_guard"] = {
            "ok": all(item["ok"] for item in steam_guard.values()),
            "code": "ok" if all(item["ok"] for item in steam_guard.values()) else "steam_guard_unproven",
            "roles": steam_guard,
        }
    roles_plan: dict = {}
    for role in staging.ROLES:
        paths = staging.role_paths(staging_root, role)
        executable = paths.exe()
        env_result = _role_environment_result(paths)
        roles_plan[role] = {
            "exe": str(executable),
            "exe_exists": executable.is_file(),
            "cwd": str(paths.install),
            "command": _role_command(paths, executable),
            "env_overrides": staging.role_environment_overrides(paths),
            "env": env_result[0] if env_result else {},
        }
    blocked = sorted(name for name, gate in gates.items() if not gate.get("ok"))
    return {
        "schema": "aisparring.launch_plan.v1",
        "session_id": session_id,
        "staging_root": str(staging_root),
        "live_install_root": str(live_install_root),
        "live_appdata_root": str(appdata_root),
        "backup_root": str(backup_root),
        "port": port,
        "require_certificate": bool(require_certificate),
        "gates": gates,
        "roles": roles_plan,
        "blocked": blocked,
        "may_launch": not blocked,
        "isolation_proven": gates.get("isolation_proof", {}).get("ok", False),
    }


def _bootstrap_manifest_gate(staging_root) -> dict:
    paths = staging.bootstrap_paths(staging_root)
    manifest_path = paths.root / staging.MANIFEST_NAME
    if not manifest_path.is_file():
        return {"ok": False, "code": "bootstrap_manifest_missing", "path": str(manifest_path)}
    try:
        manifest = staging.read_json(manifest_path)
    except (OSError, ValueError):
        return {"ok": False, "code": "bootstrap_manifest_unreadable", "path": str(manifest_path)}
    verdict = staging.verify_manifest(manifest, paths.root)
    verdict["code"] = "ok" if verdict["ok"] else "bootstrap_manifest_mismatch"
    verdict["path"] = str(manifest_path)
    return verdict


def build_bootstrap_plan(
    staging_root=None,
    live_install_root=None,
    backup_root=None,
    enumerator: Optional[ProcessEnumerator] = None,
    session_id: Optional[str] = None,
    live_appdata_root=None,
    steam_root=None,
    extra_live_roots: Optional[Sequence] = None,
) -> dict:
    staging_root = Path(staging_root or staging.DEFAULT_STAGING_ROOT)
    backup_root = Path(backup_root or staging.DEFAULT_BACKUP_ROOT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    appdata_root = resolve_live_appdata(live_appdata_root)
    enumerator = enumerator or default_enumerator()
    session_id = session_id or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    sources = live_source_map(live_install_root, appdata_root, steam_root)
    live_map = _live_roots_map(live_install_root, appdata_root, steam_root, extra_live_roots)
    paths = staging.bootstrap_paths(staging_root)
    executable = paths.exe()
    gates = {
        "live_balatro_closed": check_live_balatro_closed(enumerator, live_install_root),
        "no_staged_session": check_no_staged_session(enumerator, staging_root, live_install_root),
        "overlap": _overlap_gate(staging_root, roots=live_map),
        "bootstrap_preflight": _api_gate(staging_root, "check_bootstrap_preflight"),
        "backup_evidence": check_backup_evidence(backup_root, sources),
        "staging_manifest": _bootstrap_manifest_gate(staging_root),
        "role_environment": _env_gate(staging_root, "bootstrap"),
        "exe_binding": _exe_binding_gate(staging_root, [getattr(staging, "BOOTSTRAP_ROLE", "bootstrap")]),
    }
    env_result = _role_environment_result(paths)
    roles = {
        "bootstrap": {
            "exe": str(executable),
            "exe_exists": executable.is_file(),
            "cwd": str(paths.install),
            "command": _role_command(paths, executable),
            "env_overrides": staging.role_environment_overrides(paths),
            "env": env_result[0] if env_result else {},
        }
    }
    blocked = sorted(name for name, gate in gates.items() if not gate.get("ok"))
    return {
        "schema": "aisparring.bootstrap_plan.v1",
        "mode": "bootstrap",
        "session_id": session_id,
        "staging_root": str(staging_root),
        "live_install_root": str(live_install_root),
        "live_appdata_root": str(appdata_root),
        "backup_root": str(backup_root),
        "gates": gates,
        "roles": roles,
        "blocked": blocked,
        "may_launch": not blocked,
        "isolation_proven": False,
    }


def redacted_plan(plan: Mapping) -> dict:
    return {
        "schema": plan.get("schema"),
        "mode": plan.get("mode", "roles"),
        "session_id": plan.get("session_id"),
        "staging_root": plan.get("staging_root"),
        "port": plan.get("port"),
        "blocked": plan.get("blocked"),
        "may_launch": plan.get("may_launch"),
        "isolation_proven": plan.get("isolation_proven"),
        "gates": {
            name: {key: value for key, value in gate.items() if key != "roles"}
            for name, gate in plan.get("gates", {}).items()
        },
        "roles": {
            role: {"exe": spec.get("exe"), "cwd": spec.get("cwd"), "exe_exists": spec.get("exe_exists"),
                   "env_overrides": spec.get("env_overrides")}
            for role, spec in plan.get("roles", {}).items()
        },
    }


def _role_command(paths, executable) -> list:
    """Exact role Mods directory is passed on the command line, not only via env (NM8).

    Lovely honours ``--mod-dir`` (verified against the official source
    ``../../work/lovely-source/crates/lovely-core/src/lib.rs:141``) in addition to
    ``LOVELY_MOD_DIR``, so the pinned location is proven two ways.
    """
    return [str(executable), "--mod-dir", str(paths.mods)]


def _close_job_quietly(job) -> None:
    """Close a Job Object that was created but never attached to an owned process."""
    if job is None:
        return
    try:
        job.close()
    except Exception:  # noqa: BLE001
        pass


def _spawn_verified(
    fresh: Mapping,
    popen: Callable,
    create_time_reader: Callable,
    enumerator: ProcessEnumerator,
    live_install_root,
    staging_root,
    *,
    nonce: str,
    on_terminate: Optional[Callable[[OwnedProcess], None]] = None,
    job_factory: Optional[Callable[[], object]] = None,
    resume: Optional[Callable[[object], bool]] = None,
    session_descriptors: Optional[Mapping[str, "SessionDescriptor"]] = None,
    expected_session_id: Optional[str] = None,
    measure_crash: bool = False,
    measure_p2: bool = False,
) -> LaunchSession:
    """Start each role suspended, assign it to a mandatory Job Object, then resume.

    On Windows a Job Object is required and the child must start suspended *before*
    it is supervised: the Job Object is created before ``Popen``, a missing Job
    Object aborts with no spawn at all, and a ``Popen`` that rejects
    ``creationflags`` (or otherwise fails to start) aborts with the created Job
    Object closed and no second, unsuspended attempt. If the process cannot be
    assigned, the owned handles are terminated and the launch aborts. Create time
    is read from the retained handle, and no callback is invoked with a bare PID.
    """
    staging_root = Path(staging_root)
    session_id = str(fresh.get("session_id", ""))
    if not isinstance(nonce, str) or not nonce:
        return LaunchSession(session_id, staging_root, [], [], "", 0.0, code="session_nonce_required")
    if not fresh.get("may_launch"):
        return LaunchSession(
            session_id,
            staging_root,
            [],
            [],
            nonce,
            0.0,
            code="launch_blocked",
            blocked=fresh.get("blocked", []),
        )
    job_factory = job_factory or JobObject.create
    resume = resume or _resume_process
    create_time_reader = create_time_reader or read_owned_create_time
    spawn_time = time.time()
    owned: list = []
    records: list = []

    def abort(code: str, **extra) -> LaunchSession:
        actions = _terminate_owned_handles(owned, on_terminate)
        rollback = {"rolled_back": bool(owned), "termination": actions}
        return LaunchSession(
            session_id,
            staging_root,
            records,
            [],
            nonce,
            spawn_time,
            code=code,
            rollback=rollback,
            extra=extra,
        )

    for role, spec in fresh.get("roles", {}).items():
        final_live = check_live_balatro_closed(enumerator, live_install_root)
        if not final_live["ok"]:
            return abort("live_balatro_running", live=final_live)
        duplicate = check_no_staged_session(
            enumerator,
            staging_root,
            live_install_root,
            ignore_pids=[item.pid for item in owned],
        )
        if not duplicate["ok"]:
            return abort(duplicate["code"], duplicate=duplicate)
        paths = _role_paths_for(staging_root, role)
        executable = Path(spec["exe"])
        if not spec.get("exe_exists") or not executable.is_file():
            return abort("staged_exe_missing", role=role, exe=spec.get("exe"))
        if not staging.is_within(staging_root, executable) or is_live_install_path(executable, live_install_root):
            return abort("staged_exe_outside_staging", role=role, exe=spec.get("exe"))
        steam_natives = _steam_natives_in(paths.install)
        if steam_natives:
            return abort("staged_steam_native_present", role=role, files=steam_natives)
        actual_hash = staging.sha256_file(executable)
        binding = _exe_binding(executable)
        if binding is None:
            return abort("staged_exe_binding_missing", role=role)
        if binding != actual_hash:
            return abort("staged_exe_hash_mismatch", role=role)
        env_result = _role_environment_result(paths)
        if env_result is None:
            return abort("role_environment_unavailable", role=role)
        env, env_problems = env_result
        if env_problems:
            return abort("role_environment_unsafe", role=role, problems=env_problems)
        command = _role_command(paths, executable)
        if spec.get("command") is not None and list(spec.get("command") or []) != command:
            return abort("mod_dir_command_mismatch", role=role, expected=command)
        env = dict(env)
        if session_descriptors is not None:
            descriptor = session_descriptors.get(role)
            if descriptor is None:
                return abort("session_descriptor_missing", role=role)
            descriptor_problems = session_descriptor_problems(
                descriptor, paths, nonce, expected_session_id=expected_session_id
            )
            if descriptor_problems:
                return abort(descriptor_problems[0], role=role, problems=descriptor_problems)
            env.update(session_env_overrides(descriptor))
        env[PROBE_NONCE_VAR] = nonce
        if measure_crash:
            env[staging.MEASURE_CRASH_ENV] = "1"
        if measure_p2:
            env[staging.MEASURE_P2_ENV] = "1"
        on_windows = os.name == "nt"
        job = job_factory()
        if on_windows and job is None:
            # Mandatory suspended-before-Job (NM2): never start a child we cannot own.
            return abort("job_object_unavailable", role=role)
        creationflags = CREATE_SUSPENDED if on_windows else 0
        try:
            process = popen(
                command, cwd=spec["cwd"], env=env, close_fds=True, creationflags=creationflags
            )
        except (TypeError, ValueError):
            # An incompatible popen wrapper cannot prove a suspended start. Never
            # retry unsuspended; fail closed with the unused Job Object closed.
            _close_job_quietly(job)
            return abort("spawn_flags_unsupported", role=role)
        except OSError as error:
            _close_job_quietly(job)
            return abort("spawn_failed", role=role, detail=str(error))
        if on_windows:
            try:
                assigned = bool(job.assign(process))
            except Exception:  # noqa: BLE001
                assigned = False
            if not assigned:
                try:
                    job.close()
                except Exception:  # noqa: BLE001
                    pass
                try:
                    process.kill()
                except Exception:  # noqa: BLE001
                    pass
                return abort("job_object_assignment_failed", role=role)
            owned_process = OwnedProcess(
                role=role,
                handle=process,
                pid=int(process.pid),
                create_time=None,
                image_path=str(executable),
                exe_sha256=actual_hash,
                job=job,
            )
            owned.append(owned_process)
            if not resume(process):
                return abort("process_resume_failed", role=role, pid=int(process.pid))
        else:
            if job is not None:
                try:
                    job.assign(process)
                except Exception:  # noqa: BLE001
                    pass
            owned_process = OwnedProcess(
                role=role,
                handle=process,
                pid=int(process.pid),
                create_time=None,
                image_path=str(executable),
                exe_sha256=actual_hash,
                job=job,
            )
            owned.append(owned_process)
        create_time = create_time_reader(owned_process)
        if create_time is None:
            return abort("create_time_unavailable", role=role, pid=int(process.pid))
        owned_process.create_time = float(create_time)
        records.append(
            ProcessRecord(
                role=role,
                pid=int(process.pid),
                create_time=float(create_time),
                image_path=str(executable),
                session_id=session_id,
                exe_sha256=actual_hash,
            )
        )

    final_live = check_live_balatro_closed(enumerator, live_install_root)
    if not final_live["ok"]:
        return abort("live_balatro_running_after_spawn", live=final_live)

    try:
        session_file = write_session(
            staging_root, session_id, records, nonce=nonce, spawn_time=spawn_time
        )
    except staging.StagingError as error:
        return abort("session_write_failed", detail=error.code)

    return LaunchSession(
        session_id,
        staging_root,
        records,
        owned,
        nonce,
        spawn_time,
        session_file=session_file,
        code="launched",
    )


def execute_launch(
    plan: Mapping,
    staging_root=None,
    backup_root=None,
    live_install_root=None,
    port=None,
    popen: Callable = subprocess.Popen,
    create_time_reader: Callable = read_owned_create_time,
    enumerator: Optional[ProcessEnumerator] = None,
    on_terminate: Optional[Callable[[OwnedProcess], None]] = None,
    job_factory: Optional[Callable[[], object]] = None,
    resume: Optional[Callable[[object], bool]] = None,
    live_appdata_root=None,
    steam_root=None,
    extra_live_roots: Optional[Sequence] = None,
    supervisor: Optional[Callable[[LaunchSession], dict]] = None,
    session_descriptors: Optional[Mapping[str, "SessionDescriptor"]] = None,
    open_session: Optional[Mapping] = None,
    require_certificate: bool = True,
    measure_crash: bool = False,
    measure_p2: bool = False,
) -> object:
    """Spawn the two roles, but only under an exclusive prepared open session.

    M1: the caller's ``open_session`` mapping is never trusted. The persisted open
    record is reloaded from disk and must be ``open``, match the caller's session
    id/nonce/phase, carry no previously bound PIDs, and be phase ``MATCH`` exactly
    when ``require_certificate`` is true (a measurement phase otherwise). The plan
    is re-derived from disk immediately before spawning.
    """
    staging_root = Path(staging_root or plan.get("staging_root") or staging.DEFAULT_STAGING_ROOT)
    backup_root = Path(backup_root or plan.get("backup_root") or staging.DEFAULT_BACKUP_ROOT)
    live_install_root = Path(live_install_root or plan.get("live_install_root") or staging.DEFAULT_INSTALL)
    port = int(port if port is not None else plan.get("port", 8788))
    enumerator = enumerator or default_enumerator()
    if not isinstance(open_session, Mapping):
        return LaunchSession(
            str(plan.get("session_id", "")), staging_root, [], [], "", 0.0, code="open_session_required"
        )
    session_id = str(open_session.get("session_id"))
    if session_descriptors is not None and open_session.get("phase") != isolation_certificate.MATCH:
        return LaunchSession(
            session_id, staging_root, [], [], open_session.get("nonce"), 0.0,
            code="session_descriptors_require_match_phase",
        )
    allowed = (
        (isolation_certificate.MATCH,)
        if require_certificate
        else ("P1B", "FULL_P1", "CRASH") + tuple(isolation_certificate.P2_PHASES)
    )
    record, record_problems = _resolved_open_session(
        staging_root, open_session, allowed_phases=allowed
    )
    if record_problems:
        return LaunchSession(
            session_id, staging_root, [], [], open_session.get("nonce"), 0.0,
            code=record_problems[0], blocked=sorted(set(record_problems)),
        )
    nonce = record.get("nonce")
    # N7: the CRASH/P2 measurement gates are derived from the *prepared* phase, so a
    # normal MATCH session can never switch them on.
    phase = record.get("phase")
    measure_crash = phase == "CRASH"
    measure_p2 = phase in getattr(isolation_certificate, "P2_PHASES", ())
    fresh = build_launch_plan(
        staging_root=staging_root,
        port=port,
        live_install_root=live_install_root,
        backup_root=backup_root,
        enumerator=enumerator,
        session_id=session_id,
        live_appdata_root=live_appdata_root,
        steam_root=steam_root,
        extra_live_roots=extra_live_roots,
        require_certificate=require_certificate,
    )
    session = _spawn_verified(
        fresh,
        popen,
        create_time_reader,
        enumerator,
        live_install_root,
        staging_root,
        nonce=nonce,
        on_terminate=on_terminate,
        job_factory=job_factory,
        resume=resume,
        session_descriptors=session_descriptors,
        expected_session_id=session_id,
        measure_crash=measure_crash,
        measure_p2=measure_p2,
    )
    if session.ok:
        bound = _bind_open_session(staging_root, session)
        if not bound.get("ok"):
            return _abort_spawned_session(
                staging_root, session, bound.get("code", "open_session_bind_failed"), on_terminate
            )
    if session.ok and supervisor is not None:
        return supervisor(session)
    return session


def _resolved_open_session(staging_root, open_session: Mapping, *, allowed_phases) -> tuple:
    """Reload and validate the persisted open record; never trust the caller mapping."""
    session_id = open_session.get("session_id")
    if not isinstance(session_id, str) or not isolation_certificate.SESSION_ID_RE.match(session_id):
        return None, ["open_session_required"]
    record = isolation_certificate.load_open_record(staging_root, session_id)
    if not isinstance(record, Mapping):
        return None, ["open_session_missing"]
    problems: list = []
    if open_session.get("status") != "open" or record.get("status") != "open":
        problems.append("open_session_not_open")
    if record.get("session_id") != session_id:
        problems.append("open_session_mismatch")
    for key in ("nonce", "phase", "certificate_id", "port"):
        if key in open_session and open_session.get(key) != record.get(key):
            problems.append(f"open_session_{key}_mismatch")
    if record.get("pids"):
        problems.append("open_session_pids_bound")
    if record.get("phase") not in set(allowed_phases):
        problems.append("open_session_phase_mismatch")
    if problems:
        return None, problems
    return record, []


def _abort_spawned_session(staging_root, session: LaunchSession, code: str, on_terminate=None) -> LaunchSession:
    """Terminate the owned handles, record the global lockout, and return the failure."""
    _terminate_owned_handles(session.owned, on_terminate)
    try:
        isolation_certificate.record_session_failure(
            staging_root, session_id=session.session_id, reason=str(code)
        )
    except Exception:  # noqa: BLE001
        pass
    return LaunchSession(
        session.session_id,
        session.staging_root,
        session.records,
        [],
        session.nonce,
        session.spawn_time,
        code=str(code),
        rollback={"rolled_back": bool(session.owned), "termination": []},
    )


def execute_bootstrap(
    plan: Mapping,
    staging_root=None,
    backup_root=None,
    live_install_root=None,
    popen: Callable = subprocess.Popen,
    create_time_reader: Callable = read_owned_create_time,
    enumerator: Optional[ProcessEnumerator] = None,
    on_terminate: Optional[Callable[[OwnedProcess], None]] = None,
    job_factory: Optional[Callable[[], object]] = None,
    resume: Optional[Callable[[object], bool]] = None,
    live_appdata_root=None,
    steam_root=None,
    extra_live_roots: Optional[Sequence] = None,
    supervisor: Optional[Callable[[LaunchSession], dict]] = None,
    open_session: Optional[Mapping] = None,
) -> object:
    staging_root = Path(staging_root or plan.get("staging_root") or staging.DEFAULT_STAGING_ROOT)
    backup_root = Path(backup_root or plan.get("backup_root") or staging.DEFAULT_BACKUP_ROOT)
    live_install_root = Path(live_install_root or plan.get("live_install_root") or staging.DEFAULT_INSTALL)
    enumerator = enumerator or default_enumerator()
    if not isinstance(open_session, Mapping):
        return LaunchSession(
            str(plan.get("session_id", "")), staging_root, [], [], "", 0.0, code="open_session_required"
        )
    session_id = str(open_session.get("session_id"))
    record, record_problems = _resolved_open_session(staging_root, open_session, allowed_phases=("P1A",))
    if record_problems:
        return LaunchSession(
            session_id, staging_root, [], [], open_session.get("nonce"), 0.0,
            code=record_problems[0], blocked=sorted(set(record_problems)),
        )
    nonce = record.get("nonce")
    fresh = build_bootstrap_plan(
        staging_root=staging_root,
        live_install_root=live_install_root,
        backup_root=backup_root,
        enumerator=enumerator,
        session_id=session_id,
        live_appdata_root=live_appdata_root,
        steam_root=steam_root,
        extra_live_roots=extra_live_roots,
    )
    session = _spawn_verified(
        fresh,
        popen,
        create_time_reader,
        enumerator,
        live_install_root,
        staging_root,
        nonce=nonce,
        on_terminate=on_terminate,
        job_factory=job_factory,
        resume=resume,
        expected_session_id=session_id,
    )
    if session.ok:
        bound = _bind_open_session(staging_root, session)
        if not bound.get("ok"):
            return _abort_spawned_session(
                staging_root, session, bound.get("code", "open_session_bind_failed"), on_terminate
            )
    if session.ok and supervisor is not None:
        return supervisor(session)
    return session


def _bind_open_session(staging_root, session: LaunchSession) -> dict:
    """Record spawn time and exact owned PIDs on the open record.

    R3: binding is mandatory, never best effort. A failure is surfaced so the
    caller can abort the spawned session and raise the global lockout.
    """
    pids: dict = {}
    for record in session.records:
        pids.setdefault(record.role, []).append(int(record.pid))
    try:
        result = isolation_certificate.bind_open_session(
            staging_root, session.session_id, pids=pids, spawn_time=session.spawn_time
        )
    except Exception as error:  # noqa: BLE001
        return {"ok": False, "code": "open_session_bind_failed", "detail": type(error).__name__}
    if not isinstance(result, Mapping) or not result.get("ok"):
        code = result.get("code") if isinstance(result, Mapping) else "open_session_bind_failed"
        return {"ok": False, "code": code or "open_session_bind_failed"}
    return dict(result)


def verify_bootstrap_run(session: LaunchSession) -> dict:
    """Post-run probe check bound to the session nonce and spawn time."""
    if not isinstance(session, LaunchSession) or not session.ok:
        return {"ok": False, "code": "not_a_live_session"}
    function = getattr(staging, "check_bootstrap_evidence", None)
    if function is None:
        return {"ok": False, "code": "staging_api_missing", "function": "check_bootstrap_evidence"}
    try:
        result = function(
            session.staging_root, expected_nonce=session.nonce, spawn_time=session.spawn_time
        )
    except TypeError:
        return {"ok": False, "code": "staging_api_signature_mismatch", "function": "check_bootstrap_evidence"}
    except staging.StagingError as error:
        return {"ok": False, "code": error.code}
    if not isinstance(result, dict):
        return {"ok": False, "code": "staging_api_invalid"}
    result.setdefault("ok", False)
    return result


def verify_backup_entry(entry: Mapping, backup_root=None) -> dict:
    directory = Path(entry.get("dir", ""))
    manifest_path = Path(entry.get("manifest", ""))
    if backup_root is not None:
        root = Path(backup_root)
        if not staging.is_within(root, directory, allow_root=False):
            return {"ok": False, "code": "backup_entry_outside_root"}
        if not staging.is_within(root, manifest_path, allow_root=False):
            return {"ok": False, "code": "backup_manifest_outside_root"}
        if staging.is_within(directory, manifest_path, allow_root=True):
            return {"ok": False, "code": "backup_manifest_inside_copy"}
    if not directory.is_dir() or not manifest_path.is_file():
        return {"ok": False, "code": "backup_entry_missing"}
    try:
        manifest = staging.read_json(manifest_path)
    except (OSError, ValueError):
        return {"ok": False, "code": "backup_entry_unreadable"}
    if manifest.get("schema") != BACKUP_ENTRY_SCHEMA:
        return {"ok": False, "code": "backup_entry_schema_mismatch"}
    verdict = staging.verify_manifest(manifest, directory)
    verdict["code"] = "ok" if verdict["ok"] else "backup_entry_mismatch"
    return verdict


def check_backup_current(manifest: Mapping, backup_root, sources: Mapping) -> dict:
    """Live trees must still hash-match the recorded backup (freshness / before snapshot)."""
    problems: list = []
    root = Path(backup_root)
    entries = manifest.get("entries") or {}
    for key, expected in sources.items():
        entry = entries.get(key)
        if not entry:
            problems.append(f"{key}_entry_missing")
            continue
        if not _same_path(entry.get("source_root"), expected):
            problems.append(f"{key}_source_mismatch")
            continue
        manifest_path = Path(entry.get("manifest", ""))
        if not staging.is_within(root, manifest_path, allow_root=False) or not manifest_path.is_file():
            problems.append(f"{key}_entry_manifest_missing")
            continue
        try:
            entry_manifest = staging.read_json(manifest_path)
        except (OSError, ValueError):
            problems.append(f"{key}_entry_unreadable")
            continue
        expected_files = entry_manifest.get("files") or {}
        try:
            current_files = staging.hash_tree(expected)
        except staging.StagingError:
            problems.append(f"{key}_source_unreadable")
            continue
        if current_files != expected_files:
            problems.append(f"{key}_live_changed_since_backup")
    return {"ok": not problems, "problems": problems}


def check_backup_evidence(backup_root, sources=None) -> dict:
    """Verify the backup and return its cryptographic identity plus verified roots.

    R1: the result carries the sha256 of ``BACKUP_MANIFEST.json`` (``manifest_sha256``)
    and a content-derived ``backup_id`` over that manifest hash and every verified
    per-entry file map, together with each entry's ``files_digest``. A later
    ``prepare_session`` binds its own before-snapshot to these digests; the id can
    no longer be replaced by a caller label.
    """
    manifest_path = Path(backup_root) / BACKUP_MANIFEST_NAME
    if not manifest_path.is_file():
        return {"ok": False, "code": "backup_manifest_missing", "path": str(manifest_path)}
    try:
        manifest = staging.read_json(manifest_path)
    except (OSError, ValueError):
        return {"ok": False, "code": "backup_manifest_unreadable", "path": str(manifest_path)}
    if manifest.get("schema") != BACKUP_SCHEMA:
        return {"ok": False, "code": "backup_manifest_schema_mismatch", "path": str(manifest_path)}
    problems: list = []
    roots: dict = {}
    entries = manifest.get("entries") or {}
    for key in ("install", "appdata"):
        if not entries.get(key):
            problems.append(f"{key}_missing")
    if not any(key.startswith("steam_userdata") for key in entries):
        problems.append("steam_userdata_missing")
    for key, entry in entries.items():
        verdict = verify_backup_entry(entry, backup_root)
        if not verdict["ok"]:
            problems.append(f"{key}_{verdict['code']}")
            continue
        entry_manifest_path = Path(entry.get("manifest", ""))
        try:
            entry_manifest = staging.read_json(entry_manifest_path)
        except (OSError, ValueError):
            problems.append(f"{key}_entry_manifest_unreadable")
            continue
        files = entry_manifest.get("files") or {}
        roots[str(key)] = {
            "source_root": str(entry.get("source_root") or ""),
            "files_digest": staging._digest_of(files),
            "entry_manifest_sha256": staging.sha256_file(entry_manifest_path),
            "file_count": len(files),
        }
    if sources is not None:
        current = check_backup_current(manifest, backup_root, sources)
        problems.extend(current["problems"])
    manifest_sha256 = staging.sha256_file(manifest_path)
    backup_id = staging._digest_of(
        {
            "schema": BACKUP_SCHEMA,
            "manifest_sha256": manifest_sha256,
            "roots": {
                key: {"source_root": value["source_root"], "files_digest": value["files_digest"]}
                for key, value in sorted(roots.items())
            },
        }
    )
    return {
        "ok": not problems,
        "code": "ok" if not problems else "backup_evidence_incomplete",
        "problems": problems,
        "path": str(manifest_path),
        "manifest_sha256": manifest_sha256,
        "backup_id": backup_id,
        "backup_label": manifest.get("label"),
        "roots": roots,
    }


def _entry_manifest_name(key: str) -> str:
    return key.replace("/", "__") + ".manifest.json"


def create_live_backup(
    install_root=None,
    appdata_root=None,
    steam_userdata_root=None,
    backup_root=None,
    enumerator: Optional[ProcessEnumerator] = None,
    live_install_root=None,
    label: Optional[str] = None,
    execute: bool = False,
    steam_root=None,
    steam_userdata_roots: Optional[Sequence] = None,
) -> dict:
    install_root = Path(install_root or staging.DEFAULT_INSTALL)
    appdata_root = resolve_live_appdata(appdata_root)
    backup_root = Path(backup_root or staging.DEFAULT_BACKUP_ROOT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    label = label or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    enumerator = enumerator or default_enumerator()

    if steam_userdata_roots is None:
        if steam_userdata_root is not None:
            steam_userdata_roots = [Path(steam_userdata_root)]
        else:
            steam_userdata_roots = find_steam_userdata_apps(steam_root)
    steam_userdata_roots = [Path(item) for item in (steam_userdata_roots or [])]

    closed = check_live_balatro_closed(enumerator, live_install_root)
    if not closed["ok"]:
        return {"ok": False, "code": "live_process_running", "detail": closed, "execute": execute}
    if not steam_userdata_roots:
        return {
            "ok": False,
            "code": "steam_userdata_missing",
            "detail": "at least one Steam userdata app 2379780 profile is required for backup evidence",
            "execute": execute,
        }

    sources: dict = {"install": install_root, "appdata": appdata_root}
    for app_dir in steam_userdata_roots:
        sources[f"steam_userdata/{app_dir.parent.name}"] = app_dir

    missing = [key for key, source in sources.items() if not source.is_dir()]
    if missing:
        return {"ok": False, "code": "backup_source_missing", "missing": missing, "execute": execute}

    target = backup_root / label
    if any(staging.is_within(source, target) for source in sources.values()):
        return {"ok": False, "code": "backup_target_inside_live", "target": str(target)}
    for key, source in sources.items():
        links = staging.find_links(source)
        if links:
            return {
                "ok": False,
                "code": "backup_source_contains_links",
                "key": key,
                "link": links[0],
                "execute": execute,
            }
    if not execute:
        return {
            "ok": True,
            "code": "backup_planned",
            "execute": False,
            "target": str(target),
            "sources": {key: str(source) for key, source in sources.items()},
        }
    if target.exists():
        return {"ok": False, "code": "backup_target_exists", "target": str(target)}

    entries: dict = {}
    try:
        for key, source in sources.items():
            destination = target / key
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, destination)
            source_files = staging.hash_tree(source)
            copy_files = staging.hash_tree(destination)
            if source_files != copy_files:
                return {
                    "ok": False,
                    "code": "backup_copy_mismatch",
                    "key": key,
                    "execute": True,
                }
            entry_manifest = {
                "schema": BACKUP_ENTRY_SCHEMA,
                "backup_key": key,
                "source_root": str(source.resolve()),
                "files": copy_files,
            }
            manifest_path = staging.write_json(target / _entry_manifest_name(key), entry_manifest)
            entries[key] = {
                "source_root": str(source.resolve()),
                "dir": str(destination),
                "manifest": str(manifest_path),
                "files": len(copy_files),
            }
    except OSError as error:
        return {"ok": False, "code": "backup_copy_failed", "detail": str(error), "execute": True}

    closed_after = check_live_balatro_closed(enumerator, live_install_root)
    if not closed_after["ok"]:
        return {
            "ok": False,
            "code": "live_process_running_after_copy",
            "detail": closed_after,
            "execute": True,
        }

    record = {
        "schema": BACKUP_SCHEMA,
        "label": label,
        "created_unix": int(time.time()),
        "live_install_root": str(live_install_root),
        "live_appdata_root": str(appdata_root),
        "steam_userdata_roots": [str(item) for item in steam_userdata_roots],
        "entries": entries,
    }
    manifest_path = staging.write_json(backup_root / BACKUP_MANIFEST_NAME, record)
    return {"ok": True, "code": "backup_created", "execute": True, "manifest": str(manifest_path), "entries": entries}


def _pick_free_loopback_port() -> Optional[int]:
    import socket as _socket

    server = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
    try:
        server.bind(("127.0.0.1", 0))
        return int(server.getsockname()[1])
    except OSError:
        return None
    finally:
        server.close()


def _default_port_probe(port: int, attempts: int = 3, timeout: float = 0.5) -> dict:
    """Tool-owned native measurement: both-family listener absence + refused connect.

    Loopback only; it never contacts an external host. A successful bind proves no
    listener owns the port for that address family, and the connect attempts record
    the real refusal and timing.
    """
    import socket as _socket

    result = {
        "listener_absent": {"ipv4": False, "ipv6": False},
        "refused": False,
        "timings": [],
        "attempts": 0,
    }
    for family, address, key in (
        (_socket.AF_INET, "127.0.0.1", "ipv4"),
        (_socket.AF_INET6, "::1", "ipv6"),
    ):
        probe = _socket.socket(family, _socket.SOCK_STREAM)
        try:
            probe.bind((address, int(port)))
            result["listener_absent"][key] = True
        except OSError:
            result["listener_absent"][key] = False
        finally:
            probe.close()
    for _ in range(max(1, int(attempts))):
        client = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
        client.settimeout(timeout)
        start = time.perf_counter()
        try:
            client.connect(("127.0.0.1", int(port)))
            result["refused"] = False
        except OSError:
            result["refused"] = True
        finally:
            client.close()
        result["timings"].append(round(time.perf_counter() - start, 6))
        result["attempts"] += 1
    return result


def measure_dead_port(port=None, *, prober=None, chooser=None, attempts: int = 3) -> dict:
    """Tool-owned P2 dead-port setup: prove a loopback port has no listener at all.

    With an explicit ``port`` (the staged match port) the tool verifies nothing is
    bound to it before spawning: that is the real dead-port condition P2 requires.
    ``prober``/``chooser`` are injectable so fixtures never open a socket.
    """
    prober = prober or (lambda candidate: _default_port_probe(candidate, attempts=attempts))
    candidates = [port] if port is not None else []
    if not candidates:
        chooser = chooser or _pick_free_loopback_port
        candidates = [chooser() for _ in range(8)]
    for candidate in candidates:
        if not isinstance(candidate, int) or isinstance(candidate, bool) or not (1 <= candidate <= 65535):
            continue
        evidence = prober(candidate) or {}
        absent = evidence.get("listener_absent") or {}
        if evidence.get("refused") and absent.get("ipv4") and absent.get("ipv6"):
            return {
                "ok": True,
                "kind": "dead_port",
                "dead_port": int(candidate),
                "host": "127.0.0.1",
                "refused": True,
                "listener_absent": {"ipv4": True, "ipv6": True},
                "attempts": int(evidence.get("attempts") or attempts),
                "timings": list(evidence.get("timings") or []),
                "measured_unix": int(time.time()),
            }
    return {
        "ok": False,
        "kind": "dead_port",
        "code": "dead_port_unavailable",
        "problems": ["dead_port_unavailable"],
    }


def _default_tcp_listeners(port: int) -> dict:
    """Native *both-family* listener inventory for one loopback port (Windows).

    One ``Get-NetTCPConnection`` query returns rows for every family, so a single
    successful query is a complete inventory. The result distinguishes a failed or
    partial query (``ok`` False) from a genuinely empty table (``ok`` True with no
    rows): the caller must fail closed on the former and never prove ownership from
    the latter. ``-ErrorAction Stop`` with the CIM "No matching" error mapped to an
    empty table keeps a real query failure distinct from "nothing is listening".
    """
    command = (
        "$ok = $true; $rows = @(); "
        "try { $rows = @(Get-NetTCPConnection -State Listen -LocalPort %d -ErrorAction Stop) } "
        "catch { if ($_.Exception.Message -match 'No matching') { $rows = @() } else { $ok = $false } }; "
        "$out = @(); if ($ok) { $out = @($rows | ForEach-Object { @{ address = [string]$_.LocalAddress; pid = [int]$_.OwningProcess } }) }; "
        "ConvertTo-Json -InputObject @{ ok = $ok; rows = $out } -Compress -Depth 4"
        % int(port)
    )
    try:
        completed = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
            capture_output=True, text=True, timeout=20,
        )
    except Exception:  # noqa: BLE001
        return {"ok": False, "code": "inventory_unavailable", "rows": []}
    if completed.returncode != 0:
        return {"ok": False, "code": "inventory_unavailable", "rows": []}
    text = (completed.stdout or "").strip()
    if not text:
        return {"ok": False, "code": "inventory_unavailable", "rows": []}
    try:
        parsed = json.loads(text)
    except ValueError:
        return {"ok": False, "code": "inventory_unavailable", "rows": []}
    if not isinstance(parsed, Mapping) or parsed.get("ok") is not True:
        return {"ok": False, "code": "inventory_unavailable", "rows": []}
    rows = parsed.get("rows")
    if isinstance(rows, Mapping):
        rows = [rows]
    if not isinstance(rows, list):
        return {"ok": False, "code": "inventory_unavailable", "rows": []}
    normalized: list = []
    for row in rows:
        if not isinstance(row, Mapping):
            return {"ok": False, "code": "inventory_partial", "rows": []}
        try:
            normalized.append({"address": str(row.get("address")), "pid": int(row.get("pid"))})
        except (TypeError, ValueError):
            return {"ok": False, "code": "inventory_partial", "rows": []}
    return {"ok": True, "code": "ok", "rows": normalized}


def _classify_listener_inventory(raw, port: int):
    """Return ``(own, foreign, problems)`` from an inventory result.

    Accepts the production structured result or the legacy injected list used by
    fixtures. Any malformed/unknown/partial shape fails closed.
    """
    own: list = []
    foreign: list = []
    problems: list = []
    if raw is None:
        return own, foreign, ["listener_inventory_unavailable"]
    if isinstance(raw, Mapping):
        if raw.get("ok") is not True:
            problems.append(str(raw.get("code") or "listener_inventory_unavailable"))
        rows = raw.get("rows")
        if isinstance(rows, Mapping):
            rows = [rows]
        if not isinstance(rows, list):
            problems.append("listener_inventory_unavailable")
            rows = []
        for row in rows:
            if not isinstance(row, Mapping):
                problems.append("listener_inventory_partial")
                continue
            try:
                pid = int(row.get("pid"))
            except (TypeError, ValueError):
                problems.append("listener_inventory_partial")
                continue
            entry = {"pid": pid, "address": str(row.get("address"))}
            address = entry["address"]
            if address == "127.0.0.1" and pid == os.getpid():
                own.append(entry)
            else:
                foreign.append(entry)
        return own, foreign, problems
    if isinstance(raw, (list, tuple)):
        for item in raw:
            if not isinstance(item, Mapping):
                problems.append("listener_inventory_partial")
                continue
            try:
                pid = int(item.get("pid"))
            except (TypeError, ValueError):
                problems.append("listener_inventory_partial")
                continue
            (own if pid == os.getpid() else foreign).append({"pid": pid})
        return own, foreign, problems
    return own, foreign, ["listener_inventory_unavailable"]


def _default_tcp_owner(port: int, peer_port: int):
    """Owning PID of the exact loopback peer tuple, else ``None`` (fail closed).

    The listener is the *server* end (``127.0.0.1:port``) and the AI peer is the
    *client* end (``127.0.0.1:peer_port``). The peer's PID comes from the peer's own
    established (client-side) endpoint row - local ``127.0.0.1:peer_port``, remote
    ``127.0.0.1:port`` - not from the server-side row, which would only ever name
    this process. A successful query that yields exactly one valid row/PID is
    required: a nonzero exit, malformed output, zero or multiple rows, an ambiguous
    PID set or a missing/non-numeric owner all return ``None`` so the caller aborts
    the run. No partial result is ever returned on a query failure.
    """
    command = (
        "Get-NetTCPConnection -State Established -LocalPort %d -RemotePort %d -ErrorAction SilentlyContinue | "
        "Where-Object { $_.RemoteAddress -eq '127.0.0.1' -and $_.LocalAddress -eq '127.0.0.1' } | "
        "Select-Object -Property OwningProcess | ConvertTo-Json -Compress"
        % (int(peer_port), int(port))
    )
    try:
        completed = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
            capture_output=True, text=True, timeout=20,
        )
    except Exception:  # noqa: BLE001
        return None
    if completed.returncode != 0:
        return None
    text = (completed.stdout or "").strip()
    if not text:
        return None
    try:
        parsed = json.loads(text)
    except ValueError:
        return None
    rows = parsed if isinstance(parsed, list) else [parsed]
    if len(rows) != 1:
        return None
    row = rows[0]
    if not isinstance(row, Mapping):
        return None
    pid = row.get("OwningProcess")
    if pid is None:
        return None
    try:
        return int(pid)
    except (TypeError, ValueError):
        return None


def _listener_action_names(data: bytes) -> list:
    """Bounded JSON ``action`` names observed in the received bytes (never sent)."""
    names: list = []
    seen: set = set()
    for line in data.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            payload = json.loads(line)
        except ValueError:
            continue
        if not isinstance(payload, Mapping):
            continue
        action = payload.get("action")
        if not isinstance(action, str):
            continue
        action = action[: staging.LISTENER_MAX_ACTION_NAME]
        if action not in seen:
            seen.add(action)
            names.append(action)
        if len(names) >= staging.LISTENER_MAX_ACTIONS:
            break
    return names


class MeasurementListener:
    """Exclusive 127.0.0.1 one-connection measurement listener (section 4).

    Production binds a real loopback socket with exclusive address use and never a
    wildcard, ``::1`` or the admin port; it accepts exactly one connection, proves
    the peer is the owned AI PID through the native TCP table, sends zero bytes and
    closes the listening socket immediately after accepting so every reconnect is
    refused. ``SyntheticListener`` fixtures replace it in tests; the tool never
    accepts a caller-supplied log.
    """

    def __init__(
        self,
        port,
        *,
        mode,
        inventory=None,
        owner_lookup=None,
        now=None,
        socket_mod=None,
        threading_mod=None,
    ) -> None:
        import socket as _socket_mod
        import threading as _threading_mod

        self.port = int(port)
        self.mode = mode
        self._inventory = inventory or _default_tcp_listeners
        self._owner_lookup = owner_lookup or _default_tcp_owner
        self._now = now or time.time
        self._socket = socket_mod or _socket_mod
        self._threading = threading_mod or _threading_mod
        self._server = None
        self._conn = None
        self._thread = None
        self._armed = self._threading.Event()
        self._stop = self._threading.Event()
        self._done = self._threading.Event()
        self._ai_pids: set = set()
        self._received = bytearray()
        self._state = {
            "accepted": 0,
            "peer_pid": None,
            "peer_is_owned_ai": None,
            "peer_host": None,
            "peer_port": None,
            "sent_bytes": 0,
            "closed": False,
            "fin": False,
            "close_time": None,
            "open_until": None,
            "peer_eof": False,
            "eof_time": None,
            "problems": [],
        }

    def start(self) -> dict:
        server = self._socket.socket(self._socket.AF_INET, self._socket.SOCK_STREAM)
        try:
            if hasattr(self._socket, "SO_EXCLUSIVEADDRUSE"):
                server.setsockopt(self._socket.SOL_SOCKET, self._socket.SO_EXCLUSIVEADDRUSE, 1)
            server.bind(("127.0.0.1", self.port))
            server.listen(1)
            try:
                server.settimeout(staging.MEASUREMENT_DEADLINE_SECONDS)
            except Exception:  # noqa: BLE001
                pass
        except Exception:  # noqa: BLE001
            self._close_server(server)
            return {"ok": False, "code": "listener_bind_failed"}
        try:
            raw = self._inventory(self.port)
        except Exception:  # noqa: BLE001
            raw = None
        own, foreign, problems = _classify_listener_inventory(raw, self.port)
        # Fail closed unless the native inventory positively proves this exact
        # process owns the loopback listen socket and nothing else does.
        if not own or foreign or problems:
            self._close_server(server)
            return {
                "ok": False,
                "code": "listener_ownership_unproven",
                "own": own,
                "foreign": foreign,
                "problems": problems,
            }
        self._server = server
        self._thread = self._threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return {"ok": True, "code": "listener_started"}

    def arm(self, ai_pids) -> None:
        self._ai_pids = {int(pid) for pid in (ai_pids or [])}
        self._armed.set()

    def _close_server(self, server=None) -> None:
        target = self._server if server is None else server
        if target is None:
            return
        self._server = None
        try:
            target.close()
        except Exception:  # noqa: BLE001
            pass

    def _close_conn(self) -> None:
        conn = self._conn
        self._conn = None
        if conn is None:
            return
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass

    def _retain(self, data: bytes) -> None:
        remaining = staging.LISTENER_MAX_RECEIVED_BYTES - len(self._received)
        if remaining > 0:
            self._received.extend(data[:remaining])

    def _serve(self) -> None:
        try:
            if not self._armed.wait(staging.MEASUREMENT_DEADLINE_SECONDS):
                self._done.set()
                return
            conn, addr = self._server.accept()
        except Exception:  # noqa: BLE001
            self._close_server()
            self._done.set()
            return
        self._state["accepted"] = 1
        self._conn = conn
        # Bind the exact observed endpoint tuple, never a guessed one.
        try:
            self._state["peer_host"] = str(addr[0])
            self._state["peer_port"] = int(addr[1])
        except (TypeError, ValueError, IndexError):
            self._state["peer_host"] = None
            self._state["peer_port"] = None
        owned = False
        if self._state["peer_host"] != "127.0.0.1" or self._state["peer_port"] is None:
            self._state["problems"].append("listener_peer_endpoint_not_loopback")
        else:
            try:
                self._state["peer_pid"] = self._owner_lookup(self.port, self._state["peer_port"])
            except Exception:  # noqa: BLE001
                self._state["peer_pid"] = None
            owned = self._state["peer_pid"] is not None and self._state["peer_pid"] in self._ai_pids
            if not owned:
                self._state["problems"].append("listener_peer_not_owned_ai")
        self._state["peer_is_owned_ai"] = bool(owned)
        # Close the listening socket immediately after accepting so every reconnect
        # is refused, then abort promptly on a wrong peer (never read or hold).
        self._close_server()
        if not owned:
            self._close_conn()
            self._done.set()
            return
        try:
            conn.settimeout(0.25)
        except Exception:  # noqa: BLE001
            pass
        while not self._stop.is_set():
            try:
                data = conn.recv(4096)
            except TimeoutError:
                # A receive timeout is not an EOF. P2_CLOSE treats the quiet period
                # as "drained"; SILENT keeps holding and waiting for real data/stop.
                if self.mode == "P2_CLOSE":
                    break
                continue
            except Exception:  # noqa: BLE001
                # A reset/error is an honest end of the hold, recorded as such.
                self._state["problems"].append("listener_receive_error")
                self._state["peer_eof"] = True
                self._state["eof_time"] = round(self._now(), 6)
                self._state["open_until"] = self._state["eof_time"]
                break
            if data:
                self._retain(data)
                continue
            # An empty read is the peer's EOF.
            if self.mode == "P2_CLOSE":
                break
            # SILENT: an honest peer EOF ends the hold. Record the true EOF time and
            # stop instead of busy-spinning on a dead socket; the hold is never
            # extended past the observed EOF.
            self._state["peer_eof"] = True
            self._state["eof_time"] = round(self._now(), 6)
            self._state["open_until"] = self._state["eof_time"]
            break
        if self.mode == "P2_CLOSE":
            # A graceful FIN is claimed only when ``shutdown`` actually succeeds; a
            # failed shutdown is never recorded as a successful FIN.
            fin_ok = False
            try:
                conn.shutdown(self._socket.SHUT_WR)
                fin_ok = True
            except Exception:  # noqa: BLE001
                fin_ok = False
            self._state["closed"] = bool(fin_ok)
            self._state["fin"] = bool(fin_ok)
            if fin_ok:
                self._state["close_time"] = round(self._now(), 6)
        elif self._state["open_until"] is None:
            self._state["open_until"] = round(self._now(), 6)
        self._done.set()

    def finish(self, timeout: float = 30.0) -> dict:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout)
        self._close_conn()
        # Never fabricate a hold merely because ``finish`` was called: a premature
        # peer EOF already capped ``open_until`` at the true EOF time.
        if self._state["open_until"] is None and self.mode != "P2_CLOSE":
            if self._state.get("peer_eof") is not True and self._state["accepted"] == 1:
                self._state["open_until"] = round(self._now(), 6)
        self._close_server()
        return self._state

    def log_fields(self, nonce: str, phase: str) -> dict:
        state = self._state
        received = bytes(self._received)
        actions = _listener_action_names(received)
        return {
            "probe": "listener",
            "schema": staging.LISTENER_SCHEMA,
            "patch": staging.PATCH_ID,
            "nonce": nonce,
            "phase": phase,
            "port": self.port,
            "families": "ipv4",
            "exclusive": "true",
            "listener_pid": os.getpid(),
            "accepted": state["accepted"],
            "peer_pid": state["peer_pid"],
            "peer_host": state["peer_host"],
            "peer_port": state["peer_port"],
            "peer_is_owned_ai": state["peer_is_owned_ai"],
            "sent_bytes": state["sent_bytes"],
            "received_bytes": len(received),
            "received_sha256": hashlib.sha256(received).hexdigest(),
            "actions": ",".join(actions),
            "action_count": len(actions),
            "closed": state["closed"],
            "fin": state["fin"],
            "close_time": state["close_time"],
            "open_until": state["open_until"],
            "peer_eof": state["peer_eof"],
            "eof_time": state["eof_time"],
        }


PHASE_LAUNCH_ORDER = (
    "P1A",
    "P1B",
    "FULL_P1",
    "CRASH",
    "P2_INITIAL",
    "P2_CLOSE",
    "P2_SILENT",
)


def _read_staged_p2_fields(staging_root) -> dict:
    try:
        paths = staging.role_paths(staging_root, "ai")
    except Exception:  # noqa: BLE001
        return {}
    target = paths.data / "Balatro" / staging.PROBE_P2
    if not target.is_file():
        return {}
    try:
        return staging.parse_probe(target.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return {}


def _p2_has_exhausted_cycle(fields: Mapping) -> bool:
    index = 1
    while f"cycle{index}_outcome" in fields:
        if fields.get(f"cycle{index}_outcome") == "exhausted":
            return True
        index += 1
    return False


def _make_p2_settle(staging_root, phase: str, *, now: Callable[[], float] = time.time) -> Callable[[list], bool]:
    """The tool decides when a P2 run's required evidence has settled (section 4)."""
    quiet = 5.0 if phase == "P2_INITIAL" else 3.0
    first_settled: dict = {"at": None}

    def settle(_statuses=None) -> bool:
        fields = _read_staged_p2_fields(staging_root)
        if not fields:
            first_settled["at"] = None
            return False
        if phase == "P2_INITIAL":
            last = _as_number(fields.get("last_time"))
            ready = _as_number(fields.get("last_time")) is not None and fields.get("first_result") not in (None, "")
        else:
            index = 1
            last = None
            ready = False
            while f"cycle{index}_end_time" in fields:
                if fields.get(f"cycle{index}_outcome") == "exhausted":
                    ready = True
                    last = _as_number(fields.get(f"cycle{index}_end_time"))
                index += 1
        if not ready or last is None or (now() - last) < quiet:
            first_settled["at"] = None
            return False
        if first_settled["at"] is None:
            first_settled["at"] = now()
        return (now() - first_settled["at"]) >= quiet

    return settle


def _as_number(value):
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _make_probe_settle(
    staging_root, phase: str, nonce: str, *, now: Callable[[], float] = time.time, quiet: float = 3.0
) -> Callable[[list], bool]:
    """Settle CRASH/P1B/FULL_P1 once every required nonce-bound probe is present."""
    import isolation_certificate

    roles = isolation_certificate.PHASE_ROLES.get(phase, ())
    labels = isolation_certificate.PHASE_EVIDENCE.get(phase, ())
    first_settled: dict = {"at": None}

    def settle(_statuses=None) -> bool:
        ready = True
        for role in roles:
            try:
                paths = staging._paths_for_role(staging_root, role)
            except Exception:  # noqa: BLE001
                ready = False
                break
            save = paths.data / "Balatro"
            for label in labels:
                name = isolation_certificate.PROBE_BY_LABEL.get(label)
                if not name:
                    continue
                target = save / name
                if not target.is_file():
                    ready = False
                    break
                try:
                    fields = staging.parse_probe(target.read_text(encoding="utf-8", errors="replace"))
                except OSError:
                    ready = False
                    break
                if fields.get("nonce") != nonce:
                    ready = False
                    break
            if not ready:
                break
        if not ready:
            first_settled["at"] = None
            return False
        if first_settled["at"] is None:
            first_settled["at"] = now()
        return (now() - first_settled["at"]) >= quiet

    return settle


def _write_listener_log(staging_root, fields: Mapping) -> dict:
    paths = staging.role_paths(staging_root, "ai")
    save_dir = paths.data / "Balatro"
    target = save_dir / staging.PROBE_LISTENER
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = dict(fields)
    payload["save"] = str(save_dir)
    text = "\n".join(f"{key}={'' if value is None else value}" for key, value in payload.items()) + "\n"
    target.write_text(text, encoding="utf-8")
    return {"ok": True, "path": str(target)}


def execute_measurement_phase(
    staging_root=None,
    *,
    phase: str,
    live_install_root=None,
    live_appdata_root=None,
    steam_root=None,
    port=8788,
    backup_root=None,
    session_id=None,
    popen: Callable = subprocess.Popen,
    create_time_reader: Callable = read_owned_create_time,
    enumerator: Optional[ProcessEnumerator] = None,
    job_factory: Optional[Callable[[], object]] = None,
    resume: Optional[Callable[[object], bool]] = None,
    on_terminate: Optional[Callable[[OwnedProcess], None]] = None,
    supervisor: Optional[Callable[[LaunchSession], dict]] = None,
    timeout: Optional[float] = None,
    dead_port_probe=None,
    listener_factory: Optional[Callable[..., object]] = None,
    settle_now: Optional[Callable[[], float]] = None,
) -> dict:
    """Tool-owned measurement launch path for the ordered measurement phases.

    N2: CRASH is triggered by the tool (env-gated wrapped error handler) and read
    back from fresh nonce-bound probes plus the tool-owned end code. Section 4:
    P2_INITIAL uses a measured dead port; P2_CLOSE/P2_SILENT use the tool-owned
    exclusive 127.0.0.1 listener. N3: every run has a hard deadline and is ended by
    the tool with a distinct recorded code once the required evidence has settled.
    Nothing here enables an AI capability or a match.
    """
    import isolation_certificate

    staging_root = Path(staging_root or staging.DEFAULT_STAGING_ROOT)
    backup_root = Path(backup_root or staging.DEFAULT_BACKUP_ROOT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    appdata_root = resolve_live_appdata(live_appdata_root)
    enumerator = enumerator or default_enumerator()
    if phase not in PHASE_LAUNCH_ORDER:
        return {"ok": False, "code": "unknown_phase", "problems": ["unknown_phase"]}
    if timeout is None:
        timeout = staging.MEASUREMENT_DEADLINE_SECONDS
    session_id = session_id or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    live_map = _live_roots_map(live_install_root, appdata_root, steam_root, None)
    sources = live_source_map(live_install_root, appdata_root, steam_root)

    def closed_check() -> bool:
        return bool(check_live_balatro_closed(enumerator, live_install_root)["ok"])

    def backup_verify() -> dict:
        return check_backup_evidence(backup_root, sources)

    measurement_setup = None
    launch_port = port
    if phase == "P2_INITIAL":
        dead = measure_dead_port(port=port, prober=dead_port_probe)
        if not dead.get("ok"):
            return {"ok": False, "code": dead.get("code", "dead_port_unavailable"), "phase": phase,
                    "problems": dead.get("problems", ["dead_port_unavailable"])}
        launch_port = int(dead["dead_port"])
        measurement_setup = dead
    elif phase in ("P2_CLOSE", "P2_SILENT"):
        launch_port = int(port)
        measurement_setup = {"kind": "listener", "port": launch_port, "mode": phase}
    elif phase == "CRASH":
        measurement_setup = {"kind": "crash", "stimulus": staging.MEASUREMENT_CRASH_STIMULUS}

    session = None
    listener = None
    listener_factory = listener_factory or MeasurementListener
    try:
        if phase in ("P2_CLOSE", "P2_SILENT"):
            listener = listener_factory(launch_port, mode=phase)
            started = listener.start()
            if not started.get("ok"):
                return {"ok": False, "code": started.get("code", "listener_start_failed"),
                        "phase": phase, "problems": [started.get("code", "listener_start_failed")]}
        prepared = isolation_certificate.prepare_session(
            staging_root,
            live=live_map,
            session_id=session_id,
            port=launch_port if phase != "P1A" else None,
            closed_check=closed_check,
            phase=phase,
            backup_verify=backup_verify,
            measurement_setup=measurement_setup,
        )
        if not prepared.get("ok"):
            return {"code": "measurement_refused", "phase": phase, "problems": prepared.get("problems", [])}
        open_session = prepared["record"]
        if phase == "P1A":
            plan = build_bootstrap_plan(
                staging_root=staging_root,
                live_install_root=live_install_root,
                backup_root=backup_root,
                enumerator=enumerator,
                session_id=session_id,
                live_appdata_root=appdata_root,
                steam_root=steam_root,
            )
            session = execute_bootstrap(
                plan,
                staging_root=staging_root,
                backup_root=backup_root,
                live_install_root=live_install_root,
                live_appdata_root=appdata_root,
                steam_root=steam_root,
                popen=popen,
                create_time_reader=create_time_reader,
                enumerator=enumerator,
                job_factory=job_factory,
                resume=resume,
                on_terminate=on_terminate,
                open_session=open_session,
            )
        else:
            plan = build_launch_plan(
                staging_root=staging_root,
                port=launch_port,
                live_install_root=live_install_root,
                backup_root=backup_root,
                enumerator=enumerator,
                session_id=session_id,
                live_appdata_root=appdata_root,
                steam_root=steam_root,
                require_certificate=False,
            )
            session = execute_launch(
                plan,
                staging_root=staging_root,
                backup_root=backup_root,
                live_install_root=live_install_root,
                live_appdata_root=appdata_root,
                steam_root=steam_root,
                popen=popen,
                create_time_reader=create_time_reader,
                enumerator=enumerator,
                job_factory=job_factory,
                resume=resume,
                on_terminate=on_terminate,
                open_session=open_session,
                require_certificate=False,
            )
        if not isinstance(session, LaunchSession) or not session.ok:
            isolation_certificate.record_session_failure(
                staging_root, session_id=session_id, reason=str(getattr(session, "code", "launch_failed"))
            )
            return {"ok": False, "code": "measurement_launch_failed", "phase": phase,
                    "result": _as_dict(session)}
        owned_pids = [record.pid for record in session.records]
        ai_pids = [record.pid for record in session.records if record.role == "ai"]
        if listener is not None:
            arm = getattr(listener, "arm", None)
            if callable(arm):
                arm(ai_pids)

        def unexpected(statuses=None) -> dict:
            live = check_live_balatro_closed(enumerator, live_install_root)
            if not live.get("ok"):
                return live
            return check_no_staged_session(
                enumerator, staging_root, live_install_root, ignore_pids=owned_pids
            )

        end_mode = None
        end_code = None
        settle = None
        if phase in ("CRASH", "P1B", "FULL_P1", "P2_INITIAL", "P2_CLOSE", "P2_SILENT"):
            end_mode = staging.MEASUREMENT_END_MODE
            end_code = staging.MEASUREMENT_END_CODES[phase]
            if phase in ("P2_INITIAL", "P2_CLOSE", "P2_SILENT"):
                settle = _make_p2_settle(staging_root, phase, now=settle_now or time.time)
            else:
                settle = _make_probe_settle(
                    staging_root, phase, open_session.get("nonce") or "", now=settle_now or time.time
                )
        supervision = (
            supervisor(session)
            if supervisor is not None
            else supervise_session(
                session,
                timeout=timeout,
                unexpected_check=unexpected,
                settle=settle,
                end_mode=end_mode,
                end_code=end_code,
            )
        )
        if not supervision.get("ok"):
            isolation_certificate.record_session_failure(
                staging_root, session_id=session_id, reason="supervision_failed"
            )
            return {"ok": False, "code": "measurement_supervision_failed", "phase": phase, "supervision": supervision}
        if listener is not None:
            state = listener.finish()
            _write_listener_log(staging_root, listener.log_fields(open_session.get("nonce"), phase))
            if not state.get("peer_is_owned_ai"):
                isolation_certificate.record_session_failure(
                    staging_root, session_id=session_id, reason="listener_peer_not_owned_ai"
                )
                return {"ok": False, "code": "listener_peer_not_owned_ai", "phase": phase, "listener": state}
        receipt = isolation_certificate.record_phase_receipt(
            staging_root,
            phase=phase,
            session_id=session_id,
            session=session,
            live=live_map,
            port=launch_port if phase != "P1A" else None,
            live_closed=closed_check,
        )
        return {"phase": phase, "supervision": supervision, "receipt": receipt}
    except BaseException as error:  # noqa: BLE001
        try:
            isolation_certificate.record_session_failure(
                staging_root, session_id=session_id, reason=f"exception:{type(error).__name__}"
            )
        except Exception:  # noqa: BLE001
            pass
        raise
    finally:
        if isinstance(session, LaunchSession):
            session.close()
        if listener is not None:
            try:
                listener.finish()
            except Exception:  # noqa: BLE001
                pass


def prepare_match_session(
    staging_root=None,
    *,
    session_id: str,
    port: int,
    live_install_root=None,
    live_appdata_root=None,
    steam_root=None,
    backup_root=None,
    extra_live_roots: Optional[Sequence] = None,
) -> dict:
    """Host-safe normal-practice preparation (phase MATCH, concrete checks).

    The host supplies only ids and roots. Certificate validity, live-closed and the
    fresh verified backup are checked here with production code so the host never
    hands over a ``lambda: True`` or a fabricated backup.
    """
    staging_root = Path(staging_root or staging.DEFAULT_STAGING_ROOT)
    backup_root = Path(backup_root or staging.DEFAULT_BACKUP_ROOT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    appdata_root = resolve_live_appdata(live_appdata_root)
    live_map = _live_roots_map(live_install_root, appdata_root, steam_root, extra_live_roots)
    sources = live_source_map(live_install_root, appdata_root, steam_root)
    enumerator = default_enumerator()
    return isolation_certificate.prepare_session(
        staging_root,
        live=live_map,
        session_id=session_id,
        port=port,
        closed_check=lambda: bool(check_live_balatro_closed(enumerator, live_install_root)["ok"]),
        phase=isolation_certificate.MATCH,
        backup_verify=lambda: check_backup_evidence(backup_root, sources),
    )


def finalize_match_session(
    staging_root=None,
    *,
    session: LaunchSession,
    live_install_root=None,
    live_appdata_root=None,
    steam_root=None,
    extra_live_roots: Optional[Sequence] = None,
    backup_id=None,
) -> dict:
    """Host-safe closure: measure the retained session's exit and live-closed, then record it.

    ``session`` is the exact ``LaunchSession`` returned by the launcher; its owned
    handles and the real closed-game check are used, so the host cannot fake an
    exit or a diff.
    """
    staging_root = Path(staging_root or staging.DEFAULT_STAGING_ROOT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    appdata_root = resolve_live_appdata(live_appdata_root)
    live_map = _live_roots_map(live_install_root, appdata_root, steam_root, extra_live_roots)
    enumerator = default_enumerator()
    return isolation_certificate.record_session_verdict(
        staging_root,
        session_id=session.session_id,
        live=live_map,
        session=session,
        live_closed=lambda: bool(check_live_balatro_closed(enumerator, live_install_root)["ok"]),
        backup_id=backup_id,
    )


def abandon_prepared_session(
    staging_root=None,
    *,
    session_id: str,
    live_install_root=None,
    live_appdata_root=None,
    steam_root=None,
    extra_live_roots: Optional[Sequence] = None,
) -> dict:
    """Host-safe measured closure of a prepared-but-never-spawned session."""
    staging_root = Path(staging_root or staging.DEFAULT_STAGING_ROOT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    appdata_root = resolve_live_appdata(live_appdata_root)
    live_map = _live_roots_map(live_install_root, appdata_root, steam_root, extra_live_roots)
    return isolation_certificate.record_session_no_spawn(
        staging_root, session_id=session_id, live=live_map
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="launch_practice",
        description="Plan and gate the staged practice bootstrap. Never launches while isolation is unproven.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    plan = sub.add_parser("plan", help="print the redacted launch plan and gate results")
    plan.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
    plan.add_argument("--backup-root", default=str(staging.DEFAULT_BACKUP_ROOT))
    plan.add_argument("--install", default=str(staging.DEFAULT_INSTALL))
    plan.add_argument("--appdata", default=None)
    plan.add_argument("--steam-root", default=None)
    plan.add_argument("--port", type=int, default=8788)

    launch = sub.add_parser("launch", help="gated launch; refuses unless every gate passes")
    launch.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
    launch.add_argument("--backup-root", default=str(staging.DEFAULT_BACKUP_ROOT))
    launch.add_argument("--install", default=str(staging.DEFAULT_INSTALL))
    launch.add_argument("--appdata", default=None)
    launch.add_argument("--steam-root", default=None)
    launch.add_argument("--port", type=int, default=8788)
    launch.add_argument("--timeout", type=float, default=None)
    launch.add_argument("--poll-interval", type=float, default=1.0)

    cleanup = sub.add_parser("cleanup", help="terminate only launcher-owned processes")
    cleanup.add_argument("--session", required=True)
    cleanup.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
    cleanup.add_argument("--install", default=str(staging.DEFAULT_INSTALL))

    backup = sub.add_parser("backup", help="hash-manifested live backup (requires the game closed)")
    backup.add_argument("--install", default=str(staging.DEFAULT_INSTALL))
    backup.add_argument("--appdata", default=None)
    backup.add_argument("--steam-userdata", default=None)
    backup.add_argument("--steam-root", default=None)
    backup.add_argument("--backup-root", default=str(staging.DEFAULT_BACKUP_ROOT))
    backup.add_argument("--execute", action="store_true")

    bootstrap = sub.add_parser("bootstrap", help="plan/gate the minimal Steam-disabled bootstrap run")
    bootstrap.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
    bootstrap.add_argument("--backup-root", default=str(staging.DEFAULT_BACKUP_ROOT))
    bootstrap.add_argument("--install", default=str(staging.DEFAULT_INSTALL))
    bootstrap.add_argument("--appdata", default=None)
    bootstrap.add_argument("--steam-root", default=None)
    bootstrap.add_argument("--execute", action="store_true")
    bootstrap.add_argument("--timeout", type=float, default=None)
    bootstrap.add_argument("--poll-interval", type=float, default=1.0)

    measure = sub.add_parser("measure", help="tool-owned phase measurement (P1B/FULL_P1/CRASH/P2_*)")
    measure.add_argument(
        "--phase",
        required=True,
        choices=("P1B", "FULL_P1", "CRASH", "P2_INITIAL", "P2_CLOSE", "P2_SILENT"),
    )
    measure.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
    measure.add_argument("--backup-root", default=str(staging.DEFAULT_BACKUP_ROOT))
    measure.add_argument("--install", default=str(staging.DEFAULT_INSTALL))
    measure.add_argument("--appdata", default=None)
    measure.add_argument("--steam-root", default=None)
    measure.add_argument("--port", type=int, default=8788)
    measure.add_argument("--timeout", type=float, default=None)

    ack = sub.add_parser("acknowledge-lockout", help="append-only acknowledgement of the global lockout")
    ack.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
    ack.add_argument("--operator", required=True)
    ack.add_argument("--reason", required=True)

    return parser


def _emit(payload: Mapping) -> None:
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


def _as_dict(value) -> dict:
    if isinstance(value, LaunchSession):
        return value.to_dict()
    if isinstance(value, Mapping):
        return dict(value)
    return {"ok": False, "code": "unexpected_result"}


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "plan":
        plan = build_launch_plan(
            staging_root=args.staging_root,
            port=args.port,
            live_install_root=args.install,
            backup_root=args.backup_root,
            live_appdata_root=args.appdata,
            steam_root=args.steam_root,
        )
        _emit(redacted_plan(plan))
        return 0
    if args.command == "launch":
        # Host-only. A bare CLI launch is refused: only the practice host may run
        # the whole lifecycle with a prepared open session and a live certificate.
        _emit(
            {
                "ok": False,
                "code": "host_only_launch_requires_lifecycle",
                "detail": (
                    "launch requires a prepared open session and a current certificate; "
                    "use the practice host, or 'bootstrap --execute' / 'measure --phase' "
                    "for tool-owned measurement runs"
                ),
            }
        )
        return 3
    if args.command == "cleanup":
        result = cleanup_session(
            args.session,
            default_enumerator(),
            live_install_root=args.install,
            staging_root=args.staging_root,
        )
        _emit(result)
        return 0 if result["ok"] else 3
    if args.command == "backup":
        result = create_live_backup(
            install_root=args.install,
            appdata_root=args.appdata,
            steam_userdata_root=args.steam_userdata,
            steam_root=args.steam_root,
            backup_root=args.backup_root,
            execute=args.execute,
        )
        _emit(result)
        return 0 if result["ok"] else 3
    if args.command == "bootstrap":
        plan = build_bootstrap_plan(
            staging_root=args.staging_root,
            live_install_root=args.install,
            backup_root=args.backup_root,
            live_appdata_root=args.appdata,
            steam_root=args.steam_root,
        )
        if args.execute:
            # Tool-owned P1A phase lifecycle: prepare (exclusive, single nonce) →
            # launch → supervise → record the measured receipt. No bare launch.
            result = execute_measurement_phase(
                args.staging_root,
                phase="P1A",
                live_install_root=args.install,
                live_appdata_root=args.appdata,
                steam_root=args.steam_root,
                backup_root=args.backup_root,
                timeout=args.timeout,
            )
            _emit({"plan": redacted_plan(plan), "measurement": result})
            return 0 if result.get("receipt", {}).get("ok") else 3
        _emit(redacted_plan(plan))
        return 0 if plan["may_launch"] else 3
    if args.command == "measure":
        result = execute_measurement_phase(
            args.staging_root,
            phase=args.phase,
            live_install_root=args.install,
            live_appdata_root=args.appdata,
            steam_root=args.steam_root,
            port=args.port,
            backup_root=args.backup_root,
            timeout=args.timeout,
        )
        _emit(result)
        return 0 if result.get("receipt", {}).get("ok") else 3
    if args.command == "acknowledge-lockout":
        result = isolation_certificate.acknowledge_lockout(
            args.staging_root, operator=args.operator, reason=args.reason
        )
        _emit(result)
        return 0 if result.get("ok") else 3
    _emit({"ok": False, "code": "unknown_command"})
    return 2


if __name__ == "__main__":
    sys.exit(main())
