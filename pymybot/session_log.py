"""Append-only conversation transcripts under ``~/.mybot/sessions``.

Images are content-addressed files so repeated captures do not grow the
transcript. Event bodies are bounded before they reach JSONL: one shell receipt
or file read must not turn a log line into an unbounded blob.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import sys
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from . import __version__

FORMAT = 1
MAX_EVENT_BYTES = 64 * 1024
MAX_STRING = 8 * 1024
MAX_ITEMS = 200
MAX_DEPTH = 8
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_IMAGES = 256
MAX_IMAGE_TOTAL = 128 * 1024 * 1024
MAX_META_BYTES = 64 * 1024
MAX_KEEP = 10_000
_SESSION_NAME = re.compile(r"\d{8}-\d{6}-[0-9a-f]{8}")
_DISABLED = {"0", "false", "no", "off"}


def session_root():
    base = os.environ.get("MYBOT_HOME", "").strip()
    root = Path(base).expanduser() if base else Path.home() / ".mybot"
    return root / "sessions"


def _enabled():
    return os.environ.get("MYBOT_SESSION_LOG", "1").strip().lower() not in _DISABLED


def _now():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds")


def _restrict(path, mode):
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def _bounded(value, depth=0):
    if depth > MAX_DEPTH:
        return "<depth limit>"
    if isinstance(value, str):
        return value if len(value) <= MAX_STRING else value[:MAX_STRING] + f"...[{len(value)} chars]"
    if isinstance(value, (bytes, bytearray, memoryview)):
        return f"<{len(value)} bytes>"
    if isinstance(value, dict):
        items = list(value.items())
        result = {str(key): _bounded(item, depth + 1) for key, item in items[:MAX_ITEMS]}
        if len(items) > MAX_ITEMS:
            result["..."] = f"{len(items) - MAX_ITEMS} more keys"
        return result
    if isinstance(value, (list, tuple, set)):
        items = list(value)
        result = [_bounded(item, depth + 1) for item in items[:MAX_ITEMS]]
        if len(items) > MAX_ITEMS:
            result.append(f"... {len(items) - MAX_ITEMS} more items")
        return result
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, (bool, int, float)) or value is None:
        return value
    return str(value)


def _encode(record):
    try:
        text = json.dumps(_bounded(record), ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError):
        text = json.dumps(record, ensure_ascii=False, default=str, separators=(",", ":"))
    if len(text.encode("utf-8")) > MAX_EVENT_BYTES:
        preview = text.encode("utf-8")[:MAX_EVENT_BYTES // 4].decode("utf-8", "ignore")
        text = json.dumps({"ts": record.get("ts"), "type": record.get("type"),
                           "truncated": True, "preview": preview},
                          ensure_ascii=False, separators=(",", ":"))
    return text


class SessionLog:
    def __init__(self, *, robot="", model="", mode="cli"):
        root = session_root()
        root.mkdir(parents=True, exist_ok=True)
        _restrict(root, 0o700)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.path = root / f"{stamp}-{uuid.uuid4().hex[:8]}"
        self.path.mkdir(mode=0o700)
        _restrict(self.path, 0o700)
        images = self.path / "images"
        images.mkdir(mode=0o700)
        _restrict(images, 0o700)
        self._lock = threading.Lock()
        self._closed = False
        self._images = 0
        self._image_bytes = 0
        self._hashes = set()
        meta = {
            "format": FORMAT,
            "started_at": _now(),
            "robot": str(robot),
            "model": str(model),
            "mode": str(mode),
            "cwd": os.getcwd(),
            "pid": os.getpid(),
            "version": __version__,
        }
        (self.path / "meta.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        _restrict(self.path / "meta.json", 0o600)
        self._file = open(self.path / "transcript.jsonl", "a", encoding="utf-8",
                          newline="\n", buffering=1)
        _restrict(self.path / "transcript.jsonl", 0o600)
        self.write("session_start", robot=str(robot), model=str(model), mode=str(mode))

    def write(self, kind, **fields):
        record = {"ts": _now(), "type": kind, **fields}
        line = _encode(record)
        with self._lock:
            if self._closed:
                return
            try:
                self._file.write(line + "\n")
                self._file.flush()
            except OSError as exc:
                self._closed = True
                print(f"mybot: session log write failed: {exc}", file=sys.stderr)

    def write_image(self, tool, image, turn=None):
        if not isinstance(image, dict):
            self.write("image", tool=tool, turn=turn, omitted="invalid")
            return
        data = image.get("data")
        media_type = image.get("media_type")
        if not isinstance(media_type, str) or not media_type:
            media_type = "application/octet-stream"
        if not isinstance(data, (bytes, bytearray)) or not data:
            self.write("image", tool=tool, turn=turn, omitted="invalid", media_type=media_type)
            return
        size = len(data)
        if size > MAX_IMAGE_BYTES:
            self.write("image", tool=tool, turn=turn, omitted="size",
                       bytes=size, media_type=media_type)
            return
        digest = hashlib.sha256(data).hexdigest()
        suffix = {"image/jpeg": ".jpg", "image/png": ".png"}.get(media_type, ".bin")
        relative = Path("images") / (digest + suffix)
        target = self.path / relative
        if digest not in self._hashes:
            if self._images >= MAX_IMAGES or self._image_bytes + size > MAX_IMAGE_TOTAL:
                self.write("image", tool=tool, turn=turn, omitted="budget",
                           bytes=size, media_type=media_type)
                return
            try:
                target.write_bytes(bytes(data))
            except OSError as exc:
                self.write("image", tool=tool, turn=turn, omitted="write_failed",
                           bytes=size, media_type=media_type, error=str(exc))
                return
            _restrict(target, 0o600)
            self._hashes.add(digest)
            self._images += 1
            self._image_bytes += size
        self.write("image", tool=tool, turn=turn, sha256=digest, media_type=media_type,
                   bytes=size, path=relative.as_posix())

    def close(self, reason="closed"):
        if self._file.closed:
            return
        if not self._closed:
            self.write("session_end", reason=reason, images=self._images,
                       image_bytes=self._image_bytes)
        with self._lock:
            if self._file.closed:
                return
            self._closed = True
            try:
                self._file.flush()
                os.fsync(self._file.fileno())
            except OSError:
                pass
            try:
                self._file.close()
            except OSError:
                pass


def create_session_log(*, enabled=True, robot="", model="", mode="cli"):
    if not enabled or not _enabled():
        return None
    try:
        log = SessionLog(robot=robot, model=model, mode=mode)
    except (OSError, RuntimeError) as exc:
        print(f"mybot: session log unavailable: {exc}", file=sys.stderr)
        return None
    print(f"mybot: session log: {log.path}", file=sys.stderr)
    return log


def _terminated(path: Path):
    """Whether the last complete transcript event is ``session_end``."""
    transcript = path / "transcript.jsonl"
    try:
        size = transcript.stat().st_size
        with transcript.open("rb") as stream:
            stream.seek(max(0, size - 8192))
            tail = stream.read().decode("utf-8", "replace")
    except OSError:
        return False
    for line in reversed(tail.splitlines()):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            return False
        return isinstance(event, dict) and event.get("type") == "session_end"
    return False


def _active(meta, path: Path):
    """Best-effort: a live process that has not written ``session_end``.

    Windows has no safe signal-0 probe (``os.kill`` maps to TerminateProcess),
    so active sessions are only detected on POSIX. Pruning on Windows must not
    be run against a live session.
    """
    if os.name == "nt":
        return False
    pid = meta.get("pid")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OSError):
        pass
    return not _terminated(path)


def _session_info(path: Path):
    """Describe one session without following symlinks."""
    meta = {}
    meta_file = path / "meta.json"
    try:
        if meta_file.stat().st_size <= MAX_META_BYTES:
            value = json.loads(meta_file.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                meta = value
    except (OSError, ValueError):
        pass
    total = images = 0
    try:
        modified = path.stat().st_mtime
    except OSError:
        modified = 0.0
    for base, dirs, files in os.walk(path, followlinks=False, onerror=lambda _exc: None):
        dirs[:] = [name for name in dirs if not (Path(base) / name).is_symlink()]
        for name in files:
            item = Path(base) / name
            if item.is_symlink():
                continue
            try:
                file_stat = item.stat()
            except OSError:
                continue
            total += file_stat.st_size
            modified = max(modified, file_stat.st_mtime)
            if item.parent.name == "images":
                images += 1
    return {
        "id": path.name,
        "path": str(path),
        "started_at": meta.get("started_at", ""),
        "mode": meta.get("mode", ""),
        "robot": meta.get("robot", ""),
        "model": meta.get("model", ""),
        "pid": meta.get("pid"),
        "active": _active(meta, path),
        "bytes": total,
        "images": images,
        "modified": modified,
    }


def list_sessions(root=None):
    """Return transcripts newest-first; malformed directories are ignored."""
    base = Path(root).expanduser() if root is not None else session_root()
    if not base.is_dir():
        return []
    try:
        children = list(base.iterdir())
    except OSError:
        return []
    sessions = []
    for child in children:
        if (child.is_symlink() or not child.is_dir()
                or not _SESSION_NAME.fullmatch(child.name)
                or not (child / "meta.json").is_file()):
            continue
        sessions.append(_session_info(child))
    return sorted(sessions, key=lambda item: (item["modified"], item["id"]), reverse=True)


def delete_sessions(ids, dry_run=False, root=None):
    """Delete named transcripts with the same checks as ``prune_sessions``.

    The caller is expected to confirm interactively; this function never
    follows symlinks and never removes an active session.
    """
    if not isinstance(ids, (list, tuple)) or not 0 < len(ids) <= MAX_KEEP:
        raise ValueError(f"ids must contain 1..{MAX_KEEP} session names")
    if type(dry_run) is not bool:
        raise ValueError("dry_run must be a boolean")
    base = Path(root).expanduser() if root is not None else session_root()
    known = {item["id"]: item for item in list_sessions(base)}
    deleted, freed, skipped, errors = [], 0, [], []
    for ident in dict.fromkeys(ids):
        if not isinstance(ident, str) or not _SESSION_NAME.fullmatch(ident) or ident not in known:
            errors.append(str(ident))
            continue
        item = known[ident]
        directory = Path(item["path"])
        if item["active"]:
            skipped.append(ident)
            continue
        if (directory.parent != base or directory.is_symlink()
                or not _SESSION_NAME.fullmatch(directory.name)
                or not (directory / "meta.json").is_file()):
            errors.append(ident)
            continue
        if not dry_run:
            try:
                shutil.rmtree(directory)
            except OSError:
                errors.append(ident)
                continue
        deleted.append(ident)
        freed += item["bytes"]
    return {
        "root": str(base),
        "dry_run": dry_run,
        "deleted": deleted,
        "bytes_freed": freed,
        "skipped": skipped,
        "errors": errors,
    }


def prune_sessions(keep=20, older_than_days=None, dry_run=False, root=None):
    """Delete sessions beyond the newest ``keep``, optionally only if old.

    The newest ``keep`` sessions are always protected. ``older_than_days`` adds a
    second condition: among the remaining sessions, only those whose newest file
    is at least that old are removed. A session whose process is still alive and
    has not written ``session_end`` is skipped. Deletion never follows symlinks.
    """
    if isinstance(keep, bool) or not isinstance(keep, int) or not 1 <= keep <= MAX_KEEP:
        raise ValueError(f"keep must be in 1..{MAX_KEEP}")
    if older_than_days is not None:
        if isinstance(older_than_days, bool) or not isinstance(older_than_days, int) or not 0 <= older_than_days <= 3650:
            raise ValueError("older_than_days must be in 0..3650")
    base = Path(root).expanduser() if root is not None else session_root()
    sessions = list_sessions(base)
    candidates = sessions[keep:]
    if older_than_days is not None:
        cutoff = datetime.now().timestamp() - older_than_days * 86400
        candidates = [item for item in candidates if item["modified"] <= cutoff]
    deleted, freed, skipped, errors = [], 0, [], []
    for item in candidates:
        directory = Path(item["path"])
        # Re-check every candidate immediately before removal.
        if item["active"]:
            skipped.append(item["id"])
            continue
        if (directory.parent != base or directory.is_symlink()
                or not _SESSION_NAME.fullmatch(directory.name)
                or not (directory / "meta.json").is_file()):
            errors.append(item["id"])
            continue
        if not dry_run:
            try:
                shutil.rmtree(directory)
            except OSError:
                errors.append(item["id"])
                continue
        deleted.append(item["id"])
        freed += item["bytes"]
    return {
        "root": str(base),
        "keep": keep,
        "older_than_days": older_than_days,
        "dry_run": bool(dry_run),
        "deleted": deleted,
        "bytes_freed": freed,
        "kept": len(sessions) - len(deleted),
        "skipped": skipped,
        "errors": errors,
    }
