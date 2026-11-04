#!/usr/bin/env python3
"""Collect host system status on Linux, macOS and Windows using only the stdlib.

The collector is strictly read-only: it never writes files, never starts
services and never transmits network traffic (UDP sockets are only connected to
resolve the local route, which sends no packets).

Output is either human-readable text or a single line of JSON. Anything that
could not be measured is reported as null plus a note; nothing is invented.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time

SCHEMA_VERSION = 1
SECTIONS = ("os", "cpu", "memory", "disk", "network")

_notes = []


def note(message):
    """Record a diagnostic message; duplicates are collapsed."""
    if message not in _notes:
        _notes.append(message)


# --------------------------------------------------------------------------- #
# generic helpers
# --------------------------------------------------------------------------- #

def _run(argv, timeout=5):
    """Run a read-only helper command; return stdout text or None."""
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        note("command failed: %s (%s)" % (" ".join(argv), exc))
        return None
    if proc.returncode != 0:
        note("command exited %d: %s" % (proc.returncode, " ".join(argv)))
        return None
    return proc.stdout.decode("utf-8", "replace")


def _read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError as exc:
        note("cannot read %s (%s)" % (path, exc))
        return None


def _sysctl(name):
    text = _run(["sysctl", "-n", name])
    return text.strip() if text else None


def _is_int(text):
    return bool(text) and text.strip().lstrip("-").isdigit()


def _percent(part, whole):
    if part is None or not whole or whole <= 0:
        return None
    return round(100.0 * part / whole, 1)


def _utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _parse_size(text):
    """Parse strings like '2048.00M' into bytes; None when unparsable."""
    if not text:
        return None
    match = re.fullmatch(r"([\d.]+)\s*([KMGTPE]?)B?", text.strip(), re.IGNORECASE)
    if not match:
        return None
    scale = {"": 0, "K": 1, "M": 2, "G": 3, "T": 4, "P": 5, "E": 6}
    try:
        value = float(match.group(1))
    except ValueError:
        return None
    return int(value * (1024 ** scale[match.group(2).upper()]))


# --------------------------------------------------------------------------- #
# os section
# --------------------------------------------------------------------------- #

def _boot_epoch():
    system = platform.system()
    if system == "Linux":
        text = _read_text("/proc/uptime")
        if not text:
            return None
        try:
            return time.time() - float(text.split()[0])
        except (IndexError, ValueError):
            note("/proc/uptime is unparsable")
            return None
    if system == "Darwin":
        text = _sysctl("kern.boottime")
        if not text:
            return None
        match = re.search(r"sec\s*=\s*(\d+)", text)
        if not match:
            note("kern.boottime is unparsable")
            return None
        return float(match.group(1))
    if system == "Windows":
        try:
            import ctypes

            milliseconds = ctypes.windll.kernel32.GetTickCount64()
        except (ImportError, AttributeError, OSError) as exc:
            note("GetTickCount64 failed (%s)" % exc)
            return None
        return time.time() - milliseconds / 1000.0
    note("boot time is not supported on %s" % (system or "unknown platform"))
    return None


def collect_os():
    info = {
        "system": platform.system() or None,
        "release": platform.release() or None,
        "version": platform.version() or None,
        "machine": platform.machine() or None,
        "node": platform.node() or None,
        "python_version": platform.python_version(),
        "boot_epoch": None,
        "uptime_seconds": None,
    }
    boot = _boot_epoch()
    if boot is not None:
        info["boot_epoch"] = round(boot, 3)
        info["uptime_seconds"] = round(max(0.0, time.time() - boot), 1)
    return info


# --------------------------------------------------------------------------- #
# cpu section
# --------------------------------------------------------------------------- #

def _cpu_times():
    """Return (total_ticks, idle_ticks) cumulative since boot, or None."""
    system = platform.system()
    if system == "Linux":
        text = _read_text("/proc/stat")
        if not text:
            return None
        for line in text.splitlines():
            if not line.startswith("cpu "):
                continue
            fields = line.split()[1:]
            try:
                values = [int(value) for value in fields]
            except ValueError:
                note("/proc/stat aggregate cpu line is unparsable")
                return None
            if len(values) < 4:
                note("/proc/stat aggregate cpu line is too short")
                return None
            idle = values[3] + (values[4] if len(values) > 4 else 0)
            return sum(values), idle
        note("/proc/stat has no aggregate cpu line")
        return None
    if system == "Darwin":
        text = _sysctl("kern.cp_time")
        if not text:
            return None
        try:
            values = [int(item) for item in text.replace(",", " ").split()]
        except ValueError:
            note("kern.cp_time is unparsable")
            return None
        if len(values) < 4:
            note("kern.cp_time returned too few fields")
            return None
        return sum(values), values[3]
    if system == "Windows":
        try:
            import ctypes
            from ctypes import wintypes

            class _FileTime(ctypes.Structure):
                _fields_ = [
                    ("dwLowDateTime", wintypes.DWORD),
                    ("dwHighDateTime", wintypes.DWORD),
                ]

            def _ticks(value):
                return (value.dwHighDateTime << 32) | value.dwLowDateTime

            idle = _FileTime()
            kernel = _FileTime()
            user = _FileTime()
            ok = ctypes.windll.kernel32.GetSystemTimes(
                ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)
            )
            if not ok:
                note("GetSystemTimes failed")
                return None
            # kernel time already includes idle time
            return _ticks(kernel) + _ticks(user), _ticks(idle)
        except (ImportError, AttributeError, OSError) as exc:
            note("windows cpu time query failed (%s)" % exc)
            return None
    note("cpu time source is not supported on %s" % (system or "unknown platform"))
    return None


def collect_cpu(interval):
    info = {
        "logical_cpus": os.cpu_count(),
        "load_average": None,
        "utilization_since_boot_percent": None,
        "utilization_percent": None,
        "sample_seconds": None,
    }
    affinity = getattr(os, "sched_getaffinity", None)
    if affinity is not None:
        try:
            info["affinity_cpus"] = len(affinity(0))
        except OSError as exc:
            note("sched_getaffinity failed (%s)" % exc)
    try:
        info["load_average"] = [round(value, 2) for value in os.getloadavg()]
    except (OSError, AttributeError):
        note("load average is unavailable on this platform")

    first = _cpu_times()
    if first is None:
        note("cpu utilization is unavailable: no cpu time counter")
        return info
    info["utilization_since_boot_percent"] = _percent(first[0] - first[1], first[0])

    if interval and interval > 0:
        time.sleep(interval)
        second = _cpu_times()
        if second is None:
            note("cpu utilization sample failed on the second read")
            return info
        delta_total = second[0] - first[0]
        delta_idle = second[1] - first[1]
        if delta_total <= 0:
            note("cpu utilization sample saw no elapsed ticks")
            return info
        info["utilization_percent"] = _percent(delta_total - delta_idle, delta_total)
        info["sample_seconds"] = round(interval, 3)
    return info


# --------------------------------------------------------------------------- #
# memory section
# --------------------------------------------------------------------------- #

def _memory_linux():
    text = _read_text("/proc/meminfo")
    if not text:
        return None
    values = {}
    for line in text.splitlines():
        key, sep, rest = line.partition(":")
        if not sep:
            continue
        fields = rest.split()
        if not fields or not fields[0].isdigit():
            continue
        values[key.strip()] = int(fields[0]) * 1024
    total = values.get("MemTotal")
    if not total:
        note("/proc/meminfo has no MemTotal")
        return None
    available = values.get("MemAvailable")
    if available is None:
        available = (
            values.get("MemFree", 0)
            + values.get("Buffers", 0)
            + values.get("Cached", 0)
        )
        note("MemAvailable missing; used free+buffers+cached instead")
    used = max(0, total - available)
    info = {
        "source": "/proc/meminfo",
        "total_bytes": total,
        "available_bytes": available,
        "used_bytes": used,
        "percent_used": _percent(used, total),
        "swap_total_bytes": values.get("SwapTotal"),
        "swap_free_bytes": values.get("SwapFree"),
    }
    return info


def _memory_darwin():
    total_text = _sysctl("hw.memsize")
    total = int(total_text) if _is_int(total_text) else None
    if total is None:
        note("hw.memsize is unavailable")
    vm_text = _run(["vm_stat"])
    if not vm_text:
        return None
    page_size = 4096
    match = re.search(r"page size of (\d+) bytes", vm_text)
    if match:
        page_size = int(match.group(1))
    counts = {}
    for line in vm_text.splitlines():
        key, sep, rest = line.partition(":")
        if not sep:
            continue
        rest = rest.strip().rstrip(".")
        if rest.isdigit():
            counts[key.strip()] = int(rest)
    used_pages = (
        counts.get("Pages active", 0)
        + counts.get("Pages wired down", 0)
        + counts.get("Pages occupied by compressor", 0)
    )
    available_pages = (
        counts.get("Pages free", 0)
        + counts.get("Pages inactive", 0)
        + counts.get("Pages speculative", 0)
    )
    used = used_pages * page_size
    available = available_pages * page_size
    info = {
        "source": "sysctl hw.memsize + vm_stat",
        "total_bytes": total,
        "available_bytes": available,
        "used_bytes": used,
        "percent_used": _percent(used, total),
        "swap_total_bytes": None,
        "swap_free_bytes": None,
    }
    swap_text = _sysctl("vm.swapusage")
    if swap_text:
        swap_total = re.search(r"total\s*=\s*([\d.]+\s*[KMGTP]?B?)", swap_text)
        swap_free = re.search(r"free\s*=\s*([\d.]+\s*[KMGTP]?B?)", swap_text)
        info["swap_total_bytes"] = _parse_size(swap_total.group(1)) if swap_total else None
        info["swap_free_bytes"] = _parse_size(swap_free.group(1)) if swap_free else None
    note("macOS memory figures are approximate: file cache is not attributed")
    return info


def _memory_windows():
    try:
        import ctypes
        from ctypes import wintypes

        class _MemoryStatusEx(ctypes.Structure):
            _fields_ = [
                ("dwLength", wintypes.DWORD),
                ("dwMemoryLoad", wintypes.DWORD),
                ("ullTotalPhys", ctypes.c_uint64),
                ("ullAvailPhys", ctypes.c_uint64),
                ("ullTotalPageFile", ctypes.c_uint64),
                ("ullAvailPageFile", ctypes.c_uint64),
                ("ullTotalVirtual", ctypes.c_uint64),
                ("ullAvailVirtual", ctypes.c_uint64),
                ("ullAvailExtendedVirtual", ctypes.c_uint64),
            ]

        status = _MemoryStatusEx()
        status.dwLength = ctypes.sizeof(_MemoryStatusEx)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            note("GlobalMemoryStatusEx failed")
            return None
    except (ImportError, AttributeError, OSError) as exc:
        note("windows memory query failed (%s)" % exc)
        return None
    total = int(status.ullTotalPhys)
    available = int(status.ullAvailPhys)
    used = max(0, total - available)
    return {
        "source": "GlobalMemoryStatusEx",
        "total_bytes": total,
        "available_bytes": available,
        "used_bytes": used,
        "percent_used": _percent(used, total),
        "swap_total_bytes": int(status.ullTotalPageFile),
        "swap_free_bytes": int(status.ullAvailPageFile),
    }


def collect_memory():
    system = platform.system()
    if system == "Linux":
        return _memory_linux()
    if system == "Darwin":
        return _memory_darwin()
    if system == "Windows":
        return _memory_windows()
    note("memory collection is not supported on %s" % (system or "unknown platform"))
    return None


# --------------------------------------------------------------------------- #
# disk section
# --------------------------------------------------------------------------- #

def default_disk_paths():
    system = platform.system()
    home = os.path.expanduser("~")
    if system == "Windows":
        drive = os.environ.get("SystemDrive", "") or "C:"
        paths = [drive.rstrip("\\") + "\\"]
    else:
        paths = ["/"]
    if home and home not in paths:
        paths.append(home)
    return paths


def collect_disk(paths):
    results = []
    seen = set()
    for raw in paths:
        path = os.path.abspath(os.path.expanduser(raw))
        if path in seen:
            continue
        seen.add(path)
        try:
            usage = shutil.disk_usage(path)
        except OSError as exc:
            note("disk usage failed for %s (%s)" % (path, exc))
            continue
        results.append(
            {
                "path": path,
                "total_bytes": usage.total,
                "used_bytes": usage.used,
                "free_bytes": usage.free,
                "percent_used": _percent(usage.used, usage.total),
            }
        )
    if not results:
        note("no disk path could be measured")
    return results


# --------------------------------------------------------------------------- #
# network section
# --------------------------------------------------------------------------- #

def _route_address(family, probe):
    """Local address selected for `probe`; connecting a UDP socket sends nothing."""
    try:
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.settimeout(0.2)
            sock.connect(probe)
            return sock.getsockname()[0]
    except OSError:
        return None


def collect_network():
    info = {
        "hostname": platform.node() or None,
        "primary_ipv4": _route_address(socket.AF_INET, ("198.51.100.1", 9)),
        "primary_ipv6": None,
        "interfaces": None,
    }
    if socket.has_ipv6:
        info["primary_ipv6"] = _route_address(socket.AF_INET6, ("2001:db8::1", 9))
    try:
        info["interfaces"] = sorted(name for _, name in socket.if_nameindex())
    except (AttributeError, OSError) as exc:
        note("interface enumeration is unavailable (%s)" % type(exc).__name__)
    return info


# --------------------------------------------------------------------------- #
# rendering
# --------------------------------------------------------------------------- #

def _fmt_bytes(value):
    if value is None:
        return "-"
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    amount = float(value)
    index = 0
    while amount >= 1024 and index < len(units) - 1:
        amount /= 1024.0
        index += 1
    return ("%.0f %s" if index == 0 else "%.1f %s") % (amount, units[index])


def _fmt_value(key, value):
    if value is None:
        return "-"
    if key.endswith("_bytes"):
        return _fmt_bytes(value)
    if "percent" in key:
        try:
            return "%.1f%%" % float(value)
        except (TypeError, ValueError):
            return str(value)
    if isinstance(value, (list, tuple)):
        return " ".join(str(item) for item in value)
    return str(value)


def render_text(doc):
    lines = [
        "generated_at: %s" % doc["generated_at"],
        "schema_version: %s" % doc["schema_version"],
    ]
    for section in ("os", "cpu", "memory", "network"):
        data = doc.get(section)
        lines.append("")
        lines.append("[%s]" % section)
        if not data:
            lines.append("  (not collected)")
            continue
        for key in sorted(data):
            lines.append("  %-32s %s" % (key, _fmt_value(key, data[key])))
    lines.append("")
    lines.append("[disk]")
    disks = doc.get("disk") or []
    if not disks:
        lines.append("  (not collected)")
    for item in disks:
        lines.append(
            "  %s: %s total, %s used, %s free (%s)"
            % (
                item["path"],
                _fmt_bytes(item["total_bytes"]),
                _fmt_bytes(item["used_bytes"]),
                _fmt_bytes(item["free_bytes"]),
                _fmt_value("percent_used", item.get("percent_used")),
            )
        )
    if doc.get("notes"):
        lines.append("")
        lines.append("[notes]")
        for message in doc["notes"]:
            lines.append("  - %s" % message)
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# entrypoint
# --------------------------------------------------------------------------- #

def build_document(args, sections):
    handlers = {
        "os": collect_os,
        "cpu": lambda: collect_cpu(args.interval),
        "memory": collect_memory,
        "disk": lambda: collect_disk(args.disk_path or default_disk_paths()),
        "network": collect_network,
    }
    doc = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": _utc_now(),
        "os": None,
        "cpu": None,
        "memory": None,
        "disk": [],
        "network": None,
        "notes": [],
    }
    collected = 0
    for section in sections:
        try:
            value = handlers[section]()
        except Exception as exc:  # one broken section must not hide the rest
            note("section %s failed: %s: %s" % (section, type(exc).__name__, exc))
            value = [] if section == "disk" else None
        doc[section] = value
        if value:
            collected += 1
    doc["notes"] = list(_notes)
    return doc, collected


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Report host system status (read-only, stdlib only, cross-platform)."
    )
    parser.add_argument(
        "--section",
        action="append",
        choices=SECTIONS,
        help="collect only this section (repeatable); default: all sections",
    )
    parser.add_argument("--json", action="store_true", help="emit one line of JSON")
    parser.add_argument(
        "--pretty", action="store_true", help="indent JSON output (implies --json)"
    )
    parser.add_argument(
        "--disk-path",
        action="append",
        default=None,
        metavar="PATH",
        help="measure this path instead of the defaults (repeatable)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=0.5,
        metavar="SEC",
        help="CPU sampling window in seconds, 0 disables the delta sample (default: 0.5)",
    )
    parser.add_argument(
        "--no-network", action="store_true", help="skip the network section"
    )
    args = parser.parse_args(argv)

    if args.interval < 0:
        parser.error("--interval must be >= 0")

    sections = list(SECTIONS)
    if args.section:
        sections = []
        for name in args.section:
            if name not in sections:
                sections.append(name)
    if args.no_network and "network" in sections:
        sections.remove("network")

    doc, collected = build_document(args, sections)
    if collected == 0:
        for message in doc["notes"]:
            print("note: %s" % message, file=sys.stderr)
        print("error: no section could be collected on this platform", file=sys.stderr)
        return 1

    if args.json or args.pretty:
        text = json.dumps(
            doc,
            sort_keys=True,
            ensure_ascii=False,
            indent=2 if args.pretty else None,
            separators=None if args.pretty else (",", ":"),
        )
    else:
        text = render_text(doc)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
