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
