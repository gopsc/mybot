"""Agent camera tools use a host backend; the controller no longer knows cameras."""
from __future__ import annotations

import asyncio
import io
import sys
import threading
import time
from types import SimpleNamespace

import pytest

from pymybot.camera import CameraError, CameraService

DSHOW_DEVICES = (
    '"Integrated Webcam_FHD" (video)\n'
    '  Alternative name "@device_pnp_\\\\?\\usb#vid_3277&pid_0004#cam0\\global"\n'
    '"Microphone (Intel\u00ae Smart Sound)" (audio)\n'
    '  Alternative name "@device_cm_{33D9A762}\\wave_{29D8FB9C}"\n'
    '"USB Camera" (video)\n'
    '  Alternative name "@device_pnp_\\\\?\\usb#vid_0c45&pid_6366#cam1\\global"\n'
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
            from PIL import Image as PillowImage
            buffer = io.BytesIO()
            PillowImage.new("RGB", (2, 1)).save(buffer, "JPEG", quality=quality)
            stream.write(buffer.getvalue())

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
                    time.sleep(.002)
                    yield Packet(True)

        def close(self):
            self.closed += 1

    def open_(file, format=None, options=None, timeout=None):
        options = options or {}
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


def test_list_cameras_parses_dshow_video_devices(av_fake, monkeypatch):
    monkeypatch.setattr(sys, "platform", "win32")
    data = CameraService().list_cameras()
    assert [item["name"] for item in data["cameras"]] == [
        "@device_pnp_\\\\?\\usb#vid_3277&pid_0004#cam0\\global",
        "@device_pnp_\\\\?\\usb#vid_0c45&pid_6366#cam1\\global",
    ]
    assert data["cameras"][0]["backend"] == "dshow" and not data["truncated"]


def test_capture_reuses_device_and_reconfigures(av_fake, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    service = CameraService()
    try:
        shot = service.capture(0, 320, 240, 80)
        assert shot["media_type"] == "image/jpeg" and shot["format"] == "jpeg"
        assert (shot["width"], shot["height"]) == (2, 1)
        assert shot["data"].startswith(b"\xff\xd8")
        container = av_fake.containers[0]
        assert container.file == "/dev/video0" and container.format == "v4l2"
        assert container.options["video_size"] == "320x240"
        container.backlog = 50
        service.capture(0, 320, 240, 80)
        assert len(av_fake.containers) == 1 and container.backlog == 0
        service.capture(1, 640, 480, 80)
        assert len(av_fake.containers) == 2 and container.closed == 1
        assert av_fake.containers[1].file == "/dev/video1"
    finally:
        service.close()
    assert av_fake.containers[-1].closed == 1


def test_camera_failures_are_safe_and_release(av_fake, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    service = CameraService()
    try:
        av_fake.open_fail = True
        with pytest.raises(CameraError, match="unavailable"):
            service.capture(0)
        av_fake.open_fail = False
        service.capture(0)
        av_fake.containers[-1].read_ok = False
        with pytest.raises(CameraError, match="stream ended"):
            service.capture(0)
        av_fake.encode_fail = True
        with pytest.raises(OSError, match="encoder failed"):
            service.capture(0)
        with pytest.raises(CameraError, match="1..8192"):
            service.capture(0, 0, 480)
    finally:
        service.close()


def test_camera_ids_are_platform_specific(av_fake, monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    service = CameraService()
    try:
        with pytest.raises(CameraError, match="/dev/videoN"):
            service.capture("0:none")
        monkeypatch.setattr(sys, "platform", "darwin")
        service.capture("1:none", 320, 240)
        assert av_fake.containers[-1].file == "1:none"
    finally:
        service.close()


def test_missing_backend_reports_the_optional_extra(monkeypatch):
    monkeypatch.setitem(sys.modules, "av", None)
    with pytest.raises(CameraError, match="pymybot\\[camera\\]"):
        CameraService().capture(0)


def test_agent_camera_tools_run_without_a_robot(av_fake, monkeypatch):
    pytest.importorskip("langchain")
    from agent_fakes import TestModel

    from pymybot.agent import AgentSession

    monkeypatch.setattr(sys, "platform", "linux")

    class Executor:
        stop_event = threading.Event()

        async def start(self, *, deadline=None):
            return {"ok": True}

        async def call(self, name, arguments, *, timeout):
            raise AssertionError("camera tools must not reach the robot executor")

        def cancel(self):
            self.stop_event.set()

        async def close(self):
            return None

    async def scenario():
        session = AgentSession(Executor(), TestModel())
        try:
            names = {tool.name for tool in session.tools}
            assert {"list_cameras", "capture_camera"} <= names
            listing = await session.dispatch("list_cameras", {})
            assert listing["ok"] and listing["executed"] is False
            assert isinstance(listing["data"]["cameras"], list)
            shot = await session.dispatch("capture_camera", {
                "device": "0", "width": 320, "height": 240})
            assert shot["ok"] and shot["executed"]
            assert shot["image"]["media_type"] == "image/jpeg"
            assert shot["image"]["data"].startswith(b"\xff\xd8")
            assert "b64" not in shot["data"] and "base64" not in shot["data"]
            tool = next(item for item in session.tools if item.name == "capture_camera")
            content = await tool.ainvoke({"device": "0", "width": 320, "height": 240})
            assert content[0]["type"] == "text" and content[1]["type"] == "image"
            assert content[1]["mime_type"] == "image/jpeg"
            return listing, shot
        finally:
            await session.close()

    _listing, shot = asyncio.run(scenario())
    assert shot["data"]["width"] == 2
