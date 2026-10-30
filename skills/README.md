# Skills

This directory holds operator-trusted, agent-facing reference material. It is
loaded only when the agent is enabled and is never executed.

| Skill | Purpose |
| --- | --- |
| [`pymybot-scripting/`](pymybot-scripting/SKILL.md) | Structure SQL, MT actions, Python/Lua drivers, daemon, virtbus and error workflow references |

## Single source of truth

The agent cannot read [`../docs/`](../docs) — only `read_skill` — so these files
must stay self-sufficient for scripting work while never restating what the docs
already own. Each topic has exactly one authority:

| Topic | Authority | Skill reference |
| --- | --- | --- |
| Structure SQL grammar | `pymybot/sql.py`, `pymybot/robot.py` | [`references/structure-sql.md`](pymybot-scripting/references/structure-sql.md) |
| MT action grammar | `pymybot/{matrix,expr,actions,include}.py` | [`references/action-mt.md`](pymybot-scripting/references/action-mt.md) |
| Python/Lua driver contract | [`../docs/architecture.md`](../docs/architecture.md), [`../docs/security.md`](../docs/security.md) | [`references/driver-lua.md`](pymybot-scripting/references/driver-lua.md) |
| Daemon sampling | [`../docs/architecture.md`](../docs/architecture.md) | [`references/daemon.md`](pymybot-scripting/references/daemon.md) |
| Virtual device models | [`../docs/testing.md`](../docs/testing.md) | [`references/virt-model.md`](pymybot-scripting/references/virt-model.md) |
| CLI commands and gates | [`../docs/cli.md`](../docs/cli.md), [`../docs/security.md`](../docs/security.md) | [`references/workflow-errors.md`](pymybot-scripting/references/workflow-errors.md) |

The scripting grammars have no prose authority outside the implementation, so
the reference *is* the written source of truth for them; docs link here instead
of restating the grammar. Everything else is authored in `docs/` first.

Rules for editing a reference:

- Changed behaviour goes into the authority first, then the skill reference.
- Keep only what the agent gets wrong without help: hard rules, exact error
  strings, limits, worked examples. Replace architecture and workflow prose with
  one line plus a `docs/` link.
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
[`../docs/cli.md`](../docs/cli.md#runtime-prompts) and
[`../docs/security.md`](../docs/security.md#system-prompt-ownership).
