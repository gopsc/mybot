import sys

from pymybot import paths


def test_source_assets_fall_back_to_the_checkout(tmp_path, monkeypatch):
    package = tmp_path / "pkg"
    packaged = package / "assets" / "modules"
    packaged.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)
    monkeypatch.setattr(paths, "source_root", lambda: tmp_path)

    assert paths.asset_path("modules") == packaged
    skill_robots = package.parent.parent / "assets" / "robots"
    skill_robots.mkdir(parents=True)
    assert paths.asset_path("robots") == skill_robots
    assert paths.asset_path("skills") == tmp_path / "skills"
    (package / "assets" / "skills").mkdir()
    assert paths.asset_path("skills") == package / "assets" / "skills"


def test_frozen_assets_come_from_meipass(tmp_path, monkeypatch):
    bundle = tmp_path / "bundle"
    expected = bundle / "pymybot" / "assets"
    expected.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: tmp_path / "pkg")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(bundle), raising=False)

    assert paths.asset_dir() == expected
    assert paths.asset_path("skills") == expected / "skills"
    # Missing frozen assets must not silently fall back to a checkout.
    assert paths.asset_path("robots") == expected / "robots"


def test_nuitka_assets_resolve_beside_executable(tmp_path, monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)
    monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    monkeypatch.setattr(sys, "executable", str(tmp_path / "pymybot.exe"))
    expected = tmp_path / "pymybot" / "assets" / "skills"
    expected.mkdir(parents=True)
    assert paths.asset_path("skills") == expected


def test_nuitka_build_counts_as_frozen(monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    assert not paths.frozen()
    monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    assert paths.frozen()


def test_real_checkout_uses_skill_assets_and_shared_directories():
    assets = paths.source_root() / "skills" / "hardware-controller" / "assets"
    assert paths.asset_path("modules") == assets / "modules"
    assert paths.asset_path("scripts") == assets / "scripts"
    assert paths.asset_path("skills") == paths.source_root() / "skills"
