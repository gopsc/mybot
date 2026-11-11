"""I2C bus scanner driver.

Opens an I2C bus and scans the 7-bit address space for devices that ACK.
Each call probes every address in the configured range via a one-byte read
and reports which addresses responded.

SQL example::

    CREATE TABLE I2C_scan (name String, path String);
    INSERT INTO I2C_scan (name, path) VALUES ('scan0', '/dev/i2c-1');

MT example::

    @Action
    scan0.go;
       1  ;
    @
"""

from __future__ import annotations

_DEFAULT_START = 0x08
_DEFAULT_END = 0x77


def _parse_address(value, default):
    if value is None:
        return default
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value) if value == int(value) else default
    if isinstance(value, str):
        text = value.strip()
        if not text or text == "-":
            return default
        try:
            return int(text, 0)
        except ValueError:
            return default
    return default


class Driver:
    def __init__(self, context):
        self.context = context
        self.fd = -1
        self.bus_path = None

    def _close(self):
        if self.fd >= 0:
            fd, self.fd = self.fd, -1
            self.context.call("close_handle", fd)

    def build(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        path = data.get("path")
        if path is None:
            return {"result": "ERR", "message": "No I2C path"}
        self._close()
        opened = (self.context.call("i2c_open", path, True)
                  if data.get("proto") == "virt"
                  else self.context.call("i2c_open", path))
        if isinstance(opened, bool) or not isinstance(opened, int) or opened < 0:
            return {"result": "ERR", "message": "Failed to open I2C bus"}
        self.fd = opened
        self.bus_path = path
        return {"result": "OK", "fd": self.fd, "bus": path}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        if self.fd < 0:
            return {"result": "ERR", "message": "I2C bus not opened (build first)"}

        start = _parse_address(data.get("start_address"), _DEFAULT_START)
        end = _parse_address(data.get("end_address"), _DEFAULT_END)
        start = max(0x00, min(start, 0x7F))
        end = max(0x00, min(end, 0x7F))
        if start > end:
            start, end = end, start

        found = []
        for addr in range(start, end + 1):
            self.context.check()
            reply = self.context.call("i2c_transfer", self.fd, addr, [], 1)
            if reply is not None:
                found.append("0x%02X" % addr)

        return {
            "result": "OK",
            "bus": self.bus_path,
            "found": found,
            "count": len(found),
            "range": "0x%02X-0x%02X" % (start, end),
        }

    def destroy(self, data):
        self._close()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}
