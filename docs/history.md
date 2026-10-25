# Repository history and branch consolidation

The project grew several independent implementations before it had a stable
repository layout. The 0.2.0 cleanup consolidated them so that a new
contributor can find every edition in one place.

## Before

| Branch | Contents | Problem |
| --- | --- | --- |
| `pymybot` | Python reference edition | Ancestor of `gui-mybot`; stale |
| `gui-mybot` | Python edition + Tk GUI | Default branch; name describes a feature, not the edition |
| `cangjie` | Full Cangjie edition | Separate history, easy to miss |
| `cangjie_new` | 6-file independent prototype | No merge base; incomplete |
| `cpp_rust_agent` | C++17 host + Rust agent | Separate history, easy to miss |
| `release` | Packaged build with a built-in endpoint and session transcripts | Shared credential conflicts with the security policy |

## After

- `gui-mybot` — Python reference edition and the monorepo root. Renaming it to
  `main` requires repository-owner/admin access, so the name is unchanged for
  now.
- `implementations/cangjie/` — Cangjie edition, copied from `cangjie`.
- `implementations/cpp-rust/` — C++17 + Rust edition, copied from
  `cpp_rust_agent`.
- `archive/cangjie`, `archive/cpp-rust-agent`, `archive/cangjie-new`,
  `archive/release-session-log` — tags preserving the old branch tips and their
  full history.
- `pymybot`, `cangjie`, `cangjie_new`, `cpp_rust_agent` and `release` branches
  deleted. The `release` prototype’s built-in endpoint/key was rejected; its
  session-transcript design was later ported into the 0.3 line without the
  built-in endpoint.

## Why copy instead of merge?

The three editions do not share a file layout or build system. Merging their
histories would create conflicts in `modules/`, `robots/` and `compatibility`
files without any shared code to resolve them. Copying each tree into its own
directory keeps every edition self-contained, while the archive tags preserve
the original commits for archaeology.

## What about `cangjie_new`?

It is an unrelated, incomplete rewrite (six files, no tests). Importing it
would present a non-working edition as supported. It is archived and documented
as a prototype, not part of the monorepo.

## Current branch model

Only the default branch is long-lived. Topic branches are short-lived and
deleted after merge. See [`development.md`](development.md) and
[`release.md`](release.md).
