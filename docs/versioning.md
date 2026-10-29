# Versioning and compatibility

## Repository version

The repository tag `vX.Y.Z` describes the Python package. The version sources
are `pymybot/__init__.py`, `pyproject.toml` and `CITATION.cff` (currently
0.3.1).

## Compatibility promises

Within a minor line (`0.3.x`):

- CLI command names and JSON keys remain stable.
- `robots/*.sql` and `scripts/*.mt` accepted by earlier 0.2.x/0.3.x releases
  remain accepted, except
  where a security fix requires a documented rejection.
- Public Python module paths used by integrations (`pymybot.cli`,
  `pymybot.robot`, `pymybot.serve`) keep their entry points.
- The `serve` JSON-RPC protocol version is reported by `initialize`; new
  optional members may be added.

Breaking changes are allowed in a minor release before 1.0 but must be listed in
`CHANGELOG.md` under **Changed** or **Removed**, with a migration note.

## Script compatibility

The three script layers are data, not code:

- Structure SQL uses the strict grammar documented in
  `skills/pymybot-scripting/references/structure-sql.md`.
- MT actions use the grammar in
  `skills/pymybot-scripting/references/action-mt.md`.
- Lua drivers target the HAL contract in
  `skills/pymybot-scripting/references/driver-lua.md`.

The implementation may add optional columns/keys; unknown keys must fail loudly
rather than be silently ignored.

## Historical tags

Active archive tags (resolvable in the repository):

| Tag | Meaning |
| --- | --- |
| `v0.2.0` | First reproducible monorepo release |
| `v0.3.0` | Configurable history byte budget |
| `v0.3.1` | Session transcripts, transcript pruning, Nuitka/PyAV bundles |
| `v0.3.1beta` | Pre-release asset; superseded by `v0.3.1` |

Retired tags (removed from the remote, kept only as historical notes):

| Tag | Reason |
| --- | --- |
| `gui-v1` | Withdrawn 2026-10-25 binary release; the release and tag were removed |
