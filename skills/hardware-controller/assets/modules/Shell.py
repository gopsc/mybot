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
        self.timeout_ms = 10000

    def _close(self):
        if self.fd >= 0:
            fd, self.fd = self.fd, -1
            self.context.call("close_handle", fd)

    def build(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        timeout = _finite(data.get("timeout"))
        if timeout is None:
            timeout = 10000
        if not 1 <= timeout <= 60000:
            return {"result": "ERR", "message": "Invalid Arguments: timeout (1..60000 ms)"}
        self._close()
        opened = self.context.call("shell_open", timeout)
        if isinstance(opened, bool) or not isinstance(opened, int) or opened < 0:
            return {"result": "ERR", "message": "Failed to open shell session"}
        self.fd = opened
        self.timeout_ms = timeout
        return {"result": "OK"}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        if self.fd < 0:
            return {"result": "ERR", "message": "Shell session not opened (build first)"}
        command = data.get("cmd")
        if not isinstance(command, str) or command in ("", "-"):
            return {"result": "ERR", "message": "Invalid Arguments: cmd (command text)"}
        try:
            size = len(command.encode("utf-8"))
        except UnicodeError:
            return {"result": "ERR", "message": "Invalid Arguments: cmd (command text)"}
        if size > 65536:
            return {"result": "ERR", "message": "Invalid Arguments: cmd (over 65536 bytes)"}
        timeout = _finite(data.get("timeout"))
        if timeout is None:
            timeout = self.timeout_ms
        if not 1 <= timeout <= 60000:
            return {"result": "ERR", "message": "Invalid Arguments: timeout (1..60000 ms)"}
        result = self.context.call("shell_run", self.fd, command, timeout)
        if isinstance(result, dict) and result.get("result") in ("OK", "ERR"):
            return result
        return {"result": "ERR", "message": "Failed to execute shell command"}

    def destroy(self, data):
        self._close()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}
