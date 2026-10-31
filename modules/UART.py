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
        self.baud = 9600
        self.open_path = None

    def _close(self):
        self.open_path = None
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
        baud = _finite(data.get("baud"))
        if baud is None or baud <= 0:
            return {"result": "ERR", "message": "Invalid Arguments: baud (positive number)"}
        self._close()
        opened = (self.context.call("uart_open", path, baud, True) if data.get("proto") == "virt"
                  else self.context.call("uart_open", path, baud))
        if isinstance(opened, bool) or not isinstance(opened, int) or opened < 0:
            return {"result": "ERR", "message": "Failed to open UART file"}
        self.fd = opened
        self.baud = baud
        self.open_path = path
        return {"result": "OK"}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        if self.fd < 0:
            return {"result": "ERR", "message": "UART not opened (build first)"}
        return {"result": "OK", "fd": self.fd, "baud": self.baud, "path": self.open_path}

    def destroy(self, data):
        self._close()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}
