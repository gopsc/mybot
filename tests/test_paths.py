import sys

import pytest

from conftest import usable_symlink
from pymybot import paths


def test_source_assets_fall_back_to_the_checkout(tmp_path, monkeypatch):
    package = tmp_path / "pkg"
    packaged = package / "assets" / "modules"
    packaged.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)
    monkeypatch.setattr(paths, "source_root", lambda: tmp_path)

    assert paths.asset_path("modules") == packaged
    source_robots = tmp_path / "assets" / "robots"
    source_robots.mkdir(parents=True)
    assert paths.asset_path("robots") == source_robots
    assert paths.asset_path("shared") == tmp_path / "shared"
    (package / "assets" / "shared").mkdir()
    assert paths.asset_path("shared") == package / "assets" / "shared"


def test_frozen_assets_come_from_meipass(tmp_path, monkeypatch):
    bundle = tmp_path / "bundle"
    expected = bundle / "pymybot" / "assets"
    expected.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: tmp_path / "pkg")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(bundle), raising=False)

    assert paths.asset_dir() == expected
    assert paths.asset_path("modules") == expected / "modules"
    # Missing frozen assets must not silently fall back to a checkout.
    assert paths.asset_path("robots") == expected / "robots"


def test_nuitka_assets_resolve_beside_executable(tmp_path, monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)
    monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    monkeypatch.setattr(sys, "executable", str(tmp_path / "pymybot.exe"))
    expected = tmp_path / "pymybot" / "assets" / "modules"
    expected.mkdir(parents=True)
    assert paths.asset_path("modules") == expected


def test_nuitka_build_counts_as_frozen(monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    assert not paths.frozen()
    monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    assert paths.frozen()


def test_real_checkout_uses_root_assets():
    assets = paths.source_root() / "assets"
    assert paths.asset_path("modules") == assets / "modules"
    assert paths.asset_path("scripts") == assets / "scripts"
    assert paths.asset_path("robots") == assets / "robots"


@pytest.mark.parametrize("with_pyproject", [False, True], ids=["skill-copy", "checkout"])
def test_source_bundle_roots_protect_skill_root(tmp_path, monkeypatch, with_pyproject):
    skill = tmp_path / "skill"
    package = skill / "scripts" / "pymybot"
    package.mkdir(parents=True)
    if with_pyproject:
        (skill / "pyproject.toml").write_text("[project]\n", encoding="utf-8")
    source = skill if with_pyproject else skill / "scripts"
    assets = {source / "assets" / kind for kind in ("robots", "modules", "scripts")}
    for asset in assets:
        asset.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)
    monkeypatch.setattr(paths, "frozen", lambda: False)

    assert paths.bundle_roots() == {skill, package, package / "assets", *assets}


def test_wheel_bundle_roots_do_not_protect_all_site_packages(tmp_path, monkeypatch):
    site_packages = tmp_path / "site-packages"
    package = site_packages / "pymybot"
    assets = package / "assets"
    kinds = {assets / kind for kind in ("robots", "modules", "scripts")}
    for kind in kinds:
        kind.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)
    monkeypatch.setattr(paths, "frozen", lambda: False)

    roots = paths.bundle_roots()

    assert roots == {package, assets, *kinds}
    assert not any((site_packages / "another-package").is_relative_to(root) for root in roots)


@pytest.mark.parametrize("runtime", ["pyinstaller", "pyinstaller-no-meipass", "nuitka"])
def test_frozen_bundle_roots_include_executable_and_extraction(tmp_path, monkeypatch, runtime):
    executable_dir = tmp_path / "install"
    executable_dir.mkdir()
    package = tmp_path / "package" / "pymybot"
    package.mkdir(parents=True)
    bundle = tmp_path / "extraction" if runtime == "pyinstaller" else executable_dir
    assets = bundle / "pymybot" / "assets"
    kinds = {assets / kind for kind in ("robots", "modules", "scripts")}
    for kind in kinds:
        kind.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)
    monkeypatch.setattr(sys, "executable", str(executable_dir / "pymybot.exe"))
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)
    monkeypatch.delattr(paths, "__compiled__", raising=False)
    if runtime == "nuitka":
        monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    else:
        monkeypatch.setattr(sys, "frozen", True, raising=False)
    if runtime == "pyinstaller":
        monkeypatch.setattr(sys, "_MEIPASS", str(bundle), raising=False)

    assert paths.bundle_roots() == {package, assets, *kinds, executable_dir, bundle}


@pytest.mark.parametrize("runtime", ["source", "pyinstaller", "nuitka"])
def test_bundle_roots_resolve_directory_and_executable_aliases(tmp_path, monkeypatch, runtime):
    real = {}
    aliases = {}
    for name in ("package", "assets", "robots", "modules", "scripts", "extraction"):
        real[name] = tmp_path / "real" / name
        real[name].mkdir(parents=True)
        aliases[name] = tmp_path / (name + "-alias")
        if not usable_symlink(aliases[name], real[name]):
            pytest.skip("symlinks are not usable on this platform")
    executable_dir = tmp_path / "install"
    executable_dir.mkdir()
    executable = executable_dir / "pymybot.exe"
    executable.write_text("test executable\n", encoding="utf-8")
    launcher = tmp_path / "pymybot-alias.exe"
    if not usable_symlink(launcher, executable):
        pytest.skip("symlinks are not usable on this platform")
    monkeypatch.setattr(paths, "package_dir", lambda: aliases["package"])
    monkeypatch.setattr(paths, "asset_dir", lambda: aliases["assets"])
    monkeypatch.setattr(paths, "asset_path", lambda kind: aliases[kind])
    monkeypatch.setattr(sys, "executable", str(launcher))
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)
    monkeypatch.delattr(paths, "__compiled__", raising=False)
    expected = {real[kind] for kind in ("package", "assets", "robots", "modules", "scripts")}
    if runtime == "pyinstaller":
        monkeypatch.setattr(sys, "frozen", True, raising=False)
        monkeypatch.setattr(sys, "_MEIPASS", str(aliases["extraction"]), raising=False)
        expected.add(real["extraction"])
    elif runtime == "nuitka":
        monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    if runtime != "source":
        expected.add(executable_dir)

    assert paths.bundle_roots() == expected
