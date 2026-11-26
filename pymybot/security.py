"""Small input and JSON helpers for the local CLI, not a Lua sandbox."""
from __future__ import annotations

import json
import os
from pathlib import Path
import stat

MAX_BODY = 8 * 1024 * 1024


class SecurityError(ValueError):
    pass


def checked_text(text, cap=MAX_BODY):
    if not isinstance(text, str) or "\0" in text:
        raise SecurityError("Input must be UTF-8 text without NUL")
    if len(text.encode("utf-8")) > cap:
        raise SecurityError(f"Input exceeds the {cap} byte limit")
    return text


def read_file(path, cap=MAX_BODY):
    """Read only a regular file, bounded before decoding strict UTF-8."""
    path = Path(path).absolute()
    if not stat.S_ISREG(path.stat().st_mode):
        raise SecurityError("Input must be a regular file")
    # Nonblocking open also avoids hanging if a file is replaced with a FIFO.
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise SecurityError("Input must be a regular file")
        data = stream.read(cap + 1)
    if len(data) > cap:
        raise SecurityError(f"Input exceeds the {cap} byte limit")
    return checked_text(data.decode("utf-8"), cap)


def dumps(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
