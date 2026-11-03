# Time 系统时间驱动（纯软件，无总线/地址，不需要 --allow-hardware）
#
# 结构 SQL：
#   CREATE TABLE Time (name String);
#   INSERT INTO Time (name) VALUES ('clock');
#
# 动作脚本（MT）：
#   @Action
#   clock.now;
#           1;
#   @
#   @Action
#   clock.format clock.utc;
#   $("%H:%M:%S") 1;
#   @
#
# 字段：
#   now       只作动作列名，值被忽略；该列参与一行就取一次快照。
#   format    传给宿主 strftime 的格式串；缺省只返回结构化字段。
#   utc       0 = 本地时间（缺省），1 = format 按 UTC 输出。
#
# 回执：
#   result / epoch（秒）/ epoch_ms（毫秒）/ utc（ISO 8601，Z，微秒）/
#   local（ISO 8601，带本地偏移，微秒）/ tz_offset / year / month / day / hour /
#   minute / second / microsecond / weekday（1=周一..7=周日）/ yday / isdst /
#   formatted（给了 format 时）。
#
# 说明：
#   - 时间源是宿主系统时钟（时区与 NTP 由操作系统管理）；本驱动不读 RTC。
#   - read 每次返回当前时间，因此 $clock 引用拿到的是读取时的快照。
#   - format 使用宿主 strftime；仅接受与区域设置无关的转换（%Y %m %d %H %M %S
#     %f %z %j %U %W 等），本地化名称与平台扩展（%a/%b/%c/%p/%x/%X/%Z/%s/%G/%V）
#     返回 ERR。MT 文本必须 $("...")，且表达式内不能含实际空白——需要带空格的
#     格式时，放进 @Struct JSON 字段再引用。
#   - 动作参数不能覆盖同名结构元数据，因此 format / utc 只作为动作参数，不设 SQL 列。
#   - 无 VIRT 模型：纯软件驱动不访问总线，测试直接跑真实逻辑。
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import math
import time


_MAX_FORMAT_BYTES = 256
# 与区域设置无关、Windows/Linux 都稳定的 strftime 转换；%a/%b/%c/%p/%x/%X/%Z
# 等本地化名称和 %s/%G/%V 等平台扩展一律拒绝，避免同一脚本在不同系统上漂移。
_FORMAT_CONVERSIONS = frozenset("%HIMSUWYdfjmwyz")


def _error(message):
    return {"result": "ERR", "message": message}


def _flag(value):
    if value is None:
        return 0
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        try:
            number = float(value.strip())
        except ValueError:
            return None
    else:
        return None
    if not math.isfinite(number) or number not in (0.0, 1.0):
        return None
    return int(number)


def _format_error(value):
    if not isinstance(value, str):
        return "Invalid Arguments: format (text)"
    if "\0" in value:
        return "Invalid Arguments: format (NUL)"
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError:
        return "Invalid Arguments: format (text)"
    if size > _MAX_FORMAT_BYTES:
        return f"Invalid Arguments: format (over {_MAX_FORMAT_BYTES} bytes)"
    index = 0
    while index < len(value):
        if value[index] != "%":
            index += 1
            continue
        conversion = value[index + 1:index + 2]
        if conversion not in _FORMAT_CONVERSIONS:
            return f"Invalid Arguments: format (unsupported %{conversion})"
        index += 2
    return None


def _snapshot(data):
    ns = time.time_ns()
    seconds, nanos = divmod(ns, 1_000_000_000)
    try:
        utc_dt = datetime.fromtimestamp(seconds, tz=timezone.utc).replace(microsecond=nanos // 1000)
        local_dt = utc_dt.astimezone()
    except (OSError, OverflowError, ValueError) as exc:
        return _error(f"system time unavailable ({exc})")

    offset = local_dt.utcoffset() or timedelta(0)
    total = int(offset.total_seconds())
    sign = "+" if total >= 0 else "-"
    hours, remainder = divmod(abs(total), 3600)
    result = {
        "result": "OK",
        "epoch": seconds,
        "epoch_ms": ns // 1_000_000,
        "utc": utc_dt.isoformat(timespec="microseconds").replace("+00:00", "Z"),
        "local": local_dt.isoformat(timespec="microseconds"),
        "tz_offset": f"{sign}{hours:02d}:{remainder // 60:02d}",
        "year": local_dt.year,
        "month": local_dt.month,
        "day": local_dt.day,
        "hour": local_dt.hour,
        "minute": local_dt.minute,
        "second": local_dt.second,
        "microsecond": local_dt.microsecond,
        "weekday": local_dt.isoweekday(),
        "yday": local_dt.timetuple().tm_yday,
        "isdst": int(bool(local_dt.dst())),
    }

    utc_flag = _flag(data.get("utc"))
    if utc_flag is None:
        return _error("Invalid Arguments: utc (0|1)")
    fmt = data.get("format")
    if fmt is not None:
        message = _format_error(fmt)
        if message:
            return _error(message)
        target = utc_dt if utc_flag == 1 else local_dt
        try:
            result["formatted"] = target.strftime(fmt)
        except (UnicodeError, ValueError, OverflowError) as exc:
            return _error(f"Invalid Arguments: format ({exc})")
    return result


class Driver:
    def __init__(self, context):
        self.context = context

    def build(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return _error("Invalid Arguments Type: table")
        return {"result": "OK"}

    def call(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return _error("Invalid Arguments Type: table")
        return _snapshot(data)

    def read(self, data):
        return self.call(data)

    def destroy(self, data):
        self.context.check()
        if not isinstance(data, dict):
            return _error("Invalid Arguments Type: table")
        return {"result": "OK"}
