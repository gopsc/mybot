"""Platform shell process helpers shared by the workspace tool and the HAL.

None of this is a sandbox: commands run with the host user's privileges and
environment. The callers own gating (workspace confirmation prompts, the
HAL --allow-hardware runtime gate) and their own output ceilings.
"""
from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess


def shell_command(command):
    """Return (argv, popen_options, interpreter) for one shell command string.

    POSIX runs /bin/sh -c in a new session so the whole tree can be killed;
    Windows uses cmd.exe with /s quoting because Popen(list) would re-quote
    with CRT backslash escapes that cmd.exe does not understand.
    """
    if os.name != "nt":
        interpreter = "/bin/sh"
        return [interpreter, "-c", command], {"start_new_session": True}, interpreter
    interpreter = str(windows_system_directory() / "cmd.exe")
    return (f'"{interpreter}" /d /s /c "{command}"', {}, interpreter)


def read_pipe(pipe):
    """Nonblocking-friendly read: b"" on EOF, None when nothing is buffered."""
    if os.name == "nt":
        # Peek first: Windows anonymous pipes are not selectable and Python 3.11
        # cannot set them nonblocking. No reader threads can be left behind.
        import ctypes
        from ctypes import wintypes
        import msvcrt
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        peek = kernel.PeekNamedPipe
        peek.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                         ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD),
                         ctypes.POINTER(wintypes.DWORD)]
        peek.restype = wintypes.BOOL
        available = wintypes.DWORD()
        if not peek(msvcrt.get_osfhandle(pipe.fileno()), None, 0, None, ctypes.byref(available), None):
            if ctypes.get_last_error() in (109, 232):
                return b""
            raise OSError("Could not read shell output pipe")
        return os.read(pipe.fileno(), min(65536, available.value)) if available.value else None
    try:
        return os.read(pipe.fileno(), 65536)
    except BlockingIOError:
        return None


def kill_tree(process):
    """Best-effort kill of the child and its descendants; never raises."""
    if os.name != "nt":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    else:
        taskkill = windows_system_directory() / "taskkill.exe"
        if taskkill.is_file():
            try:
                subprocess.run([str(taskkill), "/PID", str(process.pid), "/T", "/F"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=3, check=False)
            except (OSError, subprocess.TimeoutExpired):
                pass  # Still kill/reap the direct child when tree cleanup is unavailable.
        if process.poll() is None:
            process.kill()


def windows_system_directory():
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    get_directory = kernel.GetSystemDirectoryW
    get_directory.argtypes = [wintypes.LPWSTR, wintypes.UINT]
    get_directory.restype = wintypes.UINT
    buffer = ctypes.create_unicode_buffer(32768)
    size = get_directory(buffer, len(buffer))
    if not 0 < size < len(buffer):
        raise OSError("Cannot locate the Windows system shell")
    return Path(buffer.value)
