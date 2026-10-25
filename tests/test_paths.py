import sys

from pymybot import paths


def test_source_assets_fall_back_to_the_checkout(tmp_path, monkeypatch):
    package = tmp_path / "pkg"
    packaged = package / "assets" / "modules"
    packaged.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)

    assert paths.asset_path("modules") == packaged
    assert paths.asset_path("robots") == tmp_path / "robots"


def test_frozen_assets_come_from_meipass(tmp_path, monkeypatch):
    bundle = tmp_path / "bundle"
    expected = bundle / "pymybot" / "assets"
    expected.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: tmp_path / "pkg")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(bundle), raising=False)

    assert paths.asset_dir() == expected
    assert paths.asset_path("skills") == expected / "skills"


def test_nuitka_build_counts_as_frozen(monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    assert not paths.frozen()
    monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    assert paths.frozen()


def test_real_checkout_uses_top_level_directories():
    assert paths.asset_path("modules") == paths.source_root() / "modules"
    assert paths.asset_path("scripts") == paths.source_root() / "scripts"
