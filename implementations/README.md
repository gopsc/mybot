# Implementations

pymybot is organized as a multi-language monorepo. The Python implementation is
the reference edition and lives at the repository root; the other editions are
self-contained under this directory so they can be built and released
independently.

| Edition | Path | Stack | Status | Version |
| --- | --- | --- | --- | --- |
| Python (reference) | [`../pymybot`](../pymybot) | Python 3.11+ · LuaJIT · PydanticAI | Active | 0.3.x |
| Cangjie | [`cangjie/`](cangjie) | Cangjie 1.1.3 · LuaJIT | Maintained | 0.3.3 |
| C++17 + Rust agent | [`cpp-rust/`](cpp-rust) | C++17 · Rust · LuaJIT | Maintained | 0.1.0 |

All editions share the same operator-facing model:

```text
structure SQL (.sql)  →  Lua driver (.lua)  →  action script (.mt)
```

They intentionally keep their own build systems, tests, examples and release
notes. Run commands from the edition directory, not from the repository root.
Each directory has its own `README.md` with prerequisites, build steps and
hardware notes.

## Provenance

The non-Python editions were imported from long-lived branches so that one
checkout contains every implementation:

| Edition | Source branch | Source commit |
| --- | --- | --- |
| Cangjie | `cangjie` | `8b6d654` (2026-09-14) |
| C++17 + Rust | `cpp_rust_agent` | `d7f7087` (2026-10-16) |

The original branch histories are preserved under the `archive/*` tags. The
`cangjie_new` branch was an independent, incomplete prototype with no shared
history; it is archived as `archive/cangjie-new` and is not part of the
monorepo.

## Which edition should I use?

- **Python** — fastest path for desktop control, AI agent workflows, CI and
  teaching. It has the richest GUI and the most documented tooling.
- **C++17 + Rust** — lowest runtime overhead and the most demanding
  production/real-time deployments; includes a Rust agent and a C++ MCP
  hardware backend.
- **Cangjie** — the Cangjie-ecosystem edition; useful when the host project is
  already written in Cangjie.

Do not mix files between editions. Each edition ships its own `modules/`,
`robots/` and `scripts/` trees; a driver copied between editions may depend on a
different HAL ABI.
