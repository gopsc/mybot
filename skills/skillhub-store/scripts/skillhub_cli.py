#!/usr/bin/env python3
"""SkillHub CLI 的跨平台包装器。

用法：
    python skillhub_cli.py <skillhub 子命令与参数...>

会把参数原样转发给真实的 skillhub CLI，兼容 Windows / macOS / Linux。
解析顺序：SKILLHUB_CLI 环境变量 -> ~/.skillhub/skills_store_cli.py
-> PATH 中的 skillhub -> ~/.local/bin/skillhub。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
SETUP_SCRIPT = SKILL_ROOT / "scripts" / "skillhub_setup.py"
CLI_HOME = Path.home() / ".skillhub"
CLI_FILE = CLI_HOME / "skills_store_cli.py"


def _resolve_cli() -> tuple[str, Path] | None:
    """返回 (kind, path)，kind 为 'py' 或 'exe'。"""
    env = os.environ.get("SKILLHUB_CLI", "").strip()
    if env:
        p = Path(env).expanduser()
        if p.is_file():
            return ("py" if p.suffix.lower() == ".py" else "exe", p)

    if CLI_FILE.is_file():
        return ("py", CLI_FILE)

    found = shutil.which("skillhub")
    if found:
        return ("exe", Path(found))

    wrapper = Path.home() / ".local" / "bin" / "skillhub"
    if wrapper.is_file():
        return ("exe", wrapper)

    return None


def _run(kind: str, path: Path, args: list[str]) -> int:
    if kind == "py":
        cmd = [sys.executable, str(path), *args]
        return subprocess.call(cmd)

    if os.name == "nt" and path.suffix.lower() in (".cmd", ".bat"):
        comspec = os.environ.get("COMSPEC", "cmd.exe")
        return subprocess.call([comspec, "/c", str(path), *args])

    return subprocess.call([str(path), *args])


def main() -> int:
    args = sys.argv[1:]

    if args and args[0] in ("--where", "--which"):
        resolved = _resolve_cli()
        if resolved is None:
            print("skillhub CLI 未安装", file=sys.stderr)
            return 1
        print(resolved[1])
        return 0

    resolved = _resolve_cli()
    if resolved is None:
        print("未找到 skillhub CLI。", file=sys.stderr)
        print("请先安装（Windows / 无 bash 环境）：", file=sys.stderr)
        print(f'  python "{SETUP_SCRIPT}" --cli-only', file=sys.stderr)
        print("或使用官方脚本（需要 bash）：", file=sys.stderr)
        print(
            "  curl -fsSL https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com"
            "/install/install.sh | bash -s -- --cli-only",
            file=sys.stderr,
        )
        return 127

    if not args:
        print("用法: python skillhub_cli.py <search|install|list|upgrade|verify|...> [参数]", file=sys.stderr)
        print("      python skillhub_cli.py --where   # 显示实际使用的 CLI 路径", file=sys.stderr)
        return 2

    return _run(resolved[0], resolved[1], args)


if __name__ == "__main__":
    raise SystemExit(main())