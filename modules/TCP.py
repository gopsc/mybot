# TCP 客户端总线驱动（标准库 socket，经宿主 HAL 管理连接）
#
# 结构 SQL 只配置三个字段；激活仅校验，不建立连接：
#   CREATE TABLE TCP (name String, host String, port Number);
#   INSERT INTO TCP (name, host, port) VALUES ('net', '127.0.0.1', 9000);
#
# 动作脚本（MT）显式控制连接与收发，一次派发最多一个有效操作：
#   @Action
#   net.timeout net.num_recv;
#          1000          512;
#   @
#   @Action
#   net.connect;
#             1;
#   @
#   @Action
#   net.send_hex;
#   $("00FF80");
#   @
#   @Action
#   net.recv_hex;
#              1;
#   @
#   @Action
#   net.send_str;
#    $("你好");
#   @
#   @Action
#   net.close;
#            1;
#   @
#
# MT 字段：
#   connect / close / recv_hex / recv_str
#       1 = 执行，0 = 不执行；close 重复调用也成功，已连接时 connect 不重连。
#   timeout
#       1..60000 毫秒，默认 1000；修改后用于后续连接、发送与接收。
#   num_recv
#       单次接收上限 1..512 字节，默认 512；修改后持续生效。
#   send_hex
#       十六进制文本，如 $("00FF80")；允许 ASCII 空白，不接受奇数位或非十六进制字符。
#   send_str
#       UTF-8 文本，如 $("你好")；编码后单次最多 512 字节。
#
# MT 普通单元格只接受数字；文本须用 $("...") 或字符串表达式，表达式内不能含实际空白，
# 含空白的文本可放进 @Struct JSON 字段再通过表达式引用。接收字段可按普通捕获读取：
#   net.recv_hex net.reply; 1 $reply=recv_hex;
#
# 回执：每次调用都带 result / fd / connected / host / port / timeout / num_recv；
# 发送带 sent；接收带 status（data | timeout | eof）、received，以及
# recv_hex（大写、空格分隔）或 recv_str。
#
# 行为与限制：
#   - host 必须是 IPv4/IPv6 字面量（不支持域名或 scope），port 为 1..65535。
#   - 每个 SQL 行有独立连接；激活不自动连接；重复 build 会关闭旧连接并复位默认参数。
#   - TCP 是字节流：一次接收最多读取 num_recv 字节，不保证填满或返回一个完整报文。
#   - status=timeout 不是断连；status=eof 会关闭连接。UTF-8 跨次接收的未完整字符会
#     暂存，切换到 recv_hex 时先返回这些原始字节；非法 UTF-8 或 EOF 时仍有不完整
#     字符会报错，不替换乱码。
#   - sent 只表示 socket 接受的字节数，不代表对端已执行；发送失败或取消后关闭连接，
#     不自动重连或重放；去激活会兜底关闭未显式关闭的连接。
#   - read / sample 只返回连接与配置元数据，不接收数据。
#   - 回环地址无需 --allow-hardware；非回环连接需要该开关。
import codecs
import ipaddress
from decimal import Decimal, InvalidOperation


_METADATA = frozenset({
    "name", "host", "port", "mode", "fd", "connected", "result", "message",
    "status", "received", "sent",
})
_FLAGS = frozenset({"connect", "close", "recv_hex", "recv_str"})
_SENDS = frozenset({"send_hex", "send_str"})


def _integer(value, low, high):
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        number = Decimal(value) if isinstance(value, str) else value
        if isinstance(number, Decimal) and not number.is_finite():
            return None
        if not low <= number <= high or number != int(number):
            return None
        return int(number)
    except (InvalidOperation, ValueError, OverflowError):
        return None


def _error(message):
    return {"result": "ERR", "message": message}


class Driver:
    def __init__(self, context):
        self.context = context
        self.host = None
        self.port = None
        self.fd = -1
        self.timeout = 1000
        self.num_recv = 512
        self.utf8_pending = b""

    def _metadata(self):
        return {
            "result": "OK", "fd": self.fd, "connected": self.fd >= 0,
            "host": self.host, "port": self.port,
            "timeout": self.timeout, "num_recv": self.num_recv,
        }

    def _close(self):
        self.utf8_pending = b""
        if self.fd >= 0:
            fd, self.fd = self.fd, -1
            result = self.context.call("close_handle", fd)
            if isinstance(result, dict) and result.get("result") == "ERR":
                return result
            if result == -1:
                return _error(self.context.call("last_error") or "Failed to close TCP connection")
        return None

    def _tcp_call(self, operation, *args):
        try:
            return self.context.call(operation, *args)
        except BaseException:
            self.fd = -1
            self.utf8_pending = b""
            raise

    def build(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return _error("Invalid Arguments Type: table")
        host = data.get("host")
        if not isinstance(host, str) or "%" in host:
            return _error("Invalid Arguments: host (IPv4/IPv6 literal without scope)")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            return _error("Invalid Arguments: host (IPv4/IPv6 literal without scope)")
        port = _integer(data.get("port"), 1, 65535)
        if port is None:
            return _error("Invalid Arguments: port (integer 1..65535)")
        self.context.check()
        closed = self._close()
        self.host, self.port = host, port
        self.timeout, self.num_recv = 1000, 512
        return closed if closed is not None else self._metadata()

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return _error("Invalid Arguments Type: table")
        timeout, num_recv = self.timeout, self.num_recv
        operations = []
        for key, value in data.items():
            if key in _METADATA:
                continue
            if key == "timeout":
                timeout = _integer(value, 1, 60000)
                if timeout is None:
                    return _error("Invalid Arguments: timeout (integer 1..60000 ms)")
            elif key == "num_recv":
                num_recv = _integer(value, 1, 512)
                if num_recv is None:
                    return _error("Invalid Arguments: num_recv (integer 1..512)")
            elif key in _FLAGS:
                if isinstance(value, bool) or not isinstance(value, (int, float)) or value not in (0, 1):
                    return _error(f"Invalid Arguments: {key} (numeric flag 0 or 1)")
                if value == 1:
                    operations.append((key, None))
            elif key in _SENDS:
                if not isinstance(value, str):
                    return _error(f"Invalid Arguments: {key} (string)")
                try:
                    if key == "send_hex":
                        if not value.isascii():
                            return _error("Invalid Arguments: send_hex (ASCII hex byte pairs)")
                        payload = bytes.fromhex(value)
                    else:
                        payload = value.encode("utf-8", errors="strict")
                except (ValueError, UnicodeError):
                    return _error(f"Invalid Arguments: {key} (invalid encoding)")
                if len(payload) > 512:
                    return _error(f"Invalid Arguments: {key} (at most 512 bytes)")
                operations.append((key, payload))
            else:
                return _error(f"Unknown TCP action: {key}")
        if len(operations) > 1:
            return _error("At most one TCP operation is allowed per call")
        operation, payload = operations[0] if operations else (None, None)
        if operation == "connect" and self.host is None:
            return _error("TCP endpoint not configured (build first)")
        if operation in _SENDS | {"recv_hex", "recv_str"} and self.fd < 0:
            return _error("TCP not connected (connect first)")
        self.context.check()
        self.timeout, self.num_recv = timeout, num_recv
        if operation is None:
            return self._metadata()
        if operation == "close":
            closed = self._close()
            return closed if closed is not None else self._metadata()
        if operation == "connect":
            if self.fd < 0:
                opened = self._tcp_call("tcp_open", self.host, self.port, self.timeout)
                if isinstance(opened, bool) or not isinstance(opened, int) or opened < 0:
                    return _error(self.context.call("last_error") or "Failed to connect TCP endpoint")
                self.fd = opened
            return self._metadata()
        if operation in _SENDS:
            return self._send(payload)
        return self._receive(operation)

    def _send(self, payload):
        result = self._tcp_call("tcp_write", self.fd, list(payload), self.timeout)
        if isinstance(result, dict):
            if result.get("result") == "ERR":
                self._close()
                return result
            sent = result.get("sent")
            if (result.get("result") == "OK" and type(sent) is int
                    and 0 <= sent <= len(payload)):
                return {"result": "OK", "sent": sent}
        self._close()
        return _error("Invalid TCP write response")

    def _receive(self, operation):
        if operation == "recv_hex" and self.utf8_pending:
            raw = self.utf8_pending[:self.num_recv]
            self.utf8_pending = self.utf8_pending[len(raw):]
            return {
                "result": "OK", "status": "data", "received": len(raw),
                "recv_hex": raw.hex(" ").upper(),
            }
        result = self._tcp_call("tcp_read", self.fd, self.num_recv, self.timeout)
        if isinstance(result, dict) and result.get("result") == "ERR":
            self._close()
            return result
        if not isinstance(result, dict) or result.get("result") != "OK":
            self._close()
            return _error("Invalid TCP read response")
        status, data = result.get("status"), result.get("data")
        if (status not in ("data", "timeout", "eof") or not isinstance(data, list)
                or len(data) > self.num_recv
                or any(type(byte) is not int or not 0 <= byte <= 255 for byte in data)):
            self._close()
            return _error("Invalid TCP read response")
        raw = bytes(data)
        if operation == "recv_hex":
            value = raw.hex(" ").upper()
        else:
            decoder = codecs.getincrementaldecoder("utf-8")("strict")
            try:
                value = decoder.decode(self.utf8_pending + raw, final=status == "eof")
            except UnicodeDecodeError:
                self._close()
                return _error("Incomplete UTF-8 at EOF" if status == "eof" else "Invalid UTF-8 received")
            self.utf8_pending = decoder.getstate()[0]
        if status == "eof":
            self._close()
        return {"result": "OK", "status": status, "received": len(raw), operation: value}

    def read(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return _error("Invalid Arguments Type: table")
        return self._metadata()

    def destroy(self, data):
        closed = self._close()
        if not isinstance(data, dict):
            return _error("Invalid Arguments Type: table")
        return closed if closed is not None else {"result": "OK"}
