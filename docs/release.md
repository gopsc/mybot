# Release process

## Version scheme

pymybot uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR** — incompatible script/CLI/API changes;
- **MINOR** — backward-compatible features (new commands/tools/drivers);
- **PATCH** — backward-compatible fixes.

Pre-1.0 releases still use `0.x.y`; breaking changes are documented in
`CHANGELOG.md` and called out in the release notes.

The Python reference edition, Cangjie edition and C++17 + Rust edition version
independently. A repository-wide tag (`v0.3.1`) describes the reference edition
and the state of the monorepo; edition-specific versions live in
`pymybot/__init__.py`, `implementations/cangjie/cjpm.toml` and
`implementations/cpp-rust/agent/Cargo.toml`.

## Release checklist

1. The default branch (`gui-mybot`) is green on every CI channel.
2. Version bumped in `pymybot/__init__.py`, `pyproject.toml` and `CITATION.cff`.
   The tag must equal all three version sources; the release workflow rejects
   a mismatch.
3. `CHANGELOG.md` has a dated section; docs/screenshots are current.
4. `python -I tools/ci_smoke.py wheel` passes locally.
5. Commit, tag `vX.Y.Z`, push the tag. For a pre-release, use the same PEP 440
   version in all version files and the tag (for example `0.4.0rc1` / `v0.4.0rc1`);
   tags containing `rc` or `beta` are published as GitHub prereleases.
6. The release workflow builds:
   - `pymybot-X.Y.Z.tar.gz` (sdist);
   - `pymybot-X.Y.Z-py3-none-any.whl`;
   - `pymybot-X.Y.Z-windows-x64.zip` (GUI + console, with PyAV camera support);
   - `SHA256SUMS`.
7. Verify the published assets and the Windows `doctor` output, which must
   report `av` as importable. If an asset is broken, follow the rollback steps
   below rather than editing the release in place.
8. Announce the release and close the milestone.

## Reproducibility rules

- The artifact must be built from the tagged commit, not a working tree.
- The workflow checks out the tag with `fetch-depth: 0` and records the commit
  SHA in the release notes.
- No shared credentials, local config, editor state or `dist/` output may enter
  the artifact.
- The Windows zip is built from `tools/mybot.spec`; the same spec is used for
  local smoke builds.

## Branch and tag policy

- Default branch (`gui-mybot`) — only long-lived branch.
- `feat/*`, `fix/*`, `docs/*`, `ci/*`, `chore/*` — short-lived, deleted after
  merge.
- `archive/*` tags preserve historical implementation branches.
- Never force-push the default branch; never rewrite published release tags.

## Rollback

If a release is broken:

1. Mark the GitHub release as “withdrawn” and remove broken assets.
2. Publish a patch release with the fix.
3. If a credential was included, rotate it immediately and document the
   incident in the release notes.

The withdrawn `gui-v1` asset is the reference example: it was built from an
unpublished tree and contained a shared key. It must not be redistributed.
