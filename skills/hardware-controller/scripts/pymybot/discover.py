"""Read-only host discovery: enumerate UART, FTDI, I2C and SPI devices.

I2C/SPI/UART enumeration is delegated to the bundled ``Dev_enum`` driver so
the CLI, the Skill and MT actions share one implementation. FTDI USB adapters
are listed through pyftdi and mapped to the ``ftdi://`` URLs the HAL accepts.
Nothing is opened unless ``--probe`` is set, and even then serial ports are
only opened and closed without writing.
"""
from __future__ import annotations

import importlib.util
import sys
from types import SimpleNamespace

from .hardware import ensure_ok
from .paths import asset_path

BUSES = ("i2c", "spi", "uart", "ftdi")
MAX_HINTS = 64


class DiscoveryError(ValueError):
    pass


def parse_buses(raw):
    """Parse a --buses value into a known bus tuple."""
    tokens = {token.strip().lower()
              for token in str("all" if raw is None else raw).split(",") if token.strip()}
    if "all" in tokens:
        return BUSES
    unknown = sorted(tokens - set(BUSES))
    if unknown:
        raise DiscoveryError(f"--buses accepts {', '.join(BUSES)} or all; unknown: {', '.join(unknown)}")
    if not tokens:
        raise DiscoveryError(f"--buses must name at least one of {', '.join(BUSES)}")
    return tuple(bus for bus in BUSES if bus in tokens)


def _platform_name():
    return ("linux" if sys.platform.startswith("linux")
            else "macos" if sys.platform == "darwin"
            else "windows" if sys.platform.startswith("win")
            else sys.platform)


def _load_dev_enum():
    """Import the bundled Dev_enum driver from the packaged module assets."""
    module_path = asset_path("modules") / "Dev_enum.py"
    try:
        spec = importlib.util.spec_from_file_location("pymybot_discover_dev_enum", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except OSError as exc:
        raise DiscoveryError(f"Cannot load the bundled Dev_enum driver: {exc}") from None
    return module


def _enumerate_ftdi():
    """List FTDI USB adapters as HAL-ready ftdi:// URLs (no device is opened)."""
    result = {"supported": True, "adapters": [], "notes": []}
    try:
        from pyftdi.ftdi import Ftdi
    except Exception:
        result["supported"] = False
        result["notes"].append("pyftdi is not installed; FTDI URLs unavailable (install pymybot[hardware])")
        return result
    try:
        devices = Ftdi.list_devices()
    except Exception as exc:
        result["notes"].append(f"USB enumeration failed: {type(exc).__name__}")
        return result
    for descriptor, interface in devices:
        adapter = {"vid": "0x%04X" % descriptor.vid, "pid": "0x%04X" % descriptor.pid,
                   "interface": int(interface)}
        if descriptor.sn:
            adapter["serial"] = str(descriptor.sn)
        if descriptor.description:
            adapter["description"] = str(descriptor.description)
        adapter["url"] = _ftdi_url(descriptor.vid, descriptor.pid, adapter.get("serial"), interface)
        result["adapters"].append(adapter)
    return result


def _ftdi_url(vid, pid, serial, interface):
    netloc = "%04X:%04X" % (vid, pid)
    if serial:
        netloc += f":{serial}"
    return f"ftdi://{netloc}/{int(interface)}"


def _probe_uart_ports(ports):
    """Briefly open each real UART port to report whether it is already in use.

    Only the open/close pair runs; nothing is written. Some boards reboot on
    the DTR/RTS transitions an open can pulse, so probing stays opt-in.
    """
    import serial
    for record in ports:
        device = record.get("device")
        if not device or record.get("source") == "sysfs":
            continue
        try:
            port = serial.serial_for_url(device, timeout=0.25, do_not_open=True)
            port.open()
            try:
                port.dtr = False
                port.rts = False
            finally:
                port.close()
            record["in_use"] = False
        except serial.SerialException as exc:
            errno = getattr(exc, "errno", None)
            record["in_use"] = True if errno in (11, 16, 32) else None
            record["probe_error"] = ("busy" if errno in (11, 16, 32)
                                     else "denied" if errno == 13 else "error")
        except Exception:
            record["in_use"] = None
            record["probe_error"] = "error"


def _safe_hint_value(value):
    return isinstance(value, str) and value and "'" not in value and "\\" not in value


def _sql(table, columns, values):
    return (f"CREATE TABLE {table} ({', '.join(columns)});\n"
            f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join(values)});")


def _hints(result):
    """Map discovered devices to the structure SQL that declares them."""
    hints = []

    def add(kind, device, table, columns, values):
        if len(hints) >= MAX_HINTS or not _safe_hint_value(device):
            return
        hints.append({"kind": kind, "device": device,
                      "sql": _sql(table, columns, values)})

    for record in result.get("uart", {}).get("ports", []):
        device = record.get("device")
        if device and record.get("source") != "sysfs":
            add("uart", device, "UART", ("name", "path", "baud"),
                ("'bus'", f"'{device}'", "115200"))
    for record in result.get("i2c", {}).get("adapters", []):
        device = record.get("device")
        if device and record.get("node_present", True):
            add("i2c", device, "I2C", ("name", "path"), ("'bus'", f"'{device}'"))
    for record in result.get("spi", {}).get("devices", []):
        device = record.get("device")
        if device:
            add("spi", device, "SPI", ("name", "path"), ("'bus'", f"'{device}'"))
    for adapter in result.get("ftdi", {}).get("adapters", []):
        url = adapter.get("url")
        if not url:
            continue
        add("ftdi-i2c", url, "I2C", ("name", "path"), ("'bus'", f"'{url}'"))
        add("ftdi-spi", url + "?cs=0", "SPI", ("name", "path"), ("'bus'", f"'{url}?cs=0'"))
    return hints


def discover(buses=BUSES, probe=False):
    """Enumerate host devices read-only and return a JSON-ready report."""
    buses = tuple(buses) or BUSES
    driver_buses = [bus for bus in buses if bus != "ftdi"]
    result = {"platform": _platform_name(), "buses": list(buses)}
    if driver_buses:
        module = _load_dev_enum()
        driver = module.Driver(SimpleNamespace(check=lambda: None))
        report = driver.call({"buses": ",".join(driver_buses)})
        ensure_ok(report, "discovery driver")
        report.pop("result", None)
        result.update(report)
    else:
        # Keep the documented report shape even when only FTDI was requested.
        result.update({"i2c": {"supported": False, "notes": ["not requested"]},
                       "spi": {"supported": False, "notes": ["not requested"]},
                       "uart": {"supported": False, "notes": ["not requested"]}})
    if "ftdi" in buses:
        result["ftdi"] = _enumerate_ftdi()
    if probe and "uart" in result:
        _probe_uart_ports(result["uart"].get("ports", []))
        result["uart"]["probed"] = True
        result["uart"].setdefault("notes", []).append(
            "probe briefly opened each real port; DTR/RTS may have pulsed")
    result["hints"] = _hints(result)
    return result
