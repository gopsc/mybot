#!/usr/bin/env python3
"""SkillHub CLI 跨平台安装器（Windows / macOS / Linux）。

与官方 install.sh 的 CLI 部分等价：下载 kit、解压、安装到 ~/.skillhub、
生成 config.json 与启动器。官方脚本依赖 bash，本脚本只依赖 Python 3.8+。

示例：
    python skillhub_setup.py --cli-only
    python skillhub_setup.py --kit-version 2026.8.5 --no-self-upgrade
    python skillhub_setup.py --kit ./skillhub-cli-2026.8.5.tar.gz
    python skillhub_setup.py --with-official-skills --dir ./skills
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path

DEFAULT_BASE_URL = "https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com"
PROD_SELF_UPDATE_URL = f"{DEFAULT_BASE_URL}/version.json"
CLI_FILES = ("skills_store_cli.py", "skills_upgrade.py", "version.json", "metadata.json")
OPTIONAL_FILES = ("skills_index.local.json",)


def log(message: str) -> None:
    print(message, flush=True)


def download(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "skillhub-setup/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp, open(dest, "wb") as fh:
        shutil.copyfileobj(resp, fh)


def safe_extract(archive: Path, dest: Path) -> None:
    dest = dest.resolve()
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            target = (dest / member.name).resolve()
            if target != dest and dest not in target.parents:
                raise RuntimeError(f"不安全的归档路径: {member.name}")
            if member.issym() or member.islnk():
                raise RuntimeError(f"归档包含链接文件，已拒绝: {member.name}")
        try:
            tar.extractall(dest, filter="data")
        except TypeError:  # Python < 3.12 不支持 filter 参数
            tar.extractall(dest)


def locate_kit(root: Path) -> tuple[Path, Path]:
    """返回 (cli 目录, 官方 skill 模板目录)。"""
    for cand in (root, root / "cli"):
        if (cand / "skills_store_cli.py").is_file():
            skill_dir = cand / "skill"
            if not skill_dir.is_dir():
                sibling = cand.parent / "skill"
                skill_dir = sibling if sibling.is_dir() else cand / "skill"
            return cand, skill_dir

    for child in sorted(p for p in root.iterdir() if p.is_dir()):
        try:
            return locate_kit(child)
        except RuntimeError:
            continue

    raise RuntimeError("kit 中未找到 skills_store_cli.py，可能不是有效的 SkillHub 安装包")


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def install_cli(cli_dir: Path, cli_home: Path, no_self_upgrade: bool, dry_run: bool) -> dict:
    meta = read_json(cli_dir / "metadata.json")
    version = str(read_json(cli_dir / "version.json").get("version") or "").strip()
    self_update_url = str(meta.get("self_update_manifest_url") or PROD_SELF_UPDATE_URL)

    targets = [cli_home / name for name in CLI_FILES]
    targets += [cli_home / name for name in OPTIONAL_FILES if (cli_dir / name).is_file()]

    if dry_run:
        log(f"[dry-run] 将安装 CLI {version or '(未知版本)'} 到 {cli_home}")
        for target in targets:
            log(f"[dry-run]   {target}")
        return {"ok": True, "dry_run": True, "version": version, "cli_home": str(cli_home)}

    cli_home.mkdir(parents=True, exist_ok=True)
    installed = []
    for target in targets:
        shutil.copy2(cli_dir / target.name, target)
        installed.append(str(target))

    config_path = cli_home / "config.json"
    config = read_json(config_path)
    config.setdefault("self_update_url", self_update_url)
    if not str(config.get("client_id") or "").strip():
        config["client_id"] = str(uuid.uuid4())
    if no_self_upgrade:
        config["auto_self_upgrade"] = False
        config.pop("ignored_self_update_version", None)
    config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    launcher = write_launcher(cli_home)
    if launcher:
        installed.append(str(launcher))

    return {
        "ok": True,
        "version": version,
        "cli_home": str(cli_home),
        "launcher": str(launcher) if launcher else "",
        "files": installed,
    }


def write_launcher(cli_home: Path) -> Path | None:
    python = sys.executable
    if os.name == "nt":
        bin_dir = cli_home / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        target = bin_dir / "skillhub.cmd"
        content = f'@echo off\r\n"{python}" "%~dp0..\\skills_store_cli.py" %*\r\n'
        target.write_text(content, encoding="utf-8", newline="")
        return target

    bin_dir = Path.home() / ".local" / "bin"
    try:
        bin_dir.mkdir(parents=True, exist_ok=True)
        target = bin_dir / "skillhub"
        content = (
            "#!/bin/sh\n"
            f'exec "{python}" "$HOME/.skillhub/skills_store_cli.py" "$@"\n'
        )
        target.write_text(content, encoding="utf-8", newline="\n")
        target.chmod(0o755)
        return target
    except OSError as exc:
        log(f"警告: 无法创建启动器（{exc}），可直接使用 python ~/.skillhub/skills_store_cli.py")
        return None


def install_official_skills(
    skill_dir: Path, target_root: Path, force: bool, dry_run: bool
) -> list[dict]:
    mapping = {
        "SKILL.md": "find-skills",
        "SKILL.skillhub-preference.md": "skillhub-preference",
    }
    results = []
    for source_name, folder in mapping.items():
        source = skill_dir / source_name
        if not source.is_file():
            results.append({"skill": folder, "status": "missing-source"})
            continue

        target = target_root / folder / "SKILL.md"
        if target.exists() and not force:
            results.append({"skill": folder, "status": "exists", "path": str(target)})
            continue

        if not dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

        results.append({"skill": folder, "status": "ok", "path": str(target)})
    return results


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="安装 SkillHub CLI（跨平台，等价于官方 install.sh 的 CLI 部分）"
    )
    parser.add_argument("--cli-only", action="store_true", help="只安装 CLI（默认行为）")
    parser.add_argument(
        "--with-official-skills",
        action="store_true",
        help="额外安装官方 find-skills 与 skillhub-preference 模板，需要 --dir",
    )
    parser.add_argument("--dir", help="skills 根目录，仅与 --with-official-skills 搭配")
    parser.add_argument("--force", action="store_true", help="覆盖已存在的官方模板目录")
    parser.add_argument("--cli-home", default="~/.skillhub", help="CLI 安装目录（默认 ~/.skillhub）")
    parser.add_argument("--kit-version", help="固定 kit 版本，例如 2026.8.5")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="kit 下载源基地址")
    parser.add_argument("--kit", help="本地 kit 路径（.tar.gz 或已解压目录），用于离线安装")
    parser.add_argument("--no-self-upgrade", action="store_true", help="关闭启动时自动升级")
    parser.add_argument("--dry-run", action="store_true", help="只打印计划，不写入")
    parser.add_argument("--json", action="store_true", help="以 JSON 输出结果")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    cli_home = Path(args.cli_home).expanduser()

    if args.with_official_skills and not args.dir:
        print("错误: --with-official-skills 需要同时指定 --dir <skills 目录>", file=sys.stderr)
        return 2

    if sys.version_info < (3, 8):
        print("错误: 需要 Python 3.8 或更高版本", file=sys.stderr)
        return 1

    temp_dir: tempfile.TemporaryDirectory | None = None
    try:
        if args.kit:
            kit_path = Path(args.kit).expanduser()
            if not kit_path.exists():
                print(f"错误: 本地 kit 不存在: {kit_path}", file=sys.stderr)
                return 2
            if kit_path.is_dir():
                kit_root = kit_path
            else:
                temp_dir = tempfile.TemporaryDirectory(prefix="skillhub-kit-")
                extract_dir = Path(temp_dir.name) / "extract"
                extract_dir.mkdir(parents=True, exist_ok=True)
                safe_extract(kit_path, extract_dir)
                kit_root = extract_dir
        else:
            if args.kit_version:
                url = f"{args.base_url.rstrip('/')}/install/skillhub-cli-{args.kit_version}.tar.gz"
            else:
                url = f"{args.base_url.rstrip('/')}/install/latest.tar.gz"

            if args.dry_run:
                log(f"[dry-run] 将下载 {url}")
                log(f"[dry-run] 安装到 {cli_home}")
                return 0

            temp_dir = tempfile.TemporaryDirectory(prefix="skillhub-kit-")
            archive = Path(temp_dir.name) / "kit.tar.gz"
            log(f"下载: {url}")
            download(url, archive)
            extract_dir = Path(temp_dir.name) / "extract"
            extract_dir.mkdir(parents=True, exist_ok=True)
            safe_extract(archive, extract_dir)
            kit_root = extract_dir

        cli_dir, skill_dir = locate_kit(kit_root)
        result = install_cli(cli_dir, cli_home, args.no_self_upgrade, args.dry_run)

        if args.with_official_skills:
            skills_root = Path(args.dir).expanduser().resolve()
            result["official_skills"] = install_official_skills(
                skill_dir, skills_root, args.force, args.dry_run
            )

        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0

        if args.dry_run:
            log("dry-run 完成，未写入任何文件。")
            return 0

        log("")
        log("安装完成。")
        log(f"  版本: {result.get('version') or '(未知)'}")
        log(f"  CLI : {cli_home / 'skills_store_cli.py'}")
        if result.get("launcher"):
            log(f"  启动器: {result['launcher']}")
        log("")
        log("验证:")
        log(f'  python "{cli_home / "skills_store_cli.py"}" --version')
        if os.name != "nt":
            log("  如需全局命令 skillhub，请把 ~/.local/bin 加入 PATH。")
        else:
            log(r"  如需全局命令，请把 %USERPROFILE%\.skillhub\bin 加入 PATH。")
        return 0

    except urllib.error.URLError as exc:
        print(f"错误: 下载失败（{exc}）。请检查网络/代理，或使用 --kit 本地安装。", file=sys.stderr)
        return 3
    except (RuntimeError, tarfile.TarError) as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 4
    finally:
        if temp_dir is not None:
            temp_dir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())