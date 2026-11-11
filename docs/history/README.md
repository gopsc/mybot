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

## 0.6.0 layout note

0.6.0 moved the controller Runtime to
`skills/hardware-controller/scripts/pymybot/` so the hardware-controller skill is
self-contained. The root `pymybot` package still exposes the same `pymybot.*`
imports by extending its `__path__`, and the wheel bundles the Runtime under the
package. Controller architecture, CLI, MCP, security and testing documents now
live in `skills/hardware-controller/references/`; the same-named pages in
`docs/` are redirect stubs. Older history entries below keep the paths they had
when written.

## 0.7.x controller-only cut

The `gui-mybot` branch now carries only the hardware controller. The Agent and
GUI implementation was removed in one cut, together with roles, runtime prompts,
session transcripts and the web, camera and shell tool surface. The supported
entry points are the Python CLI and the MCP stdio server, and the release
artifacts are the sdist and the wheel. The controller Runtime, default assets and
authority documents stay under `skills/hardware-controller/`; the branch name is
kept because renaming it needs repository-owner/admin access.

## Completed migration notes

- [Windows faulthandler](windows-faulthandler.md) — diagnosing LuaJIT SEH
  crashes.
