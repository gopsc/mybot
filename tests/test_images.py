"""Bounded image-container validation shared by controller receipts."""
from __future__ import annotations

import io
import struct
import zlib

import pytest

from pymybot.images import image_header, validate_image


def png_bytes(width=2, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\x00" + b"\x00\x80\xff" * width) * height))
            + chunk(b"IEND", b""))


def test_header_rejects_truncation_and_bad_crc():
    good = png_bytes()
    assert image_header(good) == ("png", (2, 1))
    with pytest.raises(ValueError, match="incomplete"):
        image_header(good[:-2])
    broken = bytearray(good)
    broken[29] ^= 0xFF
    with pytest.raises(ValueError, match="CRC"):
        image_header(bytes(broken))
    with pytest.raises(ValueError, match="unsupported"):
        image_header(b"GIF89a")


def test_real_pillow_image_validation():
    from PIL import Image
    for fmt in ("PNG", "JPEG"):
        buffer = io.BytesIO()
        Image.new("RGB", (12, 8)).save(buffer, fmt)
        encoded = buffer.getvalue()
        detected, dimensions = validate_image(encoded)
        assert dimensions == (12, 8) and detected == fmt.lower()
        with pytest.raises(ValueError):
            validate_image(encoded[:-8])


def test_decode_catches_corrupt_deflate_with_valid_framing():
    good = png_bytes(4, 4)
    pos = good.index(b"IDAT") - 4
    n = struct.unpack_from(">I", good, pos)[0]
    garbage = b"IDAT\x78\x9c" + b"\xff" * (n - 2)
    bad = (good[:pos] + struct.pack(">I", n) + garbage
           + struct.pack(">I", zlib.crc32(garbage)) + good[pos + 12 + n:])
    with pytest.raises(ValueError, match="decode failed"):
        validate_image(bad)
