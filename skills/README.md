# Skills

This directory holds operator-trusted, agent-facing reference material. It is
loaded only when the agent is enabled and is never executed.

The authoritative operator documentation lives in [`../docs/`](../docs). These
skill files are intentionally shorter and action-oriented; when a behaviour
changes, update the docs first and then keep the matching skill reference in
sync. Do not duplicate large sections wholesale—link to the docs page instead.

| Skill | Purpose |
| --- | --- |
| [`pymybot-scripting/`](pymybot-scripting/SKILL.md) | Structure SQL, MT actions, Lua drivers, daemon, virtbus and error workflow references |

Prompt layering (`SOUL`/`USER`/`STATS`), runtime prompt files and a GUI reset
button are a 0.3 design item; the system safety prefix/suffix remain
operator-owned. See [`../docs/roadmap.md`](../docs/roadmap.md) and
[`../docs/security.md`](../docs/security.md).
