#!/usr/bin/env python3
"""Read-only I2C adapter discovery and address probing.

Standard library only (Python 3.8+). Linux performs real probing through
i2c-dev ioctls; macOS and Windows have no i2c-dev interface, so they report
that honestly and only list USB-I2C bridge candidates.

Exit codes: 0 ok, 1 a requested action failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import errno
import glob
import json
import os
import re
import struct
import subprocess
import sys

IS_LINUX = sys.platform.startswith("linux")
IS_MACOS = sys.platform == "darwin"
IS_WINDOWS = sys.platform.startswith("win")

EREMOTEIO = getattr(errno, "EREMOTEIO", 121)
NAK_ERRNOS = (errno.ENXIO, EREMOTEIO)

# Linux i2c-dev ioctls. On 64-bit: struct i2c_msg is 16 bytes (2+2+2+2 pad+8)
# and struct i2c_rdwr_ioctl_data is 16 bytes (8-byte pointer + 4 + 4 pad).
I2C_SLAVE = 0x0703
I2C_RDWR = 0x0707
I2C_MSG_FORMAT = "HHHxxP"
I2C_RDWR_FORMAT = "PI4x" if struct.calcsize("P") == 8 else "PI"

DEFAULT_RANGE = "0x08-0x77"

RESERVED_7BIT = {
    "0x00": "general call / broadcast",
    "0x01": "CBUS / reserved",
    "0x02": "reserved (other bus format)",
    "0x03": "reserved (other bus format)",
    "0x04": "HS-mode master code",
    "0x05": "HS-mode master code",
    "0x06": "HS-mode master code",
    "0x07": "HS-mode master code",
    "0x78": "10-bit addressing prefix",
    "0x79": "10-bit addressing prefix",
    "0x7A": "10-bit addressing prefix",
    "0x7B": "10-bit addressing prefix",
    "0x7C": "reserved",
    "0x7D": "reserved",
    "0x7E": "reserved",
    "0x7F": "reserved",
}

# Guesses only: an ACK proves *something* answers, never a model. Always
# report these as speculation with the evidence you actually have.
COMMON_HINTS = {
    "0x0A": "SSD1306 OLED (SA0 high)", "0x3C": "SSD1306/SH1106 OLED, or PCF8574-class expander",
    "0x3D": "SSD1306 OLED (SA0 high)", "0x20": "PCF8574/PCF8575 GPIO expander",
    "0x21": "PCF8574/PCF8575 GPIO expander", "0x27": "PCF8574 LCD backpack",
    "0x3F": "PCF8574 LCD backpack", "0x28": "BMP280/BME280 (SDO low), or BNO055",
    "0x29": "TSL2561/TSL2591, VL53L0X, or TCS34725", "0x1E": "HMC5883L/LSM303 magnetometer",
    "0x40": "INA219/INA260, SHT3x, HTU21D, PCA9685", "0x41": "INA219 or PCA9685 (A0 high)",
    "0x44": "SHT31/SHT35, ISL29125", "0x48": "ADS1115/ADS1015 (ADDR=GND), LM75, PCF8591",
    "0x49": "ADS1115 (ADDR=VDD), LM75, PCF8591", "0x4A": "ADS1115 (ADDR=SDA)",
    "0x4B": "ADS1115 (ADDR=SCL)", "0x50": "24Cxx EEPROM", "0x51": "24Cxx EEPROM or PCF8563 RTC",
    "0x52": "24Cxx EEPROM or MPR121", "0x53": "ADXL345 accelerometer",
    "0x57": "24Cxx EEPROM or MAX30100", "0x5A": "MPR121, MLX90614, CCS811",
    "0x5C": "APDS9960, AM2320, BH1750", "0x68": "DS1307/DS3231 RTC, MPU6050, ITG3205",
    "0x69": "MPU6050 (AD0 high), SCD30", "0x6A": "LSM6DSx, or ICM-20948 (AD0 high)",
    "0x6B": "LSM6DSx (SDx high)", "0x70": "TCA9548A mux or HT16K33 display",
    "0x71": "TCA9548A mux (A0 high)", "0x76": "BME280/BMP280 (SDO high), BME680",
    "0x77": "BME280 (SDO high) or BMP180",
}

BRIDGE_VIDS = {
    "0403": "FTDI (FT232/FT2232: D2XX + libmpsse can drive I2C)",
    "04b4": "Cypress (USB-Serial / FX2 based bridges may expose I2C)",
    "04d8": "Microchip (MCP2221A exposes I2C over USB HID)",
    "10c4": "Silicon Labs CP210x (USB-UART only, no I2C)",
    "1a86": "WCH CH340/CH341 (CH341A can bit-bang I2C via vendor driver)",
    "1bda": "FTDI-based bridge variant",
    "2341": "Arduino (USB-UART bridge on classic boards)",
    "239a": "Adafruit (USB-UART or native USB)",
    "2e8a": "Raspberry Pi (Pico USB CDC)",
}


class ProbeError(Exception):
    """A requested probe could not be performed on this device."""


class TransferUnsupported(Exception):
    """The adapter rejected a zero-length transfer; fall back to a 1-byte read."""


def _read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def parse_addresses(spec):
    """Parse '0x48,0x68-0x69' or '8-119' into a sorted list of ints."""
    addresses = set()
    for token in str(spec).split(","):
        token = token.strip()
        if not token:
            continue
        if "-" in token[1:]:
            low, _, high = token.partition("-")
            start = int(low, 0)
            end = int(high, 0)
            if start > end:
                start, end = end, start
            addresses.update(range(start, end + 1))
        else:
            addresses.add(int(token, 0))
    invalid = [value for value in addresses if not 0 <= value <= 0x7F]
    if invalid:
        raise ValueError(
            "address out of 7-bit range: %s" % ", ".join("0x%02X" % value for value in invalid)
        )
    if not addresses:
        raise ValueError("no addresses parsed from %r" % spec)
    return sorted(addresses)


def linux_adapters(warnings):
    """Adapters from /dev plus sysfs, so containers with a masked /dev still list them."""
    nodes = {}
    for path in sorted(glob.glob("/dev/i2c-*")):
        try:
            nodes[int(os.path.basename(path).split("-", 1)[1])] = path
        except (IndexError, ValueError):
            continue
    sysfs = {}
    for entry in sorted(glob.glob("/sys/bus/i2c/devices/i2c-*")):
        try:
            bus = int(os.path.basename(entry).split("-", 1)[1])
        except (IndexError, ValueError):
            continue
        label = (_read_text(os.path.join(entry, "name")) or "").strip()
        sysfs[bus] = label or None

    adapters = []
    for bus in sorted(set(nodes) | set(sysfs)):
        device = nodes.get(bus, "/dev/i2c-%d" % bus)
        present = bus in nodes
        adapter = {
            "device": device,
            "bus": bus,
            "adapter_name": sysfs.get(bus),
            "node_present": present,
            "source": "devfs" if present else "sysfs",
            "readable": os.access(device, os.R_OK) if present else None,
            "writable": os.access(device, os.W_OK) if present else None,
        }
        if not present:
            adapter["node_visibility"] = "masked"
            warnings.append(
                "%s: kernel exposes i2c-%d but this process cannot see the node; "
                "run the probe on the host" % (device, bus)
            )
        adapters.append(adapter)
    if not adapters:
        warnings.append("no /dev/i2c-* node and no i2c-* sysfs entry found")
    return adapters


def linux_clients():
    """Addresses already claimed by a kernel driver; these answer EBUSY when probed."""
    clients = []
    for entry in sorted(glob.glob("/sys/bus/i2c/devices/*-*")):
        base = os.path.basename(entry)
        match = re.match(r"^(\d+)-([0-9a-fA-F]{4})$", base)
        if not match:
            continue
        driver_link = os.path.join(entry, "driver")
        clients.append(
            {
                "bus": int(match.group(1)),
                "address": "0x%02X" % int(match.group(2), 16),
                "name": (_read_text(os.path.join(entry, "name")) or "").strip() or None,
                "driver": os.path.basename(os.path.realpath(driver_link))
                if os.path.islink(driver_link)
                else None,
                "state": None if os.path.islink(driver_link) else "no driver bound",
            }
        )
    return clients


def _bridge_entry(vid, pid, name, source):
    vid = (vid or "").strip().lower()
    pid = (pid or "").strip().lower()
    return {
        "vendor_id": "0x%s" % vid if vid else None,
        "product_id": "0x%s" % pid if pid else None,
        "name": name or None,
        "possible_i2c": BRIDGE_VIDS.get(vid),
        "source": source,
    }


def _run(command, timeout=8):
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.decode("utf-8", "replace")


def macos_bridges(warnings):
    output = _run(["ioreg", "-p", "IOUSB", "-l", "-w", "0"])
    if output is None:
        warnings.append("ioreg unavailable; cannot list USB-I2C bridge candidates")
        return []
    bridges = []
    for block in output.split("+-o ")[1:]:
        vid = re.search(r'"idVendor"\s*=\s*(\d+)', block)
        pid = re.search(r'"idProduct"\s*=\s*(\d+)', block)
        name = re.search(r'"USB Product Name"\s*=\s*"([^"]*)"', block)
        if not vid:
            continue
        bridges.append(
            _bridge_entry("%04x" % int(vid.group(1)), "%04x" % int(pid.group(1)) if pid else None,
                          name.group(1) if name else None, "ioreg")
        )
    return bridges


def windows_bridges(warnings):
    output = _run(
        [
            "powershell", "-NoProfile", "-NonInteractive", "-Command",
            "Get-PnpDevice -PresentOnly | ForEach-Object { \"$($_.FriendlyName)|$($_.InstanceId)\" }",
        ],
        timeout=20,
    )
    if output is None:
        warnings.append("PowerShell Get-PnpDevice unavailable; cannot list USB-I2C bridge candidates")
        return []
    bridges = []
    for line in output.splitlines():
        match = re.search(r"VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})", line)
        if not match:
            continue
        name = line.split("|", 1)[0].strip()
        bridges.append(_bridge_entry(match.group(1), match.group(2), name, "Get-PnpDevice"))
    return bridges


def linux_bridges(warnings):
    output = _run(["lsusb"])
    if output is None:
        warnings.append("lsusb unavailable; cannot list USB-I2C bridge candidates")
        return []
    bridges = []
    for line in output.splitlines():
        match = re.search(r"ID ([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s*(.*)$", line)
        if match:
            bridges.append(_bridge_entry(match.group(1), match.group(2), match.group(3), "lsusb"))
    return bridges


def _quick_write(fd, address):
    """Select the slave and issue a zero-length write: presence check with no data on the bus."""
    import ctypes
    import fcntl

    message = ctypes.create_string_buffer(
        struct.pack(I2C_MSG_FORMAT, address, 0, 0, 0), struct.calcsize(I2C_MSG_FORMAT)
    )
    request = bytearray(struct.pack(I2C_RDWR_FORMAT, ctypes.addressof(message), 1))
    try:
        fcntl.ioctl(fd, I2C_RDWR, request, True)
    except OSError as exc:
        if exc.errno in (errno.ENOTTY, getattr(errno, "EOPNOTSUPP", 95), errno.EINVAL):
            raise TransferUnsupported(exc.strerror or "ioctl rejected") from exc
        raise


def _classify(exc):
    if exc.errno in NAK_ERRNOS:
        return "nak"
    if exc.errno == errno.EBUSY:
        return "busy"
    if exc.errno in (errno.EACCES, errno.EPERM):
        return "error: permission denied"
    return "error: %s" % (getattr(exc, "strerror", None) or exc)


def _probe_read(fd, addresses):
    """Fallback: select the slave and read one byte. Some devices dislike this."""
    import fcntl

    outcome = {}
    for address in addresses:
        try:
            fcntl.ioctl(fd, I2C_SLAVE, address)
        except OSError as exc:
            outcome["0x%02X" % address] = _classify(exc)
            continue
        try:
            os.read(fd, 1)
            outcome["0x%02X" % address] = "ack"
        except OSError as exc:
            outcome["0x%02X" % address] = _classify(exc)
    return outcome


def probe_device(device, addresses, warnings):
    try:
        fd = os.open(device, os.O_RDWR)
    except OSError as exc:
        raise ProbeError(
            "cannot open %s: %s" % (device, getattr(exc, "strerror", None) or exc)
        ) from exc
    outcome = {}
    try:
        unsupported = False
        for address in addresses:
            try:
                _quick_write(fd, address)
                outcome["0x%02X" % address] = "ack"
            except TransferUnsupported as exc:
                unsupported = True
                warnings.append(
                    "%s: zero-length transfer unsupported (%s); falling back to a 1-byte "
                    "read, which can have side effects on some devices" % (device, exc)
                )
                break
            except OSError as exc:
                outcome["0x%02X" % address] = _classify(exc)
        if unsupported:
            outcome = _probe_read(fd, addresses)
    finally:
        os.close(fd)
    return outcome


def build_probe(devices, addresses, warnings):
    probes = []
    for device in devices:
        try:
            outcome = probe_device(device, addresses, warnings)
        except ProbeError as exc:
            warnings.append(str(exc))
            probes.append({"device": device, "error": str(exc), "ok": False})
            continue
        found = sorted(key for key, value in outcome.items() if value == "ack")
        probes.append(
            {
                "device": device,
                "ok": True,
                "addresses_scanned": len(addresses),
                "found": found,
                "detail": {key: value for key, value in outcome.items() if value != "nak"},
                "hints": {
                    key: {"guess": COMMON_HINTS[key], "confidence": "speculation"}
                    for key in found
                    if key in COMMON_HINTS
                },
                "reserved": {key: RESERVED_7BIT[key] for key in found if key in RESERVED_7BIT},
            }
        )
    return probes


def render_text(result):
    lines = ["platform: %s  python: %s" % (result["platform"], result["python"])]
    if result.get("probe_unavailable"):
        lines.append("PROBE NOT PERFORMED: %s" % result["probe_unavailable"])
    if not result["supported"]:
        lines.append(
            "i2c-dev: not available on this platform (no /dev/i2c-*); address probing is unsupported"
        )
    for adapter in result["adapters"]:
        state = "node ok" if adapter["node_present"] else "node masked"
        lines.append(
            "adapter %s (bus %s) %s [%s%s]"
            % (
                adapter["device"],
                adapter["bus"],
                adapter["adapter_name"] or "unknown adapter",
                state,
                "" if adapter["readable"] is not False else ", not readable",
            )
        )
    if result["clients"]:
        lines.append("bound clients:")
        for client in result["clients"]:
            lines.append(
                "  bus %s 0x%02X %s%s"
                % (
                    client["bus"],
                    int(client["address"], 16),
                    client["name"] or "unnamed",
                    " (%s)" % client["driver"] if client["driver"] else " (%s)" % (client["state"] or ""),
                )
            )
    for probe in result["probes"]:
        if not probe.get("ok"):
            lines.append("probe %s: FAILED %s" % (probe["device"], probe["error"]))
            continue
        found = probe["found"]
        lines.append(
            "probe %s: %d addresses scanned, %d answered"
            % (probe["device"], probe["addresses_scanned"], len(found))
        )
        if not found:
            lines.append("  no ACK: check wiring, pull-ups, 3.3V/GND, and the bus number")
        for key in found:
            note = probe["reserved"].get(key)
            hint = probe["hints"].get(key)
            suffix = ""
            if hint:
                suffix += "  ~ %s (guess)" % hint["guess"]
            if note:
                suffix += "  [reserved: %s]" % note
            lines.append("  %s ack%s" % (key, suffix))
        for key, value in probe["detail"].items():
            if value not in ("ack", "nak"):
                lines.append("  %s %s" % (key, value))
    if result["bridges"]:
        lines.append("usb bridge candidates:")
        for bridge in result["bridges"]:
            lines.append(
                "  %s:%s %s%s"
                % (
                    bridge["vendor_id"],
                    bridge["product_id"],
                    bridge["name"] or "unnamed",
                    " -- %s" % bridge["possible_i2c"] if bridge["possible_i2c"] else "",
                )
            )
    for warning in result["warnings"]:
        lines.append("warning: %s" % warning)
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="i2c_probe.py",
        description="Read-only I2C adapter discovery and address probing (stdlib only).",
    )
    parser.add_argument("--list", action="store_true", help="list adapters and bound clients only")
    parser.add_argument("--probe", action="store_true", help="actively scan addresses (needs i2c-dev)")
    parser.add_argument("--i2c-device", action="append", default=None,
                        help="probe only this node, repeatable (default: every adapter)")
    parser.add_argument("--addresses", default=DEFAULT_RANGE,
                        help="addresses to scan, e.g. 0x48,0x68-0x69 (default %s)" % DEFAULT_RANGE)
    parser.add_argument("--bridges", action="store_true",
                        help="also list USB-I2C bridge candidates (automatic off Linux)")
    parser.add_argument("--json", action="store_true", help="print one JSON object to stdout")
    args = parser.parse_args(argv)

    warnings = []
    try:
        addresses = parse_addresses(args.addresses)
    except ValueError as exc:
        parser.error(str(exc))

    supported = IS_LINUX
    adapters = linux_adapters(warnings) if IS_LINUX else []
    clients = linux_clients() if IS_LINUX else []
    if not IS_LINUX:
        warnings.append(
            "no i2c-dev on this platform: adapters and address probing are unavailable; "
            "a USB-I2C bridge or vendor SDK is required"
        )

    bridges = []
    if args.bridges or not IS_LINUX:
        if IS_MACOS:
            bridges = macos_bridges(warnings)
        elif IS_WINDOWS:
            bridges = windows_bridges(warnings)
        elif IS_LINUX:
            bridges = linux_bridges(warnings)

    probes = []
    # A requested scan that never reached the bus is a failure, not a success:
    # reporting ok=True with zero probes would claim a result we do not have.
    probe_attempted = bool(args.probe)
    probe_unavailable = None
    if args.probe and not supported:
        probe_unavailable = "address probing requires Linux i2c-dev"
        warnings.append("--probe ignored: %s" % probe_unavailable)
    elif args.probe:
        devices = args.i2c_device or [
            adapter["device"] for adapter in adapters if adapter["node_present"]
        ]
        if not devices:
            probe_unavailable = (
                "no adapter node is visible to this process; the kernel lists i2c buses "
                "but /dev/i2c-* is masked (container or sandbox). Run the probe on the host"
            )
            warnings.append("--probe: %s" % probe_unavailable)
        probes = build_probe(devices, addresses, warnings)

    failed = probe_attempted and not probes
    if not failed:
        failed = any(not probe.get("ok") for probe in probes)
    for probe in probes:
        if probe.get("ok") and any(
            str(value).startswith("error:") for value in probe["detail"].values()
        ):
            failed = True

    result = {
        "platform": "linux" if IS_LINUX else "macos" if IS_MACOS else "windows" if IS_WINDOWS else sys.platform,
        "python": "%d.%d.%d" % sys.version_info[:3],
        "supported": supported,
        "ok": not failed,
        "addresses": ["0x%02X" % value for value in addresses] if args.probe else [],
        "adapters": adapters,
        "clients": clients,
        "bridges": bridges,
        "probes": probes,
        "probe_unavailable": probe_unavailable,
        "warnings": warnings,
    }

    if args.json:
        print(json.dumps(result, ensure_ascii=False, sort_keys=False))
    else:
        print(render_text(result))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
