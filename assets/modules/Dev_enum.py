"""Cross-platform I2C / SPI / UART device enumeration driver.

Queries the operating system for available bus adapters and device nodes.
Passive by default — no bus transactions, no port opening.  Useful as a
diagnostic first step before writing structure SQL.

SQL example::

    CREATE TABLE Dev_enum (name String);
    INSERT INTO Dev_enum (name) VALUES ('enum0');

MT example::

    @Action
    enum0.go;
       1  ;
    @

Optional action parameter ``buses`` selects which buses to enumerate
(comma-separated, default ``all``).  Accepted tokens: ``i2c``, ``spi``,
``uart``, ``all``.
"""

from __future__ import annotations

import glob
import os
import re
import sys


_IS_LINUX = sys.platform.startswith("linux")
_IS_MACOS = sys.platform == "darwin"
_IS_WINDOWS = sys.platform.startswith("win")

_LINUX_TTY_PATTERNS = (
    "/dev/ttyS*",
    "/dev/ttyUSB*",
    "/dev/ttyACM*",
    "/dev/ttyAMA*",
    "/dev/ttyCH*",
    "/dev/ttyXR*",
    "/dev/ttySC*",
    "/dev/ttyGS*",
    "/dev/rfcomm*",
)

_MACOS_TTY_PATTERNS = (
    "/dev/cu.*",
    "/dev/tty.*",
)

_LINUX_SERIAL_PREFIXES = (
    "ttyS", "ttyUSB", "ttyACM", "ttyAMA",
    "ttyCH", "ttyXR", "ttySC", "ttyGS", "rfcomm",
)


def _read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return None


def _natural_key(value):
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", value)]


def _parse_buses(raw):
    if raw is None:
        return ("i2c", "spi", "uart")
    if isinstance(raw, str):
        tokens = {t.strip().lower() for t in raw.split(",") if t.strip()}
    else:
        return ("i2c", "spi", "uart")
    if "all" in tokens:
        return ("i2c", "spi", "uart")
    valid = {"i2c", "spi", "uart"}
    return tuple(t for t in ("i2c", "spi", "uart") if t in tokens and t in valid)


# ---- I2C ------------------------------------------------------------------ #

def _enumerate_i2c():
    result = {"supported": False, "adapters": [], "clients": [], "notes": []}
    if not _IS_LINUX:
        if _IS_MACOS:
            result["notes"].append(
                "macOS has no generic i2c-dev; use a USB bridge (FTDI/CH34x)")
        elif _IS_WINDOWS:
            result["notes"].append(
                "Windows has no generic I2C namespace; use a vendor SDK")
        else:
            result["notes"].append("unsupported platform: " + sys.platform)
        return result

    result["supported"] = True
    seen = set()
    for path in sorted(glob.glob("/dev/i2c-*"), key=_natural_key):
        record = {
            "device": path,
            "node_present": True,
            "readable": os.access(path, os.R_OK),
            "writable": os.access(path, os.W_OK),
        }
        suffix = path.rsplit("-", 1)[-1]
        if suffix.isdigit():
            seen.add(int(suffix))
            record["bus"] = int(suffix)
            name = _read_text("/sys/class/i2c-dev/i2c-%s/name" % suffix)
            if name:
                record["adapter_name"] = name
        result["adapters"].append(record)

    hidden = 0
    for entry in sorted(glob.glob("/sys/class/i2c-dev/i2c-*"), key=_natural_key):
        suffix = os.path.basename(entry).rsplit("-", 1)[-1]
        if not suffix.isdigit():
            continue
        bus = int(suffix)
        if bus in seen:
            continue
        record = {
            "device": "/dev/i2c-%d" % bus,
            "bus": bus,
            "node_present": False,
            "source": "sysfs",
            "readable": None,
            "writable": None,
        }
        name = _read_text(os.path.join(entry, "name"))
        if name:
            record["adapter_name"] = name
        result["adapters"].append(record)
        hidden += 1

    result["adapters"].sort(key=lambda r: (r.get("bus", -1), r["device"]))
    if hidden:
        result["node_visibility"] = "masked"
        result["notes"].append(
            "%d adapter(s) in sysfs but /dev node not visible" % hidden)

    for entry in sorted(glob.glob("/sys/bus/i2c/devices/*-*"), key=_natural_key):
        base = os.path.basename(entry)
        match = re.match(r"^(\d+)-([0-9a-fA-F]{4})$", base)
        if not match:
            continue
        driver_link = os.path.join(entry, "driver")
        result["clients"].append({
            "bus": int(match.group(1)),
            "address": "0x%02X" % int(match.group(2), 16),
            "name": _read_text(os.path.join(entry, "name")) or None,
            "driver": (os.path.basename(os.path.realpath(driver_link))
                       if os.path.islink(driver_link) else None),
        })

    if not result["adapters"]:
        result["notes"].append(
            "no /dev/i2c-* node: load i2c-dev or enable the bus in the device tree")
    return result


# ---- SPI ------------------------------------------------------------------ #

def _enumerate_spi():
    result = {"supported": False, "controllers": [], "devices": [], "notes": []}
    if not _IS_LINUX:
        if _IS_MACOS:
            result["notes"].append(
                "macOS has no spidev; use a USB-SPI bridge (FTDI/CH347)")
        elif _IS_WINDOWS:
            result["notes"].append(
                "Windows has no spidev; use a vendor SDK")
        else:
            result["notes"].append("unsupported platform: " + sys.platform)
        return result

    result["supported"] = True
    for path in sorted(glob.glob("/sys/class/spi_master/spi*"), key=_natural_key):
        controller = {"name": os.path.basename(path)}
        driver = os.path.join(path, "device", "driver")
        if os.path.islink(driver):
            controller["driver"] = os.path.basename(os.path.realpath(driver))
        result["controllers"].append(controller)

    if any(c.get("driver") == "intel-spi" for c in result["controllers"]):
        result["notes"].append(
            "intel-spi is the PCH firmware flash controller, not a general-purpose bus")

    for path in sorted(glob.glob("/dev/spidev*"), key=_natural_key):
        record = {
            "device": path,
            "readable": os.access(path, os.R_OK),
            "writable": os.access(path, os.W_OK),
        }
        match = re.match(r"spidev(\d+)\.(\d+)$", os.path.basename(path))
        if match:
            record["bus"] = int(match.group(1))
            record["chip_select"] = int(match.group(2))
        sysfs = os.path.join("/sys/class/spidev", os.path.basename(path))
        modalias = _read_text(os.path.join(sysfs, "device", "modalias"))
        if modalias:
            record["modalias"] = modalias
        result["devices"].append(record)

    general = [c for c in result["controllers"] if c.get("driver") != "intel-spi"]
    if not result["devices"] and general:
        result["notes"].append(
            "no /dev/spidev*: enable CONFIG_SPI_SPIDEV or add a device tree overlay")
    return result


# ---- UART ----------------------------------------------------------------- #

def _enumerate_uart():
    result = {"supported": True, "backend": None, "ports": [], "notes": []}
    try:
        from serial.tools import list_ports
    except Exception:
        list_ports = None

    if list_ports is not None:
        result["backend"] = "pyserial"
        for port in sorted(list_ports.comports(),
                           key=lambda p: _natural_key(p.device)):
            result["ports"].append({
                "device": port.device,
                "description": port.description,
                "hwid": port.hwid,
                "vid": "0x%04X" % port.vid if port.vid is not None else None,
                "pid": "0x%04X" % port.pid if port.pid is not None else None,
                "serial_number": port.serial_number,
                "manufacturer": port.manufacturer,
                "product": port.product,
            })
    else:
        result["backend"] = "os"
        patterns = _LINUX_TTY_PATTERNS if _IS_LINUX else _MACOS_TTY_PATTERNS if _IS_MACOS else ()
        seen = set()
        for pattern in patterns:
            for path in sorted(glob.glob(pattern), key=_natural_key):
                if path in seen:
                    continue
                seen.add(path)
                result["ports"].append({"device": path})
        if _IS_WINDOWS:
            result["notes"].append(
                "pyserial not installed; cannot enumerate COM ports on Windows")
        elif list_ports is None:
            result["notes"].append(
                "pyserial not installed; VID/PID and product names unavailable")

    if _IS_LINUX:
        known = {p["device"] for p in result["ports"]}
        for entry in sorted(glob.glob("/sys/class/tty/*"), key=_natural_key):
            name = os.path.basename(entry)
            if not name.startswith(_LINUX_SERIAL_PREFIXES):
                continue
            device = "/dev/" + name
            if device in known:
                continue
            type_text = _read_text(os.path.join(entry, "type"))
            try:
                uart_type = int(type_text)
            except (TypeError, ValueError):
                uart_type = None
            record = {"device": device, "source": "sysfs", "node_present": False}
            if uart_type is not None:
                record["uart_type"] = uart_type
            result["ports"].append(record)
        result["ports"].sort(key=lambda p: _natural_key(p["device"]))

        for pattern in ("/dev/serial/by-id/*", "/dev/serial/by-path/*"):
            for path in sorted(glob.glob(pattern)):
                target = os.path.realpath(path)
                for port in result["ports"]:
                    if port["device"] == target:
                        port.setdefault("stable_links", []).append(path)

    return result


# ---- Driver --------------------------------------------------------------- #

class Driver:
    def __init__(self, context):
        self.context = context

    def build(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}

        buses = _parse_buses(data.get("buses"))
        result = {
            "result": "OK",
            "platform": ("linux" if _IS_LINUX
                         else "macos" if _IS_MACOS
                         else "windows" if _IS_WINDOWS
                         else sys.platform),
            "buses": list(buses),
        }

        if "i2c" in buses:
            result["i2c"] = _enumerate_i2c()
        if "spi" in buses:
            result["spi"] = _enumerate_spi()
        if "uart" in buses:
            result["uart"] = _enumerate_uart()

        return result

    def destroy(self, data):
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}
