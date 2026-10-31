class Driver:
    def __init__(self, context):
        self.context = context
        self.fd = -1

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
        opened = (self.context.call("i2c_open", path, True) if data.get("proto") == "virt"
                  else self.context.call("i2c_open", path))
        if isinstance(opened, bool) or not isinstance(opened, int) or opened < 0:
            return {"result": "ERR", "message": "Failed to open I2C file"}
        self.fd = opened
        return {"result": "OK", "fd": self.fd}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        if self.fd < 0:
            return {"result": "ERR", "message": "I2C not opened (build first)"}
        return {"result": "OK", "fd": self.fd}

    def destroy(self, data):
        self._close()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}
