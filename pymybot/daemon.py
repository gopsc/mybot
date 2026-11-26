"""Portable daemon workers and the primitive-only Lua slot bridge.

LuaState must recursively convert globals() and bridge() results to Lua values,
and bridge arguments back to Python values. Inject __daemon_call as a Lua
closure, not a Python object visible to Lua. Runtime creation, load, call and
close belong exclusively to the worker thread. No pointer or native mutex ABI
is involved; slot IDs are capabilities scoped to the daemon and its peers.
"""
from __future__ import annotations

import itertools
import math
import re
import threading
import time
from pathlib import Path, PurePosixPath

from .errors import BudgetExceeded, DriverError, ScriptError

SLOT_MAXVALS = 64
SLOT_CAPACITY_LIMIT = 1024
MAX_INTERVAL_MS = 3_600_000
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*\Z")
_INTEGER = re.compile(r"[+-]?[0-9]+\Z")
_ids = itertools.count(1)
_id_lock = threading.Lock()


def _integer(value, label, low, high):
    if isinstance(value, bool) or not _INTEGER.fullmatch(str(value)):
        raise ScriptError(f"Daemon {label} must be an integer")
    try:
        number = int(value)
    except (ValueError, OverflowError) as exc:
        raise ScriptError(f"Daemon {label} is out of range") from exc
    if not low <= number <= high:
        raise ScriptError(f"Daemon {label} must be in {low}..{high}")
    return number


def _fields(value, capacity, separator=r"[,|]"):
    fields = re.split(separator, value)
    for field in fields:
        name, colon, mode = field.partition(":")
        if not name or any(c.isspace() for c in name) or mode not in {"", "f", "float", "s16"}:
            raise ScriptError(f"Daemon fields: invalid field or mode {field!r}")
    if len(fields) > capacity:
        raise ScriptError(f"Daemon field count {len(fields)} exceeds maxvals {capacity}")
    return len(fields)


def validate_config(config: dict):
    """Validate without opening a runtime or hardware; return normalized strings.

    Values may contain '=' (not ';' or NUL), notably multi-device @key=value
    parameters. A '-' is the matrix's unspecified-value marker.
    """
    if not isinstance(config, dict):
        raise ScriptError("Daemon config must be a dictionary")
    result = {}
    for key, value in config.items():
        if not isinstance(key, str) or not _IDENT.fullmatch(key):
            raise ScriptError(f"Invalid daemon config key {key!r}")
        if isinstance(value, bool) or not isinstance(value, (str, int, float)):
            raise ScriptError(f"Daemon {key} must be a string or number")
        value = str(value)
        if "\x00" in value or ";" in value:
            raise ScriptError(f"Daemon {key} contains NUL or ';', corrupting DAEMON_CONFIG")
        if value != "-":
            result[key] = value
    chunk = result.get("chunk", "")
    parts = PurePosixPath(chunk)
    if not chunk or parts.is_absolute() or ".." in parts.parts or "\\" in chunk or ":" in chunk:
        raise ScriptError("Daemon chunk must be a module-relative path without traversal")
    capacity = _integer(result.get("maxvals", "64"), "maxvals", 1, SLOT_CAPACITY_LIMIT)
    _integer(result.get("interval", "5"), "interval", 1, MAX_INTERVAL_MS)
    if "proto" in result and result["proto"] not in {"virt", "i2c", "spi", "uart"}:
        raise ScriptError("Daemon proto must be i2c, spi, uart or virt")
    if "sign" in result:
        _integer(result["sign"], "sign", -(2**63), 2**63 - 1)
    if "kind" in result and result["kind"] not in {"imu", "odom"}:
        raise ScriptError("Daemon kind must be imu or odom")
    for key, low, high in (("mode", 0, 3), ("bits", 1, 32), ("speed", 1, 2**32 - 1),
                           ("delay", 0, 65535), ("baud", 1, 2**31 - 1)):
        if key in result:
            _integer(result[key], key, low, high)
    if "driver" in result and not _IDENT.fullmatch(result["driver"]):
        raise ScriptError("Daemon driver must be a module name")
    if "fields" in result:
        _fields(result["fields"], capacity)
    if "sources" in result:
        sources = [s.strip() for s in re.split(r"[,|]", result["sources"])]
        if any(not _IDENT.fullmatch(s) for s in sources):
            raise ScriptError("Daemon sources contains an empty or invalid name")
        if len(set(sources)) != len(sources) or result.get("name") in sources:
            raise ScriptError("Daemon sources contains duplicate names or a self reference")
        result["sources"] = "|".join(sources)
    if "devices" in result:
        if result.get("proto", "i2c") not in {"i2c", "virt"}:
            raise ScriptError("Multi-device daemon requires proto=i2c or virt")
        count = 0
        for device in result["devices"].split("|"):
            items = device.split("@")
            if len(items) < 3 or not _IDENT.fullmatch(items[0]):
                raise ScriptError("Daemon devices must contain driver@addr@fields")
            address = items[1]
            if not re.fullmatch(r"(?:0[xX][0-9a-fA-F]+|[0-9]+)", address):
                raise ScriptError("Daemon devices has an invalid I2C address")
            if not 0 <= int(address, 16 if address.lower().startswith("0x") else 10) <= 127:
                raise ScriptError("Daemon devices I2C address must be in 0..127")
            count += _fields(items[2], capacity, ",")
            for extra in items[3:]:
                key, sep, value = extra.partition("=")
                if not sep or not _IDENT.fullmatch(key):
                    raise ScriptError("Daemon devices extra parameter must be key=value")
        if count > capacity:
            raise ScriptError(f"Daemon total field count {count} exceeds maxvals {capacity}")
    filename = parts.name
    if filename == "sensor_daemon.lua" and (not result.get("driver") or not result.get("fields")):
        raise ScriptError("sensor_daemon requires driver and fields")
    if filename == "sensor_daemon_multi.lua" and not result.get("devices"):
        raise ScriptError("sensor_daemon_multi requires devices")
    if filename == "sensor_aggregate.lua" and not result.get("sources"):
        raise ScriptError("sensor_aggregate requires sources")
    return result


class Slot:
    """A Python-owned latest-sample slot; all mutable state uses one condition."""

    def __init__(self, capacity=SLOT_MAXVALS):
        self.capacity = _integer(capacity, "capacity", 1, SLOT_CAPACITY_LIMIT)
        with _id_lock:
            self.id = next(_ids)
        if self.id >= 2**53:
            raise DriverError("Daemon slot ID space exhausted")
        self.condition = threading.Condition(threading.RLock())
        self.count = 0
        self.values = ()
        self.status = 0
        self.stop = False
        self.quiesce = False
        self.error = ""

    def snapshot(self):
        with self.condition:
            return {"count": self.count, "nvals": len(self.values), "values": list(self.values),
                    "capacity": self.capacity, "status": self.status, "stop": int(self.stop),
                    "quiesce": int(self.quiesce)}

    def publish(self, values):
        if isinstance(values, dict):
            if set(values) != set(range(1, len(values) + 1)):
                raise DriverError("Daemon publish requires a dense numeric array")
            values = [values[i] for i in range(1, len(values) + 1)]
        if not isinstance(values, (list, tuple)):
            raise DriverError("Daemon publish requires an array")
        converted = []
        for value in values[:self.capacity]:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise DriverError("Daemon publish values must be finite numbers")
            try:
                value = float(value)
            except OverflowError as exc:
                raise DriverError("Daemon publish value overflows double") from exc
            if not math.isfinite(value):
                raise DriverError("Daemon publish values must be finite numbers")
            converted.append(value)
        with self.condition:
            # A failed slot can never be revived by another sample/status reset.
            if self.stop or self.quiesce:
                return False
            if self.status < 0 and converted:
                raise DriverError(f"Daemon slot permanently failed (status {self.status})")
            self.values = tuple(converted)
            self.count = (self.count + 1) % 0x7FFFFFFF
            self.condition.notify_all()
        return True

    def fail(self, code=-1, message=""):
        code = _integer(code, "status", -(2**31), 0)
        with self.condition:
            if self.status >= 0:
                self.status = code
                if message:
                    self.error = str(message)
            self.condition.notify_all()

    def request_stop(self):
        with self.condition:
            self.stop = True
            self.condition.notify_all()

    def set_quiesced(self):
        with self.condition:
            self.quiesce = True
            self.condition.notify_all()


class _WorkerBudget:
    def __init__(self, daemon, cleanup=False):
        self.daemon = daemon
        self.cleanup = cleanup

    def check(self):
        if self.daemon.quiesced or (not self.cleanup and self.daemon.stopping):
            raise BudgetExceeded("Daemon stop requested" if not self.cleanup else "Daemon teardown expired")


class DaemonVariable:
    kind = "daemon"
    # Bounded independently of the sampling interval (which can be one hour).
    destroy_timeout = 2.0

    def __init__(self, name, config, registry, runtime_factory, stop_event):
        if not isinstance(name, str) or not _IDENT.fullmatch(name):
            raise ScriptError(f"Invalid daemon name {name!r}")
        self.name = name
        self.config = validate_config(dict(config, name=name))
        self.registry = registry
        self.runtime_factory = runtime_factory
        self.stop_event = stop_event if stop_event is not None else threading.Event()
        self.interval_ms = int(self.config.get("interval", 5))
        self.slot = Slot(int(self.config.get("maxvals", SLOT_MAXVALS)))
        self.peers = {}
        # Resolve once, before any build. Retain strong references even after
        # hot removal; never look up a replacement daemon with the same name.
        previous = []
        for variable in registry.values():
            if variable.name == name:
                break
            previous.append(variable)
        for source in self.config.get("sources", "").split("|"):
            if not source:
                continue
            peer = registry.get(source)
            if source == name or peer not in previous or not isinstance(peer, DaemonVariable):
                raise ScriptError(f"Daemon source '{source}' must name a previously declared daemon")
            self.peers[source] = peer
        self._slots = {self.slot.id: self.slot, **{p.slot.id: p.slot for p in self.peers.values()}}
        self._owned_slots = {self.slot.id}
        self._lifecycle = threading.RLock()
        self._thread = None
        self._ready = threading.Event()
        self._done = threading.Event()
        self._destroyed = False
        self._teardown_deadline = None
        self._cleaning_up = False

    @property
    def stopping(self):
        if self.stop_event.is_set():
            self.slot.request_stop()
        with self.slot.condition:
            return self.slot.stop

    @property
    def cleaning_up(self):
        with self._lifecycle:
            return self._cleaning_up

    @property
    def quiesced(self):
        with self._lifecycle:
            deadline = self._teardown_deadline
        if deadline is not None and not self._done.is_set() and time.monotonic() >= deadline:
            self.slot.set_quiesced()
        with self.slot.condition:
            return self.slot.quiesce

    def globals(self):
        return {"DAEMON_SLOT_ADDR": self.slot.id,
                "DAEMON_CONFIG": ";".join(f"{k}={v}" for k, v in self.config.items()
                                          if k not in {"name", "chunk"}),
                "DAEMON_SLOT_LAYOUT": {"protocol": "python-slots-v1", "maxvals": self.slot.capacity},
                "DAEMON_PEER_SLOTS": {name: peer.slot.id for name, peer in self.peers.items()}}

    def bridge(self, operation, *args):
        """Operations used by pthread.lua; return only scalars/lists/dictionaries.

        slot_new(capacity) -> ID; capacity/get_status/should_stop/quiesced(ID)
        -> scalar; read_sample(ID) -> snapshot dict; publish(ID, numeric array),
        set_status(ID, code), signal_stop(ID), quiesce(ID), init_slot(ID) -> bool.
        Peer slots are read-only. IDs are validated, never dereferenced.
        """
        if operation == "slot_new":
            if len(args) != 1:
                raise DriverError("slot_new expects a capacity")
            slot = Slot(args[0])
            with self._lifecycle:
                if len(self._owned_slots) >= SLOT_CAPACITY_LIMIT:
                    raise DriverError("Too many daemon-owned slots")
                self._slots[slot.id] = slot
                self._owned_slots.add(slot.id)
            return slot.id
        arity = {"capacity": 1, "get_status": 1, "should_stop": 1, "quiesced": 1,
                 "read_sample": 1, "publish": 2, "set_status": 2, "signal_stop": 1,
                 "quiesce": 1, "init_slot": 1}
        if operation not in arity or len(args) != arity[operation]:
            raise DriverError(f"Unknown daemon operation or wrong argument count: {operation!r}")
        ident = args[0]
        if isinstance(ident, bool) or not isinstance(ident, (int, float)) or not 0 < ident < 2**53 or ident % 1:
            raise DriverError("Daemon slot ID must be a positive exact integer")
        with self._lifecycle:
            slot = self._slots.get(ident)
            owned = ident in self._owned_slots
        if slot is None:
            raise DriverError("Unknown or unauthorized daemon slot ID")
        if operation in {"publish", "set_status", "signal_stop", "quiesce", "init_slot"} and not owned:
            raise DriverError("Daemon peer slots are read-only")
        if operation == "capacity":
            return slot.capacity
        if operation == "get_status":
            return slot.snapshot()["status"]
        if operation == "should_stop":
            if slot is self.slot:
                return self.stopping
            return bool(slot.snapshot()["stop"])
        if operation == "quiesced":
            return self.quiesced if slot is self.slot else bool(slot.snapshot()["quiesce"])
        if operation == "read_sample":
            snapshot = slot.snapshot()
            if snapshot["stop"] or snapshot["quiesce"] or snapshot["status"] < 0:
                raise DriverError("Daemon slot stopped or failed; refusing stale snapshot")
            return snapshot
        if operation == "publish":
            return slot.publish(args[1])
        if operation == "set_status":
            slot.fail(args[1])
        elif operation == "signal_stop":
            slot.request_stop()
        elif operation == "quiesce":
            slot.set_quiesced()
        # Slots are initialized on allocation. init_slot never resets stop/status.
        return True

    def build(self):
        with self._lifecycle:
            if self._destroyed or self.stopping:
                raise DriverError(f"Daemon '{self.name}' is stopped")
            if self._thread is not None:
                return
            self._thread = threading.Thread(target=self._run, name=f"daemon:{self.name}", daemon=True)
            try:
                self._thread.start()
            except BaseException as exc:
                self._thread = None
                self.slot.fail(-1, f"cannot start worker: {exc}")
                self.request_stop()
                self._done.set()
                raise

    def _wait_interval(self):
        deadline = time.monotonic() + self.interval_ms / 1000
        with self.slot.condition:
            while not self.stopping and self.slot.status >= 0:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return
                self.slot.condition.wait(min(remaining, 0.05))

    def _run(self):
        runtime = None
        try:
            if self.stopping:
                return
            runtime = self.runtime_factory(daemon=self)
            # Use the same trusted module resolver as dofile inside the chunk.
            # A small fake runtime can omit __mpath and accept a relative Path.
            chunk = self.config["chunk"]
            globals_table = getattr(runtime, "globals", {})
            resolver = globals_table["__mpath"] if "__mpath" in globals_table else None
            if resolver is not None:
                chunk = resolver["resolve"](chunk)
            runtime.load(Path(chunk))
            if not runtime.has_function("daemon_tick"):
                raise DriverError("Daemon chunk must define daemon_tick()")
            self._ready.set()
            budget = _WorkerBudget(self)
            while not self.stopping:
                if self.slot.snapshot()["status"] < 0:
                    break
                budget.check()
                runtime.call("daemon_tick", budget=budget)
                self._wait_interval()
        except BaseException as exc:
            if not (isinstance(exc, BudgetExceeded) and self.stopping):
                self.slot.fail(-1, str(exc))
        finally:
            self._ready.set()
            # Worker exit means peers must not keep using the final snapshot.
            self.request_stop()
            with self._lifecycle:
                self._cleaning_up = True
            try:
                if runtime is not None:
                    if not self.quiesced and runtime.has_function("daemon_cleanup"):
                        runtime.call("daemon_cleanup", budget=_WorkerBudget(self, cleanup=True))
            except BaseException as exc:
                self.slot.fail(-1, f"cleanup: {exc}")
            finally:
                if runtime is not None:
                    try:
                        runtime.close()
                    except BaseException as exc:
                        self.slot.fail(-1, f"close: {exc}")
                with self._lifecycle:
                    self._cleaning_up = False
                self._done.set()

    def read(self):
        self.stopping  # Observe a controller-wide stop even during a long tick.
        with self.slot.condition:
            if self.slot.status < 0:
                raise DriverError(f"Daemon '{self.name}' permanently failed (status {self.slot.status}): {self.slot.error}")
            if self.slot.stop or self.slot.quiesce or self._destroyed:
                raise DriverError(f"Daemon '{self.name}' stopped; refusing stale snapshot")
            if self._thread is None:
                raise DriverError(f"Daemon '{self.name}' is not built")
            snapshot = self.slot.snapshot()
        values = snapshot["values"]
        return {"result": "OK", "status": "OK", "count": snapshot["count"],
                "nvals": len(values), "values": values,
                **{f"v{i}": value for i, value in enumerate(values)}}

    def play(self, params):
        return self.read()

    def wait_for_sample(self, after=0, timeout=1.0):
        """Wait for a changed count (including wraparound), stop, failure or timeout."""
        if not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout < 0:
            raise ValueError("timeout must be a finite nonnegative number")
        deadline = time.monotonic() + timeout
        with self.slot.condition:
            while True:
                snapshot = self.read()
                if snapshot["count"] != after:
                    return snapshot
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"Daemon '{self.name}' has no new sample")
                self.slot.condition.wait(min(remaining, 0.05))

    def request_stop(self, deadline=None):
        if deadline is not None:
            with self._lifecycle:
                if self._teardown_deadline is None or deadline < self._teardown_deadline:
                    self._teardown_deadline = deadline
        self.slot.request_stop()

    def destroy(self):
        self.request_stop()
        with self._lifecycle:
            self._destroyed = True
            if self._teardown_deadline is None:
                self._teardown_deadline = time.monotonic() + self.destroy_timeout
            deadline = self._teardown_deadline
            worker = self._thread
        if worker is None:
            self._done.set()
            return
        if worker is threading.current_thread():
            return
        worker.join(max(0, deadline - time.monotonic()))
        if worker.is_alive():
            self.slot.set_quiesced()
            raise DriverError(f"Daemon '{self.name}' teardown timed out; worker quiesced, runtime retained until worker exits")
