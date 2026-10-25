"""CI dependency preflights and isolated sdist/wheel installation verification."""
from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ASSET_SUFFIXES = {"modules": ".lua", "robots": ".sql", "scripts": ".mt", "skills": ".md"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def preflight(mode):
    if mode == "base":
        require(importlib.util.find_spec("pydantic_ai") is None,
                "Base CI must not have pydantic_ai installed")
    else:
        # Missing agent dependencies must fail rather than silently skip integration tests.
        for name in ("pydantic_ai", "pymybot.agent", "pytest", "openai", "anthropic",
                     "pydantic_ai.models.function", "pydantic_ai.models.openai",
                     "pydantic_ai.models.anthropic", "pydantic_ai.providers.openai",
                     "pydantic_ai.providers.anthropic", "pydantic_ai.providers.deepseek"):
            importlib.import_module(name)
    print(f"{mode} dependency preflight passed", flush=True)


def asset_manifest(root):
    result = {}
    for directory, suffix in ASSET_SUFFIXES.items():
        files = sorted((root / directory).rglob("*" + suffix))
        require(files, f"Missing or empty asset directory: {root / directory}")
        for path in files:
            result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def smoke_env():
    # Source-tree paths and application settings must not mask packaging failures.
    excluded = {"PYTHONPATH", "PYTHONHOME", "PIP_TARGET", "PIP_PREFIX", "PIP_USER", "PIP_ROOT"}
    prefixes = ("MYBOT_", "BOT4CJ_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_")
    env = {key: value for key, value in os.environ.items()
           if key.upper() not in excluded and not key.upper().startswith(prefixes)}
    env["PIP_CONFIG_FILE"] = os.devnull
    return env


def run(command, *, cwd, env, timeout=600):
    print("+ " + subprocess.list2cmdline([str(arg) for arg in command]), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True, timeout=timeout)


def wheel_smoke():
    source = Path(__file__).resolve().parents[1]
    expected = asset_manifest(source)
    env = smoke_env()
    with tempfile.TemporaryDirectory(prefix="pymybot-wheel-") as temporary:
        root = Path(temporary).resolve()
        require(not root.is_relative_to(source),
                "Temporary directory must be outside the checkout; set TMPDIR/TEMP accordingly")
        work = root / "work"
        work.mkdir()
        dist = root / "dist"
        # Default build creates the wheel from the sdist, exposing MANIFEST omissions.
        run([sys.executable, "-I", "-m", "build", "--outdir", str(dist), str(source)],
            cwd=work, env=env)
        wheels = list(dist.glob("*.whl"))
        require(len(wheels) == 1 and len(list(dist.glob("*.tar.gz"))) == 1,
                "Expected exactly one sdist and one wheel in the fresh output directory")
        venv = root / "venv"
        run([sys.executable, "-I", "-m", "venv", str(venv)], cwd=work, env=env)
        python = venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
        run([str(python), "-I", "-m", "pip", "--isolated", "install", "--no-input", str(wheels[0])],
            cwd=work, env=env)
        run([str(python), "-I", "-m", "pip", "--isolated", "check"], cwd=work, env=env)
        manifest = root / "assets.json"
        manifest.write_text(json.dumps({"source": str(source), "assets": expected}), encoding="utf-8")
        # Run the verifier outside the checkout with Python import isolation.
        verifier = work / "ci_smoke.py"
        shutil.copy2(Path(__file__).resolve(), verifier)
        run([str(python), "-I", str(verifier), "installed", "--manifest", str(manifest)],
            cwd=work, env=env, timeout=120)
    print("sdist -> wheel -> clean-venv smoke passed", flush=True)


def installed_smoke(manifest_path):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    source = Path(manifest["source"]).resolve()
    require(sys.prefix != sys.base_prefix, "Wheel verification requires a fresh venv")
    require(not Path.cwd().resolve().is_relative_to(source), "Smoke cwd is inside the checkout")
    require(all(not Path(path).resolve().is_relative_to(source) for path in sys.path),
            "Checkout leaked into the smoke import path")
    preflight("base")

    import pymybot
    from pymybot.agent_skills import SkillsLibrary, default_skills_root
    from pymybot.cli import default_scripts_dir
    from pymybot.robot import module_roots

    package = Path(pymybot.__file__).resolve().parent
    require(package.is_relative_to(Path(sys.prefix).resolve()) and not package.is_relative_to(source),
            f"pymybot was not imported from the wheel venv: {package}")
    assets = package / "assets"
    actual = asset_manifest(assets)
    expected = manifest["assets"]
    missing, extra = sorted(expected.keys() - actual.keys()), sorted(actual.keys() - expected.keys())
    changed = sorted(key for key in expected.keys() & actual.keys() if expected[key] != actual[key])
    require(not (missing or extra or changed),
            f"Wheel assets differ from source: missing={missing}, extra={extra}, changed={changed}")
    require(module_roots() == [assets / "modules"], "Default modules did not resolve to wheel assets")
    require(default_scripts_dir() == assets / "scripts", "Default scripts did not resolve to wheel assets")
    require(default_skills_root() == assets / "skills", "Default skills did not resolve to wheel assets")
    skills = SkillsLibrary(default_skills_root(), required=True)
    require(skills.enabled, "Packaged skills did not load")
    for skill in skills.index()["skills"]:
        for name in skill["files"]:
            skills.read(skill["name"], name)

    env = smoke_env()
    cli = [sys.executable, "-I", "-m", "pymybot"]

    def command_json(command):
        result = subprocess.run(command, cwd=Path.cwd(), env=env,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        if result.returncode:
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            result.check_returncode()
        payload = json.loads(result.stdout)
        require(payload.get("ok") is True, f"CLI smoke failed: {payload}")
        return payload

    run([*cli, "--help"], cwd=Path.cwd(), env=env, timeout=30)
    # Also verify the generated console entry point, not just python -m.
    console = Path(sys.executable).parent / ("pymybot.exe" if os.name == "nt" else "pymybot")
    scripts = command_json([str(console), "scripts"])
    require(Path(scripts["scripts_dir"]).resolve() == assets / "scripts", "Console used non-wheel scripts")
    require(scripts["scripts"] == sorted(key.removeprefix("scripts/") for key in expected
                                         if key.startswith("scripts/")), "Packaged script listing is incomplete")
    robot = str(assets / "robots" / "relay-test.sql")
    action = str(assets / "scripts" / "relay-test.mt")
    checked = command_json([*cli, "check", "--robot", robot, "--input", action])
    require(checked.get("valid") is True and checked.get("activated") is False,
            "Packaged quickstart check failed")
    # Only Timer/Relay run; neither hardware permissions nor model access are enabled.
    executed = command_json([*cli, "--no-agent", "--robot", robot, "--input", action, "--timeout", "10"])
    require(executed.get("command") == "run" and executed.get("outputs"), "No-agent execution produced no outputs")
    preflight("base")
    print(f"Verified {len(actual)} packaged assets and no-agent CLI from {package}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("base", "agent", "wheel", "installed"))
    parser.add_argument("--manifest", type=Path, help="internal: expected assets for the installed verifier")
    args = parser.parse_args()
    if args.mode == "installed":
        if args.manifest is None:
            parser.error("installed requires --manifest")
        installed_smoke(args.manifest.resolve())
    elif args.mode == "wheel":
        wheel_smoke()
    else:
        preflight(args.mode)


if __name__ == "__main__":
    main()
