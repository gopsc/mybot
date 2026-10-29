from pathlib import Path
from shutil import copy2, rmtree

from setuptools.command.build_py import build_py


class BuildPy(build_py):
    def run(self):
        super().run()
        root = Path(__file__).parent
        destination = Path(self.build_lib) / "pymybot" / "assets"
        if destination.exists():
            rmtree(destination)
        for name, suffix in (
            ("modules", ".py"), ("modules", ".lua"),
            ("robots", ".sql"), ("scripts", ".mt"), ("skills", ".md"),
        ):
            for source in sorted((root / name).rglob("*" + suffix)):
                target = destination / source.relative_to(root)
                target.parent.mkdir(parents=True, exist_ok=True)
                copy2(source, target)
