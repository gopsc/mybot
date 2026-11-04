#!/usr/bin/env python3
"""Cross-platform I2C / UART / SPI device enumeration.

Passive by default: it only reports what the operating system already exposes.
Active operations are opt-in per bus:
    I2C   --probe                  address scan (address bytes only, no payload)
    UART  --check-open             open each port briefly (may toggle DTR)
    SPI   --loopback <device>      full-duplex transfer (needs MOSI -> MISO)

Exit codes: 0 = ok, 1 = a requested action failed, 2 = usage error.
"""

from __future__ import annotations

import argparse
import errno
import glob
import json
import os
import re
import struct
import sys

IS_LINUX = sys.platform.startswith("linux")
IS_MACOS = sys.platform == "darwin"
IS_WINDOWS = sys.platform.startswith("win")

EREMOTEIO = getattr(errno, "EREMOTEIO", 121)
NAK_ERRNOS = (errno.ENXIO, EREMOTEIO)

# Linux i2c-dev ioctls and structure layouts (see references/i2c.md).
I2C_SLAVE = 0x0703
I2C_RDWR = 0x0707
I2C_MSG_FORMAT = "HHHxxP"          # struct i2c_msg: addr, flags, len, buf
I2C_RDWR_FORMAT = "PI4x" if struct.calcsize("P") == 8 else "PI"

# Linux spidev ioctls and struct spi_ioc_transfer layout (see references/spi.md).
SPI_IOC_WR_MODE = 0x40016B01
SPI_IOC_WR_BITS_PER_WORD = 0x40016B03
SPI_IOC_WR_MAX_SPEED_HZ = 0x40046B04
SPI_TRANSFER_FORMAT = "PPIIHBBBBBB"
SPI_MESSAGE_IOCTL = (
    (1 << 30) | (struct.calcsize(SPI_TRANSFER_FORMAT) << 16) | (ord("k") << 8)
)

DEFAULT_I2C_RANGE = "0x08-0x77"
DEFAULT_SPI_PAYLOAD = "a55aff0001020408"
LINUX_TTY_PATTERNS = (
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

LINUX_SERIAL_PREFIXES = (
    "ttyS",
    "ttyUSB",
    "ttyACM",
    "ttyAMA",
    "ttyCH",
    "ttyXR",
    "ttySC",
    "ttyGS",
    "rfcomm",
)


class ProbeError(RuntimeError):
    """A requested active operation could not be carried out."""


class _TransferUnsupported(Exception):
    """The adapter rejected the transfer type; fall back to another probe mode."""


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return None


def _natural_key(value):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", value)]


def _has_module(name):
    try:
        __import__(name)
    except Exception:
        return False
    return True


def _parse_number(text):
    """0x-prefixed text is hex, everything else is decimal (so "08" stays 8)."""
    text = text.strip()
    return int(text, 16) if text.lower().startswith("0x") else int(text, 10)


def _parse_addresses(spec):
    addresses = []
    for chunk in spec.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "-" in chunk:
            low_text, _, high_text = chunk.partition("-")
            low, high = _parse_number(low_text), _parse_number(high_text)
            if high < low:
                raise ValueError("reversed range %r" % chunk)
            addresses.extend(range(low, high + 1))
        else:
            addresses.append(_parse_number(chunk))
    if not addresses:
        raise ValueError("no address given")
    for address in addresses:
        if not 0x00 <= address <= 0x7F:
            raise ValueError("address 0x%02X is outside the 7-bit range" % address)
    return sorted(set(addresses))


def _parse_hex_bytes(text):
    cleaned = re.sub(r"0x|[\s,:_-]", "", text)
    if not cleaned or len(cleaned) % 2:
        raise ValueError("payload must be whole bytes in hex, e.g. a55aff00")
    return bytes.fromhex(cleaned)


def _i2c_reserved_note(address):
    if address <= 0x07:
        return "reserved/special (general call, CBUS, Hs-mode master)"
    if address <= 0x0F:
        return "reserved (SMBus host notify or reserved)"
    if address <= 0x1F:
        return "reserved (CBus / 10-bit prefix)"
    if address >= 0x78:
        return "reserved (10-bit addressing)"
    return None


# --------------------------------------------------------------------------- #
# I2C
# --------------------------------------------------------------------------- #
def _parent_i2c_bus(entry):
    """Walk up a sysfs path to the owning adapter (i2c-N), for ACPI-style clients."""
    path = os.path.realpath(entry)
    while path and path != "/":
        match = re.match(r"^i2c-(\d+)$", os.path.basename(path))
        if match:
            return int(match.group(1))
        path = os.path.dirname(path)
    return None


def _i2c_sysfs_clients():
    clients = []
    for entry in sorted(glob.glob("/sys/bus/i2c/devices/*"), key=_natural_key):
        base = os.path.basename(entry)
        if re.match(r"^i2c-\d+$", base):
            continue  # adapter, already listed
        record = {"sysfs_name": base}
        match = re.match(r"^(\d+)-([0-9a-fA-F]{4})$", base)
        if match:
            record["bus"] = int(match.group(1))
            record["address"] = "0x%02X" % int(match.group(2), 16)
        else:
            bus = _parent_i2c_bus(entry)
            if bus is not None:
                record["bus"] = bus
        name = _read_text(os.path.join(entry, "name"))
        if name:
            record["name"] = name
        modalias = _read_text(os.path.join(entry, "modalias"))
        if modalias:
            record["modalias"] = modalias
        driver_link = os.path.join(entry, "driver")
        if os.path.islink(driver_link):
            record["driver"] = os.path.basename(os.path.realpath(driver_link))
        elif os.path.exists(os.path.join(entry, "waiting_for_supplier")):
            record["state"] = "waiting_for_supplier (no driver bound)"
        clients.append(record)
    return clients


def _sysfs_i2c_names():
    """Adapters the kernel knows about, whether or not /dev nodes are visible."""
    names = {}
    for path in glob.glob("/sys/class/i2c-dev/i2c-*"):
        suffix = os.path.basename(path).rsplit("-", 1)[-1]
        if suffix.isdigit():
            names[int(suffix)] = _read_text(os.path.join(path, "name"))
    return names


def enumerate_i2c():
    result = {"supported": False, "adapters": [], "clients": [], "notes": []}
    if IS_LINUX:
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
        for bus, name in sorted(_sysfs_i2c_names().items()):
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
            if name:
                record["adapter_name"] = name
            result["adapters"].append(record)
            hidden += 1
        result["adapters"].sort(key=lambda item: (item.get("bus", -1), item["device"]))
        if hidden:
            result["node_visibility"] = "masked"
            result["notes"].append(
                "%d adapter(s) exist per /sys/class/i2c-dev but /dev/i2c-* is not visible to "
                "this process (container or sandbox with a private /dev?); probing needs the "
                "real device node, so run --probe on the host" % hidden
            )
        result["clients"] = _i2c_sysfs_clients()
        if any("NVIDIA i2c adapter" in (item.get("adapter_name") or "") for item in result["adapters"]):
            result["notes"].append(
                "adapters named 'NVIDIA i2c adapter' are usually display DDC/AUX channels owned "
                "by the DRM driver; user peripherals are rarely attached there"
            )
        if not result["adapters"]:
            result["notes"].append(
                "no /dev/i2c-* node: load the adapter driver (i2c-dev, i2c-i801, "
                "i2c-bcm2835, ...) or enable the bus in the device tree"
            )
    elif IS_MACOS:
        result["notes"].append(
            "macOS has no generic i2c-dev character device; I2C is only reachable "
            "through a vendor SDK (FTDI / CH34x / Aardvark bridges)"
        )
    elif IS_WINDOWS:
        result["notes"].append(
            "Windows has no generic I2C device namespace; enumerate through the vendor "
            "SDK (FTDI D2XX, CH341/CH347, Total Phase, Aardvark)"
        )
    else:
        result["notes"].append("unsupported platform: %s" % sys.platform)
    return result


def _probe_with_smbus2(device, addresses):
    import smbus2

    bus_number = int(device.rsplit("-", 1)[-1])
    outcome = {}
    with smbus2.SMBus(bus_number) as bus:
        for address in addresses:
            key = "0x%02X" % address
            try:
                bus.write_quick(address)
                outcome[key] = "ack"
            except OSError as exc:
                if exc.errno in NAK_ERRNOS:
                    outcome[key] = "nak"
                else:
                    outcome[key] = "error: %s" % (exc.strerror or exc)
    return outcome


def _i2c_quick_write(fd, address):
    """Zero-length I2C_RDWR write: address + W only, no data bytes on the bus."""
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
            raise _TransferUnsupported(exc.strerror or "ioctl rejected") from exc
        raise


def _probe_ioctl_read(fd, addresses):
    """Fallback: select the slave and read one byte. Some devices dislike this."""
    import fcntl

    outcome = {}
    for address in addresses:
        key = "0x%02X" % address
        try:
            fcntl.ioctl(fd, I2C_SLAVE, address)
        except OSError as exc:
            outcome[key] = "error: %s" % (exc.strerror or exc)
            continue
        try:
            os.read(fd, 1)
            outcome[key] = "ack"
        except OSError as exc:
            outcome[key] = (
                "nak" if exc.errno in NAK_ERRNOS else "error: %s" % (exc.strerror or exc)
            )
    return outcome


def _probe_ioctl(device, addresses, warnings):
    try:
        fd = os.open(device, os.O_RDWR)
    except OSError as exc:
        raise ProbeError("cannot open %s: %s" % (device, exc.strerror or exc)) from exc
    try:
        outcome = {}
        unsupported = False
        for address in addresses:
            key = "0x%02X" % address
            try:
                _i2c_quick_write(fd, address)
                outcome[key] = "ack"
            except _TransferUnsupported as exc:
                unsupported = True
                warnings.append(
                    "%s: zero-length transfer unsupported (%s); falling back to a "
                    "1-byte read, which can have side effects on some devices"
                    % (device, exc)
                )
                break
            except OSError as exc:
                outcome[key] = (
                    "nak"
                    if exc.errno in NAK_ERRNOS
                    else "error: %s" % (exc.strerror or exc)
                )
        if unsupported:
            outcome = _probe_ioctl_read(fd, addresses)
        return outcome
    finally:
        os.close(fd)


def _probe_device(device, addresses, warnings):
    if not os.path.exists(device):
        raise ProbeError("%s does not exist" % device)
    if _has_module("smbus2"):
        try:
            return _probe_with_smbus2(device, addresses)
        except OSError as exc:
            warnings.append(
                "smbus2 backend failed on %s (%s); retrying with raw ioctl"
                % (device, exc.strerror or exc)
            )
    return _probe_ioctl(device, addresses, warnings)


def probe_i2c(adapters, addresses, warnings):
    if not IS_LINUX:
        warnings.append("I2C address probing is only implemented for Linux i2c-dev")
        return
    for adapter in adapters:
        device = adapter["device"]
        try:
            outcome = _probe_device(device, addresses, warnings)
        except ProbeError as exc:
            adapter["probe_error"] = str(exc)
            warnings.append(str(exc))
            continue
        found = sorted(key for key, value in outcome.items() if value == "ack")
        detail = {key: value for key, value in outcome.items() if value != "nak"}
        probe = {
            "addresses_scanned": len(addresses),
            "found": found,
            "detail": detail,
        }
        annotated = {
            key: _i2c_reserved_note(int(key, 16)) for key in found if _i2c_reserved_note(int(key, 16))
        }
        if annotated:
            probe["warnings"] = annotated
        adapter["probe"] = probe


# --------------------------------------------------------------------------- #
# UART
# --------------------------------------------------------------------------- #
def _windows_serial_ports():
    try:
        import winreg
    except ImportError:
        return []
    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DEVICEMAP\SERIALCOMM")
    except OSError:
        return []
    entries = []
    try:
        index = 0
        while True:
            try:
                name, value, _ = winreg.EnumValue(key, index)
            except OSError:
                break
            entries.append((name, value))
            index += 1
    finally:
        key.Close()
    return entries


def _serial_symlinks():
    links = []
    for pattern in ("/dev/serial/by-id/*", "/dev/serial/by-path/*"):
        for path in sorted(glob.glob(pattern)):
            links.append({"path": path, "target": os.path.realpath(path)})
    return links


def _uart_from_os():
    ports = []
    seen = set()
    if IS_LINUX or IS_MACOS:
        patterns = LINUX_TTY_PATTERNS if IS_LINUX else ("/dev/cu.*", "/dev/tty.*")
        for pattern in patterns:
            for path in sorted(glob.glob(pattern), key=_natural_key):
                if path in seen:
                    continue
                seen.add(path)
                ports.append({"device": path})
        ports.sort(key=lambda item: _natural_key(item["device"]))
    elif IS_WINDOWS:
        for name, value in _windows_serial_ports():
            ports.append({"device": value, "registry_entry": name})
    return ports


def _sysfs_serial_candidates():
    """Serial nodes the kernel knows about, mapped to their UART type (None = n/a)."""
    found = []
    for path in glob.glob("/sys/class/tty/*"):
        name = os.path.basename(path)
        if not name.startswith(LINUX_SERIAL_PREFIXES):
            continue
        type_text = _read_text(os.path.join(path, "type"))
        try:
            uart_type = int(type_text)
        except (TypeError, ValueError):
            uart_type = None
        found.append((name, uart_type))
    return found


def enumerate_uart(warnings, include_phantom=False):
    result = {
        "supported": True,
        "backend": None,
        "ports": [],
        "symlinks": [],
        "notes": [],
    }
    try:
        from serial.tools import list_ports
    except Exception:
        list_ports = None
    if list_ports is not None:
        result["backend"] = "pyserial"
        for port in sorted(list_ports.comports(), key=lambda item: _natural_key(item.device)):
            result["ports"].append(
                {
                    "device": port.device,
                    "description": port.description,
                    "hwid": port.hwid,
                    "vid": "0x%04X" % port.vid if port.vid is not None else None,
                    "pid": "0x%04X" % port.pid if port.pid is not None else None,
                    "serial_number": port.serial_number,
                    "manufacturer": port.manufacturer,
                    "product": port.product,
                    "interface": port.interface,
                }
            )
    else:
        result["backend"] = "os"
        result["ports"] = _uart_from_os()
        warnings.append(
            "pyserial is not installed; VID/PID and product names are unavailable "
            "(pip install pyserial), kernel ttyS* entries may be phantom ports"
        )
    for port in result["ports"]:
        port.setdefault("node_present", True)
    if IS_LINUX:
        known = {os.path.basename(port["device"]) for port in result["ports"]}
        masked = 0
        phantom = 0
        for name, uart_type in _sysfs_serial_candidates():
            if name in known:
                continue
            masked += 1
            if uart_type == 0:
                phantom += 1
                if not include_phantom:
                    continue
            record = {
                "device": "/dev/" + name,
                "source": "sysfs",
                "node_present": False,
                "uart_type": uart_type,
            }
            if uart_type == 0:
                record["note"] = "type 0: no UART detected behind this node (often phantom)"
            result["ports"].append(record)
        if phantom and not include_phantom:
            result["notes"].append(
                "%d tty node(s) report uart type 0 (no UART behind them) and are hidden; "
                "use --include-phantom to list them" % phantom
            )
        if masked:
            result["node_visibility"] = "masked"
            warnings.append(
                "%d serial port(s) exist per /sys/class/tty but the /dev node is not visible "
                "to this process; metadata is limited and --check-open cannot work here"
                % masked
            )
        result["ports"].sort(key=lambda item: _natural_key(item["device"]))
        result["symlinks"] = _serial_symlinks()
    return result


def check_uart_ports(ports, warnings):
    if ports:
        warnings.append(
            "--check-open opens every port; opening may assert DTR and reset an "
            "attached board (Arduino/ESP32) or disturb a running console"
        )
    flags = os.O_RDWR | getattr(os, "O_NOCTTY", 0) | getattr(os, "O_NONBLOCK", 0)
    for record in ports:
        device = record["device"]
        target = "\\\\.\\" + device if IS_WINDOWS and not device.startswith("\\\\.\\") else device
        try:
            fd = os.open(target, flags)
        except OSError as exc:
            record["open"] = "denied: %s" % (exc.strerror or exc)
        else:
            os.close(fd)
            record["open"] = "ok"


# --------------------------------------------------------------------------- #
# SPI
# --------------------------------------------------------------------------- #
def enumerate_spi():
    result = {"supported": False, "controllers": [], "devices": [], "notes": []}
    if not IS_LINUX:
        if IS_MACOS:
            result["notes"].append(
                "macOS has no spidev interface; SPI needs a vendor driver or an "
                "external USB bridge (FTDI/CH347/Aardvark)"
            )
        elif IS_WINDOWS:
            result["notes"].append(
                "Windows has no spidev interface; use the vendor SDK for your USB-SPI "
                "bridge (FTDI D2XX, CH347, Total Phase, Aardvark)"
            )
        else:
            result["notes"].append("unsupported platform: %s" % sys.platform)
        return result
    result["supported"] = True
    for path in sorted(glob.glob("/sys/class/spi_master/spi*"), key=_natural_key):
        controller = {"name": os.path.basename(path)}
        driver = os.path.join(path, "device", "driver")
        if os.path.islink(driver):
            controller["driver"] = os.path.basename(os.path.realpath(driver))
        result["controllers"].append(controller)
    if any(item.get("driver") == "intel-spi" for item in result["controllers"]):
        result["notes"].append(
            "intel-spi is the PCH firmware/BIOS flash controller, not a general-purpose SPI "
            "bus: it has no spidev by design and writing through it can brick the machine"
        )
    for path in sorted(glob.glob("/dev/spidev*"), key=_natural_key):
        name = os.path.basename(path)
        record = {
            "device": path,
            "readable": os.access(path, os.R_OK),
            "writable": os.access(path, os.W_OK),
        }
        match = re.match(r"^spidev(\d+)\.(\d+)$", name)
        if match:
            record["bus"] = int(match.group(1))
            record["chip_select"] = int(match.group(2))
        sysfs = os.path.join("/sys/class/spidev", name)
        modalias = _read_text(os.path.join(sysfs, "device", "modalias"))
        if modalias:
            record["modalias"] = modalias
        of_node = os.path.join(sysfs, "device", "of_node")
        if os.path.islink(of_node):
            record["device_tree_node"] = os.path.basename(os.path.realpath(of_node))
        result["devices"].append(record)
    general = [item for item in result["controllers"] if item.get("driver") != "intel-spi"]
    if not result["devices"] and general:
        result["notes"].append(
            "no /dev/spidev* node: enable CONFIG_SPI_SPIDEV, load the spidev module, "
            "add a spidev child to the controller, or export it via the device tree overlay"
        )
    return result


def spi_loopback(device, payload, mode, speed, bits):
    """Full-duplex transfer through spi_ioc_transfer; needs MOSI wired to MISO."""
    import ctypes
    import fcntl

    try:
        fd = os.open(device, os.O_RDWR)
    except OSError as exc:
        raise ProbeError("cannot open %s: %s" % (device, exc.strerror or exc)) from exc
    try:
        fcntl.ioctl(fd, SPI_IOC_WR_MODE, struct.pack("B", mode & 0xFF))
        fcntl.ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, struct.pack("B", bits & 0xFF))
        fcntl.ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, struct.pack("I", speed))
        tx = ctypes.create_string_buffer(bytes(payload), len(payload))
        rx = ctypes.create_string_buffer(len(payload))
        transfer = struct.pack(
            SPI_TRANSFER_FORMAT,
            ctypes.addressof(tx),
            ctypes.addressof(rx),
            len(payload),
            speed,
            0,
            bits & 0xFF,
            0,
            0,
            0,
            0,
            0,
        )
        fcntl.ioctl(fd, SPI_MESSAGE_IOCTL, bytearray(transfer), True)
        return rx.raw[: len(payload)]
    except OSError as exc:
        raise ProbeError("SPI transfer on %s failed: %s" % (device, exc.strerror or exc)) from exc
    finally:
        os.close(fd)


# --------------------------------------------------------------------------- #
# rendering
# --------------------------------------------------------------------------- #
def _render_i2c(section, lines):
    lines.append("[I2C]")
    if not section["supported"]:
        lines.append("  not supported on this platform")
    else:
        if not section["adapters"]:
            lines.append("  no adapters found")
        for adapter in section["adapters"]:
            label = "  %s" % adapter["device"]
            if "adapter_name" in adapter:
                label += "  (%s)" % adapter["adapter_name"]
            if adapter.get("node_present") is False:
                label += "  [node not visible]"
            elif not (adapter.get("readable") and adapter.get("writable")):
                label += "  [no read/write permission]"
            lines.append(label)
            probe = adapter.get("probe")
            if probe:
                found = probe["found"]
                lines.append(
                    "    scanned %d addresses, %d responded: %s"
                    % (
                        probe["addresses_scanned"],
                        len(found),
                        ", ".join(found) if found else "none",
                    )
                )
            if "probe_error" in adapter:
                lines.append("    probe error: %s" % adapter["probe_error"])
        for client in section["clients"]:
            parts = []
            if "bus" in client:
                parts.append("bus %s" % client["bus"])
            if "address" in client:
                parts.append("addr %s" % client["address"])
            else:
                parts.append(client["sysfs_name"])
            label = "  client: " + " ".join(parts)
            if client.get("name"):
                label += "  %s" % client["name"]
            if client.get("driver"):
                label += "  driver=%s" % client["driver"]
            elif client.get("state"):
                label += "  %s" % client["state"]
            lines.append(label)
    for note in section["notes"]:
        lines.append("  note: %s" % note)


def _render_uart(section, lines):
    lines.append("[UART]")
    lines.append("  backend: %s" % section["backend"])
    if not section["ports"]:
        lines.append("  no serial ports reported")
    for port in section["ports"]:
        label = "  %s" % port["device"]
        description = " / ".join(
            item for item in (port.get("description"), port.get("manufacturer"), port.get("product")) if item
        )
        if description:
            label += "  " + description
        ids = []
        if port.get("vid") and port.get("pid"):
            ids.append("%s:%s" % (port["vid"], port["pid"]))
        if port.get("serial_number"):
            ids.append("sn=%s" % port["serial_number"])
        if ids:
            label += "  [%s]" % " ".join(ids)
        if port.get("open"):
            label += "  open=%s" % port["open"]
        if port.get("node_present") is False:
            label += "  [node not visible]"
        if port.get("uart_type") is not None:
            label += "  uart_type=%s" % port["uart_type"]
        if port.get("note"):
            label += "  (%s)" % port["note"]
        lines.append(label)
    for link in section.get("symlinks") or []:
        lines.append("  stable link: %s -> %s" % (link["path"], link["target"]))
    for note in section["notes"]:
        lines.append("  note: %s" % note)


def _render_spi(section, lines):
    lines.append("[SPI]")
    if not section["supported"]:
        lines.append("  not supported on this platform")
    else:
        for controller in section["controllers"]:
            label = "  controller: %s" % controller["name"]
            if controller.get("driver"):
                label += "  (%s)" % controller["driver"]
            lines.append(label)
        if not section["devices"]:
            lines.append("  no /dev/spidev* nodes")
        for device in section["devices"]:
            label = "  %s" % device["device"]
            if "bus" in device:
                label += "  (bus %d, cs %d)" % (device["bus"], device["chip_select"])
            if device.get("modalias"):
                label += "  %s" % device["modalias"]
            if not (device.get("readable") and device.get("writable")):
                label += "  [no read/write permission]"
            lines.append(label)
        for device, outcome in (section.get("loopback") or {}).items():
            if outcome.get("ok"):
                lines.append(
                    "  loopback %s: tx=%s rx=%s echo=%s"
                    % (device, outcome["tx"], outcome["rx"], outcome["echo"])
                )
            else:
                lines.append("  loopback %s: failed (%s)" % (device, outcome.get("error")))
    for note in section["notes"]:
        lines.append("  note: %s" % note)


def render_text(report):
    lines = ["platform: %s (python %s)" % (report["platform"], report["python"])]
    for bus, renderer in (("i2c", _render_i2c), ("uart", _render_uart), ("spi", _render_spi)):
        section = report.get(bus)
        if section is None:
            continue
        lines.append("")
        renderer(section, lines)
    if report["warnings"]:
        lines.append("")
        lines.append("warnings:")
        for item in report["warnings"]:
            lines.append("  - %s" % item)
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# entry point
# --------------------------------------------------------------------------- #
def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="bus_enum.py",
        description="Enumerate I2C / UART / SPI devices exposed by the operating system.",
        epilog="Passive by default; --probe, --check-open and --loopback are active.",
    )
    parser.add_argument(
        "--bus",
        action="append",
        choices=["all", "i2c", "uart", "spi"],
        help="bus to enumerate (repeatable, default: all)",
    )
    parser.add_argument("--json", action="store_true", help="emit one line of JSON")
    parser.add_argument(
        "--probe", action="store_true", help="I2C: actively scan addresses (default range 0x08-0x77)"
    )
    parser.add_argument(
        "--addresses", default=DEFAULT_I2C_RANGE, help="I2C addresses: 0x08-0x77 or 0x48,0x68"
    )
    parser.add_argument("--i2c-device", help="I2C: restrict probing to one device, e.g. /dev/i2c-1")
    parser.add_argument(
        "--check-open", action="store_true", help="UART: open each port briefly (may toggle DTR)"
    )
    parser.add_argument(
        "--include-phantom",
        action="store_true",
        help="UART: also list tty nodes whose uart type is 0 (no UART behind them)",
    )
    parser.add_argument(
        "--loopback",
        action="append",
        metavar="DEVICE",
        help="SPI: full-duplex transfer on DEVICE (requires MOSI wired to MISO)",
    )
    parser.add_argument("--spi-mode", type=int, default=0, help="SPI mode 0-3 (default 0)")
    parser.add_argument("--spi-speed", type=int, default=1000000, help="SPI clock in Hz (default 1 MHz)")
    parser.add_argument("--spi-bits", type=int, default=8, help="SPI bits per word (default 8)")
    parser.add_argument("--spi-payload", default=DEFAULT_SPI_PAYLOAD, help="SPI loopback bytes, hex")
    args = parser.parse_args(argv)

    buses = list(dict.fromkeys(args.bus or ["all"]))
    if "all" in buses:
        buses = ["i2c", "uart", "spi"]

    warnings = []
    failures = 0
    report = {
        "platform": sys.platform,
        "python": "%d.%d.%d" % sys.version_info[:3],
        "buses": buses,
        "warnings": warnings,
    }

    if "i2c" in buses:
        section = enumerate_i2c()
        if args.probe:
            try:
                addresses = _parse_addresses(args.addresses)
            except ValueError as exc:
                parser.error("--addresses: %s" % exc)
            targets = section["adapters"]
            if args.i2c_device:
                targets = [item for item in targets if item["device"] == args.i2c_device]
                if not targets:
                    warnings.append(
                        "--i2c-device %s is not in the enumerated adapter list" % args.i2c_device
                    )
            probe_i2c(targets, addresses, warnings)
            failures += sum(1 for item in targets if "probe_error" in item)
        report["i2c"] = section

    if "uart" in buses:
        section = enumerate_uart(warnings, args.include_phantom)
        if args.check_open:
            check_uart_ports(section["ports"], warnings)
            failures += sum(1 for item in section["ports"] if str(item.get("open", "")).startswith("denied"))
        report["uart"] = section

    if "spi" in buses:
        section = enumerate_spi()
        if args.loopback:
            try:
                payload = _parse_hex_bytes(args.spi_payload)
            except ValueError as exc:
                parser.error("--spi-payload: %s" % exc)
            if not 0 <= args.spi_mode <= 3:
                parser.error("--spi-mode must be 0..3")
            if not 1 <= args.spi_bits <= 32:
                parser.error("--spi-bits must be 1..32")
            if not 1000 <= args.spi_speed <= 100000000:
                parser.error("--spi-speed must be 1 kHz .. 100 MHz")
            warnings.append(
                "--loopback drives MOSI and samples MISO; only use it with MOSI wired to MISO"
            )
            outcomes = {}
            for device in args.loopback:
                try:
                    received = spi_loopback(device, payload, args.spi_mode, args.spi_speed, args.spi_bits)
                except ProbeError as exc:
                    outcomes[device] = {"ok": False, "error": str(exc)}
                    warnings.append(str(exc))
                    failures += 1
                else:
                    outcomes[device] = {
                        "ok": True,
                        "echo": received == payload,
                        "tx": payload.hex(),
                        "rx": received.hex(),
                    }
            section["loopback"] = outcomes
        report["spi"] = section

    report["ok"] = failures == 0

    if args.json:
        for item in warnings:
            print("warning: %s" % item, file=sys.stderr)
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(render_text(report))

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
