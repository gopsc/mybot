"""Sandbox backends for the workspace shell.

``off`` keeps the existing workspace jail. ``auto`` uses bubblewrap when it can
actually create a namespace, otherwise it falls back to the jail. ``bwrap``
requires bubblewrap and fails instead of silently running unsandboxed.

The bubblewrap profile mounts the host read-only, gives the workspace a
read-write overlay, provides a private ``/tmp`` and `/proc`, clears the
environment, and unshares the network, PID, IPC and UTS namespaces. It is only
selected after a real probe: sandboxing must not break silently.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

from .security import SecurityError

SANDBOX_MODES = ("off", "auto", "bwrap")
_USABLE = None


def _probe_bwrap():
    if os.name != "posix" or not sys.platform.startswith("linux"):
        return False
    executable = shutil.which("bwrap")
    if not executable:
        return False
    try:
        completed = subprocess.run(
            [executable, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
             "--unshare-pid", "--unshare-net", "--", "/bin/true"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=3, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0


def bwrap_usable():
    global _USABLE
    if _USABLE is None:
        _USABLE = _probe_bwrap()
    return _USABLE


def resolve_backend(mode):
    mode = str(mode or "off").strip().lower()
    if mode not in SANDBOX_MODES:
        raise SecurityError(f"Unknown sandbox mode: {mode}")
    if mode == "off":
        return "workspace"
    if bwrap_usable():
        return "bwrap"
    if mode == "bwrap":
        raise SecurityError("bubblewrap is unavailable or cannot create a sandbox namespace")
    return "workspace"


def describe_backend(mode):
    backend = resolve_backend(mode)
    if backend == "bwrap":
        return "bubblewrap: read-only host, private /tmp and PID/network namespaces"
    return "workspace jail only (no OS sandbox; install bubblewrap for namespace isolation)"


def backend_status():
    try:
        backend = resolve_backend("auto")
    except SecurityError as exc:  # pragma: no cover - auto never raises here
        return {"name": "sandbox", "label": "Shell sandbox", "status": "warning",
                "backend": "unavailable", "detail": str(exc)}
    return {
        "name": "sandbox",
        "label": "Shell sandbox",
        "status": "ok" if backend == "bwrap" else "warning",
        "optional": True,
        "backend": backend,
        "detail": describe_backend("off" if backend == "workspace" else "bwrap"),
    }


def wrap_shell(argv, *, mode, workspace, cwd):
    """Return ``(argv, backend)``; only bubblewrap rewrites the command."""
    backend = resolve_backend(mode)
    if backend != "bwrap":
        return list(argv), backend
    executable = shutil.which("bwrap")
    root = str(workspace)
    command = str(cwd)
    return [
        executable, "--die-with-parent", "--new-session",
        "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-net",
        "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
        "--bind", root, root, "--chdir", command,
        "--clearenv", "--setenv", "PATH", "/usr/local/bin:/usr/bin:/bin",
        "--setenv", "HOME", "/tmp", "--setenv", "TMPDIR", "/tmp",
        "--setenv", "LANG", "C.UTF-8", "--", *argv,
    ], backend
