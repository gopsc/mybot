# Skills

This directory holds operator-trusted, agent-facing reference material and the
self-contained hardware-controller Runtime. `read_skill` never executes content;
the controller Runtime explicitly loads trusted code and assets from
`hardware-controller/`.

| Skill | Purpose |
| --- | --- |
| [`hardware-controller/`](hardware-controller/SKILL.md) | Self-contained Python controller, MCP server, Agent `run_skill`, authoritative controller docs and default robots/scripts/modules assets |
| [`pymybot-scripting/`](pymybot-scripting/SKILL.md) | Structure SQL, MT actions, Python/Lua drivers, daemon, virtbus and error workflow references |
| [`skill-authoring/`](skill-authoring/SKILL.md) | 技能编写规范: SKILL.md layout, frontmatter, trigger descriptions, references and the approved workspace `install_skill` workflow |
| [`i2c-address-probe/`](i2c-address-probe/SKILL.md) | 宿主侧 I2C 地址探测（只读），sh/Python 脚本、判读手册，Agent 可经 `run_skill` 的 `list-buses` / `scan` 执行 |

## Single source of truth

The agent cannot read [`../docs/`](../docs) — only `read_skill` — so these files
must stay self-sufficient for scripting work while never restating what an
authority document already owns. Each topic has exactly one authority. The
controller's authority documents live under `hardware-controller/references/`;
the same-named pages in [`../docs/`](../docs) are redirect stubs for human readers.

| Topic | Authority | Skill reference |
| --- | --- | --- |
| Structure SQL grammar | `pymybot/sql.py`, `pymybot/robot.py` | [`references/structure-sql.md`](pymybot-scripting/references/structure-sql.md) |
| MT action grammar | `pymybot/{matrix,expr,actions,include}.py` | [`references/action-mt.md`](pymybot-scripting/references/action-mt.md) |
| Python/Lua driver contract | [`references/architecture.md`](hardware-controller/references/architecture.md), [`security.md`](hardware-controller/references/security.md) | [`references/driver-lua.md`](pymybot-scripting/references/driver-lua.md) |
| Daemon sampling | [`references/architecture.md`](hardware-controller/references/architecture.md) | [`references/daemon.md`](pymybot-scripting/references/daemon.md) |
| Virtual device models | [`references/testing.md`](hardware-controller/references/testing.md) | [`references/virt-model.md`](pymybot-scripting/references/virt-model.md) |
| CLI commands and gates | [`references/cli.md`](hardware-controller/references/cli.md), [`security.md`](hardware-controller/references/security.md) | [`references/workflow-errors.md`](pymybot-scripting/references/workflow-errors.md) |
| Controller architecture | `hardware-controller/scripts/pymybot/` | [`references/architecture.md`](hardware-controller/references/architecture.md) |
| Controller CLI and serve | `hardware-controller/scripts/pymybot/{cli,serve}.py` | [`references/cli.md`](hardware-controller/references/cli.md) |
| Controller MCP | `hardware-controller/scripts/pymybot/mcp_server.py` | [`references/mcp.md`](hardware-controller/references/mcp.md) |
| Controller security | `hardware-controller/scripts/pymybot/` | [`references/security.md`](hardware-controller/references/security.md) |
| Controller testing | `tests/` | [`references/testing.md`](hardware-controller/references/testing.md) |
| Host-side I2C probing | `i2c-address-probe/scripts/i2c_probe.py` | [`references/usage.md`](i2c-address-probe/references/usage.md) |
| Executable Skill actions | `hardware-controller/skill.json`, `pymybot/agent_skill_runner.py` | [`hardware-controller/SKILL.md`](hardware-controller/SKILL.md#agent-原生-run_skill) |

The scripting grammars have no prose authority outside the implementation, so
the reference *is* the written source of truth for them; docs link here instead
of restating the grammar. Other topics are authored in `docs/` or in the
`hardware-controller/references/` authority documents.

Rules for editing a reference:

- Changed behaviour goes into the authority first, then the skill reference.
- Keep only what the agent gets wrong without help: hard rules, exact error
  strings, limits, worked examples. Replace architecture and workflow prose with
  one line plus a link to the authority that owns it.
- Never copy a docs section wholesale. `tools/check_docs_skill_sync.py` warns on
  long verbatim runs and fails on dead links, unregistered references and a
  missing `Source:` line.
- The `../docs/` links are for reviewing the repository. Wheels and frozen builds
  package `skills/` without `docs/`, so a rule must never depend on following one.

Runtime prompt layering is implemented separately from these scripting references:
bundled `prompts/` defaults seed `MYBOT_HOME/prompts`, with CLI list/restore and
GUI management. Safety layers 0/100 are pinned to trusted bundled hashes; core
is operator-only. Agent changes to SOUL/USER/STATS (97/98/99) require a dedicated
per-call prompt approval, CAS and backup; ordinary action/file grants do not
apply. Automatic STATS is sanitized host metadata and can be disabled. See
[`hardware-controller/references/cli.md`](hardware-controller/references/cli.md#runtime-prompts) and
[`security.md`](hardware-controller/references/security.md#system-prompt-ownership).
