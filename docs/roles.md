# Agent roles

A role is a self-contained Agent profile under `~/.mybot/roles` (or
`$MYBOT_HOME/roles`). It binds a personality/prompt library, reference skills,
an optional external MCP configuration and resumable model history. Robot
structures, action scripts, hardware permissions and approval grants remain
operator/session settings; a role never grants them.

## Directory format

```text
~/.mybot/roles/<name>/
├── role.json          # format version, name and operator description
├── prompts/           # complete PromptLibrary
├── skills/            # role-specific SKILL.md directories
├── mcp.json           # optional mcpServers configuration
└── history.json       # complete PydanticAI messages, grouped by turn
```

`pymybot roles create` copies the trusted bundled `prompts/` baseline, including
its manifest and safety hashes. Editing a role does not change the global
`~/.mybot/prompts` library or another role. Safety layers 0/100 remain immutable;
SOUL/USER/STATS retain the existing ownership and approval rules.

Role names contain 1–64 letters, numbers (including Unicode letters), `_`, `-`
or `.`, and cannot start with `.`. Role directories and their prompt, skill,
MCP and history inputs reject links/junctions. On POSIX, created role content
uses private directory/file permissions.

## CLI

```sh
# Empty skills and no MCP, using the bundled prompt baseline
pymybot roles create technician --description " cautious field technician"

# Import existing skills and an mcpServers JSON at creation time
pymybot roles create researcher \
  --skills-dir ./skills \
  --mcp-config ./mcp.json

pymybot roles list
pymybot roles show technician
pymybot agent --role technician --robot robots/relay-test.sql --task "列出硬件"
pymybot gui --role technician

# Explicitly erase only this role's resumable model history
pymybot roles clear-history technician --yes
```

A role owns its skills and MCP file, so CLI `--role` cannot be combined with
`--skills-dir` or `--mcp-config`. The independent `--prompt-file` OPERATOR layer
may still be added. MCP environment-variable references are resolved at load
time; keys are never copied into role metadata or command output.

## GUI

The toolbar role selector lists the global default and every valid role.
**新建** creates a role from the bundled prompt baseline and imports the
currently selected Skills/MCP when present. The selected role is saved as a GUI
preference, not as an approval grant.

While a role is selected:

- the Skills and MCP context fields show the role-owned paths;
- **工具 → MCP 配置** edits the role's `mcp.json`;
- **设置 → 提示词**, send-time safety validation and prompt-update diffs use the
  role's PromptLibrary;
- **新对话** closes the Agent, releases hardware and clears that role's saved
  model history;
- **清空对话** only clears the visible window, as before.

Switching roles does not erase either role's history. The next request opens
the newly selected role with its own capabilities and context.

## Resumable history

After each complete successful turn, `AgentSession` serializes the full
PydanticAI message history to `history.json` with an atomic replacement. The
next CLI, GUI or JSON-RPC session using that role restores it before the first
model request. Existing `history_turns` and `history_bytes` limits prune whole
turns, preserving tool-call/receipt pairs.

Failed, cancelled or partially executed turns are not appended. Corrupt or
unsupported history blocks the model request instead of silently starting with
amnesia. `/clear` in the terminal REPL and `agent.reset` with
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

`agent.ask` accepts `role`. `agent.reset` accepts optional `role` and
`clearHistory`; without `clearHistory`, closing or switching a role preserves
its history. Role management performs no hardware activation or model request.
