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
        for source in sorted((root / "skills" / "hardware-controller" / "scripts" / "pymybot").glob("*.py")):
            target = Path(self.build_lib) / "pymybot" / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            copy2(source, target)
        asset_root = root / "skills" / "hardware-controller" / "references" / "assets"
        for name, suffix in (
            ("modules", ".py"), ("modules", ".lua"),
            ("robots", ".sql"), ("scripts", ".mt"), ("skills", ".md"),
            ("prompts", ".md"), ("prompts", ".json"),
        ):
            source_root = asset_root if name in {"modules", "robots", "scripts"} else root
            for source in sorted((source_root / name).rglob("*" + suffix)):
                target = destination / source.relative_to(source_root)
                target.parent.mkdir(parents=True, exist_ok=True)
                copy2(source, target)
