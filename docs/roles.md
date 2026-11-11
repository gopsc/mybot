# Agent roles

A role is a self-contained Agent profile under `~/.mybot/roles` (or
`$MYBOT_HOME/roles`). It binds a personality/prompt library, reference skills,
an optional external MCP configuration and resumable model history. Robot
structures, action scripts, hardware permissions and approval grants remain
operator/session settings; a role never grants them.

**Autonomous agent runs require a role.** `pymybot agent` without `--role`, the
GUI without a selected role and `serve` `agent.ask` without `role` are rejected;
there is no global default conversation.

## Directory format

```text
~/.mybot/roles/<name>/
├── role.json          # format version, name and operator description
├── prompts/           # complete PromptLibrary
├── skills/            # complete skill directories (SKILL.md plus optional scripts/, references/, assets/)
├── workspace/         # role-owned workspace; Agent file tools write here
├── mcp.json           # optional mcpServers configuration
└── history.json       # complete LangChain messages, grouped by turn (format 2)
```

`pymybot roles create` copies the trusted bundled `prompts/` baseline, including
its manifest and safety hashes, plus complete skill directories with their
`scripts/`, `references/` and `assets/`, so runnable skills stay runnable inside a
role. Selecting a role makes the Agent use `~/.mybot/roles/<name>/workspace`
instead of the global workspace; use `install_skill(path)` to install a skill
the Agent authored under that workspace. Editing a role does not change the global
`~/.mybot/prompts` library or another role. Safety layers 0/100 remain immutable;
SOUL/USER/STATS retain the existing ownership and approval rules.

A role copies the bundled skill tree as it exists when the role is created.
In a source checkout the `hardware-controller` skill is self-contained, so the
role also carries its own `scripts/pymybot` Runtime and `assets/`; in an
installed wheel the Runtime stays in the package and the skill uses the
packaged CLI. `roles repair` only fills missing files and never overwrites
existing ones, so upgrading pymybot does not upgrade controller code already
copied into a role. Recreate the role, or deliberately sync its
`skills/hardware-controller/` tree, when it must move to a newer Runtime.

Role names contain 1–64 letters, numbers (including Unicode letters), `_`, `-`
or `.`, and cannot start with `.`. Role directories and their prompt, skill,
MCP and history inputs reject links/junctions. On POSIX, created role content
uses private directory/file permissions.

## Extra prompt layers

A role's `prompts/` directory may also contain operator-authored layers named
`NNN_name.md` (three-digit number 001–099, lowercase name). They join the
composed prompt in numeric order — `011_robot.md` sits between core layer 10
and SOUL layer 97 — and are read-only to the agent: only 10/97/98/99 keep their
existing ownership and approval rules. Bundled extra layers are seeded into a
role's prompt directory on first use (never overwriting an edited file), so a
new role starts with every default layer; the bundled extras are
`011_robot.md` (摄像头机器人) and `012_skill_store.md` (技能商店). Reserved numbers (0, 10, 97, 98, 99,
100) and values above 99 are rejected, each extra layer is capped at 64 KiB, and
the composed prompt stays capped at 128 KiB. The global `~/.mybot/prompts` and
the bundled defaults keep the fixed six-layer contract; this applies to role
directories only.

## CLI

```sh
# Copied with every bundled skill, the bundled prompt baseline and its extra layers
pymybot roles create technician --description " cautious field technician"

# Import existing skills and an mcpServers JSON at creation time
pymybot roles create researcher \
  --skills-dir ./skills \
  --mcp-config ./mcp.json

pymybot roles list
pymybot roles show technician
pymybot agent --role technician --task "列出硬件"
pymybot gui --role technician

# Explicitly erase only this role's resumable model history
pymybot roles clear-history technician --yes

# Permanently delete the role directory (prompts, skills, workspace, history)
pymybot roles delete technician --yes

# Fill missing skill files, and add bundled skills the role lacks
pymybot roles repair technician --yes
# ... or from a known-complete skills root
pymybot roles repair technician --skills-dir ./skills --yes
```

`roles show` reports `runnable` (skills that ship an entrypoint: a legacy
`skill.json` action or a top-level `scripts/*.py`) and `incomplete`
(runnable bundled skills whose declared entrypoint is missing). `roles repair`
copies only **missing** files into skills that already exist in the role; it
never overwrites a file, prompt, history entry or workspace file, so operator
edits survive. A new role copies complete skill directories, and creation
refuses a skill whose manifest declares an entrypoint that was not copied.

A role owns its skills and MCP file, so CLI `--role` cannot be combined with
`--skills-dir` or `--mcp-config`. `serve`'s `agent.ask` applies the same rule:
`workspaceDir`, `skillsDir` and `mcpConfig` may be omitted or set to the role's
own path, but conflicting values are rejected instead of silently ignored. The
independent `--prompt-file` OPERATOR layer may still be added. MCP
environment-variable references are resolved at load time; keys are never
copied into role metadata or command output.

## GUI

The toolbar role selector lists every valid role. **新建** creates a role from
the bundled prompt baseline and imports the currently selected Skills/MCP when
present. If no skills root is configured (or the selected role's skills
directory is empty), it falls back to the packaged default skills so a new role
does not silently start without references. The selected role is saved as a GUI
preference, not as an approval grant. **删除** asks for confirmation, closes the
Agent conversation and permanently deletes the selected role's whole directory;
without a role the composer refuses to send and asks you to create one.

While a role is selected:

- the Skills and MCP context fields show the role-owned paths, and **设置** shows
  the role-owned workspace/skills/MCP paths read-only;
- **工具 → MCP 配置** edits the role's `mcp.json`;
- **设置 → 提示词**, send-time safety validation and prompt-update diffs use the
  role's PromptLibrary;
- **新对话** closes the Agent, releases hardware, clears that role's saved
  model history and clears the visible window;
- **清空对话** only clears the visible window and keeps the model context, as before.

Switching roles does not erase either role's history. The next request opens
the newly selected role with its own capabilities and context.

## Resumable history

After each complete successful turn, `AgentSession` serializes the full
LangChain message history to `history.json` with an atomic replacement. One
live conversation per role is enforced with a `.agent.lock` file; a second
window or process using the same role fails instead of silently replacing the
other writer's turns. The
next CLI, GUI or JSON-RPC session using that role restores it before the first
model request. The `history_bytes` byte cap prunes whole turns, preserving
tool-call/receipt pairs; there is no turn-count limit. An optional
`max_context_tokens` limit also prunes old complete turns before each model
request; the current turn is never partially rewritten and instead fails
explicitly if it alone exceeds the remaining input budget.

Failed, cancelled or partially executed turns are not appended. Version 1
(PydanticAI) history is recognized and ignored so the role starts a fresh
conversation. Corrupt or otherwise unsupported history blocks the model
request instead of silently starting with amnesia.
`pymybot roles clear-history NAME --yes` and `agent.reset` with
`clearHistory=true` provide explicit erasure.

`history.json` is different from `~/.mybot/sessions`: session transcripts are
append-only audit records and are not used to reconstruct model context.
History can contain private conversation and tool data; protect and back up the
role directory accordingly.

## JSON-RPC

| Method | Purpose |
| --- | --- |
| `roles.list` | List valid roles and the role root |
| `roles.create` | Create with `name`, optional `description`, `skillsDir`, `mcpConfig` |
| `roles.show` | Inspect role paths, skills and history counts |
| `roles.clear_history` | Clear an inactive role's history |

`agent.ask` requires `role`. `agent.reset` accepts optional `role` and
`clearHistory`; without `clearHistory`, closing or switching a role preserves
its history. Role management performs no hardware activation or model request.
