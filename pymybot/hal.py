"""Portable hardware boundary. No Python objects or binary strings cross into Lua.

HALManager.call accepts only the operations in _OPERATIONS. Byte payloads are
lists of integers; the host recursively converts Lua tables in both directions.
Handles are process-local logical IDs, not operating-system file descriptors.
"""
from __future__ import annotations

import base64
import errno
import importlib
import io
import ipaddress
import math
import os
from pathlib import Path
import re
import select
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
from typing import Callable
import urllib.error
import urllib.request
from urllib.parse import parse_qs, urlsplit, urlunsplit
import zlib

from .process import kill_tree, read_pipe, shell_command

# PyAV's log level and capture are process-global.
_AV_LOG_LOCK = threading.Lock()
# DirectShow's video input category; FFmpeg prints video devices as (video) or
# (none), so the category GUID is the reliable discriminator from audio devices.
_DSHOW_VIDEO_GUID = "65e8773d-8f56-11d0-a3b9-00a0c9223196"


class _Resource:
    def __init__(self, kind, key, backend, connection, **state):
        self.kind, self.key, self.backend, self.device = kind, key, backend, connection
        self.state = state
        self.lock = threading.RLock()
        self.refs = 0
        self.closed = False


class _Call:
    """Per-request context; thread-local so concurrent workers never share it."""

    __slots__ = ("cancel", "owner", "cancelled")

    def __init__(self, cancel, owner):
        self.cancel = cancel
        self.owner = owner
        self.cancelled = False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """3xx must surface as a status; never follow to another host silently."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_HTTP_OPENER = urllib.request.build_opener(_NoRedirect)


class HALManager:
    """Shared, reference-counted buses with per-bus transaction locks.

    camera_src_root is a host capability, never taken from Lua options or env.
    cancel_check, when supplied, should raise to cancel sleeps/serial polling.
    """

    MAX_IMAGE_BYTES = 16 * 1024 * 1024
    MAX_IMAGE_PIXELS = 32 * 1024 * 1024
    CAMERA_TIMEOUT = 10.0
    CAMERA_FORMATS = {"win32": "dshow", "linux": "v4l2", "darwin": "avfoundation"}
    UART_MAX_BYTES = 512
    UART_MAX_MS = 60000
    TCP_MAX_BYTES = 512
    TCP_MAX_MS = 60000
    HTTP_MAX_BYTES = 4 * 1024 * 1024
    HTTP_MAX_HEADERS = 16
    HTTP_TIMEOUT_MS = 60000
    SHELL_MAX_CMD_BYTES = 64 * 1024
    SHELL_MAX_OUT_BYTES = 1024 * 1024
    SHELL_TIMEOUT_MS = 60000
    BAUDS = {1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
             230400, 460800, 500000, 921600, 1000000}
    _OPERATIONS = {
        "i2c_open", "i2c_transfer", "spi_open", "spi_setup", "spi_transfer",
        "uart_open", "uart_write", "uart_read", "uart_flush", "virt_attach",
        "tcp_open", "tcp_write", "tcp_read",
        "http_open", "http_request",
        "shell_open", "shell_run",
        "camera_open", "camera_capture", "close_handle", "sleep_ms", "last_error",
    }

    def __init__(self, camera_src_root: Path | None = None, *,
                 cancel_check: Callable[[], None] | None = None):
        self.camera_src_root = (Path(camera_src_root).resolve(strict=True)
                                if camera_src_root is not None else None)
        if self.camera_src_root is not None and not self.camera_src_root.is_dir():
            raise ValueError("camera_src_root must be a directory")
        self._camera_root_stat = self.camera_src_root.stat() if self.camera_src_root else None
        self._cancel_check = cancel_check
        self._lock = threading.RLock()
        self._handles: dict[int, _Resource] = {}
        self._settings: dict[int, dict] = {}
        self._buses: dict[tuple, _Resource] = {}
        # Original virtbus allocates from 3; keep physical IDs out of that range.
        self._next_handle = 1 << 40
        self._closed = False
        self._errors = threading.local()
        self._calls = threading.local()
        self._owners: dict[int, object] = {}

    def call(self, operation: str, *args, cancel_check=None,
             owner=None) -> dict | list[int] | int | str | None:
        """Dispatch, returning scalars/lists/dicts/None (never device objects).

        Open/setup/write/close failures return -1; transfer/read failures None;
        camera failures and unsupported operations return {result: ERR, message}.
        last_error returns the calling thread's most recent diagnostic string.
        sleep_ms raises cancellation exceptions so cancellation is not swallowed.
        cancel_check is request-scoped (thread-local); owner tags handles opened
        by that request so they can be released together.
        """
        if operation == "last_error":
            return getattr(self._errors, "message", "")
        if not isinstance(operation, str) or operation not in self._OPERATIONS:
            return {"result": "ERR", "message": f"Unsupported HAL operation: {operation}"}
        previous = getattr(self._calls, "current", None)
        context = self._calls.current = _Call(cancel_check, owner)
        try:
            if operation == "sleep_ms":
                return self._sleep_ms(*args)
            try:
                if self._closed:
                    raise RuntimeError("HAL manager is closed")
                return getattr(self, "_" + operation)(*args)
            except Exception as exc:
                if context.cancelled:
                    raise
                message = f"{operation}: {exc}"
                self._errors.message = message
                if operation == "tcp_write":
                    return {"result": "ERR", "message": message, "sent": 0}
                if operation in {"camera_capture", "http_request", "shell_run", "tcp_read"}:
                    return {"result": "ERR", "message": message}
                if operation in {"i2c_transfer", "spi_transfer", "uart_read"}:
                    return None
                return -1
        finally:
            self._calls.current = previous

    @staticmethod
    def _integer(value, low=0, high=0xFFFFFFFF):
        if isinstance(value, bool) or not isinstance(value, (int, float, str)):
            raise ValueError("expected an integer")
        n = float(value)
        if not math.isfinite(n) or not n.is_integer() or not low <= n <= high:
            raise ValueError(f"integer outside {low}..{high}: {value}")
        return int(n)

    @classmethod
    def _bytes(cls, data, maximum, minimum=0):
        # Empty Lua tables may be converted by the host to an empty dict.
        if isinstance(data, dict) and not data:
            data = []
        if not isinstance(data, (list, tuple)) or not minimum <= len(data) <= maximum:
            raise ValueError(f"expected {minimum}..{maximum} bytes")
        return bytes(cls._integer(b, 0, 255) for b in data)

    @staticmethod
    def _ftdi_path(path, spi=False):
        if not isinstance(path, str) or not path.startswith("ftdi://"):
            raise ValueError("an explicit ftdi:// USB URL is required")
        u = urlsplit(path)
        if (not re.fullmatch(r"[A-Za-z0-9_.:+-]+", u.netloc)
                or not re.fullmatch(r"/[1-4]", u.path) or u.fragment):
            raise ValueError("invalid FTDI URL (specify device and interface 1..4)")
        cs = 0
        if u.query:
            q = parse_qs(u.query, strict_parsing=True)
            if not spi or set(q) != {"cs"} or len(q["cs"]) != 1:
                raise ValueError("only SPI ?cs=0..4 is supported")
            cs = HALManager._integer(q["cs"][0], 0, 4)
        return urlunsplit((u.scheme, u.netloc, u.path, "", "")), cs

    def _register(self, resource, **settings):
        if self._closed:
            raise RuntimeError("HAL manager is closed")
        handle = self._next_handle
        self._next_handle += 1
        self._handles[handle] = resource
        self._settings[handle] = settings
        context = getattr(self._calls, "current", None)
        if context is not None and context.owner is not None:
            self._owners[handle] = context.owner
        resource.refs += 1
        return handle

    def _active_cancel(self):
        context = getattr(self._calls, "current", None)
        if context is not None and context.cancel is not None:
            return context.cancel
        return self._cancel_check

    def _tick_cancel(self):
        check = self._active_cancel()
        if check is None:
            return
        try:
            check()
        except BaseException:
            context = getattr(self._calls, "current", None)
            if context is not None:
                context.cancelled = True
            raise

    def _release_virtual_owner(self, owner, resource=None):
        """Drop one runtime's models and queued input without closing a borrowed bus."""
        if resource is not None:
            resources = [resource]
        else:
            with self._lock:
                resources = list({id(item): item for item in self._handles.values()}.values())
        for item in resources:
            if item.backend != "virtual":
                continue
            with item.lock:
                item.state["models"].pop(owner, None)
                item.state["rings"].pop(owner, None)

    def release_owner(self, owner):
        """Close owned handles and detach models borrowed from other runtimes."""
        if owner is None:
            return
        self._release_virtual_owner(owner)
        with self._lock:
            handles = [handle for handle, held in self._owners.items() if held is owner]
        for handle in handles:
            try:
                self._close_handle(handle)
            except Exception as exc:
                self._errors.message = f"release_owner: {exc}"

    def _current_owner(self):
        context = getattr(self._calls, "current", None)
        return context.owner if context is not None else None

    def _virtual_model(self, resource, identity):
        models = resource.state["models"].get(self._current_owner(), {})
        return models.get(identity)

    def _virt_attach(self, handle, kind, identity, model):
        resource = self._get(handle, kind)
        if resource.backend != "virtual" or not isinstance(model, dict):
            raise ValueError("virtual model requires a matching virtual bus and callback table")
        if kind == "i2c":
            identity = self._integer(identity, 0, 127)
        elif not isinstance(identity, str) or identity != resource.key[2]:
            raise ValueError("SPI/UART model identity must match the virtual bus path")
        with resource.lock:
            self._live(resource)
            resource.state["models"].setdefault(self._current_owner(), {})[identity] = model
        return 0

    def _get(self, handle, kind=None):
        handle = self._integer(handle, 0, (1 << 53) - 1)
        with self._lock:
            r = self._handles.get(handle)
            if r is None or r.closed or (kind is not None and r.kind != kind):
                raise ValueError("invalid or closed hardware handle")
            return r

    @staticmethod
    def _live(resource):
        if resource.closed:
            raise ValueError("hardware handle is closed")

    def _bus_open(self, kind, path, baud=None, virtual=False):
        if not isinstance(path, str):
            raise ValueError("device path must be text")
        cs = 0
        if kind == "uart":
            baud = self._integer(baud, 1)
            if baud not in self.BAUDS:
                raise ValueError("unsupported UART baud")
            virtual = virtual or re.fullmatch(r"virt-\w[\w_./-]*", path) is not None
            if re.fullmatch(r"(?:\\\\\.\\)?COM[1-9][0-9]*", path, re.I):
                path = path.upper()
            elif path != "loop://" and not virtual and not re.fullmatch(r"/dev/(?:tty[A-Za-z0-9._-]+|cu\.[A-Za-z0-9._-]+|serial[0-9]+)", path):
                raise ValueError("UART requires COMn, a serial device, loop://, or a virt-* path")
            backend, endpoint = ("virtual", path) if virtual else ("serial", path)
        elif virtual or re.fullmatch(r"virt-\w[\w_./-]*", path):
            backend, endpoint = "virtual", path
        elif path.startswith("ftdi://"):
            endpoint, cs = self._ftdi_path(path, kind == "spi")
            backend = "ftdi"
        else:
            pattern = r"/dev/i2c-[0-9]+" if kind == "i2c" else r"/dev/spidev[0-9]+\.[0-9]+"
            if not re.fullmatch(pattern, path):
                raise ValueError(f"{kind} requires an explicit ftdi:// URL or legacy /dev path")
            if sys.platform != "linux":
                raise ValueError("legacy /dev I2C/SPI paths are Linux-only; use ftdi://")
            backend, endpoint = "linux", path
        key = (kind, backend, endpoint)
        with self._lock:
            if self._closed:
                raise RuntimeError("HAL manager is closed")
            if backend == "ftdi":
                other = "spi" if kind == "i2c" else "i2c"
                if (other, backend, endpoint) in self._buses:
                    raise ValueError("FTDI interface already in use by another bus protocol")
            r = self._buses.get(key)
            if r is not None:
                if kind == "uart" and r.state["baud"] != baud:
                    raise ValueError("shared UART already opened with another baud")
                return self._register(r, cs=cs, mode=0, bits=8, speed=1000000)
            device = None
            try:
                if backend == "virtual":
                    pass  # Models and streams are attached by each runtime owner.
                elif backend == "serial":
                    serial = importlib.import_module("serial")
                    device = serial.serial_for_url(path, baudrate=baud, timeout=0,
                                                   write_timeout=1, bytesize=8,
                                                   parity="N", stopbits=1)
                elif backend == "ftdi":
                    module = importlib.import_module("pyftdi." + kind)
                    device = module.I2cController() if kind == "i2c" else module.SpiController(cs_count=5)
                    # PyUSB/FTDI has finite USB transfer timeouts; no unbounded retry loop.
                    device.configure(endpoint)
                elif kind == "i2c":
                    module = importlib.import_module("smbus2")
                    device = module.SMBus(int(path.rsplit("-", 1)[1]))
                else:
                    module = importlib.import_module("spidev")
                    device = module.SpiDev()
                    bus, chip = path.removeprefix("/dev/spidev").split(".")
                    device.open(int(bus), int(chip))
                r = _Resource(kind, key, backend, device, baud=baud, cs=cs,
                              mode=0, bits=8, speed=1000000, models={}, rings={})
                self._buses[key] = r
                return self._register(r, cs=cs, mode=0, bits=8, speed=1000000)
            except Exception:
                if device is not None:
                    try:
                        device.terminate() if backend == "ftdi" else device.close()
                    except Exception:
                        pass
                raise

    def _i2c_open(self, path, virtual=False):
        return self._bus_open("i2c", path, virtual=True) if virtual else self._bus_open("i2c", path)

    def _spi_open(self, path, virtual=False):
        return self._bus_open("spi", path, virtual=True) if virtual else self._bus_open("spi", path)

    def _uart_open(self, path, baud, virtual=False):
        return (self._bus_open("uart", path, baud, virtual=True) if virtual
                else self._bus_open("uart", path, baud))

    def _i2c_transfer(self, handle, address, write, read_count):
        address = self._integer(address, 0, 127)
        write = self._bytes(write, 258)
        n = self._integer(read_count, 0, 16)
        if not write and not n:
            raise ValueError("empty I2C transaction")
        r = self._get(handle, "i2c")
        with r.lock:
            self._live(r)
            if r.backend == "virtual":
                model = self._virtual_model(r, address)
                if model is None:
                    raise IOError("virtual I2C device is not attached")
                if write and model.get("write") is not None:
                    if not callable(model["write"]) or model["write"](list(write)) is False:
                        raise IOError("virtual I2C write NACK")
                if n:
                    reader = model.get("read")
                    reply = [0] * n if reader is None else reader(n)
                    out = self._bytes(reply, n, n)
                else:
                    out = b""
            elif r.backend == "ftdi":
                port = r.device.get_port(address)
                if write and n:
                    out = port.exchange(write, n)  # repeated START, one locked transaction
                elif n:
                    out = port.read(n)
                else:
                    port.write(write)
                    out = b""
            else:
                msg = importlib.import_module("smbus2").i2c_msg
                messages = [msg.write(address, write)] if write else []
                if n:
                    messages.append(msg.read(address, n))
                r.device.i2c_rdwr(*messages)
                out = bytes(messages[-1]) if n else b""
            if len(out) != n:
                raise IOError("short I2C read")
            return list(out)

    def _spi_setup(self, handle, mode, bits, speed):
        mode = self._integer(mode, 0, 3)
        bits = self._integer(bits, 7, 16)
        speed = self._integer(speed, 1, 0xFFFFFFFF)
        r = self._get(handle, "spi")
        with r.lock:
            self._live(r)
            config = self._settings[int(handle)]
            if r.backend == "virtual":
                pass  # Controller setup succeeds without an attached SPI model.
            elif r.backend == "ftdi":
                if bits != 8:
                    raise ValueError("pyftdi SPI supports 8-bit words only")
                port = r.device.get_port(cs=config["cs"], freq=speed, mode=mode)
                port.set_frequency(speed)
                port.set_mode(mode)
            else:
                r.device.mode, r.device.bits_per_word, r.device.max_speed_hz = mode, bits, speed
            config.update(mode=mode, bits=bits, speed=speed)
        return 0

    def _spi_transfer(self, handle, data, delay_us=0):
        data = self._bytes(data, 64, 1)
        delay = self._integer(delay_us or 0, 0, 65535)
        r = self._get(handle, "spi")
        with r.lock:
            self._live(r)
            config = self._settings[int(handle)]
            if r.backend == "virtual":
                model = self._virtual_model(r, r.key[2])
                if model is None:
                    raise IOError("virtual SPI device is not attached")
                transfer = model.get("xfer")
                reply = [0] * len(data) if transfer is None else transfer(list(data))
                if not isinstance(reply, (list, tuple)):
                    raise IOError("virtual SPI transfer failed")
                normalized = list(reply[:len(data)]) + [0] * max(0, len(data) - len(reply))
                out = self._bytes(normalized, len(data), len(data))
            elif r.backend == "ftdi":
                port = r.device.get_port(cs=config["cs"], freq=config["speed"], mode=config["mode"])
                port.set_frequency(config["speed"])
                port.set_mode(config["mode"])
                if delay:
                    # Keep CS asserted through the requested delay, release even on errors.
                    try:
                        out = port.exchange(data, duplex=True, start=True, stop=False)
                        self._sleep_ms(delay / 1000)
                    finally:
                        port.force_select(True)  # /CS high = deselected
                else:
                    out = port.exchange(data, duplex=True)
            else:
                r.device.mode = config["mode"]
                out = r.device.xfer2(list(data), config["speed"], delay, config["bits"])
            if len(out) != len(data):
                raise IOError("short SPI transfer")
            return list(out)

    def _uart_write(self, handle, data):
        data = self._bytes(data, self.UART_MAX_BYTES, 1)
        r = self._get(handle, "uart")
        with r.lock:
            self._live(r)
            if r.backend == "virtual":
                model = self._virtual_model(r, r.key[2])
                if model is None or model.get("on_write") is None:
                    return len(data)
                reply = model["on_write"](list(data))
                if reply is False:
                    raise IOError("virtual UART write failed")
                if reply is not None:
                    r.state["rings"].setdefault(self._current_owner(), bytearray()).extend(
                        self._bytes(reply, self.UART_MAX_BYTES))
                return len(data)
            n = r.device.write(data)
            if n != len(data):
                raise IOError("short UART write")
            return n

    def _uart_read(self, handle, count, timeout_ms=0):
        n = min(self._integer(count, 1), self.UART_MAX_BYTES)
        timeout_ms = float(timeout_ms or 0)
        if not math.isfinite(timeout_ms) or timeout_ms > self.UART_MAX_MS:
            raise ValueError("UART timeout must be finite and <=60000 ms")
        deadline = time.monotonic() + max(0, timeout_ms) / 1000
        r = self._get(handle, "uart")
        out = bytearray()
        with r.lock:
            self._live(r)
            if r.backend == "virtual":
                ring = r.state["rings"].get(self._current_owner())
                if not ring:
                    return []
                out = list(ring[:n])
                del ring[:n]
                return out
            while True:
                self._tick_cancel()
                part = r.device.read(n - len(out))  # timeout=0: portable nonblocking read
                if len(part) > n - len(out):
                    raise IOError("oversized UART read")
                out.extend(part)
                if len(out) == n or time.monotonic() >= deadline:
                    return list(out)
                # A pyserial empty read is a timeout, NOT POSIX EOF.
                time.sleep(min(.001, max(0, deadline - time.monotonic())))

    def _uart_flush(self, handle):
        r = self._get(handle, "uart")
        with r.lock:
            self._live(r)
            if r.backend == "virtual":
                r.state["rings"].pop(self._current_owner(), None)
            else:
                r.device.reset_input_buffer()
        return 0

    @classmethod
    def _tcp_endpoint(cls, host, port):
        if not isinstance(host, str) or "%" in host:
            raise ValueError("TCP host must be an IPv4 or IPv6 address without a scope")
        address = ipaddress.ip_address(host)
        return address, cls._integer(port, 1, 65535)

    def _tcp_wait(self, device, reading, deadline):
        while True:
            self._tick_cancel()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            readable, writable, exceptional = select.select(
                [device] if reading else [], [] if reading else [device],
                [device], min(remaining, .05),
            )
            self._tick_cancel()
            if time.monotonic() >= deadline:
                return False
            if readable or writable or exceptional:
                return True

    @staticmethod
    def _tcp_disconnect(resource):
        device, resource.device = resource.device, None
        if device is not None:
            device.close()

    def _tcp_open(self, host, port, timeout_ms=1000):
        address, port = self._tcp_endpoint(host, port)
        timeout = self._integer(timeout_ms, 1, self.TCP_MAX_MS)
        deadline = time.monotonic() + timeout / 1000
        self._tick_cancel()
        device = socket.socket(socket.AF_INET if address.version == 4 else socket.AF_INET6, socket.SOCK_STREAM)
        registered = False
        try:
            device.setblocking(False)
            code = device.connect_ex((str(address), port))
            connected = {0, errno.EISCONN, 10056}
            pending = {errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY, errno.EINTR, 10035, 10036, 10037}
            if code not in connected:
                if code not in pending:
                    raise OSError(code, "TCP connection failed")
                if not self._tcp_wait(device, False, deadline):
                    raise TimeoutError("TCP connection timed out")
                code = device.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                if code:
                    raise OSError(code, "TCP connection failed")
            self._tick_cancel()
            with self._lock:
                handle = self._register(_Resource("tcp", None, "socket", device))
                registered = True
                return handle
        finally:
            if not registered:
                device.close()

    def _tcp_write(self, handle, data, timeout_ms=1000):
        payload = self._bytes(data, self.TCP_MAX_BYTES)
        timeout = self._integer(timeout_ms, 1, self.TCP_MAX_MS)
        deadline = time.monotonic() + timeout / 1000
        resource = self._get(handle, "tcp")
        sent = 0
        completed = False
        with resource.lock:
            try:
                self._live(resource)
                if resource.device is None:
                    raise ConnectionError("TCP connection is closed")
                self._tick_cancel()
                while sent < len(payload):
                    if not self._tcp_wait(resource.device, False, deadline):
                        raise TimeoutError("TCP send timed out")
                    try:
                        count = resource.device.send(memoryview(payload)[sent:])
                    except (BlockingIOError, InterruptedError):
                        continue
                    if count == 0:
                        raise ConnectionError("TCP connection closed during send")
                    sent += count
                self._tick_cancel()
                completed = True
                return {"result": "OK", "sent": sent}
            except Exception as exc:
                context = getattr(self._calls, "current", None)
                if context is not None and context.cancelled:
                    raise
                message = f"tcp_write: {exc} (sent {sent} bytes; peer execution is unknown)"
                self._errors.message = message
                return {"result": "ERR", "message": message, "sent": sent}
            finally:
                if not completed:
                    self._tcp_disconnect(resource)

    def _tcp_read(self, handle, count, timeout_ms=1000):
        count = self._integer(count, 1, self.TCP_MAX_BYTES)
        timeout = self._integer(timeout_ms, 1, self.TCP_MAX_MS)
        deadline = time.monotonic() + timeout / 1000
        resource = self._get(handle, "tcp")
        completed = False
        with resource.lock:
            try:
                self._live(resource)
                if resource.device is None:
                    raise ConnectionError("TCP connection is closed")
                while True:
                    if not self._tcp_wait(resource.device, True, deadline):
                        completed = True
                        return {"result": "OK", "status": "timeout", "data": []}
                    try:
                        data = resource.device.recv(count)
                    except (BlockingIOError, InterruptedError):
                        continue
                    self._tick_cancel()
                    if not data:
                        self._tcp_disconnect(resource)
                    completed = True
                    return {"result": "OK", "status": "data" if data else "eof", "data": list(data)}
            finally:
                if not completed:
                    self._tcp_disconnect(resource)

    @staticmethod
    def _http_base(base):
        if not isinstance(base, str):
            raise ValueError("HTTP base URL must be text")
        u = urlsplit(base)
        if u.scheme not in {"http", "https"} or not u.netloc:
            raise ValueError("HTTP base requires an http(s):// URL with a host")
        if u.username is not None or u.password is not None or u.query or u.fragment:
            raise ValueError("HTTP base must not embed credentials, query, or fragment")
        u.port  # property access raises ValueError on malformed ports
        if not re.fullmatch(r"[0-9A-Za-z.\[\]:\-]+", u.netloc):
            raise ValueError("HTTP base host contains invalid characters")
        path = u.path or "/"
        if not path.isascii() or re.search(r"[\x00-\x1f\x7f ]", path):
            raise ValueError("HTTP base path must be ASCII text without spaces")
        if len(path) > 1:
            path = path.rstrip("/") or "/"
        return urlunsplit((u.scheme, u.netloc, path, "", ""))

    def _http_open(self, base, timeout_ms=10000):
        base = self._http_base(base)
        timeout_ms = self._integer(timeout_ms, 1, self.HTTP_TIMEOUT_MS)
        with self._lock:
            # Like camera_open: validation only; HTTP has no persistent connection
            # to establish, requests happen per http_request call.
            return self._register(_Resource("http", None, "urllib", None,
                                            base=base, timeout=timeout_ms))

    def _http_request(self, handle, method, path, headers=None, body=None):
        if not isinstance(method, str) or method.upper() not in {"GET", "POST", "PUT", "DELETE", "PATCH"}:
            raise ValueError("HTTP method must be GET, POST, PUT, DELETE, or PATCH")
        method = method.upper()
        if not isinstance(path, str) or not path.isascii() or re.search(r"[\x00-\x1f\x7f ]", path):
            raise ValueError("HTTP path must be relative ASCII text without spaces")
        if "://" in path or path.startswith("//"):
            raise ValueError("HTTP path must be relative to the declared base URL")
        if path and not path.startswith("/"):
            path = "/" + path
        target = urlsplit(path)
        if target.scheme or target.netloc:
            raise ValueError("HTTP path must be relative to the declared base URL")
        headers = {} if headers in (None, []) else headers
        if not isinstance(headers, dict) or len(headers) > self.HTTP_MAX_HEADERS:
            raise ValueError(f"HTTP headers must be a table of at most {self.HTTP_MAX_HEADERS} entries")
        for key, value in headers.items():
            if (not isinstance(key, str) or not isinstance(value, str) or not key
                    or not key.isascii() or not value.isascii()
                    or re.search(r"[\x00-\x1f\x7f]", key + value)):
                raise ValueError("HTTP header names and values must be plain ASCII text")
        data = None
        if body is not None:
            if not isinstance(body, str) or len(body.encode("utf-8")) > self.HTTP_MAX_BYTES:
                raise ValueError("HTTP body must be text within the size ceiling")
            data = body.encode("utf-8")
        r = self._get(handle, "http")
        with r.lock:
            self._live(r)
            request = urllib.request.Request(r.state["base"] + path, data=data, method=method)
            for key, value in headers.items():
                request.add_header(key, value)
            try:
                response = _HTTP_OPENER.open(request, timeout=r.state["timeout"] / 1000)
            except urllib.error.HTTPError as error:
                # 4xx/5xx (and 3xx, since redirects are refused) are responses.
                with error:
                    return self._http_result(error.code, error.read(self.HTTP_MAX_BYTES + 1),
                                             error.headers)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                raise IOError(str(getattr(error, "reason", error))) from error
            with response:
                return self._http_result(response.status,
                                         response.read(self.HTTP_MAX_BYTES + 1),
                                         response.headers)

    def _http_result(self, status, payload, headers):
        if len(payload) > self.HTTP_MAX_BYTES:
            raise ValueError("HTTP response exceeds the size ceiling")
        trimmed = {}
        for index, (key, value) in enumerate(headers.items()):
            if index >= self.HTTP_MAX_HEADERS:
                break
            trimmed[key.lower()] = value
        return {"result": "OK", "status": self._integer(status, 100, 599),
                "body": payload.decode("utf-8", "replace"), "headers": trimmed}

    def _shell_open(self, timeout_ms=10000):
        timeout_ms = self._integer(timeout_ms, 1, self.SHELL_TIMEOUT_MS)
        with self._lock:
            # Like http_open: validation only; the process is spawned per
            # shell_run call, so there is no persistent resource to hold.
            return self._register(_Resource("shell", None, "subprocess", None,
                                            timeout=timeout_ms))

    def _shell_run(self, handle, command, timeout_ms=None):
        """Run one command through the platform shell; output is capped, not lost.

        A finished command returns result="OK" whatever its exit code was; only
        launch failures, timeouts, and cancellation are ERR. The gate that keeps
        this op behind --allow-hardware lives in the host runtime, not here.
        """
        if not isinstance(command, str) or not command or "\0" in command:
            raise ValueError("shell command must be nonempty text without NUL")
        if len(command.encode("utf-8")) > self.SHELL_MAX_CMD_BYTES:
            raise ValueError("shell command exceeds the size ceiling")
        r = self._get(handle, "shell")
        with r.lock:
            self._live(r)
            if timeout_ms is None:
                timeout_ms = r.state["timeout"]
            timeout_ms = self._integer(timeout_ms, 1, self.SHELL_TIMEOUT_MS)
            deadline = time.monotonic() + timeout_ms / 1000
            argv, options, _ = shell_command(command)
            try:
                child = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, bufsize=0, **options)
            except OSError as exc:
                raise IOError(f"cannot start the platform shell: {exc}") from exc
            timed_out = False
            truncated = False
            try:
                pipes = [child.stdout, child.stderr]
                if os.name != "nt":
                    for pipe in pipes:
                        os.set_blocking(pipe.fileno(), False)
                buffers = [bytearray(), bytearray()]
                active = {0, 1}
                exited_at = None
                while True:
                    self._tick_cancel()
                    for index in tuple(active):
                        chunk = read_pipe(pipes[index])
                        if chunk == b"":
                            active.remove(index)
                        elif chunk:
                            room = self.SHELL_MAX_OUT_BYTES - len(buffers[index])
                            buffers[index].extend(chunk[:room])
                            truncated |= len(chunk) > room
                    exit_code = child.poll()
                    now = time.monotonic()
                    if exited_at is None:
                        if exit_code is not None:
                            # The shell is gone; kill leftovers so pipes reach EOF.
                            exited_at = now
                            kill_tree(child)
                        elif now >= deadline:
                            timed_out = True
                            exited_at = now
                            kill_tree(child)
                    if exited_at is not None:
                        if not active:
                            break
                        if now - exited_at >= 0.25:
                            truncated = True  # An escaped descendant kept a pipe.
                            break
                        time.sleep(0.001)
                    else:
                        # Short bounded wait keeps the loop cancellable and cheap.
                        try:
                            child.wait(timeout=0.01)
                        except subprocess.TimeoutExpired:
                            pass
            finally:
                if child.poll() is None:
                    kill_tree(child)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
                child.stdout.close()
                child.stderr.close()
            code = child.returncode if child.returncode is not None else -1
            result = {"result": "OK", "code": code, "truncated": truncated,
                      "out": buffers[0].decode("utf-8", "replace"),
                      "err": buffers[1].decode("utf-8", "replace")}
            if timed_out:
                result["result"] = "ERR"
                result["message"] = f"command timed out after {timeout_ms} ms"
            return result

    def _sleep_ms(self, ms):
        ms = float(ms)
        if not math.isfinite(ms) or ms <= 0:
            return 0
        deadline = time.monotonic() + min(ms, 4294967) / 1000
        while True:
            self._tick_cancel()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return 0
            time.sleep(min(remaining, .05) if self._active_cancel() else remaining)

    @classmethod
    def _size(cls, width, height):
        width, height = cls._integer(width, 1, 8192), cls._integer(height, 1, 8192)
        if width * height > cls.MAX_IMAGE_PIXELS:
            raise ValueError("image dimensions exceed pixel ceiling")
        return width, height

    @classmethod
    def _camera_device(cls, device):
        if device is None or device == "":
            return 0
        if isinstance(device, str) and re.fullmatch(r"/dev/video[0-9]+", device):
            if sys.platform != "linux":
                raise ValueError("/dev/video paths are Linux-only; use a camera index on Windows")
            return device
        return cls._integer(device, 0, 255)

    def _camera_open(self, device=0, width=640, height=480):
        device = self._camera_device(device)
        width, height = self._size(width, height)
        with self._lock:
            # Do not import av or probe devices during robot activation.
            return self._register(_Resource("camera", None, "av", None,
                                           device=device, width=width, height=height))

    @classmethod
    def _image_header(cls, data):
        """Reject truncated containers, verify PNG CRCs, bound dimensions pre-decode."""
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            pos, size, seen_data = 8, None, False
            while pos + 12 <= len(data):
                n = struct.unpack_from(">I", data, pos)[0]
                kind = data[pos + 4:pos + 8]
                end = pos + 12 + n
                if end > len(data):
                    break
                chunk = data[pos + 4:pos + 8 + n]
                if zlib.crc32(chunk) & 0xFFFFFFFF != struct.unpack_from(">I", data, pos + 8 + n)[0]:
                    raise ValueError("invalid PNG CRC")
                if size is None:
                    if kind != b"IHDR" or n != 13:
                        raise ValueError("invalid PNG header")
                    size = cls._size(*struct.unpack_from(">II", data, pos + 8))
                if kind == b"IDAT":
                    seen_data = True
                if kind == b"IEND":
                    if n or end != len(data) or not seen_data:
                        break
                    return "png", size
                pos = end
            raise ValueError("incomplete PNG image")
        if data.startswith(b"\xff\xd8"):
            pos, size, scan = 2, None, False
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
                    if size and scan and pos == len(data):
                        return "jpeg", size
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
                    size = cls._size(width, height)
                if marker == 0xDA:
                    scan = True
                pos += n
            raise ValueError("incomplete or unsupported JPEG image")
        raise ValueError("unsupported image format (expected JPEG or PNG)")

    def _validate_image(self, data):
        if not 0 < len(data) <= self.MAX_IMAGE_BYTES:
            raise ValueError("image exceeds byte ceiling or is empty")
        fmt, size = self._image_header(data)
        image = importlib.import_module("PIL.Image")
        try:
            with image.open(io.BytesIO(data), formats=[fmt.upper()]) as decoded:
                decoded.load()
                decoded_size = decoded.size
        except (OSError, SyntaxError, ValueError) as exc:
            raise ValueError(f"invalid image data (decode failed: {exc})") from exc
        if decoded_size != size:
            raise ValueError("invalid image data (dimension mismatch)")
        return fmt, size

    def _file_capture(self, src):
        if self.camera_src_root is None:
            raise ValueError("simulated camera src requires a host camera_src_root")
        if not isinstance(src, str) or not src:
            raise ValueError("camera src must be a nonempty path")
        if (self.camera_src_root.resolve(strict=True) != self.camera_src_root
                or not os.path.samestat(self.camera_src_root.stat(), self._camera_root_stat)):
            raise ValueError("camera source root changed")
        path = Path(src)
        if not path.is_absolute():
            path = self.camera_src_root / path
        path = path.resolve(strict=True)
        if not path.is_relative_to(self.camera_src_root):
            raise ValueError("camera src is outside the allowed root")
        before = path.stat()
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("camera src is not a regular file")
        if before.st_size > self.MAX_IMAGE_BYTES:
            raise ValueError("image exceeds byte ceiling")
        with path.open("rb") as stream:
            opened = os.fstat(stream.fileno())
            if not stat.S_ISREG(opened.st_mode) or not os.path.samestat(before, opened):
                raise ValueError("camera source changed during open")
            data = stream.read(self.MAX_IMAGE_BYTES + 1)
            after = os.fstat(stream.fileno())
        if (path.resolve(strict=True) != path or not os.path.samestat(before, path.stat())
                or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns)):
            raise ValueError("camera source changed during capture")
        fmt, size = self._validate_image(data)
        return self._image_result(data, fmt, size, "file", note=f"Simulated image: {path}")

    @staticmethod
    def _image_result(data, fmt, size, source, **extra):
        b64 = base64.b64encode(data).decode("ascii")
        return dict(result="OK", source=source, format=fmt, mime="image/" + fmt,
                    bytes=len(data), b64=b64, base64=b64, width=size[0], height=size[1], **extra)

    @staticmethod
    def _dshow_video_devices(av):
        """Return DirectShow video devices' unique alternative names in index order."""
        logging = importlib.import_module("av.logging")
        with _AV_LOG_LOCK:
            level = logging.get_level()
            logging.set_level(logging.INFO)
            try:
                with logging.Capture(local=False) as logs:
                    try:
                        av.open("dummy", format="dshow", options={"list_devices": "true"}).close()
                    except av.FFmpegError:
                        pass  # list_devices prints the list, then always fails to open
            finally:
                logging.set_level(level)
        text = "".join(message for _, _, message in logs)
        return [alt for kind, alt in re.findall(
            r'^"[^"\n]*" \(([^)\n]*)\)\s*\n\s*Alternative name "([^"\n]+)"', text, re.M)
            if "video" in kind.lower() or _DSHOW_VIDEO_GUID in alt.lower()]

    def _camera_input(self, av, device):
        fmt = self.CAMERA_FORMATS.get(sys.platform)
        if fmt is None:
            raise ValueError(f"camera capture is not supported on {sys.platform}")
        if isinstance(device, str):
            return device, fmt
        if fmt == "v4l2":
            return f"/dev/video{device}", fmt
        if fmt == "avfoundation":
            return f"{device}:none", fmt
        names = self._dshow_video_devices(av)
        if device >= len(names):
            raise IOError(f"camera unavailable: {device} ({len(names)} video devices found)")
        return "video=" + names[device], fmt

    def _latest_frame(self, container):
        """Decode the newest frame, discarding the backlog queued since the last capture.

        FFmpeg devices (dshow especially) queue seconds of frames while idle. A read
        that has to wait on the camera proves the backlog is drained.
        """
        stream = container.streams.video[0]
        rate = stream.average_rate or stream.guessed_rate
        live_wait = 0.5 / float(rate) if rate else 0.005
        deadline = time.monotonic() + self.CAMERA_TIMEOUT
        packets = container.demux(stream)
        pending = []
        while True:
            started = time.monotonic()
            packet = next(packets, None)
            if packet is None or packet.size == 0:
                raise IOError("camera stream ended")
            if packet.is_keyframe:
                pending.clear()
            pending.append(packet)
            if time.monotonic() - started >= live_wait or started >= deadline:
                break
        # Decode from the last keyframe so inter-frame codecs keep their references.
        frames = [frame for packet in pending for frame in packet.decode()]
        if not frames:
            raise IOError("camera capture failed")
        return frames[-1]

    def _camera_capture(self, handle, options=None):
        # Empty Lua tables can arrive as [] or {} depending on host conversion.
        options = {} if options is None or options == [] else options
        if not isinstance(options, dict):
            raise ValueError("camera options must be a table")
        r = self._get(handle, "camera")
        with r.lock:
            self._live(r)
            if options.get("src"):
                return self._file_capture(options["src"])
            if os.environ.get("MYBOT_SIM_CAPTURE_SOCK"):
                raise ValueError("simulator capture sockets are not supported by this backend; use explicit src")
            if ("width" in options) != ("height" in options):
                raise ValueError("width and height must be given together")
            width, height = self._size(options.get("width", r.state["width"]), options.get("height", r.state["height"]))
            device = self._camera_device(options.get("path", options.get("device", r.state["device"])))
            desired = dict(device=device, width=width, height=height)
            av = importlib.import_module("av")
            try:
                if r.device is not None and r.state != desired:
                    r.device.close()
                    r.device = None
                if r.device is None:
                    file, fmt = self._camera_input(av, device)
                    # Unlike OpenCV, FFmpeg devices reject sizes the camera does not offer.
                    device_options = {"video_size": f"{width}x{height}"}
                    if fmt == "avfoundation":
                        # avfoundation defaults to 29.97 fps, which most webcams reject.
                        device_options["framerate"] = "30"
                    try:
                        r.device = av.open(file, format=fmt, options=device_options,
                                           timeout=self.CAMERA_TIMEOUT)
                    except av.FFmpegError as exc:
                        raise IOError(f"camera unavailable: {device} ({exc})") from exc
                    r.state = desired
                frame = self._latest_frame(r.device)
                size = self._size(frame.width, frame.height)
                quality = self._integer(options.get("quality", 90), 1, 100)
                encoded = io.BytesIO()
                frame.to_image().save(encoded, "JPEG", quality=quality)
                data = encoded.getvalue()
                if len(data) > self.MAX_IMAGE_BYTES:
                    raise ValueError("image exceeds byte ceiling")
                fmt, encoded_size = self._image_header(data)
                if fmt != "jpeg" or size != encoded_size:
                    raise ValueError("invalid JPEG encoder output")
                return self._image_result(data, "jpeg", size, "pyav")
            except Exception:
                if r.device is not None:
                    r.device.close()
                    r.device = None
                raise

    def _close_handle(self, handle):
        with self._lock:
            r = self._get(handle)
            owner = self._current_owner()
            if (r.backend == "virtual" and owner is not None
                    and self._owners.get(int(handle)) is not owner):
                self._release_virtual_owner(owner, r)
                return 0
            del self._handles[int(handle)]
            self._settings.pop(int(handle), None)
            self._owners.pop(int(handle), None)
            r.refs -= 1
            if r.refs:
                return 0
            if r.key is not None:
                self._buses.pop(r.key, None)
            with r.lock:
                r.closed = True
                if r.backend == "virtual":
                    r.state["models"].clear()
                    r.state["rings"].clear()
                if r.device is not None:
                    if r.backend == "ftdi":
                        r.device.terminate()
                    else:
                        r.device.close()
                    r.device = None
        return 0

    def close(self):
        """Release every resource exactly once; idempotent and safe after failures."""
        with self._lock:
            for handle in list(self._handles):
                try:
                    self._close_handle(handle)
                except Exception as exc:
                    self._errors.message = f"close: {exc}"
            self._closed = True
