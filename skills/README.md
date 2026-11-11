# Skills

This directory holds the self-contained hardware-controller Runtime and its
operator documentation. `hardware-controller/` is the only bundled skill: the
controller sources, the default assets and the authoritative references all live
under it.

| Skill | Purpose |
| --- | --- |
| [`hardware-controller/`](hardware-controller/SKILL.md) | Self-contained Python controller, MCP server, `assets` CRUD, the three-layer scripting grammars and the default robots/scripts/modules assets |

## Single source of truth

The controller's authority documents live under `hardware-controller/references/`;
the same-named pages in [`../docs/`](../docs) are redirect stubs for human readers.
Each topic has exactly one authority:

| Topic | Authority | Skill reference |
| --- | --- | --- |
| Structure SQL grammar | `pymybot/sql.py`, `pymybot/robot.py` | [`references/structure-sql.md`](hardware-controller/references/structure-sql.md) |
| MT action grammar | `pymybot/{matrix,expr,actions,include}.py` | [`references/action-mt.md`](hardware-controller/references/action-mt.md) |
| Python/Lua driver contract | [`references/architecture.md`](hardware-controller/references/architecture.md), [`security.md`](hardware-controller/references/security.md) | [`references/driver-lua.md`](hardware-controller/references/driver-lua.md) |
| Daemon sampling | [`references/architecture.md`](hardware-controller/references/architecture.md) | [`references/daemon.md`](hardware-controller/references/daemon.md) |
| Virtual device models | [`references/testing.md`](hardware-controller/references/testing.md) | [`references/virt-model.md`](hardware-controller/references/virt-model.md) |
| CLI commands and gates | [`references/cli.md`](hardware-controller/references/cli.md), [`security.md`](hardware-controller/references/security.md) | [`references/workflow-errors.md`](hardware-controller/references/workflow-errors.md) |
| Controller architecture | `hardware-controller/scripts/pymybot/` | [`references/architecture.md`](hardware-controller/references/architecture.md) |
| Controller CLI and MCP | `hardware-controller/scripts/pymybot/{cli,mcp_server,executor}.py` | [`references/cli.md`](hardware-controller/references/cli.md) |
| Controller MCP | `hardware-controller/scripts/pymybot/mcp_server.py` | [`references/mcp.md`](hardware-controller/references/mcp.md) |
| Controller security | `hardware-controller/scripts/pymybot/` | [`references/security.md`](hardware-controller/references/security.md) |
| Controller testing | `tests/` | [`references/testing.md`](hardware-controller/references/testing.md) |

The scripting grammars have no prose authority outside the implementation, so
the reference *is* the written source of truth for them; docs link here instead
of restating the grammar. Other topics are authored in `docs/` or in the
`hardware-controller/references/` authority documents.

Rules for editing a reference:

- Changed behaviour goes into the authority first, then the skill reference.
- Keep only what a reader gets wrong without help: hard rules, exact error
  strings, limits, worked examples. Replace architecture and workflow prose with
  one line plus a link to the authority that owns it.
- Never copy a docs section wholesale. `tools/check_docs_skill_sync.py` warns on
  long verbatim runs and fails on dead links, unregistered references and a
  missing `Source:` line.
- The `../docs/` links are for reviewing the repository. Wheels and installed
  builds package `skills/` without `docs/`, so a rule must never depend on
  following one.
