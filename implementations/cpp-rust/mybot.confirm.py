#!/usr/bin/env python3
"""mybot 策略确认程序（mybot.policy.json 的 confirm_command）。

协议（docs/agent.md「策略钩子」）：后端把 {"tool": ..., "args": {...}} 写到本程序的
stdin，按退出码裁决——0 放行，其他一律拒绝。本程序 fail-closed：读不懂、不在名单、
出任何异常都拒绝。

当前策略（最小权限）
  * write_file —— 只放行"新建文件"；overwrite 为真时拒绝，除非路径落在
                  OVERWRITE_PREFIXES 的某个前缀之下
  * 其余（run_command / apply_sql / 将来新增的工具）—— 一律拒绝

放宽的办法（改完立即生效，不用重启后端：每次调用都会重新执行本文件）
  * 允许覆盖 site/ 目录下的文件：OVERWRITE_PREFIXES = ("site/",)
  * 允许覆盖根目录内任意文件（    不推荐）：OVERWRITE_PREFIXES = ("",)
  * 允许模型执行 shell：把 "run_command" 加进 ALLOW_ALWAYS（等于对它不再设闸门）

为什么没有终端 y/n 提示：后端把确认程序放在独立进程组里运行，在后台进程组里读终端
会收到 SIGTTIN 被停住，直到超时被杀（见 .tmp/rust-agent-audit-2026-10-08.md F-4）。

重要：本文件和 mybot.policy.json 必须放在 --fs-root 之外，否则模型可以先改写
自己的审批规则再放行自己。
"""
import json
import posixpath
import sys

ALLOW_ALWAYS = set()            # 无条件放行的工具名
ALLOW_CREATE_ONLY = {"write_file"}   # 只放行"新建"的工具名
OVERWRITE_PREFIXES = ()         # 允许覆盖的相对路径前缀；空 = 一律不许覆盖
MAX_STDIN = 8 * 1024 * 1024


def deny(why):
    # 模型给的字符串一律用 !r 输出：控制字符 / 终端转义序列会被转义，不会污染你的终端
    print(f"[confirm] 拒绝: {why}", file=sys.stderr)
    sys.exit(1)


def allow(note):
    print(f"[confirm] 放行: {note}", file=sys.stderr)
    sys.exit(0)


def decide(tool, args):
    if tool in ALLOW_ALWAYS:
        allow(f"{tool!r}（ALLOW_ALWAYS）")
    if tool not in ALLOW_CREATE_ONLY:
        deny(f"工具 {tool!r} 不在放行名单（要放行请改 mybot.confirm.py）")

    path = args.get("path")
    if not isinstance(path, str) or not path or "\x00" in path:
        deny(f"{tool!r} 缺少合法的 path: {path!r}")
    norm = posixpath.normpath(path)
    if norm.startswith("/") or norm == ".." or norm.startswith("../"):
        deny(f"路径不在 fs-root 之内: {path!r}")

    # 只有明确的 false / 缺省 / null 才算"不覆盖"；其它任何值都按覆盖处理
    overwrite = args.get("overwrite", False)
    if overwrite is not False and overwrite is not None:
        if any(norm.startswith(p) for p in OVERWRITE_PREFIXES):
            allow(f"{tool!r} 覆盖 {norm!r}")
        deny(f"覆盖 {norm!r} 不可逆，默认不放行（需要时把前缀加进 OVERWRITE_PREFIXES）")
    allow(f"{tool!r} 新建 {norm!r}")


def main():
    # 必须先把 stdin 读到 EOF 再裁决：提前退出会让后端写 stdin 时遇到 EPIPE
    raw = sys.stdin.buffer.read(MAX_STDIN + 1)
    if len(raw) > MAX_STDIN:
        deny("请求体过大")
    try:
        req = json.loads(raw)
        tool, args = req["tool"], req["args"]
    except Exception as e:  # noqa: BLE001 —— 任何解析问题都按拒绝处理
        deny(f"请求不是预期的 JSON（{type(e).__name__}）")
    if not isinstance(tool, str) or not isinstance(args, dict):
        deny("tool / args 类型不符")
    decide(tool, args)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except BaseException as e:  # noqa: BLE001 —— fail-closed：未预料的异常一律拒绝
        print(f"[confirm] 拒绝: 内部错误 {type(e).__name__}", file=sys.stderr)
        sys.exit(1)
