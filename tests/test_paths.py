import sys

from pymybot import paths


def test_source_assets_fall_back_to_the_checkout(tmp_path, monkeypatch):
    package = tmp_path / "pkg"
    packaged = package / "assets" / "modules"
    packaged.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)

    assert paths.asset_path("modules") == packaged
    assert paths.asset_path("robots") == tmp_path / "robots"
    assert paths.asset_path("prompts") == tmp_path / "prompts"
    (package / "assets" / "prompts").mkdir()
    assert paths.asset_path("prompts") == package / "assets" / "prompts"


def test_frozen_assets_come_from_meipass(tmp_path, monkeypatch):
    bundle = tmp_path / "bundle"
    expected = bundle / "pymybot" / "assets"
    expected.mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: tmp_path / "pkg")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(bundle), raising=False)

    assert paths.asset_dir() == expected
    assert paths.asset_path("skills") == expected / "skills"
    # Missing frozen prompts must not silently fall back to a checkout.
    assert paths.asset_path("prompts") == expected / "prompts"


def test_nuitka_assets_resolve_beside_executable(tmp_path, monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)
    monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    monkeypatch.setattr(sys, "executable", str(tmp_path / "pymybot.exe"))
    expected = tmp_path / "pymybot" / "assets" / "prompts"
    expected.mkdir(parents=True)
    assert paths.asset_path("prompts") == expected


def test_nuitka_build_counts_as_frozen(monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    assert not paths.frozen()
    monkeypatch.setattr(paths, "__compiled__", object(), raising=False)
    assert paths.frozen()


def test_real_checkout_uses_top_level_directories():
    assert paths.asset_path("modules") == paths.source_root() / "modules"
    assert paths.asset_path("scripts") == paths.source_root() / "scripts"
    assert paths.asset_path("prompts") == paths.source_root() / "prompts"
