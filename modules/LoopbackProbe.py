from pymybot.errors import DriverError


class Driver:
    def __init__(self, context):
        self.context = context

    def build(self, data):
        return {"result": "OK"}

    def call(self, data):
        fd = data["fd"]
        value = data.get("value", 0)
        if self.context.call("uart_write", fd, [value]) != 1:
            raise DriverError("UART write failed: " + self.context.call("last_error"))
        reply = self.context.call("uart_read", fd, 1, 200)
        if reply is None or len(reply) != 1:
            raise DriverError("UART echo timed out or failed")
        return {"result": "OK", "rx": reply[0]}
