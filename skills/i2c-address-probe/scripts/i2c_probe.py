#!/usr/bin/env python3
"""Read-only I2C slave address prober for Linux i2c-dev buses.

Probe method: bind the slave address with I2C_SLAVE, then perform a single
SMBus "read byte" transaction (falls back to one plain I2C read on adapters
that do not implement SMBus). No data byte is ever written, so this is not
equivalent to `i2cdetect` quick-write mode (-q / default without -r).

Exit codes
  0  scan completed (zero hits still exits 0)
  1  internal error
  2  bad arguments (including an out-of-range address range)
  3  cannot open the bus (permissions, missing node, no python3)
  4  transactions ran but every one failed with a non-NACK error
"""

import argparse
import array
import errno
import fcntl
import glob
import json
import os
import re
import struct
import sys
import time

I2C_SLAVE = 0x0703
I2C_SMBUS = 0x0720
I2C_SMBUS_READ = 1
I2C_SMBUS_BYTE = 1

ADDR_MIN = 0x08
ADDR_MAX = 0x77

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_ARGS = 2
EXIT_NOBUS = 3
EXIT_DEADBUS = 4


def eprint(*args):
    print(*args, file=sys.stderr)


# ---------------------------------------------------------------- argument parsing

def parse_addr(text):
    try:
        value = int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "not a number: %r (use 0x48 or 72)" % text)
    if not ADDR_MIN <= value <= ADDR_MAX:
        raise argparse.ArgumentTypeError(
            "address 0x%02x out of range 0x%02x-0x%02x; this tool refuses to "
            "probe broadcast/10-bit reserved addresses" % (value, ADDR_MIN, ADDR_MAX))
    return value


def parse_range(text):
    parts = re.split(r"[-:]", text.strip())
    if len(parts) != 2:
        raise argparse.ArgumentTypeError(
            "range must look like 0x40-0x4f, got %r" % text)
    try:
        lo, hi = int(parts[0], 0), int(parts[1], 0)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "range bounds must be numbers, got %r" % text)
    if not ADDR_MIN <= lo <= ADDR_MAX or not ADDR_MIN <= hi <= ADDR_MAX:
        raise argparse.ArgumentTypeError(
            "range 0x%02x-0x%02x leaves 0x%02x-0x%02x; refusing to scan "
            "broadcast/10-bit reserved addresses" % (lo, hi, ADDR_MIN, ADDR_MAX))
    if lo > hi:
        raise argparse.ArgumentTypeError(
            "range start 0x%02x is above end 0x%02x (no silent swap)" % (lo, hi))
    return lo, hi


def parse_bus(text):
    """Accept 1, i2c-1 or /dev/i2c-1."""
    raw = text.strip()
    match = re.fullmatch(r"(?:/dev/)?i2c-(\d+)", raw)
    if match:
        return "/dev/i2c-%s" % match.group(1)
    if raw.isdigit():
        return "/dev/i2c-%s" % raw
    if raw.startswith("/dev/"):
        return raw
    raise argparse.ArgumentTypeError(
        "bus must be 1, i2c-1 or /dev/i2c-1, got %r" % text)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="i2c_probe.py",
        description="Read-only I2C address prober (0x08-0x77). Never writes a data byte.",
        epilog="Zero hits plus NACKs usually means wiring/power/address jumpers, "
               "not a broken adapter. Exit 0 only means 'the scan finished'.")
    parser.add_argument("--bus", type=parse_bus, help="bus: 1, i2c-1 or /dev/i2c-1")
    parser.add_argument("--list-buses", action="store_true",
                        help="print available /dev/i2c-* nodes and exit")
    parser.add_argument("--addr", type=parse_addr, action="append", metavar="ADDR",
                        help="probe only this address (repeatable), overrides --range")
    parser.add_argument("--range", type=parse_range, default=(ADDR_MIN, ADDR_MAX),
                        metavar="LO-HI", help="address range, default 0x08-0x77")
    parser.add_argument("--repeat", type=int, default=1, metavar="N",
                        help="probe each address N times to detect flapping (default 1)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--no-sysfs", action="store_true",
                        help="skip /sys bound-driver lookup (fewer reads, same probe)")
    return parser


# ---------------------------------------------------------------- bus handling

def list_buses():
    def key(path):
        tail = path.rsplit("-", 1)[-1]
        return (0, int(tail)) if tail.isdigit() else (1, path)

    return sorted(glob.glob("/dev/i2c-*"), key=key)


def bus_id_of(path):
    tail = os.path.basename(path).rsplit("-", 1)[-1]
    return int(tail) if tail.isdigit() else None


def open_bus(path):
    try:
        # i2c-dev requires O_RDWR even for read-only transfers.
        return os.open(path, os.O_RDWR)
    except OSError as exc:
        eprint("cannot open %s: %s" % (path, exc.strerror or exc))
        if exc.errno in (errno.EACCES, errno.EPERM):
            eprint("hint: /dev/i2c-%s needs root or membership in the 'i2c' group"
                   % (bus_id_of(path) or "N"))
        elif exc.errno == errno.ENOENT:
            eprint("hint: bus node missing; check `ls /dev/i2c-*` and that the "
                   "adapter/overlay is loaded")
        return None


# ---------------------------------------------------------------- probe primitives

def _smbus_read_byte(fd):
    """SMBus read byte: no command, no data written by us."""
    data = array.array("B", [0] * 34)
    msg = struct.pack("@BBIP", I2C_SMBUS_READ, 0, I2C_SMBUS_BYTE,
                      data.buffer_info()[0])
    fcntl.ioctl(fd, I2C_SMBUS, msg)
    return data[0]


def _plain_read_byte(fd):
    """Single-byte plain I2C read, for adapters without SMBus emulation."""
    chunk = os.read(fd, 1)
    if not chunk:
        raise OSError(errno.EREMOTEIO, "no byte returned")
    return chunk[0]


def probe_one(fd, addr):
    """Return (status, detail). status: 'ok' | 'nack' | 'bound' | 'error'."""
    try:
        fcntl.ioctl(fd, I2C_SLAVE, addr)
    except OSError as exc:
        if exc.errno == errno.EBUSY:
            return "bound", "EBUSY"
        return "error", "set_slave_errno_%d" % exc.errno

    for read in (_smbus_read_byte, _plain_read_byte):
        try:
            return "ok", "read:%02X" % read(fd)
        except OSError as exc:
            code = exc.errno
            if code in (errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP):
                continue  # adapter lacks SMBus, try the next strategy
            if code in (errno.EREMOTEIO, errno.ENXIO, errno.ENODEV):
                return "nack", "nack"
            return "error", "errno_%d" % code
    return "error", "no_read_strategy"


def sysfs_bound_name(bus_id, addr):
    if bus_id is None:
        return None
    path = "/sys/bus/i2c/devices/%d-%04x/name" % (bus_id, addr)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            name = handle.read().strip()
        return name or None
    except OSError:
        return None


# ---------------------------------------------------------------- scan

def scan(fd, addresses, repeat, bus_id, use_sysfs):
    results = {}
    for addr in addresses:
        seen = []
        detail = None
        bound = None
        for attempt in range(repeat):
            if attempt:
                time.sleep(0.005)  # let a marginal bus settle between passes
            status, info = probe_one(fd, addr)
            if status == "bound" and use_sysfs:
                bound = sysfs_bound_name(bus_id, addr) or "bound"
            seen.append(status)
            if detail is None or status != "ok":
                detail = info
            if status in ("bound", "error") and repeat == 1:
                break

        if "bound" in seen:
            results[addr] = {"state": "bound", "detail": "EBUSY", "name": bound}
        elif all(s == "ok" for s in seen):
            results[addr] = {"state": "ok", "detail": detail}
        elif all(s == "nack" for s in seen):
            results[addr] = {"state": "nack", "detail": "nack"}
        elif any(s == "ok" for s in seen):
            results[addr] = {"state": "unstable", "detail": detail}
        elif "error" in seen:
            results[addr] = {"state": "error", "detail": detail}
        else:
            results[addr] = {"state": "nack", "detail": "nack"}
    return results


# ---------------------------------------------------------------- rendering

CELL = {
    "nack": "--",
    "bound": "UU",
    "unstable": "??",
    "error": "EE",
}


def render_grid(bus_path, lo, hi, results, repeat, probed):
    lines = []
    lines.append("bus: %s   range: 0x%02x-0x%02x   probed: %d x %d"
                 % (bus_path, lo, hi, probed, repeat))
    lines.append("      " + "".join("%2x " % col for col in range(16)).rstrip())
    for row in range(lo & 0xF0, (hi & 0xF0) + 0x10, 0x10):
        cells = []
        for col in range(16):
            addr = row + col
            if not lo <= addr <= hi:
                cells.append("   ")
                continue
            entry = results[addr]
            state = entry["state"]
            if state == "ok":
                cells.append("%2s " % entry["detail"].split(":")[-1].lower())
            else:
                cells.append("%2s " % CELL.get(state, "EE"))
        # 6-char prefix keeps columns aligned with the header digits
        lines.append("%02x:   " % row + "".join(cells).rstrip())
    lines.append("legend: XX=read value  --=NACK  UU=kernel driver bound  "
                 "??=flapping  EE=error  blank=out of range")
    return "\n".join(lines)


def summarize(results, repeat):
    found = sorted(a for a, e in results.items() if e["state"] == "ok")
    unstable = sorted(a for a, e in results.items() if e["state"] == "unstable")
    bound = {("0x%02x" % a): (e.get("name") or "bound")
             for a, e in sorted(results.items()) if e["state"] == "bound"}
    failed = {}
    for entry in results.values():
        if entry["state"] in ("nack", "error"):
            failed[entry["detail"]] = failed.get(entry["detail"], 0) + 1
    return found, unstable, bound, failed


def emit_json(bus_path, lo, hi, results, repeat, probed, exit_code):
    found, unstable, bound, failed = summarize(results, repeat)
    payload = {
        "bus": bus_path,
        "bus_id": bus_id_of(bus_path),
        "range": "0x%02x-0x%02x" % (lo, hi),
        "probed": probed,
        "repeat": repeat,
        "count": len(found),
        "found": ["0x%02x" % a for a in found],
        "acks": {("0x%02x" % a): e["detail"] for a, e in sorted(results.items())
                 if e["state"] == "ok"},
        "unstable": ["0x%02x" % a for a in unstable],
        "bound": bound,
        "failed": failed,
        "exit_code": exit_code,
    }
    print(json.dumps(payload, sort_keys=False))


# ---------------------------------------------------------------- main

def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.list_buses:
        buses = list_buses()
        if args.json:
            print(json.dumps({"buses": buses, "count": len(buses)}))
        else:
            for path in buses:
                print(path)
            if not buses:
                eprint("no /dev/i2c-* nodes found")
        return EXIT_OK

    if not args.bus:
        parser.error("--bus is required (or use --list-buses)")
    if args.repeat < 1:
        parser.error("--repeat must be >= 1")

    if args.addr:
        addresses = sorted(set(args.addr))
        lo, hi = addresses[0], addresses[-1]
        exact = True
    else:
        lo, hi = args.range
        addresses = list(range(lo, hi + 1))
        exact = False

    fd = open_bus(args.bus)
    if fd is None:
        return EXIT_NOBUS

    try:
        results = scan(fd, addresses, args.repeat, bus_id_of(args.bus),
                       not args.no_sysfs)
    finally:
        os.close(fd)

    found, unstable, bound, failed = summarize(results, args.repeat)
    error_only = (not found and not unstable
                  and failed.get("nack", 0) == 0
                  and sum(failed.values()) > 0)
    exit_code = EXIT_DEADBUS if error_only else EXIT_OK

    if args.json:
        emit_json(args.bus, lo, hi, results, args.repeat, len(addresses), exit_code)
    else:
        if exact:
            print("bus: %s   addresses: %s   probed: %d x %d" % (
                args.bus, " ".join("0x%02x" % a for a in addresses),
                len(addresses), args.repeat))
            for addr in addresses:
                entry = results[addr]
                extra = (" (%s)" % entry["name"]) if entry.get("name") else ""
                print("0x%02x: %s %s%s" % (addr, entry["state"],
                                           entry["detail"], extra))
        else:
            print(render_grid(args.bus, lo, hi, results, args.repeat,
                              len(addresses)))
        print("found: %d%s" % (len(found),
                               ("".join(" 0x%02x" % a for a in found)
                                if found else "")))
        if bound:
            print("kernel-bound: " + " ".join(
                "0x%s=%s" % (k[2:], v) for k, v in bound.items()))
        if unstable:
            print("unstable: " + " ".join("0x%02x" % a for a in unstable))
        if failed:
            print("failed: " + "  ".join("%s=%d" % (k, v)
                                         for k, v in sorted(failed.items())))
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        eprint("interrupted")
        sys.exit(EXIT_INTERNAL)
    except Exception as exc:  # never hide a traceback behind exit 0
        eprint("internal error: %s: %s" % (type(exc).__name__, exc))
        sys.exit(EXIT_INTERNAL)
