"""Nuitka standalone build for pymybot (POSIX; Windows uses nuitka_compile_test.ps1).

    pip install -e ".[gui,agent,camera,web,mcp]"
    pip install nuitka
    python tools/nuitka_build.py

The command is derived from the packages actually installed, so a "full"
environment (GUI, agent, camera, web, MCP) produces a full bundle while a lean
environment still builds a working CLI. ``tools/bundle_assets.py`` stays the
single source of truth for the bundled data; this script only translates it to
Nuitka arguments and then repairs the two things Nuitka gets wrong for us:

* Python driver sources are skipped from data directories, but native drivers
  load ``<Table>.py`` at run time, so they are copied into the bundle.
* The executable must be able to find ``pymybot/assets`` and the GUI plugins;
  ``ci_smoke.py frozen`` verifies the result.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

# Nuitka does not need every implementation detail it can see; keeping these
# out shortens compile time and avoids pulling the test suite into the bundle.
EXCLUDES = ("pytest", "tests", "tkinter", "_tkinter")

# Qt modules pymybot never imports; excluding them only makes sense when
# PySide6 is part of the build at all.
QT_EXCLUDES = ("PySide6.Qt3D", "PySide6.QtBluetooth", "PySide6.QtMultimedia",
               "PySide6.QtNetworkAuth", "PySide6.QtWebEngine",
               "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets")

# Distribution metadata imported at run time (importlib.metadata).
METADATA = ("lupa", "sqlparse", "pyserial", "pyftdi", "pillow", "pydantic-ai-slim",
            "pydantic-graph", "pydantic", "openai", "anthropic", "genai-prices",
            "httpx", "httpx2", "httpcore", "httpcore2", "mcp", "beautifulsoup4", "av")

# Imported lazily or through dynamic lookup, so Nuitka cannot see them.
# The agent stack (pydantic_ai/openai/anthropic) is deliberately NOT listed:
# forcing every submodule of ~90 MB of source generates several hundred MB of C
# and does not fit a small SD card. Nuitka follows the real imports instead.
PACKAGES = ("serial", "pyftdi", "PIL", "smbus2", "spidev", "bs4", "httpx",
            "httpx2", "av", "mcp")

LUA_MODULES = ("lupa.luajit21", "lupa.lua54", "lupa.lua55")


def available(module: str) -> bool:
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


def installed(distribution: str) -> bool:
    import importlib.metadata

    try:
        importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        return False
    return True


def data_args() -> list[str]:
    """Bundled data directories, mirroring tools/bundle_assets.py."""
    from bundle_assets import ASSET_SUFFIXES

    args = []
    for kind in ASSET_SUFFIXES:
        source = ROOT / kind
        if source.is_dir():
            args.append(f"--include-data-dir={source}=pymybot/assets/{kind}")
    gui_assets = ROOT / "pymybot" / "gui" / "assets"
    if gui_assets.is_dir():
        args.append(f"--include-data-dir={gui_assets}=pymybot/gui/assets")
    for extra in ("README.md", "LICENSE", "CHANGELOG.md"):
        if (ROOT / extra).is_file():
            args.append(f"--include-data-files={ROOT / extra}={extra}")
    return args


def build_args(output_dir: Path, *, gui: bool, jobs: int, onefile: bool,
               agent: bool = True) -> list[str]:
    args = [
        sys.executable, "-m", "nuitka", str(ROOT / "tools" / "entry_cli.py"),
        "--mode=" + ("onefile" if onefile else "standalone"),
        "--assume-yes-for-downloads",
        f"--output-dir={output_dir}",
        "--output-folder-name=pymybot.dist",
        "--output-filename=pymybot",
        "--company-name=pymybot",
        "--product-name=pymybot",
        "--file-version=0.5.0.0",
        "--product-version=0.5.0.0",
        f"--jobs={jobs}",
        "--lto=no",  # LTO multiplies build time on a Pi for little gain.
        "--nofollow-import-to=" + ",".join(EXCLUDES),
    ]
    if gui:
        args += ["--enable-plugin=pyside6",
                 "--include-qt-plugins=platforms,styles,imageformats,iconengines,egldeviceintegrations",
                 "--include-module=PySide6.QtSvg",
                 "--nofollow-import-to=" + ",".join(QT_EXCLUDES)]
    if not agent:
        args.append("--nofollow-import-to=" + ",".join(AGENT_MODULES))
    # Nuitka 4.x exposes executable icons for Windows only (--windows-icon-from-ico);
    # a POSIX desktop entry has to carry the icon instead.
    for module in LUA_MODULES:
        if available(module):
            args.append(f"--include-module={module}")
    for package in PACKAGES:
        if available(package):
            args.append(f"--include-package={package}")
    for distribution in METADATA:
        if not agent and distribution in AGENT_DISTRIBUTIONS:
            continue  # Nuitka refuses metadata for a package it was told to skip.
        if installed(distribution):
            args.append(f"--include-distribution-metadata={distribution}")
    args += data_args()
    return args


# Agent-only modules. Excluding them keeps a CLI/MCP bundle buildable on small
# disks: pymybot.agent* raise ModuleNotFoundError, which cli.py and serve.py
# already translate into "install pymybot[agent]". agent_executor and
# agent_skills stay because the MCP server uses them.
AGENT_MODULES = ("pymybot.agent", "pymybot.agent_context", "pymybot.agent_intent",
                 "pymybot.agent_memory", "pymybot.agent_prompt", "pymybot.agent_web",
                 "pydantic_ai", "openai", "anthropic", "fastmcp", "griffe",
                 "tiktoken", "genai_prices")
AGENT_DISTRIBUTIONS = frozenset({"pydantic-ai-slim", "pydantic-graph", "pydantic",
                                 "openai", "anthropic", "genai-prices"})


def has_tool(name: str) -> str | None:
    """Find a build tool on PATH or beside the interpreter (pip-installed)."""
    found = shutil.which(name)
    if found:
        return found
    beside = Path(sys.executable).parent / name
    return str(beside) if beside.is_file() else None


def preflight() -> list[str]:
    """Problems that would stop the build late instead of early."""
    problems = []
    if sys.platform.startswith("linux") and not has_tool("patchelf"):
        problems.append("patchelf is required for --mode=standalone on Linux: "
                        "pip install patchelf (or apt install patchelf)")
    if not any(shutil.which(cc) for cc in ("cc", "gcc", "clang")):
        problems.append("no C compiler found (install build-essential/clang)")
    return problems


def build_env() -> dict[str, str]:
    """Make tools installed beside the interpreter visible to Nuitka.

    patchelf is frequently installed with ``pip`` into the venv, which is not
    on PATH unless the venv was activated.
    """
    env = dict(os.environ)
    bindir = str(Path(sys.executable).parent)
    env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
    return env


def repair(bundle: Path) -> list[str]:
    """Copy what Nuitka leaves out and report missing runtime pieces."""
    notes = []
    # Native drivers are loaded from source at run time.
    modules = bundle / "pymybot" / "assets" / "modules"
    if modules.is_dir():
        copied = 0
        for source in sorted((ROOT / "modules").glob("*.py")):
            shutil.copy2(source, modules / source.name)
            copied += 1
        notes.append(f"copied {copied} Python driver sources into {modules.relative_to(bundle)}")
    else:
        notes.append(f"WARNING: missing packaged modules at {modules}")

    # A PySide6 build without a platform plugin cannot open a window.
    if (bundle / "PySide6").exists():
        plugin = bundle / "PySide6" / "Qt" / "plugins" / "platforms"
        if not any(plugin.glob("libqxcb*.so")) and not any(plugin.glob("libqoffscreen*.so")):
            notes.append(f"WARNING: no X11/offscreen Qt platform plugin under {plugin.relative_to(bundle)}")
    return notes


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build-nuitka")
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    parser.add_argument("--no-gui", action="store_true", help="skip PySide6 collection")
    parser.add_argument("--no-agent", action="store_true",
                        help="exclude the agent stack (pydantic-ai/openai/anthropic); "
                             "the CLI reports the missing extra at run time")
    parser.add_argument("--onefile", action="store_true", help="build a single executable")
    parser.add_argument("--dry-run", action="store_true", help="print the command and exit")
    parser.add_argument("--skip-smoke", action="store_true", help="do not run the frozen smoke test")
    options = parser.parse_args(argv)

    gui = not options.no_gui and available("PySide6")
    if not gui and not options.no_gui:
        print("nuitka_build: PySide6 is not installed; building without the GUI", file=sys.stderr)
    if not available("nuitka"):
        print('nuitka_build: install it first: pip install nuitka', file=sys.stderr)
        return 2
    problems = preflight()
    if problems:
        for problem in problems:
            print("nuitka_build: " + problem, file=sys.stderr)
        return 2

    output_dir = options.output_dir.resolve()
    command = build_args(output_dir, gui=gui, jobs=options.jobs, onefile=options.onefile,
                         agent=not options.no_agent)
    if options.dry_run:
        print(" \\\n  ".join(command))
        return 0

    label = "full" if gui else "no GUI"
    if options.no_agent:
        label += ", no agent"
    print(f"nuitka_build: {output_dir} ({label}, jobs={options.jobs})", flush=True)
    completed = subprocess.run(command, cwd=ROOT, env=build_env())
    if completed.returncode:
        return completed.returncode

    bundle = output_dir / "pymybot.dist"
    for note in repair(bundle):
        print("nuitka_build: " + note, file=sys.stderr)
    executable = bundle / "pymybot"
    if not executable.is_file():
        print(f"nuitka_build: no executable at {executable}", file=sys.stderr)
        return 1
    if not options.skip_smoke:
        smoke = subprocess.run([sys.executable, "-I", str(ROOT / "tools" / "ci_smoke.py"),
                                "frozen", "--executable", str(executable)], cwd=ROOT)
        if smoke.returncode:
            return smoke.returncode
    print(f"nuitka_build: OK -> {executable}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
