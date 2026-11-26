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


def _version(info):
    # On Windows/Python 3.12 stat().ctime can be birth time while fstat().ctime
    # is change time. Compare ctime only within the same kind of stat below.
    return (info.st_dev, info.st_ino), info.st_size, info.st_mtime_ns


def read_file(path, cap=MAX_BODY, check=None):
    """Read only a regular file, bounded before decoding strict UTF-8.

    Opens with O_NOFOLLOW where the platform provides it and compares file
    identity, size and timestamps before open, after open and after reading,
    so a file swapped or modified mid-read is rejected instead of being
    trusted. ``check`` is an optional caller budget/liveness callback.
    """
    if check is None:
        def check():
            return None
    path = Path(path).absolute()
    check()
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise SecurityError("Input must be a regular file")
    # Nonblocking open also avoids hanging if a file is replaced with a FIFO.
    flags = (os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
             | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0))
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as stream:
        opened = os.fstat(stream.fileno())
        check()
        if not stat.S_ISREG(opened.st_mode) or _version(before) != _version(opened):
            raise SecurityError("File changed while opening")
        data = stream.read(cap + 1)
        after = os.fstat(stream.fileno())
    check()
    current = path.stat()
    if (_version(before) != _version(after) or _version(before) != _version(current)
            or before.st_ctime_ns != current.st_ctime_ns
            or opened.st_ctime_ns != after.st_ctime_ns):
        raise SecurityError("File changed while reading")
    if len(data) > cap:
        raise SecurityError(f"Input exceeds the {cap} byte limit")
    return checked_text(data.decode("utf-8"), cap)


def dumps(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
