import math

def _finite(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        if isinstance(value, str) and value.strip().lower().lstrip("+-").startswith("0x"):
            number = float.fromhex(value.strip())
        else:
            number = float(value)
    except (ValueError, OverflowError):
        return None
    return number if math.isfinite(number) else None


class Driver:
    def __init__(self, context):
        self.context = context
        self.fd = -1
        self.delay_us = 0

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
            return {"result": "ERR", "message": "Invalid Arguments: path"}
        mode = _finite(data.get("spi_mode"))
        if mode is None or not 0 <= mode <= 3 or not mode.is_integer():
            return {"result": "ERR", "message": "Invalid Arguments: spi_mode (0~3)"}
        bits = _finite(data.get("bits"))
        if bits is None or not 7 <= bits <= 16 or not bits.is_integer():
            return {"result": "ERR", "message": "Invalid Arguments: bits (7~16)"}
        speed = _finite(data.get("speed"))
        if speed is None or not 0 < speed <= 0xFFFFFFFF or not speed.is_integer():
            return {"result": "ERR", "message": "Invalid Arguments: speed (>0)"}
        delay = _finite(data.get("delay"))
        if delay is None or delay < 0:
            return {"result": "ERR", "message": "Invalid Arguments: delay (>=0)"}
        self._close()
        opened = (self.context.call("spi_open", path, True) if data.get("proto") == "virt"
                  else self.context.call("spi_open", path))
        if isinstance(opened, bool) or not isinstance(opened, int) or opened < 0:
            return {"result": "ERR", "message": "Failed to open SPI file"}
        self.fd = opened
        # HAL setup has no delay parameter; consumers pass it per transfer.
        result = self.context.call("spi_setup", self.fd, int(mode), int(bits), int(speed))
        if result != 0:
            self._close()
            return {"result": "ERR", "message": "Failed to setup SPI device"}
        self.delay_us = delay
        return {"result": "OK", "fd": self.fd}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        if self.fd < 0:
            return {"result": "ERR", "message": "SPI not opened (build first)"}
        return {"result": "OK", "fd": self.fd, "delay": self.delay_us}

    def destroy(self, data):
        self._close()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}
