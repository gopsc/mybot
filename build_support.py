import json
from pathlib import Path
from shutil import copy2, rmtree

from setuptools.command.build_py import build_py


def _skill_scripts(root):
    """Skill entrypoints ship with the wheel unless the manifest uses the CLI fallback.

    The hardware-controller Runtime is packaged as ``pymybot/*.py`` and declares
    ``packaged: "cli"``, so copying its skill scripts would duplicate it.
    """
    skills_dir = root / "skills"
    for skill_dir in sorted(skills_dir.iterdir()):
        if not skill_dir.is_dir():
            continue
        manifest = skill_dir / "skill.json"
        if manifest.is_file():
            try:
                document = json.loads(manifest.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            run = document.get("run") if isinstance(document, dict) else None
            if isinstance(run, dict) and run.get("packaged") == "cli":
                continue
        scripts_dir = skill_dir / "scripts"
        if scripts_dir.is_dir():
            for source in sorted(scripts_dir.rglob("*.py")):
                if "__pycache__" not in source.parts:
                    yield source


class BuildPy(build_py):
    def run(self):
        super().run()
        root = Path(__file__).parent
        destination = Path(self.build_lib) / "pymybot" / "assets"
        if destination.exists():
            rmtree(destination)
        for source in sorted((root / "skills" / "hardware-controller" / "scripts" / "pymybot").glob("*.py")):
            target = Path(self.build_lib) / "pymybot" / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            copy2(source, target)
        asset_root = root / "skills" / "hardware-controller" / "assets"
        for name, suffix in (
            ("modules", ".py"), ("modules", ".lua"),
            ("robots", ".sql"), ("scripts", ".mt"), ("skills", ".md"),
            ("skills", ".json"), ("prompts", ".md"), ("prompts", ".json"),
        ):
            source_root = asset_root if name in {"modules", "robots", "scripts"} else root
            for source in sorted((source_root / name).rglob("*" + suffix)):
                target = destination / source.relative_to(source_root)
                target.parent.mkdir(parents=True, exist_ok=True)
                copy2(source, target)
        for source in _skill_scripts(root):
            target = destination / source.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            copy2(source, target)
