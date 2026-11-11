from pathlib import Path
from shutil import copy2, rmtree

from setuptools.command.build_py import build_py


class BuildPy(build_py):
    """Ship the controller Runtime and its default assets inside the wheel.

    The controller sources live in the self-contained hardware-controller skill;
    the installed ``pymybot`` package is the same modules plus ``assets/``.
    """

    def run(self):
        super().run()
        root = Path(__file__).parent
        runtime = root / "skills" / "hardware-controller" / "scripts" / "pymybot"
        for source in sorted(runtime.glob("*.py")):
            target = Path(self.build_lib) / "pymybot" / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            copy2(source, target)
        destination = Path(self.build_lib) / "pymybot" / "assets"
        if destination.exists():
            rmtree(destination)
        asset_root = root / "skills" / "hardware-controller" / "assets"
        for name, suffix in (
            ("modules", ".py"), ("modules", ".lua"),
            ("robots", ".sql"), ("scripts", ".mt"),
        ):
            for source in sorted((asset_root / name).rglob("*" + suffix)):
                target = destination / source.relative_to(asset_root)
                target.parent.mkdir(parents=True, exist_ok=True)
                copy2(source, target)
        # Runtime dependency notes are referenced from SKILL.md, so they ship with
        # the assets even though they are not an importable Python module.
        for source in sorted((root / "skills").rglob("requirements.txt")):
            target = destination / source.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            copy2(source, target)
