# Repository history and branch consolidation

The project grew several independent implementations before it had a stable
repository layout. The 0.2.0 cleanup consolidated the Python implementation
under the repository root. Implementations that were no longer maintained were
later removed from the tree, leaving a single supported codebase.

## Before

| Branch | Contents | Problem |
| --- | --- | --- |
| `pymybot` | Python implementation | Ancestor of `gui-mybot`; stale |
| `gui-mybot` | Python implementation + Tk GUI | Default branch; name describes a feature, not the implementation |
| `release` | Packaged build with a built-in endpoint and session transcripts | Shared credential conflicts with the security policy |

## After

- `gui-mybot` — the Python implementation and the repository root. Renaming it
  to `main` requires repository-owner/admin access, so the name is unchanged for
  now.
- `pymybot` and `release` branches deleted. The `release` prototype’s built-in
  endpoint/key was rejected; its session-transcript design was later ported into
  the 0.3 line without the built-in endpoint.

## Current branch model

Only the default branch is long-lived. Topic branches are short-lived and
deleted after merge. See [`../development.md`](../development.md) and
[`../release.md`](../release.md).

## Completed migration notes

- [Camera pipeline migration](camera-migration.md) — OpenCV to PyAV/Pillow.
- [Windows faulthandler](windows-faulthandler.md) — diagnosing LuaJIT SEH
  crashes.
