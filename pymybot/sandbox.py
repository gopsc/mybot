"""Sandbox backends for the workspace shell.

Without protected paths, ``off`` keeps the existing workspace cwd (no OS
isolation). ``auto`` uses bubblewrap when it can actually create a namespace,
otherwise it falls back. ``bwrap`` requires bubblewrap. Protected prompt paths
require a usable bubblewrap backend regardless of the fallback policy; ``off``
is rejected. Their read-only mounts protect writes, not shell confidentiality.

The bubblewrap profile mounts the host read-only, gives the workspace a
read-write overlay, provides a private ``/tmp`` and `/proc`, clears the
environment, and unshares the network, PID, IPC and UTS namespaces. It is only
selected after a real probe: sandboxing must not break silently.
"""
from __future__ import annotations

import os
from pathlib import Path
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


def wrap_shell(argv, *, mode, workspace, cwd, protected_paths=()):
    """Return ``(argv, backend)``; protected roots must already exist.

    Workspace validates linked paths and root identities before dispatch. Mount
    protections follow its writable bind so a nested prompt root stays read-only.
    """
    protected_paths = tuple(protected_paths)
    backend = resolve_backend(mode)
    if protected_paths and backend != "bwrap":
        raise SecurityError("Prompt protection requires usable bubblewrap; enable sandbox=auto or bwrap. "
                            "Shell was not executed; unisolated fallback is disabled")
    if backend != "bwrap":
        # Preserve the platform's argv shape: Windows uses one cmd.exe string.
        return argv, backend
    executable = shutil.which("bwrap")
    if not executable:
        raise SecurityError("bubblewrap is unavailable; shell was not executed")
    protected_mounts = []
    if protected_paths:
        workspace_path = Path(workspace).resolve(strict=True)
        roots = {Path(path).resolve(strict=True) for path in protected_paths}
        for path in roots:
            if not path.is_dir():
                raise SecurityError("Protected prompt roots must be existing directories")
            if workspace_path.is_relative_to(path):
                raise SecurityError("Workspace cannot be inside a protected prompt directory")
        # A read-only child mount alone does not stop renaming its writable
        # ancestors. Pin each such ancestor as a mountpoint, without making its
        # ordinary sibling files read-only. Install all read-only roots last.
        parents = {parent for path in roots for parent in path.parents
                   if parent != workspace_path and parent.is_relative_to(workspace_path)
                   and not any(parent.is_relative_to(root) for root in roots)}
        for flag, paths in (("--bind", parents), ("--ro-bind", roots)):
            for path in sorted(paths, key=lambda path: (len(path.parts), str(path))):
                protected_mounts.extend((flag, str(path), str(path)))
    root = str(workspace)
    command = str(cwd)
    return [
        executable, "--die-with-parent", "--new-session",
        "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-net",
        "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
        "--bind", root, root, *protected_mounts, "--chdir", command,
        "--clearenv", "--setenv", "PATH", "/usr/local/bin:/usr/bin:/bin",
        "--setenv", "HOME", "/tmp", "--setenv", "TMPDIR", "/tmp",
        "--setenv", "LANG", "C.UTF-8", "--", *argv,
    ], backend
