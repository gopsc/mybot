from pathlib import Path
from shutil import copy2, rmtree

from setuptools.command.build_py import build_py


class BuildPy(build_py):
    """Ship the default robots, modules and action scripts inside the wheel.

    The sources already live in the package (``pymybot/``); only the assets at
    the repository root need copying into ``pymybot/assets``.
    """

    def run(self):
        super().run()
        root = Path(__file__).parent
        destination = Path(self.build_lib) / "pymybot" / "assets"
        if destination.exists():
            rmtree(destination)
        asset_root = root / "assets"
        for name, suffix in (
            ("modules", ".py"), ("modules", ".lua"),
            ("robots", ".sql"), ("scripts", ".mt"),
        ):
            for source in sorted((asset_root / name).rglob("*" + suffix)):
                target = destination / source.relative_to(asset_root)
                target.parent.mkdir(parents=True, exist_ok=True)
                copy2(source, target)
