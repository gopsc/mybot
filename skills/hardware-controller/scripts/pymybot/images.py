"""Bounded image-container validation shared by receipts and the Agent camera."""
from __future__ import annotations

import importlib
import io
import struct
import zlib

MAX_IMAGE_BYTES = 16 * 1024 * 1024
MAX_IMAGE_PIXELS = 32 * 1024 * 1024


def size(width, height):
    if isinstance(width, bool) or isinstance(height, bool):
        raise ValueError("image dimensions must be integers")
    if not isinstance(width, int) or not isinstance(height, int):
        raise ValueError("image dimensions must be integers")
    if not 1 <= width <= 8192 or not 1 <= height <= 8192:
        raise ValueError("image dimensions must be in 1..8192")
    if width * height > MAX_IMAGE_PIXELS:
        raise ValueError("image dimensions exceed pixel ceiling")
    return width, height


def image_header(data):
    """Reject truncated containers, verify PNG CRCs, bound dimensions pre-decode."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        pos, found, seen_data = 8, None, False
        while pos + 12 <= len(data):
            n = struct.unpack_from(">I", data, pos)[0]
            kind = data[pos + 4:pos + 8]
            end = pos + 12 + n
            if end > len(data):
                break
            chunk = data[pos + 4:pos + 8 + n]
            if zlib.crc32(chunk) & 0xFFFFFFFF != struct.unpack_from(">I", data, pos + 8 + n)[0]:
                raise ValueError("invalid PNG CRC")
            if found is None:
                if kind != b"IHDR" or n != 13:
                    raise ValueError("invalid PNG header")
                found = size(*struct.unpack_from(">II", data, pos + 8))
            if kind == b"IDAT":
                seen_data = True
            if kind == b"IEND":
                if n or end != len(data) or not seen_data:
                    break
                return "png", found
            pos = end
        raise ValueError("incomplete PNG image")
    if data.startswith(b"\xff\xd8"):
        pos, found, scan = 2, None, False
        while pos < len(data):
            if data[pos] != 255:
                if scan:
                    pos += 1
                    continue
                break
            while pos < len(data) and data[pos] == 255:
                pos += 1
            if pos >= len(data):
                break
            marker = data[pos]
            pos += 1
            if scan and (marker == 0 or 0xD0 <= marker <= 0xD7):
                continue
            if marker == 0xD9:
                if found and scan and pos == len(data):
                    return "jpeg", found
                break
            if pos + 2 > len(data):
                break
            n = struct.unpack_from(">H", data, pos)[0]
            if n < 2 or pos + n > len(data):
                break
            if marker in {0xC0, 0xC1, 0xC2}:
                if n < 8:
                    break
                height, width = struct.unpack_from(">HH", data, pos + 3)
                found = size(width, height)
            if marker == 0xDA:
                scan = True
            pos += n
        raise ValueError("incomplete or unsupported JPEG image")
    raise ValueError("unsupported image format (expected JPEG or PNG)")


def validate_image(data):
    if not 0 < len(data) <= MAX_IMAGE_BYTES:
        raise ValueError("image exceeds byte ceiling or is empty")
    fmt, dimensions = image_header(data)
    image = importlib.import_module("PIL.Image")
    try:
        with image.open(io.BytesIO(data), formats=[fmt.upper()]) as decoded:
            decoded.load()
            decoded_size = decoded.size
    except (OSError, SyntaxError, ValueError) as exc:
        raise ValueError(f"invalid image data (decode failed: {exc})") from exc
    if decoded_size != dimensions:
        raise ValueError("invalid image data (dimension mismatch)")
    return fmt, dimensions
