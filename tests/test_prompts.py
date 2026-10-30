"""Prompt storage uses real files: no in-memory filesystem/security stand-ins."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

import pytest

import pymybot.prompts as prompts
from pymybot.paths import asset_path
from pymybot.security import SecurityError

CORE_SHA = "f83f1fbcf091c5aed6f38f0837bef32c2d408f96bc510838bc328430488939b8"
IDS = ["0", "10", "97", "98", "99", "100"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_manifest(root, manifest):
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")


@pytest.fixture
def library(tmp_path):
    result = prompts.PromptLibrary(home=tmp_path / "runtime" / "prompts")
    result.ensure_home()
    return result


@pytest.fixture
def bundle(tmp_path):
    target = tmp_path / "bundle"
    shutil.copytree(asset_path("prompts"), target)
    return target


def test_constructor_defaults_listing_and_golden_core(tmp_path, monkeypatch):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path / "configured"))
    library = prompts.PromptLibrary()
    assert library.home == tmp_path / "configured" / "prompts"
    assert library.defaults == asset_path("prompts")
    assert not library.home.parent.exists()
    assert all(row["missing"] for row in library.list_layers())
    report = library.validate_defaults()
    assert report["version"] == 1
    assert [row["id"] for row in report["layers"]] == IDS
    assert [row["editable"] for row in library.layers] == [False, True, "agent", "agent", "agent", False]
    assert report["hash"] == sha((library.defaults / "manifest.json").read_bytes())
    assert sha((library.defaults / "010_core.md").read_bytes()) == CORE_SHA
    assert not library.home.parent.exists()
    monkeypatch.delenv("MYBOT_HOME")
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    assert prompts.PromptLibrary().home == tmp_path / ".mybot" / "prompts"


def test_bootstrap_preserves_existing_and_returns_only_created(tmp_path):
    root = tmp_path / "custom-prompts"
    root.mkdir()
    (root / "010_core.md").write_text("operator core\n", encoding="utf-8")
    (root / "unmanaged.txt").write_text("not owned by library", encoding="utf-8")
    library = prompts.PromptLibrary(home=root)
    result = library.ensure_home()
    assert result["root"] == str(root)
    assert len(result["created"]) == 6
    assert "010_core.md" not in result["created"]
    assert library.read("10")["content"] == "operator core\n"
    assert (root / "unmanaged.txt").read_text() == "not owned by library"
    assert library.ensure_home()["created"] == []
    rows = library.list_layers()
    assert rows[1]["modified"] and rows[1]["bytes"] == len(b"operator core\n")
    assert isinstance(rows[1]["mtime"], float)
    assert not any(row["missing"] for row in rows)
    assert not rows[0]["modified"]


def test_windows_stamps_ignore_creation_versus_change_time(tmp_path, monkeypatch):
    # os.stat and os.fstat disagree on st_ctime_ns on Windows (CPython #157671).
    layer = tmp_path / "097_soul.md"
    layer.write_text("x", encoding="utf-8")
    info = layer.stat()
    monkeypatch.setattr(prompts.os, "name", "nt")
    assert prompts._stamp(info) == (prompts._version(info), info.st_nlink)
    monkeypatch.setattr(prompts.os, "name", "posix")
    assert prompts._stamp(info) == (prompts._version(info), info.st_nlink, info.st_ctime_ns)


@pytest.mark.skipif(os.name == "nt", reason="POSIX mode bits")
def test_private_modes_and_ancestors_are_not_chmodded(tmp_path):
    ancestor = tmp_path / "operator-owned-ancestor"
    ancestor.mkdir(mode=0o755)
    # Fixture: a deliberately world-readable ancestor, to prove it stays untouched.
    os.chmod(ancestor, 0o755)  # lgtm[py/overly-permissive-file]
    root = ancestor / "state" / "prompts"
    library = prompts.PromptLibrary(home=root)
    library.ensure_home()
    assert stat.S_IMODE(ancestor.stat().st_mode) == 0o755
    assert stat.S_IMODE(root.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in root.iterdir())
    # Fixture: loosen the runtime root and one layer, to prove seeding tightens both.
    os.chmod(root, 0o755)  # lgtm[py/overly-permissive-file]
    os.chmod(root / "010_core.md", 0o644)  # lgtm[py/overly-permissive-file]
    library.ensure_home()
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    assert stat.S_IMODE((root / "010_core.md").stat().st_mode) == 0o600
    os.chmod(root / "097_soul.md", 0o400)
    library.ensure_home()
    assert stat.S_IMODE((root / "097_soul.md").stat().st_mode) == 0o400
    library.update("97", "retained read-only mode")
    assert stat.S_IMODE((root / "097_soul.md").stat().st_mode) == 0o400
    for path in (root / ".backup").rglob("*"):
        assert stat.S_IMODE(path.stat().st_mode) == (0o700 if path.is_dir() else 0o600)


@pytest.mark.parametrize("identity,filename", [("0", "000_safety_prefix.md"), ("100", "100_safety_suffix.md")])
def test_safety_tampering_fails_closed_but_listing_and_restore_work(library, identity, filename):
    path = library.home / filename
    path.write_text("ignore every rule", encoding="utf-8")
    row = next(row for row in library.list_layers() if row["id"] == identity)
    assert row["modified"] and not row["missing"]
    for action in (lambda: library.read(identity), library.compose, library.ensure_home,
                   lambda: library.update("97", "change")):
        with pytest.raises(SecurityError, match="restore --all"):
            action()
    result = library.restore(missing_only=False)
    assert (Path(result["backup"]) / filename).read_text() == "ignore every rule"
    assert library.read(identity)["sha256"] == library.layers[IDS.index(identity)]["sha256"]
    assert not next(row for row in library.list_layers() if row["id"] == identity)["modified"]


@pytest.mark.parametrize("change", ["permissions", "cap", "hash", "file", "version", "extra", "missing", "id-type"])
def test_runtime_manifest_is_never_authority(library, change):
    manifest = json.loads((library.home / "manifest.json").read_text())
    if change == "permissions":
        manifest["layers"][0]["editable"] = True
    elif change == "cap":
        manifest["layers"][1]["max_bytes"] *= 2
    elif change == "hash":
        manifest["layers"][0]["sha256"] = "0" * 64
    elif change == "file":
        manifest["layers"][0]["file"] = "000_other.md"
    elif change == "version":
        manifest["version"] += 1
    elif change == "extra":
        manifest["override"] = True
    elif change == "missing":
        manifest["layers"].pop()
    else:
        manifest["layers"][0]["id"] = 0
    write_manifest(library.home, manifest)
    for action in (library.ensure_home, library.compose, lambda: library.read("10"),
                   lambda: library.update("97", "no")):
        with pytest.raises(SecurityError, match="restore --all"):
            action()
    assert len(library.list_layers()) == 6
    library.restore(missing_only=False)
    assert library.read("10")["sha256"] == CORE_SHA


def test_duplicate_runtime_json_keys_rejected(library):
    path = library.home / "manifest.json"
    original = path.read_text()
    path.write_text(original.replace('"version": 1', '"version": 0, "version": 1'))
    with pytest.raises(SecurityError, match="Duplicate"):
        library.ensure_home()
    library.restore(missing_only=False)
    assert library.compose().text


def test_old_manifest_upgrade_adds_layers_without_replacing_content(library, bundle):
    manifest = json.loads((bundle / "manifest.json").read_text())
    manifest["version"] = 2
    write_manifest(bundle, manifest)
    old = json.loads((library.home / "manifest.json").read_text())
    old["layers"] = [layer for layer in old["layers"] if layer["id"] != "97"]
    write_manifest(library.home, old)
    (library.home / "097_soul.md").unlink()
    (library.home / "098_user.md").write_text("retained user memory", encoding="utf-8")
    upgraded = prompts.PromptLibrary(home=library.home, defaults=bundle)
    result = upgraded.ensure_home()
    assert result["created"] == ["097_soul.md"]
    assert upgraded.read("98")["content"] == "retained user memory"
    assert json.loads((upgraded.home / "manifest.json").read_text())["version"] == 2
    archived = list((upgraded.home / ".backup").glob("*/manifest.json"))
    assert len(archived) == 1 and json.loads(archived[0].read_text()) == old
    old["layers"][1]["max_bytes"] += 1
    write_manifest(library.home, old)
    with pytest.raises(SecurityError, match="Older runtime"):
        upgraded.ensure_home()


def test_restore_missing_only_preserves_changes_and_all_archives(library):
    library.update("97", "soul change", reason="test")
    (library.home / "098_user.md").unlink()
    result = library.restore()
    assert result["created"] == ["098_user.md"] and result["backup"] is None
    assert library.read("97")["content"] == "soul change"
    result = library.restore(missing_only=False)
    backup = Path(result["backup"])
    assert (backup / "097_soul.md").read_text() == "soul change"
    assert (backup / "manifest.json").is_file()
    assert len(json.loads((backup / "metadata.json").read_text())["files"]) == 7
    assert library.read("97")["content"] == ""


@pytest.mark.parametrize("bad", [b"not json", b"\xff\x00", b"x" * 40000])
def test_full_restore_repairs_opaque_corruption(library, bad):
    (library.home / "manifest.json").write_bytes(bad)
    (library.home / "000_safety_prefix.md").write_bytes(bad)
    assert len(library.list_layers()) == 6
    with pytest.raises(SecurityError):
        library.compose()
    result = library.restore(missing_only=False)
    assert (Path(result["backup"]) / "manifest.json").read_bytes() == bad
    assert (Path(result["backup"]) / "000_safety_prefix.md").read_bytes() == bad
    assert library.compose().layer_hashes["10"] == CORE_SHA


def test_update_audits_hashes_and_cas(library):
    before = library.read("97")
    result = library.update("97", "private memory", actor="agent", reason="approved learning",
                            expected_hash=before["sha256"])
    assert result == {"layer": "97", "old_hash": before["sha256"],
                      "new_hash": sha(b"private memory"), "backup": result["backup"],
                      "actor": "agent", "reason": "approved learning"}
    backup = Path(result["backup"])
    assert (backup / "097_soul.md").read_bytes() == b""
    metadata = json.loads((backup / "metadata.json").read_text())
    assert metadata["actor"] == "agent" and metadata["reason"] == "approved learning"
    assert metadata["files"]["097_soul.md"] == {"old_hash": before["sha256"], "new_hash": sha(b"private memory")}
    assert "private memory" not in (backup / "metadata.json").read_text()
    with pytest.raises(SecurityError, match="conflict"):
        library.update("97", "stale save", expected_hash=before["sha256"])
    assert library.read("97")["content"] == "private memory"
    assert library.update("97", "private memory")["backup"] is None


@pytest.mark.parametrize("actor,allowed", [("operator", {"10", "97", "98", "99"}),
                                             ("agent", {"97", "98", "99"}), ("stats", {"99"}),
                                             ("other", set())])
def test_actor_permissions(library, actor, allowed):
    for identity in IDS:
        if identity in allowed:
            assert library.update(identity, "allowed", actor=actor)["layer"] == identity
        else:
            with pytest.raises(SecurityError, match="not permitted"):
                library.update(identity, "forbidden", actor=actor)


def test_utf8_caps_and_invalid_text(library):
    cap = next(layer["max_bytes"] for layer in library.layers if layer["id"] == "97")
    content = "界" * (cap // 3) + "x" * (cap % 3)
    library.update("97", content)
    assert library.read("97")["bytes"] == cap
    for bad in (content + "x", "\0", "\ud800", b"not a string"):
        with pytest.raises(SecurityError):
            library.update("97", bad)
    for bad in (b"\xff", b"x\0y", b"x" * (cap + 1)):
        (library.home / "097_soul.md").write_bytes(bad)
        with pytest.raises(SecurityError):
            library.read("97")
        with pytest.raises(SecurityError):
            library.compose()
    library.restore(missing_only=False)
    for bad in ("\0", "\ud800", 42):
        with pytest.raises(SecurityError):
            library.compose(context=bad)


def test_composition_order_total_utf8_safety_and_hashes(library):
    for identity in ("97", "98", "99"):
        library.update(identity, "layer-" + identity)
    result = library.compose(operator="operator input", guide="guide input", project="project input",
                             context="context input", intent="intent input")
    assert result.sections == ["0", "10", "operator", "97", "98", "99", "guide", "project", "context", "intent", "100"]
    markers = ["PROMPT LAYER 0:", "PROMPT LAYER 10:", "operator input", "layer-97", "layer-98", "layer-99",
               "guide input", "project input", "context input", "intent input", "PROMPT LAYER 100:"]
    assert [result.text.index(marker) for marker in markers] == sorted(result.text.index(marker) for marker in markers)
    assert "UNTRUSTED PROJECT DATA" in result.text and "UNTRUSTED CONTEXT DATA" in result.text
    assert result.text.endswith(library.read("100")["content"])
    assert result.digest == sha(result.text.encode("utf-8"))
    assert result.layer_hashes == {identity: library.read(identity)["sha256"] for identity in IDS}
    assert result.truncated == []
    capped = library.compose(operator="界" * prompts.MAX_PROMPT_TOTAL, project="context" * prompts.MAX_PROMPT_TOTAL,
                             intent="intent" * prompts.MAX_PROMPT_TOTAL)
    assert len(capped.text.encode("utf-8")) <= prompts.MAX_PROMPT_TOTAL
    assert capped.truncated == ["operator", "project", "intent"]
    assert capped.text.endswith(library.read("100")["content"])
    for identity in IDS:
        assert library.read(identity)["content"] in capped.text
    assert capped.digest == sha(capped.text.encode("utf-8"))


def test_required_layers_never_silently_truncated(tmp_path, bundle):
    manifest = json.loads((bundle / "manifest.json").read_text())
    for layer in manifest["layers"]:
        layer["max_bytes"] = 65536
    write_manifest(bundle, manifest)
    library = prompts.PromptLibrary(home=tmp_path / "runtime", defaults=bundle)
    library.ensure_home()
    library.update("10", "a" * 65536)
    library.update("97", "b" * 65536)
    with pytest.raises(SecurityError, match="Required prompt layers exceed"):
        library.compose()


@pytest.mark.parametrize("bad_id", [0, 10, "000", "../010_core.md", "/tmp/file", "10/../97", "97\0", None, []])
def test_layer_ids_are_not_paths(library, bad_id):
    with pytest.raises(SecurityError):
        library.read(bad_id)
    with pytest.raises(SecurityError):
        library.update(bad_id, "bad")


def symlink_or_skip(link, target):
    try:
        link.symlink_to(target, target_is_directory=target.is_dir())
    except (OSError, NotImplementedError):
        pytest.skip("Symlinks unavailable")
    if not link.is_symlink():
        pytest.skip("Symlink creation silently unavailable")


def test_symlinked_roots_ancestors_and_defaults_rejected(tmp_path, bundle):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "linked"
    symlink_or_skip(link, real)
    library = prompts.PromptLibrary(home=link / "prompts")
    assert not (real / "prompts").exists()
    for action in (library.ensure_home, library.list_layers, lambda: library.restore(False)):
        with pytest.raises((SecurityError, OSError)):
            action()
    symlink_or_skip(tmp_path / "linked-bundle", bundle)
    with pytest.raises((SecurityError, OSError)):
        prompts.PromptLibrary(defaults=tmp_path / "linked-bundle")
    with pytest.raises(SecurityError, match="traversal"):
        prompts.PromptLibrary(home=real / ".." / "elsewhere")


@pytest.mark.parametrize("name", ["097_soul.md", "000_safety_prefix.md", "manifest.json", ".prompts.lock"])
@pytest.mark.parametrize("kind", ["symlink", "hardlink", "fifo", "directory"])
def test_linked_or_special_runtime_files_rejected(library, tmp_path, name, kind):
    target = tmp_path / "outside"
    target.write_bytes((library.home / name).read_bytes())
    path = library.home / name
    path.unlink()
    if kind == "symlink":
        symlink_or_skip(path, target)
    elif kind == "hardlink":
        try:
            os.link(target, path)
        except OSError:
            pytest.skip("Hardlinks unavailable")
    elif kind == "fifo":
        if not hasattr(os, "mkfifo"):
            pytest.skip("FIFOs unavailable")
        os.mkfifo(path)
    else:
        path.mkdir()
    before = target.read_bytes()
    for action in (library.ensure_home, library.compose, lambda: library.restore(False)):
        with pytest.raises((SecurityError, OSError)):
            action()
    assert target.read_bytes() == before


def test_linked_backup_directory_rejected_before_overwrite(library, tmp_path):
    outside = tmp_path / "backups-outside"
    outside.mkdir()
    symlink_or_skip(library.home / ".backup", outside)
    before = library.read("97")["sha256"]
    with pytest.raises((SecurityError, OSError)):
        library.update("97", "not written")
    with pytest.raises((SecurityError, OSError)):
        library.restore(False)
    assert library.read("97")["sha256"] == before
    assert list(outside.iterdir()) == []


@pytest.mark.parametrize("mutation", ["duplicate-id", "traversal", "backslash", "huge-cap", "bool-cap", "bool-version", "hash", "editable", "extra", "missing"])
def test_trusted_manifest_validation(tmp_path, bundle, mutation):
    manifest = json.loads((bundle / "manifest.json").read_text())
    layer = manifest["layers"][1]
    if mutation == "duplicate-id":
        manifest["layers"].append(dict(layer))
    elif mutation == "traversal":
        layer["file"] = "../010_core.md"
    elif mutation == "backslash":
        layer["file"] = "010_..\\core.md"
    elif mutation == "huge-cap":
        layer["max_bytes"] = 2 ** 50
    elif mutation == "bool-cap":
        layer["max_bytes"] = True
    elif mutation == "bool-version":
        manifest["version"] = True
    elif mutation == "hash":
        layer["sha256"] = "0" * 64
    elif mutation == "editable":
        layer["editable"] = 1
    elif mutation == "extra":
        layer["permissions"] = "all"
    else:
        manifest["layers"].pop()
    write_manifest(bundle, manifest)
    with pytest.raises(SecurityError):
        prompts.PromptLibrary(home=tmp_path / "untouched", defaults=bundle)
    assert not (tmp_path / "untouched").exists()


def test_default_file_links_and_duplicate_keys_rejected(tmp_path, bundle):
    path = bundle / "010_core.md"
    outside = tmp_path / "original-core"
    path.rename(outside)
    os.link(outside, path)
    with pytest.raises(SecurityError, match="Hardlinked"):
        prompts.PromptLibrary(defaults=bundle)
    path.unlink()
    path.write_bytes(outside.read_bytes())
    manifest = bundle / "manifest.json"
    manifest.write_text(manifest.read_text().replace('"version": 1', '"version": 1, "version": 1'))
    with pytest.raises(SecurityError, match="Duplicate"):
        prompts.PromptLibrary(defaults=bundle)


def test_public_layer_metadata_cannot_weaken_authority(library):
    layers = library.layers
    layers[0]["editable"] = True
    layers[2]["max_bytes"] = 999999
    with pytest.raises(SecurityError):
        library.update("0", "forbidden")
    with pytest.raises(SecurityError):
        library.update("97", "x" * 9000)
    assert library.layers[0]["editable"] is False


def test_threaded_cas_has_exactly_one_winner(library):
    expected = library.read("97")["sha256"]

    def save(index):
        other = prompts.PromptLibrary(home=library.home)
        try:
            other.update("97", str(index), expected_hash=expected)
            return "saved"
        except SecurityError as exc:
            assert "conflict" in str(exc)
            return "conflict"

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(save, range(4)))
    assert results.count("saved") == 1 and results.count("conflict") == 3


def test_process_cas_has_exactly_one_winner(library):
    expected = library.read("97")["sha256"]
    program = """
import sys
from pymybot.prompts import PromptLibrary
from pymybot.security import SecurityError
try:
    PromptLibrary(home=sys.argv[1]).update('97', sys.argv[3], expected_hash=sys.argv[2])
except SecurityError as exc:
    if 'conflict' not in str(exc):
        raise
    sys.exit(7)
"""
    children = [subprocess.Popen([sys.executable, "-c", program, str(library.home), expected, str(index)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 cwd=str(Path(__file__).absolute().parents[1])) for index in range(3)]
    codes = []
    for child in children:
        _, err = child.communicate(timeout=30)
        codes.append(child.returncode)
        assert child.returncode in (0, 7), err.decode()
    assert sorted(codes) == [0, 7, 7]


def test_replace_failure_keeps_original_and_backup(library, monkeypatch):
    old = library.read("97")
    original_replace = prompts.os.replace

    def fail_replace(src, dst, *args, **kwargs):
        if str(dst).endswith("097_soul.md"):
            raise OSError("simulated replace failure")
        return original_replace(src, dst, *args, **kwargs)

    monkeypatch.setattr(prompts.os, "replace", fail_replace)
    with pytest.raises(OSError, match="simulated"):
        library.update("97", "must not appear")
    assert library.read("97") == old
    assert list((library.home / ".backup").glob("*/097_soul.md"))
    assert not list(library.home.glob(".prompt-*.tmp"))


def test_postpublish_failure_reports_unknown_outcome(library, monkeypatch):
    if not prompts._DIR_FD:
        pytest.skip("Directory fsync requires POSIX descriptors")
    identity = library.home.stat().st_ino
    original_fsync = prompts.os.fsync

    def fail_home_sync(fd):
        if os.fstat(fd).st_ino == identity:
            raise OSError("simulated durability failure")
        return original_fsync(fd)

    monkeypatch.setattr(prompts.os, "fsync", fail_home_sync)
    with pytest.raises(prompts.PromptWriteError, match="unknown"):
        library.update("97", "already replaced")
    assert library.read("97")["content"] == "already replaced"


def test_lock_contention_fails_without_blocking(library):
    other = prompts.PromptLibrary(home=library.home)
    with library._locked():
        with pytest.raises(SecurityError, match="lock conflict"):
            other.read("97")


def test_manifest_and_files_are_bounded_before_decoding(library, bundle, monkeypatch):
    cap = next(layer["max_bytes"] for layer in library.layers if layer["id"] == "97")
    with (library.home / "097_soul.md").open("wb") as stream:
        stream.truncate(cap + 1)
    original_read = prompts.os.read

    def no_read(descriptor, count):
        if os.fstat(descriptor).st_size > cap:
            raise AssertionError("Oversized file must be rejected before reading")
        return original_read(descriptor, count)

    monkeypatch.setattr(prompts.os, "read", no_read)
    with pytest.raises(SecurityError, match="byte limit"):
        library.read("97")
    (bundle / "manifest.json").write_bytes(b" " * (32 * 1024 + 1))
    with pytest.raises(SecurityError, match="byte limit"):
        prompts.PromptLibrary(defaults=bundle)


def test_bundle_can_be_inspected_but_not_mutated(bundle):
    library = prompts.PromptLibrary(home=bundle, defaults=bundle)
    before = (bundle / "manifest.json").stat().st_mode
    assert library.validate_defaults()["version"] == 1
    with pytest.raises(SecurityError, match="trusted bundle"):
        library.ensure_home()
    with pytest.raises(SecurityError, match="trusted bundle"):
        library.restore(False)
    assert not (bundle / ".prompts.lock").exists()
    assert (bundle / "manifest.json").stat().st_mode == before
