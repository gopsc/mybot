"""Host camera service behind the Agent's built-in list/capture tools.

The controller no longer declares cameras or ships a Camera driver. This module
talks to the host directly: enumerate devices, open one with PyAV (optional
``pymybot[camera]``), take the newest frame and encode a bounded JPEG with
Pillow. Device failures are reported as safe CameraError messages.
"""
from __future__ import annotations

import importlib
import io
from pathlib import Path
import re
import sys
import threading
import time

from .images import size, validate_image

TIMEOUT = 10.0
FORMATS = {"win32": "dshow", "linux": "v4l2", "darwin": "avfoundation"}
MAX_DEVICES = 64
MAX_CAPTURE_BYTES = 4 * 1024 * 1024
_AV_LOG_LOCK = threading.Lock()
_DSHOW_VIDEO_GUID = "65e8773d-8f56-11d0-a3b9-00a0c9223196"


class CameraError(ValueError):
    """A camera operation failed; the message is safe to show to the model."""


def _av():
    try:
        return importlib.import_module("av")
    except ImportError:
        raise CameraError("Camera support requires the optional extra: pip install pymybot[camera]") from None


def _integer(value, low, high, name):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise CameraError(f"{name} must be an integer in {low}..{high}")
    return value


class CameraService:
    """One lazily opened host camera; all methods are thread-safe."""

    def __init__(self):
        self._lock = threading.RLock()
        self._container = None
        self._state = None

    # -- enumeration -------------------------------------------------------
    def list_cameras(self):
        platform = sys.platform
        if platform == "win32":
            devices = [{"index": index, "id": name, "name": name, "backend": "dshow"}
                       for index, name in enumerate(self._dshow_devices())]
        elif platform == "linux":
            devices = self._v4l2_devices()
        elif platform == "darwin":
            devices = self._avfoundation_devices()
        else:
            raise CameraError(f"Camera capture is not supported on {platform}")
        return {"cameras": devices[:MAX_DEVICES], "truncated": len(devices) > MAX_DEVICES}

    @staticmethod
    def _v4l2_devices():
        devices = []
        paths = []
        for path in Path("/dev").glob("video*"):
            match = re.fullmatch(r"video([0-9]+)", path.name)
            if match:
                paths.append((int(match.group(1)), path))
        for index, path in sorted(paths):
            name = path.name
            try:
                name = (Path("/sys/class/video4linux") / path.name / "name").read_text(
                    encoding="utf-8", errors="replace").strip() or name
            except OSError:
                pass
            devices.append({"index": index, "id": str(path), "name": name, "backend": "v4l2"})
        return devices

    @staticmethod
    def _avfoundation_devices():
        av = _av()
        logging = importlib.import_module("av.logging")
        text = _capture_log(logging, lambda: av.open(
            "none", format="avfoundation", options={"list_devices": "true"}))
        devices, video = [], False
        for line in text.splitlines():
            lowered = line.lower()
            if "video devices:" in lowered:
                video = True
                continue
            if "audio devices:" in lowered:
                video = False
                continue
            match = re.search(r"\[(\d+)\]\s+(.+?)\s*$", line)
            if video and match:
                devices.append({"index": int(match.group(1)), "id": f"{match.group(1)}:none",
                                "name": match.group(2), "backend": "avfoundation"})
        return devices

    @staticmethod
    def _dshow_devices():
        av = _av()
        logging = importlib.import_module("av.logging")
        text = _capture_log(logging, lambda: av.open(
            "dummy", format="dshow", options={"list_devices": "true"}))
        return [name for kind, name in re.findall(
            r'^"[^"\n]*" \(([^)\n]*)\)\s*\n\s*Alternative name "([^"\n]+)"', text, re.M)
            if "video" in kind.lower() or _DSHOW_VIDEO_GUID in name.lower()]

    # -- capture -----------------------------------------------------------
    @staticmethod
    def _device(device):
        if device is None or device == "" or device == []:
            return 0
        if isinstance(device, bool):
            raise CameraError("device must be an index or device id")
        if isinstance(device, str) and device.isdigit():
            return int(device)
        if isinstance(device, int):
            return _integer(device, 0, 255, "device")
        if isinstance(device, str):
            return device
        raise CameraError("device must be an index or device id")

    def _input(self, device):
        fmt = FORMATS.get(sys.platform)
        if fmt is None:
            raise CameraError(f"Camera capture is not supported on {sys.platform}")
        if isinstance(device, int):
            if fmt == "v4l2":
                return f"/dev/video{device}", fmt
            if fmt == "avfoundation":
                return f"{device}:none", fmt
            names = self._dshow_devices()
            if device >= len(names):
                raise CameraError(f"Camera {device} is unavailable ({len(names)} found)")
            return "video=" + names[device], fmt
        if fmt == "dshow":
            return (device if device.startswith("video=") else "video=" + device), fmt
        if fmt == "v4l2":
            if not re.fullmatch(r"/dev/video[0-9]+", device):
                raise CameraError("Linux camera ids must look like /dev/videoN")
            return device, fmt
        if ":" not in device:
            raise CameraError("macOS camera ids must look like N:none")
        return device, fmt

    @staticmethod
    def _latest_frame(container):
        """Decode the newest frame, discarding the backlog queued while idle."""
        stream = container.streams.video[0]
        rate = stream.average_rate or stream.guessed_rate
        live_wait = 0.5 / float(rate) if rate else 0.005
        deadline = time.monotonic() + TIMEOUT
        packets = container.demux(stream)
        pending = []
        while True:
            started = time.monotonic()
            packet = next(packets, None)
            if packet is None or packet.size == 0:
                raise CameraError("Camera stream ended")
            if packet.is_keyframe:
                pending.clear()
            pending.append(packet)
            if time.monotonic() - started >= live_wait or started >= deadline:
                break
        frames = [frame for packet in pending for frame in packet.decode()]
        if not frames:
            raise CameraError("Camera capture failed")
        return frames[-1]

    def capture(self, device=0, width=640, height=480, quality=90):
        try:
            width, height = size(width, height)
        except ValueError as exc:
            raise CameraError(str(exc)) from None
        quality = _integer(quality, 1, 100, "quality")
        device = self._device(device)
        av = _av()
        desired = {"device": device, "width": width, "height": height}
        with self._lock:
            try:
                if self._container is not None and self._state != desired:
                    self._container.close()
                    self._container = None
                if self._container is None:
                    file, fmt = self._input(device)
                    options = {"video_size": f"{width}x{height}"}
                    if fmt == "avfoundation":
                        options["framerate"] = "30"
                    try:
                        self._container = av.open(file, format=fmt, options=options, timeout=TIMEOUT)
                    except av.FFmpegError as exc:
                        raise CameraError(f"Camera unavailable: {device} ({exc})") from None
                    self._state = desired
                frame = self._latest_frame(self._container)
                frame_size = size(frame.width, frame.height)
                encoded = io.BytesIO()
                frame.to_image().save(encoded, "JPEG", quality=quality)
                data = encoded.getvalue()
                if len(data) > MAX_CAPTURE_BYTES:
                    raise CameraError("camera image exceeds the capture byte limit")
                validate_image(data)
                return {"data": data, "media_type": "image/jpeg", "format": "jpeg",
                        "width": frame_size[0], "height": frame_size[1], "bytes": len(data),
                        "device": device, "backend": "pyav"}
            except BaseException:
                self.close()
                raise

    def close(self):
        with self._lock:
            if self._container is not None:
                try:
                    self._container.close()
                finally:
                    self._container = None
                    self._state = None


def _capture_log(logging, action):
    with _AV_LOG_LOCK:
        level = logging.get_level()
        logging.set_level(logging.INFO)
        try:
            with logging.Capture(local=False) as logs:
                try:
                    action().close()
                except Exception:
                    pass  # list_devices prints the list and then fails to open
        finally:
            logging.set_level(level)
    return "".join(message for _, _, message in logs)
