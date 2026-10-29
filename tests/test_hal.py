"""Hardware-free tests of portable transports and the original Lua driver ABI."""
from __future__ import annotations

import base64
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib
import io
import json
from pathlib import Path
import socket
import struct
import sys
import threading
import time
from types import SimpleNamespace
import zlib

import pytest

from pymybot.errors import BudgetExceeded
from pymybot.hal import HALManager

ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "modules"
I2C_URL = "ftdi://ftdi:232h:TEST/1"
SPI_URL = "ftdi://ftdi:2232h:TEST/2"


@pytest.fixture
def manager():
    m = HALManager()
    yield m
    m.close()


@pytest.fixture
def ftdi(monkeypatch):
    instances = []

    class Port:
        def __init__(self, controller, address):
            self.controller, self.address = controller, address
            self.mode, self.frequency = 0, 1000000

        def set_frequency(self, value):
            self.frequency = value

        def set_mode(self, value):
            self.mode = value

        def exchange(self, data, count=None, **kwargs):
            c = self.controller
            assert not c.active, "transactions on a shared bus must be serialized"
            c.active = True
            try:
                if c.pause:
                    time.sleep(.001)
                c.log.append(("exchange", self.address, list(data), count, kwargs,
                              self.mode, self.frequency))
                if c.fail:
                    raise IOError("USB disconnected")
                if c.short:
                    return b""
                return bytes(b ^ 0xFF for b in data) if kwargs.get("duplex") else bytes(range(count))
            finally:
                c.active = False

        def read(self, count):
            self.controller.log.append(("read", self.address, count))
            return bytes(range(count))

        def write(self, data):
            self.controller.log.append(("write", self.address, list(data)))

        def force_select(self, level):
            self.controller.log.append(("select", level))

    class Controller:
        def __init__(self, **kwargs):
            self.log, self.ports = [], {}
            self.active = self.pause = self.fail = self.short = False
            self.terminated = 0
            self.kwargs = kwargs
            instances.append(self)

        def configure(self, url):
            self.url = url
            if "BROKEN" in url:
                raise IOError("configure failed")

        def get_port(self, address=None, *, cs=None, freq=None, mode=None):
            key = cs if cs is not None else address
            if key not in self.ports:
                self.ports[key] = Port(self, key)
            return self.ports[key]

        def terminate(self):
            self.terminated += 1

    monkeypatch.setitem(sys.modules, "pyftdi.i2c", SimpleNamespace(I2cController=Controller))
    monkeypatch.setitem(sys.modules, "pyftdi.spi", SimpleNamespace(SpiController=Controller))
    return instances


def test_native_builtin_drivers_share_hal_transports(ftdi):
    from pymybot.robot import Robot

    sql = f'''
CREATE TABLE I2C(name String, path String);
INSERT INTO I2C(name,path) VALUES('i','{I2C_URL}');
CREATE TABLE SPI(name String, path String, spi_mode Number, bits Number, speed Number, delay Number);
INSERT INTO SPI(name,path,spi_mode,bits,speed,delay) VALUES('s','{SPI_URL}',3,8,500000,2);
CREATE TABLE UART(name String, path String, baud Number);
INSERT INTO UART(name,path,baud) VALUES('u','loop://',9600);
CREATE TABLE HTTP(name String, base String);
INSERT INTO HTTP(name,base) VALUES('h','http://127.0.0.1');
CREATE TABLE Camera(name String);
INSERT INTO Camera(name) VALUES('c');
CREATE TABLE Shell(name String);
INSERT INTO Shell(name) VALUES('sh');
'''
    with Robot(sql, allow_hardware=True) as robot:
        assert {variable.kind for variable in robot.registry.values()} == {"python"}
        assert all(variable.runtime._virtual is None for variable in robot.registry.values())
        assert len(robot.hal._handles) == 6
        i2c = robot.registry["i"]
        spi = robot.registry["s"]
        assert i2c.runtime.context.call("i2c_transfer", i2c.read()["fd"], 0x40, [0], 2) == [0, 1]
        assert spi.runtime.context.call("spi_transfer", spi.read()["fd"], [0, 255], 2) == [255, 0]
        assert spi.read()["delay"] == 2
    assert not robot.hal._handles and not robot.hal._buses
    assert len(ftdi) == 2 and all(device.terminated == 1 for device in ftdi)


def test_ftdi_i2c_atomic_shared_and_close(manager, ftdi):
    a = manager.call("i2c_open", I2C_URL)
    b = manager.call("i2c_open", I2C_URL)
    assert a >= 0 and a != b and len(ftdi) == 1
    assert manager.call("i2c_transfer", a, 0x40, [0xFF, 0], 3) == [0, 1, 2]
    assert ftdi[0].log[-1][:4] == ("exchange", 0x40, [255, 0], 3)
    assert manager.call("i2c_transfer", b, 0x41, [], 2) == [0, 1]
    assert manager.call("i2c_transfer", b, 0x41, [9], 0) == []
    assert manager.call("close_handle", a) == 0
    assert not ftdi[0].terminated
    assert manager.call("i2c_transfer", a, 0x40, [], 1) is None
    assert manager.call("i2c_transfer", b, 0x40, [], 1) == [0]
    manager.close()
    manager.close()
    assert ftdi[0].terminated == 1
    assert manager.call("i2c_open", I2C_URL) == -1


def test_i2c_limits_and_short_read(manager, ftdi):
    h = manager.call("i2c_open", I2C_URL)
    for addr, data, n in [(128, [], 1), (1, [], 17), (1, [0] * 259, 0),
                          (1, [256], 0), (1, [float("nan")], 0), (1, [], 0)]:
        assert manager.call("i2c_transfer", h, addr, data, n) is None
    assert not ftdi[0].log
    ftdi[0].short = True
    assert manager.call("i2c_transfer", h, 10, [1], 1) is None
    assert "short I2C" in manager.call("last_error")


def test_ftdi_bus_lock_and_protocol_conflict(manager, ftdi):
    a = manager.call("i2c_open", I2C_URL)
    b = manager.call("i2c_open", I2C_URL)
    assert manager.call("spi_open", I2C_URL) == -1
    assert "another bus protocol" in manager.call("last_error")
    ftdi[0].pause = True
    with ThreadPoolExecutor(max_workers=4) as pool:
        outputs = list(pool.map(lambda i: manager.call("i2c_transfer", (a, b)[i % 2], i % 127, [i], 2), range(40)))
    assert outputs == [[0, 1]] * 40


def test_spi_shared_controller_per_handle_setup_and_delay(manager, ftdi):
    a = manager.call("spi_open", SPI_URL)
    b = manager.call("spi_open", SPI_URL + "?cs=1")
    assert a >= 0 and b >= 0 and len(ftdi) == 1
    assert manager.call("spi_setup", a, 3, 8, 500000) == 0
    assert manager.call("spi_setup", b, 0, 8, 1000000) == 0
    assert manager.call("spi_transfer", a, [0, 255, 128], 1) == [255, 0, 127]
    exchange = ftdi[0].log[-2]
    assert exchange[1] == 0 and exchange[-2:] == (3, 500000)
    assert exchange[4] == dict(duplex=True, start=True, stop=False)
    assert ftdi[0].log[-1] == ("select", True)
    assert manager.call("spi_transfer", b, [1]) == [254]
    assert ftdi[0].log[-1][1] == 1
    ftdi[0].fail = True
    assert manager.call("spi_transfer", a, [0], 1) is None
    assert ftdi[0].log[-1] == ("select", True)


def test_spi_rejects_invalid_configuration(manager, ftdi):
    h = manager.call("spi_open", SPI_URL)
    for mode, bits, speed in [(1.5, 8, 1), (4, 8, 1), (0, 16, 1000), (0, 8, 0)]:
        assert manager.call("spi_setup", h, mode, bits, speed) == -1
    for data in [[], [0] * 65, [-1], [1.5], "not bytes"]:
        assert manager.call("spi_transfer", h, data) is None
    assert manager.call("spi_transfer", h, [1], 65536) is None


@pytest.mark.parametrize("path", ["ftdi://", "ftdi:///?", "ftdi://ftdi:232h/0", "ftdi://ftdi:232h/1?bad=1", "random", "/tmp/bus"])
def test_reject_bad_ftdi_routes(manager, ftdi, path):
    assert manager.call("i2c_open", path) == -1
    assert manager.call("spi_open", path) == -1
    assert not ftdi


def test_failed_configure_cleans_up(manager, ftdi):
    assert manager.call("i2c_open", "ftdi://ftdi:232h:BROKEN/1") == -1
    assert ftdi[0].terminated == 1
    assert not manager._handles and not manager._buses


def test_windows_uses_portable_routes_only(manager, ftdi, monkeypatch):
    monkeypatch.setattr(sys, "platform", "win32")
    assert manager.call("i2c_open", "/dev/i2c-1") == -1
    assert manager.call("spi_open", "/dev/spidev0.0") == -1
    assert manager.call("i2c_open", I2C_URL) >= 0
    assert manager.call("spi_open", SPI_URL) >= 0
    assert "smbus2" not in sys.modules and "spidev" not in sys.modules


def test_linux_legacy_backends_are_library_wrappers(manager, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    class Message(list):
        @staticmethod
        def write(address, data):
            return Message(data)
        @staticmethod
        def read(address, count):
            return Message(range(count))
    class SMBus:
        def __init__(self, bus):
            self.bus, self.calls, self.closed = bus, [], False
        def i2c_rdwr(self, *messages):
            self.calls.append(messages)
        def close(self):
            self.closed = True
    class SPI:
        def open(self, bus, cs):
            self.bus, self.cs = bus, cs
        def xfer2(self, data, speed, delay, bits):
            return data
        def close(self):
            self.closed = True
    monkeypatch.setitem(sys.modules, "smbus2", SimpleNamespace(SMBus=SMBus, i2c_msg=Message))
    monkeypatch.setitem(sys.modules, "spidev", SimpleNamespace(SpiDev=SPI))
    i = manager.call("i2c_open", "/dev/i2c-1")
    s = manager.call("spi_open", "/dev/spidev0.1")
    assert i >= 0 and s >= 0
    assert manager.call("i2c_transfer", i, 0x40, [0xFF], 3) == [0, 1, 2]
    assert manager.call("spi_setup", s, 1, 16, 10000) == 0
    assert manager.call("spi_transfer", s, [128, 255], 1) == [128, 255]
    bus, spi = manager._get(i).device, manager._get(s).device
    assert len(bus.calls[-1]) == 2 and spi.cs == 1
    manager.close()
    assert bus.closed and spi.closed


def test_missing_libraries_fail_lazily(manager, monkeypatch):
    original = importlib.import_module
    def unavailable(name):
        if name in {"av", "serial", "pyftdi.i2c", "pyftdi.spi"}:
            raise ImportError("optional library missing")
        return original(name)
    monkeypatch.setattr(importlib, "import_module", unavailable)
    h = manager.call("camera_open")
    assert h >= 0
    assert manager.call("camera_capture", h, {})["result"] == "ERR"
    assert manager.call("uart_open", "COM3", 9600) == -1
    assert manager.call("i2c_open", I2C_URL) == -1
    assert manager.call("spi_open", SPI_URL) == -1
    assert "optional library missing" in manager.call("last_error")


@pytest.fixture
def serial_fake(monkeypatch):
    devices = []

    class Serial:
        def __init__(self, path, **kwargs):
            self.path, self.options = path, kwargs
            self.data = bytearray()
            self.closed = 0
            self.fail = self.short = False
            devices.append(self)

        def write(self, data):
            self.data.extend(data)
            return 0 if self.short else len(data)

        def read(self, n):
            if self.fail:
                raise IOError("unplugged")
            out = bytes(self.data[:n])
            del self.data[:n]
            return out

        def reset_input_buffer(self):
            self.data.clear()

        def close(self):
            self.closed += 1

    monkeypatch.setitem(sys.modules, "serial", SimpleNamespace(serial_for_url=Serial))
    return devices


@pytest.mark.parametrize("path", ["COM3", "com12", r"\\.\COM33", "loop://"])
def test_uart_com_urls_binary_and_sharing(manager, serial_fake, path):
    a = manager.call("uart_open", path, 115200)
    b = manager.call("uart_open", path, 115200)
    assert a >= 0 and b >= 0 and len(serial_fake) == 1
    assert serial_fake[0].options["timeout"] == 0
    assert serial_fake[0].options["write_timeout"] == 1
    assert manager.call("uart_open", path, 9600) == -1
    assert manager.call("uart_write", a, [0, 255, 128, 10]) == 4
    assert manager.call("uart_read", b, 9, 2) == [0, 255, 128, 10]
    assert manager.call("uart_read", a, 10, 4) == []  # empty is timeout, not EOF
    assert manager.call("uart_write", a, [1]) == 1
    assert manager.call("uart_flush", b) == 0
    assert manager.call("uart_read", a, 1, 0) == []
    assert manager.call("close_handle", a) == 0 and serial_fake[0].closed == 0
    assert manager.call("close_handle", b) == 0 and serial_fake[0].closed == 1


def test_uart_error_limits(manager, serial_fake):
    h = manager.call("uart_open", "COM4", 9600)
    for n, timeout in [(0, 0), (1, 60001), (1, float("inf")), (1, float("nan"))]:
        assert manager.call("uart_read", h, n, timeout) is None
    assert manager.call("uart_write", h, [0] * 513) == -1
    assert manager.call("uart_open", "socket://untrusted:1234", 9600) == -1
    assert manager.call("uart_open", "COM0", 9600) == -1
    assert manager.call("uart_open", "COM4", 42) == -1
    serial_fake[0].short = True
    assert manager.call("uart_write", h, [1]) == -1
    serial_fake[0].fail = True
    assert manager.call("uart_read", h, 1, 10) is None
    assert "unplugged" in manager.call("last_error")


def test_uart_per_call_cancel_interrupts_polling(manager, serial_fake):
    h = manager.call("uart_open", "COM5", 115200)
    def cancel():
        raise BudgetExceeded("per-call cancel")
    started = time.monotonic()
    with pytest.raises(BudgetExceeded, match="per-call cancel"):
        manager.call("uart_read", h, 1, 300, cancel_check=cancel)
    assert time.monotonic() - started < 0.2
    # The check is scoped to that request and must not stick to the thread.
    assert manager.call("uart_read", h, 1, 5) == []


def test_uart_per_call_cancel_is_thread_local(manager, serial_fake):
    a = manager.call("uart_open", "COM6", 115200)
    b = manager.call("uart_open", "COM6", 115200)
    def cancel():
        raise BudgetExceeded("worker cancel")
    with ThreadPoolExecutor(max_workers=2) as pool:
        cancelled = pool.submit(manager.call, "uart_read", a, 1, 300, cancel_check=cancel)
        normal = pool.submit(manager.call, "uart_read", b, 1, 40)
        with pytest.raises(BudgetExceeded, match="worker cancel"):
            cancelled.result()
        assert normal.result() == []


def test_real_pyserial_loopback(manager):
    pytest.importorskip("serial")
    h = manager.call("uart_open", "loop://", 115200)
    assert h >= 0, manager.call("last_error")
    assert manager.call("uart_write", h, [0, 127, 128, 255]) == 4
    assert manager.call("uart_read", h, 4, 200) == [0, 127, 128, 255]
    assert manager.call("uart_read", h, 1, 5) == []
    assert manager.call("uart_flush", h) == 0


def png_bytes(width=2, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\x00" + b"\x00\x80\xff" * width) * height))
            + chunk(b"IEND", b""))


def mock_jpeg():
    # Container fixture for the fake encoder; actual decoding is tested with real Pillow.
    return (b"\xff\xd8\xff\xc0\x00\x0b\x08\x00\x01\x00\x02\x01\x01\x11\x00"
            b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x12\xff\xd9")


# Verbatim FFmpeg 8 dshow list_devices output, including an audio name with parentheses.
DSHOW_DEVICES = (
    '"Integrated Webcam_FHD" (video)\n'
    '  Alternative name "@device_pnp_\\\\?\\usb#vid_3277&pid_0004#cam0\\global"\n'
    '"Microphone (Intel\u00ae Smart Sound)" (audio)\n'
    '  Alternative name "@device_cm_{33D9A762}\\wave_{29D8FB9C}"\n'
    '"USB Camera" (video)\n'
    '  Alternative name "@device_pnp_\\\\?\\usb#vid_0c45&pid_6366#cam1\\global"\n'
)

# Some FFmpeg/PyAV builds print video inputs as "(none)" and identify the
# category only through the DirectShow GUID in the alternative name.
DSHOW_DEVICES_NONE = (
    '"Integrated Webcam_FHD" (none)\n'
    '  Alternative name "@device_pnp_cam0_{65E8773D-8F56-11D0-A3B9-00A0C9223196}"\n'
    '"Microphone" (audio)\n'
    '  Alternative name "@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\\wave_x"\n'
)


@pytest.fixture
def av_fake(monkeypatch):
    containers = []

    class FFmpegError(Exception):
        pass

    class Image:
        def save(self, stream, fmt, quality):
            assert fmt == "JPEG" and 1 <= quality <= 100
            if module.encode_fail:
                raise OSError("encoder failed")
            stream.write(mock_jpeg())

    class Frame:
        width, height = 2, 1

        def __init__(self, live):
            self.live = live

        def to_image(self):
            assert self.live, "captured a queued backlog frame"
            return Image()

    class Packet:
        size, is_keyframe = 100, True

        def __init__(self, live):
            self.live = live

        def decode(self):
            return [Frame(self.live)]

    class Container:
        def __init__(self, file, fmt, options, timeout):
            self.file, self.format, self.options, self.timeout = file, fmt, options, timeout
            self.closed = 0
            self.read_ok = True
            self.backlog = 3
            self.streams = SimpleNamespace(video=[SimpleNamespace(average_rate=1000, guessed_rate=None)])
            containers.append(self)

        def demux(self, stream):
            assert stream is self.streams.video[0]
            while self.read_ok:
                if self.backlog:
                    self.backlog -= 1
                    yield Packet(False)
                else:
                    time.sleep(.002)  # waiting on the camera: a 1000 fps stream's live frame
                    yield Packet(True)

        def close(self):
            self.closed += 1

    def open_(file, format=None, options=None, timeout=None):
        if options.get("list_devices"):
            assert module.logging.level == module.logging.INFO and module.logging.capturing
            module.logging.captured.append((32, "dshow", module.devices))
            raise FFmpegError("Immediate exit requested")
        if module.open_fail:
            raise FFmpegError("I/O error")
        return Container(file, format, options, timeout)

    class Capture:
        def __init__(self, local=True):
            assert local is False

        def __enter__(self):
            logging.captured, logging.capturing = [], True
            return logging.captured

        def __exit__(self, *exc):
            logging.capturing = False

    logging = SimpleNamespace(INFO=32, level=None, capturing=False, captured=[], Capture=Capture)
    logging.get_level = lambda: logging.level
    logging.set_level = lambda level: setattr(logging, "level", level)
    module = SimpleNamespace(open=open_, FFmpegError=FFmpegError, logging=logging,
                             containers=containers, devices=DSHOW_DEVICES,
                             open_fail=False, encode_fail=False)
    monkeypatch.setitem(sys.modules, "av", module)
    monkeypatch.setitem(sys.modules, "av.logging", logging)
    return module


def test_dshow_video_devices_accept_none_kind_with_video_guid(manager, av_fake):
    av_fake.devices = DSHOW_DEVICES_NONE
    assert manager._dshow_video_devices(av_fake) == [
        "@device_pnp_cam0_{65E8773D-8F56-11D0-A3B9-00A0C9223196}"]


def test_camera_lazy_capture_fields_reconfigure_close(manager, av_fake):
    h = manager.call("camera_open", 0, 640, 480)
    assert h >= 0 and not av_fake.containers
    shot = manager.call("camera_capture", h, {})
    assert shot["result"] == "OK", shot
    assert shot["format"] == "jpeg" and shot["mime"] == "image/jpeg"
    assert shot["source"] == "pyav" and shot["b64"] == shot["base64"]
    assert base64.b64decode(shot["b64"]) == mock_jpeg()
    assert (shot["width"], shot["height"], shot["bytes"]) == (2, 1, len(mock_jpeg()))
    assert av_fake.containers[0].options["video_size"] == "640x480"
    av_fake.containers[0].backlog = 50  # frames the device queued while idle
    assert manager.call("camera_capture", h, {})["result"] == "OK", manager.call("last_error")
    assert len(av_fake.containers) == 1 and av_fake.containers[0].backlog == 0
    assert manager.call("camera_capture", h, {"device": 1})["result"] == "OK"
    assert len(av_fake.containers) == 2 and av_fake.containers[0].closed == 1
    assert manager.call("close_handle", h) == 0
    assert av_fake.containers[1].closed == 1
    assert manager.call("camera_capture", h, {})["result"] == "ERR"


@pytest.mark.parametrize("platform, device, file, fmt", [
    ("linux", 0, "/dev/video0", "v4l2"),
    ("linux", "/dev/video2", "/dev/video2", "v4l2"),
    ("darwin", 1, "1:none", "avfoundation"),
    ("win32", 0, "video=@device_pnp_\\\\?\\usb#vid_3277&pid_0004#cam0\\global", "dshow"),
    ("win32", 1, "video=@device_pnp_\\\\?\\usb#vid_0c45&pid_6366#cam1\\global", "dshow"),
])
def test_camera_platform_device_inputs(manager, av_fake, monkeypatch, platform, device, file, fmt):
    monkeypatch.setattr(sys, "platform", platform)
    h = manager.call("camera_open", device, 320, 240)
    assert manager.call("camera_capture", h, {})["result"] == "OK", manager.call("last_error")
    container = av_fake.containers[-1]
    assert (container.file, container.format) == (file, fmt)
    assert container.options["video_size"] == "320x240"
    assert ("framerate" in container.options) == (fmt == "avfoundation")
    assert av_fake.logging.level is None


def test_camera_platform_failures(manager, av_fake, monkeypatch):
    monkeypatch.setattr(sys, "platform", "win32")
    h = manager.call("camera_open", 2)
    response = manager.call("camera_capture", h, {})
    assert response["result"] == "ERR" and "2 video devices found" in response["message"]
    monkeypatch.setattr(sys, "platform", "freebsd14")
    response = manager.call("camera_capture", h, {})
    assert response["result"] == "ERR" and "not supported on freebsd14" in response["message"]
    assert not av_fake.containers


def test_camera_capture_failures_release_and_retry(manager, av_fake):
    h = manager.call("camera_open", 0, 640, 480)
    av_fake.open_fail = True
    response = manager.call("camera_capture", h, {})
    assert response["result"] == "ERR" and "camera unavailable" in response["message"]
    assert not av_fake.containers
    av_fake.open_fail = False
    assert manager.call("camera_capture", h, {})["result"] == "OK"
    av_fake.containers[-1].read_ok = False
    assert manager.call("camera_capture", h, {})["result"] == "ERR"
    assert av_fake.containers[-1].closed == 1
    av_fake.encode_fail = True
    assert "encoder failed" in manager.call("camera_capture", h, {})["message"]
    assert len(av_fake.containers) == 2 and av_fake.containers[-1].closed == 1


def test_camera_source_sandbox_validation_and_ceiling(tmp_path, av_fake):
    root = tmp_path / "allowed"
    root.mkdir()
    (root / "photo.png").write_bytes(png_bytes())
    outside = tmp_path / "outside.png"
    outside.write_bytes(png_bytes())
    with_manager = HALManager(root)
    h = with_manager.call("camera_open")
    try:
        shot = with_manager.call("camera_capture", h, {"src": "photo.png"})
        assert shot["result"] == "OK" and shot["mime"] == "image/png"
        assert not av_fake.containers
        for src in ["../outside.png", str(outside), "missing.png"]:
            assert with_manager.call("camera_capture", h, {"src": src})["result"] == "ERR"
        (root / "bad.png").write_bytes(png_bytes()[:-2])
        assert with_manager.call("camera_capture", h, {"src": "bad.png"})["result"] == "ERR"
        (root / "bad.png").write_bytes(b"not an image")
        assert with_manager.call("camera_capture", h, {"src": "bad.png"})["result"] == "ERR"
        with_manager.MAX_IMAGE_BYTES = 10
        assert "ceiling" in with_manager.call("camera_capture", h, {"src": "photo.png"})["message"]
    finally:
        with_manager.close()
    denied = HALManager()
    try:
        h = denied.call("camera_open")
        response = denied.call("camera_capture", h, {"src": str(outside), "src_root": str(tmp_path)})
        assert response["result"] == "ERR" and "camera_src_root" in response["message"]
    finally:
        denied.close()


def test_camera_source_symlink_escape(tmp_path, av_fake):
    root = tmp_path / "root"
    root.mkdir()
    outside = tmp_path / "image.png"
    outside.write_bytes(png_bytes())
    try:
        (root / "escape.png").symlink_to(outside)
    except OSError:
        pytest.skip("symlinks require privileges on this platform")
    m = HALManager(root)
    try:
        h = m.call("camera_open")
        assert m.call("camera_capture", h, {"src": "escape.png"})["result"] == "ERR"
    finally:
        m.close()


def test_camera_validation_and_no_silent_simulator_fallback(manager, av_fake, monkeypatch):
    assert manager.call("camera_open", "https://untrusted/video", 1, 1) == -1
    assert manager.call("camera_open", 0, 0, 1) == -1
    h = manager.call("camera_open")
    assert manager.call("camera_capture", h, {"width": 10})["result"] == "ERR"
    monkeypatch.setenv("MYBOT_SIM_CAPTURE_SOCK", "/missing/socket")
    assert "not supported" in manager.call("camera_capture", h, {})["message"]
    assert not av_fake.containers


def test_real_pillow_image_validation(tmp_path):
    from PIL import Image
    m = HALManager(tmp_path)
    h = m.call("camera_open")
    try:
        for extension, fmt in [(".png", "PNG"), (".jpg", "JPEG")]:
            buffer = io.BytesIO()
            Image.new("RGB", (12, 8)).save(buffer, fmt)
            encoded = buffer.getvalue()
            file = tmp_path / ("image" + extension)
            file.write_bytes(encoded)
            shot = m.call("camera_capture", h, {"src": str(file)})
            assert shot["result"] == "OK", shot
            assert (shot["width"], shot["height"]) == (12, 8)
            file.write_bytes(encoded[:-8])
            assert m.call("camera_capture", h, {"src": str(file)})["result"] == "ERR"
        # Valid PNG framing and CRCs around a corrupt deflate stream: only a real decode catches it.
        good = png_bytes(4, 4)
        pos = good.index(b"IDAT") - 4
        n = struct.unpack_from(">I", good, pos)[0]
        garbage = b"IDAT\x78\x9c" + b"\xff" * (n - 2)
        bad = (good[:pos] + struct.pack(">I", n) + garbage
               + struct.pack(">I", zlib.crc32(garbage)) + good[pos + 12 + n:])
        (tmp_path / "corrupt.png").write_bytes(bad)
        response = m.call("camera_capture", h, {"src": "corrupt.png"})
        assert response["result"] == "ERR" and "decode failed" in response["message"]
    finally:
        m.close()


def test_portable_sleep_cancellation_and_unsupported(manager):
    assert manager.call("sleep_ms", 0) == 0
    assert manager.call("sleep_ms", float("nan")) == 0
    assert manager.call("speaker_open", "default")["result"] == "ERR"
    assert manager.call("__dict__")["result"] == "ERR"
    def cancelled():
        raise InterruptedError("cancelled")
    m = HALManager(cancel_check=cancelled)
    with pytest.raises(InterruptedError, match="cancelled"):
        m.call("sleep_ms", 1000)
    m.close()


def lua_runtime(manager, monkeypatch):
    lupa = pytest.importorskip("lupa.luajit21")
    monkeypatch.setenv("BOT4CJ_MODULE_PATH", str(MODULES))
    lua = lupa.LuaRuntime(encoding="utf-8", unpack_returned_tuples=True,
                          register_eval=False, register_builtins=False)
    def from_lua(value):
        if lupa.lua_type(value) == "table":
            keys = list(value.keys())
            if keys and set(keys) == set(range(1, len(keys) + 1)):
                return [from_lua(value[i]) for i in range(1, len(keys) + 1)]
            return {k: from_lua(v) for k, v in value.items()}
        return value
    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        return value
    lua.globals()["__hal_call"] = lambda operation, *args: to_lua(manager.call(operation, *(from_lua(v) for v in args)))
    # __mpath is the host's path resolver; keeps Windows drive letters out of
    # the original source mpath.lua's colon-separated environment parsing.
    lua.globals()["__module_root"] = str(MODULES)
    lua.execute('__mpath = {resolve=function(rel) return __module_root .. "/" .. rel end}')
    lua.execute(f'dofile({str(MODULES / "lib/HAL.lua")!r})')
    lua.globals()["__hal_call"] = None
    return lua


def test_host_runtime_camera_bridge(manager, av_fake):
    pytest.importorskip("lupa.luajit21")
    from pymybot.runtime import LuaState
    # av_fake is installed: this opt-in exercises dispatch, never real hardware.
    state = LuaState([MODULES], manager, threading.Event(), allow_hardware=True)
    try:
        state.load(MODULES / "Camera.lua")
        assert state.globals["__hal_call"] is None
        assert state.call("build", {})["result"] == "OK"
        result = state.call("call", {})
        assert result["result"] == "OK" and result["b64"]
        assert state.call("destroy", {})["result"] == "OK"
    finally:
        state.close()


def test_lua_original_i2c_spi_buffers_and_utf8_bridge(manager, ftdi, monkeypatch):
    lua = lua_runtime(manager, monkeypatch)
    lua.globals()["i2c_url"] = I2C_URL
    lua.globals()["spi_url"] = SPI_URL
    lua.execute('''
        assert(__hal_call == nil)
        assert(type(__BOT4CJ_HAL.camera_capture) == "function")
        local f = i2c_open(i2c_url)
        assert(i2c_set_addr(f, 0x40))
        assert(i2c_write_reg(f, 0xFF, 0x80) == true)
        assert(i2c_write_multi(f, 1, 255, 128) == 0)
        assert(i2c_write_reg16(f, 0x1234, 128, 255) == 0)
        assert(i2c_read_reg(f, 1) == 0)
        assert(i2c_read_multi(f, 1, 3) == 258)
        assert(i2c_read_reg16(f, 0x1234, 3) == 258)
        assert(i2c_read(f, 3) == 258)
        assert(#i2c_read_bytes(f, 100) == 16)
        assert(#i2c_read_multi_bytes(f, 1, 0) == 1)
        assert(i2c_read_multi(f, 1, 7) == -1)
        assert(i2c_write_reg(f, 256, 0) == false)
        local s = spi_open(spi_url)
        assert(spi_setup(s, 0, 8, 1000000, 0) == 0)
        assert(spi_write(s, 128) == 0)
        assert(spi_read(s) == 255)
        assert(spi_write3(s, 255, 0, 128) == 0)
        assert(spi_write_multi(s, {0, 128, 255}) == 0)
        assert(spi_read_multi(s, 2) == 65535)
        local bytes = spi_xfer_full(s, {0, 128, 255})
        assert(bytes[1] == 255 and bytes[2] == 127 and bytes[3] == 0)
        assert(spi_xfer_full(s, {1.5}) == nil)
        i2c_close(f); spi_close(s)
        assert(not pcall(gpio_request_line, "anything", 1, 1))
        assert(not pcall(pwm_export, 0, 0))
    ''')
    assert all(c.terminated == 1 for c in ftdi)


def test_lua_uart_binary_transport(manager, serial_fake, monkeypatch):
    lua = lua_runtime(manager, monkeypatch)
    lua.execute('''
        local f = uart_open("COM9", 115200)
        assert(f >= 0)
        assert(uart_write(f, {0, 128, 255}) == 3)
        local b = uart_read(f, 3, 10)
        assert(b[1] == 0 and b[2] == 128 and b[3] == 255)
        assert(#uart_read(f, 1, 2) == 0)
        assert(uart_read(f, 1, math.huge) == nil)
        assert(uart_flush(f) == 0)
        assert(uart_close(f) == 0)
    ''')


def test_lua_virtual_sensor_operations_and_mixed_buses(manager, ftdi, monkeypatch):
    lua = lua_runtime(manager, monkeypatch)
    lua.globals()["i2c_url"] = I2C_URL
    lua.execute('''
        local v = __BOT4CJ_VIRTBUS
        v.attach("registers", 0x40, {
            write = function(b) assert(b[1] == 0x20) end,
            read = function(n) return {0x80, 0xFF} end,
        })
        local virtual = i2c_open("virt-i2c-0")
        local physical = i2c_open(i2c_url)
        assert(i2c_set_addr(virtual, 0x40))
        assert(i2c_set_addr(physical, 0x40))
        assert(i2c_read_multi(virtual, 0x20, 2) == 0x80FF)
        assert(i2c_read_multi(physical, 0x20, 2) == 1)
        v.attach_spi("spi", "virt-spi-0", {xfer=function(b) return b end})
        local spi = spi_open("virt-spi-0")
        assert(spi_setup(spi, 0, 8, 1000000) == 0)
        assert(spi_xfer_full(spi, {128, 255})[2] == 255)
        v.attach_uart("uart", "virt-uart-0", {on_write=function(b) return b end})
        local uart = uart_open("virt-uart-0", 9600)
        assert(uart_write(uart, {128, 255}) == 2)
        assert(uart_read(uart, 2, 0)[1] == 128)
        i2c_close(virtual); i2c_close(physical); spi_close(spi); uart_close(uart)
        assert(v.fd_count() == 0)
    ''')


def test_lua_synthetic_i2c_sensor_and_nack(manager, monkeypatch, synthetic_modules):
    lua = lua_runtime(manager, monkeypatch)
    lua.execute(f'dofile({str(synthetic_modules[0] / "SyntheticI2C.lua")!r})')
    lua.execute('''
        local model = SyntheticI2C_VIRT.new({count=40961})
        local vbus = __BOT4CJ_VIRTBUS
        vbus.attach("synthetic", 0x31, model)
        local fd = i2c_open("virt-i2c-synthetic")
        local data = {fd=fd, address=0x31, tag=19}
        assert(build(data).result == "OK")
        local value = call(data)
        assert(value.result == "OK" and value.COUNT == 40961)
        assert(value.VALUE == 10240.25 and value.TAG == 19)
        assert(model.registers[4] == 19)
        model.nack = true
        assert(build(data).message == "synthetic I2C write NACK")
        assert(call(data).message == "synthetic I2C read NACK")
        assert(i2c_write_reg(fd, 4, 1) == false)
        assert(i2c_write_multi(fd, 4, 1) == -1)
        assert(i2c_read_multi_bytes(fd, 0, 2) == nil)
        model.nack = false
        model.read_nack = true
        assert(call(data).result == "ERR")
        model.read_nack = false
        assert(call(data).COUNT == 40961)
        assert(destroy(data).result == "OK")
        i2c_close(fd)
        assert(vbus.fd_count() == 0)
    ''')


def test_windows_style_module_paths_and_cross_state_virtual_sensor(manager, monkeypatch, synthetic_modules):
    bus_lua = lua_runtime(manager, monkeypatch)
    sensor_lua = lua_runtime(manager, monkeypatch)
    for lua in (bus_lua, sensor_lua):
        lua.execute('''
            local getenv = os.getenv
            os.getenv = function(name)
                if name == "BOT4CJ_MODULE_PATH" then return "C:/robots/modules;D:/extra" end
                return getenv(name)
            end
        ''')
    bus_lua.execute(f'dofile({str(MODULES / "I2C.lua")!r})')
    data = bus_lua.table_from(dict(path="virt-i2c-0", proto="virt"))
    assert bus_lua.globals().build(data)["result"] == "OK"
    fd = bus_lua.globals().call(data)["fd"]
    sensor_lua.execute(f'dofile({str(synthetic_modules[0] / "SyntheticI2C.lua")!r})')
    data = sensor_lua.table_from(dict(fd=fd, address=0x31, proto="virt"))
    try:
        assert sensor_lua.globals().build(data)["result"] == "OK"
        assert sensor_lua.globals().call(data)["COUNT"] == 40961
        sensor_lua.execute('''
            local v = __BOT4CJ_VIRTBUS
            local adopted = false
            for _, entry in ipairs(v.txlog) do
                if entry.dir == "adopt" then adopted = true end
            end
            assert(adopted and v.fd_count() == 1)
        ''')
    finally:
        assert sensor_lua.globals().destroy(data)["result"] == "OK"
        assert bus_lua.globals().destroy(bus_lua.table())["result"] == "OK"
    for lua in (bus_lua, sensor_lua):
        lua.execute('assert(__BOT4CJ_VIRTBUS.fd_count() == 0)')


def test_lua_hal_speaker_open_is_unsupported(manager, monkeypatch):
    lua = lua_runtime(manager, monkeypatch)
    lua.execute('''
        local ok, message = pcall(speaker_open, "default")
        assert(not ok)
        assert(message:find("speaker_open is not supported", 1, true))
    ''')
    assert not manager._handles


def test_lua_existing_bus_modules_and_camera(manager, ftdi, serial_fake, av_fake, monkeypatch):
    for module, data in [("I2C", dict(path=I2C_URL)),
                         ("SPI", dict(path=SPI_URL, spi_mode=0, bits=8, speed=1000000, delay=0)),
                         ("UART", dict(path="COM9", baud=9600)),
                         ("Camera", dict(device=0))]:
        lua = lua_runtime(manager, monkeypatch)
        lua.execute(f'dofile({str(MODULES / (module + ".lua"))!r})')
        assert lua.globals().build(lua.table_from(data))["result"] == "OK"
        result = lua.globals().call(lua.table())
        assert result["result"] == "OK"
        if module == "Camera":
            assert result["b64"] and result["format"] == "jpeg"
            assert lua.globals().read(lua.table())["result"] == "OK"
        assert lua.globals().destroy(lua.table())["result"] == "OK"


class _EchoHandler(BaseHTTPRequestHandler):
    """Echo endpoint: replies with method/path/auth/body; /missing → 404, /redirect → 302."""

    def log_message(self, *args):
        pass

    def _respond(self):
        if self.path.endswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", "http://example.com/x")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8") if length else ""
        payload = json.dumps({
            "method": self.command,
            "path": self.path,
            "auth": self.headers.get("Authorization"),
            "ctype": self.headers.get("Content-Type"),
            "body": body,
        }).encode("utf-8")
        self.send_response(404 if self.path.endswith("/missing") else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = lambda self: self._respond()


@pytest.fixture
def httpd():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _EchoHandler)
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_http_open_rejects_invalid_bases(manager):
    for bad in ["ftp://127.0.0.1/", "http://", "http://user:pw@127.0.0.1:1/",
                "http://127.0.0.1:1/?q=1", "http://127.0.0.1:1/#frag",
                "http://127.0.0.1:bad/", "http://127.0.0.1:1/x y", "plain text", 5, None]:
        assert manager.call("http_open", bad) == -1
    # timeout bounds are enforced next to the URL shape
    assert manager.call("http_open", "http://127.0.0.1:1/", 0) == -1
    assert manager.call("http_open", "http://127.0.0.1:1/", 60001) == -1


def test_http_request_roundtrip_status_and_redirects(manager, httpd):
    handle = manager.call("http_open", httpd + "/base/", 2000)
    assert handle >= 0
    out = manager.call("http_request", handle, "get", "echo?x=1", {"Authorization": "Bearer t"}, None)
    assert out["result"] == "OK" and out["status"] == 200
    echo = json.loads(out["body"])
    assert echo["path"] == "/base/echo?x=1" and echo["method"] == "GET" and echo["auth"] == "Bearer t"
    assert out["headers"]["content-type"] == "application/json"
    out = manager.call("http_request", handle, "POST", "/echo", None, '{"a": 1}')
    assert json.loads(out["body"])["body"] == '{"a": 1}'
    # 4xx is a valid response (status carries the code), not a transport error
    out = manager.call("http_request", handle, "GET", "/missing", None, None)
    assert out["result"] == "OK" and out["status"] == 404
    # redirects surface as status, never followed to another host
    out = manager.call("http_request", handle, "GET", "/redirect", None, None)
    assert out["result"] == "OK" and out["status"] == 302


def test_http_request_rejects_escape_attempts(manager, httpd):
    handle = manager.call("http_open", httpd, 2000)
    # absolute or scheme-relative paths would bypass the declared base
    for path in ["http://example.com/", "//example.com/", "https://example.com"]:
        assert manager.call("http_request", handle, "GET", path, None, None)["result"] == "ERR"
    # header injection / unknown method / oversized header sets
    assert manager.call("http_request", handle, "GET", "/x", {"Bad": "a\r\nb"}, None)["result"] == "ERR"
    assert manager.call("http_request", handle, "FLY", "/x", None, None)["result"] == "ERR"
    assert manager.call("http_request", handle, "GET", "/x",
                        {f"H{i}": "v" for i in range(17)}, None)["result"] == "ERR"
    manager.call("close_handle", handle)
    assert manager.call("http_request", handle, "GET", "/x", None, None)["result"] == "ERR"


def test_http_request_transport_failure(manager):
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    handle = manager.call("http_open", f"http://127.0.0.1:{port}/", 500)
    out = manager.call("http_request", handle, "GET", "/", None, None)
    assert out == {"result": "ERR", "message": manager.call("last_error")}


def test_lua_http_globals(manager, monkeypatch, httpd):
    lua = lua_runtime(manager, monkeypatch)
    lua.globals()["base"] = httpd
    lua.execute('''
        local fd = http_open(base .. "/", 2000)
        assert(fd >= 0)
        local out = http_request(fd, "GET", "/echo", {["X-K"] = "v"}, nil)
        assert(out.result == "OK" and out.status == 200)
        assert(http_close(fd) == 0)
        assert(http_open(base, 0) == -1)
        assert(http_open(base, 70000) == -1)
    ''')


def test_shell_open_validates_timeout(manager):
    assert manager.call("shell_open") >= 0
    assert manager.call("shell_open", 1) >= 0
    assert manager.call("shell_open", 60000) >= 0
    assert manager.call("shell_open", 0) == -1
    assert manager.call("shell_open", 60001) == -1
    assert manager.call("shell_open", "slow") == -1


def test_shell_run_captures_streams_and_exit_code(manager):
    handle = manager.call("shell_open", 10000)
    out = manager.call("shell_run", handle, "echo out-words")
    assert out["result"] == "OK" and out["code"] == 0 and not out["truncated"]
    assert "out-words" in out["out"] and out["err"] == ""
    # both cmd.exe and sh accept 1>&2 as the stderr redirect
    out = manager.call("shell_run", handle, "echo err-words 1>&2")
    assert out["result"] == "OK" and "err-words" in out["err"] and out["out"] == ""
    # a finished command is OK whatever its exit code; code carries it
    out = manager.call("shell_run", handle, "exit 3")
    assert out["result"] == "OK" and out["code"] == 3


def test_shell_run_timeout_kills_and_reports_partial_output(manager):
    handle = manager.call("shell_open", 400)
    # the explicit flush matters: a piped stdout is block-buffered, so without
    # it the line would still sit in the child's buffer when the kill arrives
    command = (f'"{sys.executable}" -c "import sys; print(\'partial-out\'); '
               'sys.stdout.flush(); import time; time.sleep(30)"')
    started = time.monotonic()
    out = manager.call("shell_run", handle, command)
    assert time.monotonic() - started < 10
    assert out["result"] == "ERR" and "timed out" in out["message"]
    assert "partial-out" in out["out"]


def test_shell_run_caps_output_streams(manager):
    handle = manager.call("shell_open", 20000)
    size = HALManager.SHELL_MAX_OUT_BYTES + 4096
    command = f'"{sys.executable}" -c "print(\'x\' * {size})"'
    out = manager.call("shell_run", handle, command)
    assert out["result"] == "OK" and out["truncated"] is True
    assert len(out["out"].encode("utf-8")) <= HALManager.SHELL_MAX_OUT_BYTES
    out = manager.call("shell_run", handle, "echo small")
    assert out["result"] == "OK" and out["truncated"] is False


def test_shell_run_rejects_bad_commands_and_handles(manager):
    handle = manager.call("shell_open", 1000)
    for bad in ("", None, 5, "echo\0hi", "x" * (HALManager.SHELL_MAX_CMD_BYTES + 1)):
        assert manager.call("shell_run", handle, bad)["result"] == "ERR"
    for timeout in (0, 60001, "slow"):
        assert manager.call("shell_run", handle, "echo hi", timeout)["result"] == "ERR"
    assert manager.call("shell_run", 987654321, "echo hi")["result"] == "ERR"


def test_shell_close_invalidates_the_session(manager):
    handle = manager.call("shell_open", 1000)
    assert manager.call("shell_run", handle, "echo hi")["result"] == "OK"
    assert manager.call("close_handle", handle) == 0
    assert manager.call("shell_run", handle, "echo hi")["result"] == "ERR"


def test_lua_shell_globals(manager, monkeypatch):
    lua = lua_runtime(manager, monkeypatch)
    lua.execute('''
        local fd = shell_open(5000)
        assert(fd >= 0)
        local out = shell_run(fd, "echo lua-shell")
        assert(out.result == "OK" and out.code == 0)
        assert(string.find(out.out, "lua-shell", 1, true) ~= nil)
        assert(shell_close(fd) == 0)
        assert(shell_open(0) == -1)
        assert(shell_open(70000) == -1)
    ''')
