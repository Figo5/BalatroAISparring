"""Read-only Windows/LuaJIT identity gate against this test process only.

No game, child process, live file, or process termination is involved.
"""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import sys
from lupa.luajit21 import LuaRuntime


def main():
    if os.name != "nt":
        raise RuntimeError("This native identity acceptance check requires Windows")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = Path(__file__).resolve().parent.parent.as_posix()
    adapter, library_type, symbol_type = lua.execute('''
      local ffi=require('ffi')
      local host=dofile(ROOT..'/AISparring/integration/companion_host.lua')
      local adapter=host.default_identity({ffi=ffi})
      local kernel=ffi.load('kernel32')
      return adapter,type(kernel),type(kernel.GetCurrentProcessId)
    ''')
    assert adapter is not None, f"Production identity rejected real ffi ({library_type}/{symbol_type})"
    current = adapter["current"]()
    assert current is not None and current["pid"] == os.getpid(), "Wrong or missing current-process identity"

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    stamps = [wintypes.FILETIME() for _ in range(4)]
    assert kernel.GetProcessTimes(kernel.GetCurrentProcess(), *(ctypes.byref(v) for v in stamps))
    expected = ((stamps[0].dwHighDateTime << 32) | stamps[0].dwLowDateTime) / 10_000_000 - 11644473600
    assert abs(current["create_time"] - expected) < 0.01, "Creation-time conversion differs from native measurement"
    again = adapter["process"](os.getpid())
    assert again is not None and again["create_time"] == current["create_time"]
    assert adapter["process"](-1) is None
    print("PASS real LuaJIT FFI current-process PID and creation time match native Windows query")
    print("PASS repeated self-identity and invalid-PID refusal; no game or other process touched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
