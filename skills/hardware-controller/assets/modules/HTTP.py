import json
import math
import re


_BASE_URL = re.compile(
    r"https?://(?:[0-9A-Za-z][0-9A-Za-z.\-]*(?::[0-9]+)?"
    r"|\[[0-9A-Fa-f:]+\](?::[0-9]+)?)(?:/[0-9A-Za-z._~/%()\-]*)?"
)


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


def _text(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "nil"
    if isinstance(value, float):
        return format(value, ".14g")
    return str(value)


def _headers(spec):
    if spec is None or spec == "-" or spec == "":
        return None
    if isinstance(spec, dict):
        return {_text(key): _text(value) for key, value in spec.items()}
    if not isinstance(spec, str):
        return None
    headers = {}
    for pair in spec.split("|"):
        if not pair:
            continue
        match = re.fullmatch(r"\s*([^=|]+)\s*=\s*(.*?)\s*", pair, re.DOTALL)
        if match is None:
            return None
        headers[match[1]] = match[2]
    return headers


def _json_value(value, depth=0):
    if depth > 64:
        raise ValueError("JSON nesting too deep")
    if isinstance(value, dict):
        if value and all(
            not isinstance(key, bool) and isinstance(key, (int, float))
            and 1 <= key <= len(value) and int(key) == key for key in value
        ):
            return [_json_value(value[index], depth + 1) for index in range(1, len(value) + 1)]
        if not all(isinstance(key, str) for key in value):
            raise ValueError("JSON object keys must be strings")
        return {key: _json_value(item, depth + 1) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item, depth + 1) for item in value]
    if isinstance(value, float) and value.is_integer() and abs(value) < 2 ** 53:
        return int(value)
    return value


class Driver:
    def __init__(self, context):
        self.context = context
        self.fd = -1
        self.base_url = None
        self.timeout_ms = 10000

    def _close(self):
        self.base_url = None
        if self.fd >= 0:
            fd, self.fd = self.fd, -1
            self.context.call("close_handle", fd)

    def build(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        base = data.get("base")
        if not isinstance(base, str) or _BASE_URL.fullmatch(base) is None:
            return {"result": "ERR", "message": "Invalid Arguments: base (credential-free http(s):// URL)"}
        timeout = _finite(data.get("timeout"))
        if timeout is None:
            timeout = 10000
        if not 1 <= timeout <= 60000:
            return {"result": "ERR", "message": "Invalid Arguments: timeout (1..60000 ms)"}
        self._close()
        opened = self.context.call("http_open", base, timeout)
        if isinstance(opened, bool) or not isinstance(opened, int) or opened < 0:
            return {"result": "ERR", "message": "Failed to open HTTP endpoint"}
        self.fd = opened
        self.base_url = base
        self.timeout_ms = timeout
        return {"result": "OK"}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        if self.fd < 0:
            return {"result": "ERR", "message": "HTTP endpoint not opened (build first)"}
        if data.get("method") is None and data.get("path") is None:
            return {"result": "OK", "fd": self.fd, "base": self.base_url, "timeout": self.timeout_ms}
        method = data.get("method")
        if method is None or method is False:
            method = "GET"
        path = data.get("path")
        if path is None or path is False:
            path = ""
        headers = _headers(data.get("headers"))
        body = data.get("body")
        if isinstance(data.get("json"), (dict, list, tuple)):
            try:
                body = json.dumps(_json_value(data["json"]), ensure_ascii=False,
                                  allow_nan=False, separators=(",", ":"))
            except (TypeError, ValueError, OverflowError, RecursionError):
                return {"result": "ERR", "message": "Invalid Arguments: json (not encodable)"}
            if headers is None:
                headers = {}
            if "Content-Type" not in headers and "content-type" not in headers:
                headers["Content-Type"] = "application/json"
        self.context.check()
        result = self.context.call("http_request", self.fd, method, path, headers, body)
        if isinstance(result, dict) and result.get("result") in ("OK", "ERR"):
            return result
        return {"result": "ERR", "message": "Failed to execute HTTP request"}

    def destroy(self, data):
        self._close()
        if not isinstance(data, dict):
            return {"result": "ERR", "message": "Invalid Arguments Type: table"}
        return {"result": "OK"}
