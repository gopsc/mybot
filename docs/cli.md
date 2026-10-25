# CLI reference

The CLI is the automation-friendly control surface. It prints exactly one JSON
object on stdout per invocation; diagnostics and streaming agent output go to
stderr.

```sh
python -m pymybot --help
python -m pymybot --version
python -m pymybot doctor
```

## Entry points

| Command | Purpose | Activates hardware? |
| --- | --- | --- |
| `pymybot` | Open the GUI (default entry) | No |
| `pymybot --no-gui ...` | Terminal agent or controller command | Depending on command |
| `pymybot gui` | Explicit GUI entry | No |
| `pymybot check --robot SQL [--input MT]` | Static validation of SQL, modules, references and MT/Include syntax | No |
| `pymybot hardware --robot SQL` | List declared hardware and metadata | No |
| `pymybot scripts [--scripts-dir DIR]` | List `.mt` action scripts | No |
| `pymybot query --robot SQL --sql "..."` | `SHOW TABLES;` or `SELECT * FROM table [WHERE ...];` | No |
| `pymybot run --robot SQL --input MT` | Activate, run one action, deactivate | Yes |
| `pymybot sample --robot SQL --name VAR` | Read a named variable (`--count`, `--interval-ms`) | Yes |
| `pymybot apply-sql --robot SQL --sql "..."` | Apply restricted SQL to a temporary session | Yes |
| `pymybot agent ...` | PydanticAI task/REPL | Via approved tools |
| `pymybot serve` | Long-lived stdio JSON-RPC backend | Via requests |
| `pymybot doctor` | Environment/dependency/asset diagnostics | No |

## Global options

| Option | Meaning |
| --- | --- |
| `--module-path DIR` | Replace default module search path; repeatable. Must include a `modules` directory. |
| `--camera-src-dir DIR` | Allow file-backed Camera sources inside this directory. |
| `--timeout SECONDS` | Wall-clock budget for the command/action (where applicable). |
| `--var NAME=VALUE` | Bind a session variable; repeatable. |
| `--allow-hardware` | Open physical devices, non-loopback HTTP or the Shell driver. |
| `--no-gui` | Keep the terminal interface. |
| `--no-agent` | Bypass the model; with `--robot` and `--input`, run directly. |

`BOT4CJ_MODULE_PATH` is the environment-variable equivalent of repeated
`--module-path` (use the platform path separator).

## Examples

```sh
# Static validation, no hardware
python -m pymybot check \
  --robot robots/relay-test.sql \
  --input scripts/relay-test.mt

# Pure-software end-to-end run (Timer + Relay)
python -m pymybot run \
  --robot robots/relay-test.sql \
  --input scripts/relay-test.mt \
  --timeout 10

# Query the structure without activating it
python -m pymybot query --robot robots/relay-test.sql --sql "SHOW TABLES;"

# Serve a long-lived session to an IDE
python -m pymybot serve
```

Every SQL statement must end with `;`, including a single statement. A missing
semicolon is `SQL: unexpected end of script`.

## JSON contract

Success:

```json
{"ok":true,"command":"run","outputs":[{"slept":1,"result":"OK"}]}
```

Failure:

```json
{"ok":false,"error":{"type":"ScriptError","message":"..."}}
```

Exit codes: `0` success, `1` runtime error, `2` usage error, `130` interrupted.
The agent may add `tool_events` and `cleanup_errors`; it never includes tool
arguments, secrets or images in the final JSON.

## `serve` protocol

`pymybot serve` exchanges one JSON-RPC 2.0 object per line on stdin/stdout.
Diagnostics go to stderr. A final non-JSON CLI result line may appear on stdout
when the process exits; clients should ignore lines without `jsonrpc`.

| Method | Parameters | Result |
| --- | --- | --- |
| `initialize` | — | `protocol`, `version`, `agent`, `status` |
| `session.status` | — | `state`, `robot`, `busy`, ... |
| `session.activate` | `robot`, optional `modulePaths`, `cameraSrcDir`, `allowHardware` | session state |
| `session.deactivate` | — | cancels work and cleans drivers |
| `run` | `input`, optional `vars`, `timeout` | `outputs` |
| `apply-sql` | `sql` | session mutation |
| `sample` | `name`, optional `count`, `intervalMs`, `timeout` | `sample` notifications |
| `agent.ask` | `task`, `robot`, `scriptsDir`, agent options | multi-turn result and `agent.event` notifications |
| `agent.reset` | — | closes the conversation and releases hardware |
| `cancel` | `id` | cancels a request (`-32800` for the cancelled request) |
| `shutdown` | — | cleanup and exit |

Only one hardware operation runs at a time (`-32001` when busy). An active
session and an agent conversation are mutually exclusive (`-32002` when the
state is wrong). The server may send a `confirm` request to the client; only
`{"approved": true}` executes a gated tool.

## Agent options

Agent mode is documented in the README and
[`../skills/pymybot-scripting/references/action-mt.md`](../skills/pymybot-scripting/references/action-mt.md).
The important flags are:

| Option | Meaning |
| --- | --- |
| `--model PROVIDER:MODEL` | `openai`, `openai-chat`, `anthropic` or `deepseek`; defaults to `MYBOT_MODEL`. |
| `--base-url URL` | Custom OpenAI-compatible endpoint; HTTPS required except loopback. |
| `--api-key-env NAME` | Environment variable holding the key; never pass the key itself. |
| `--task TEXT` | One-shot task; without it, start the REPL. |
| `--workspace-dir DIR` | Enable bounded file tools inside `DIR`. |
| `--enable-shell` | Enable the shell tool inside the workspace; still not a sandbox. |
| `--allow-actions` | Pre-approve action scripts/reads/captures for this session. |
| `--allow-file-writes` | Pre-approve file creation/editing. |
| `--allow-shell` | Pre-approve shell commands (requires `--enable-shell`). |
| `--max-requests`, `--max-tool-calls`, `--max-history-bytes`, `--timeout` | Budgets. `--max-history-bytes` bounds retained conversation history (64 KiB–64 MiB, default 4 MiB). |

See [`gui.md`](gui.md) for the graphical equivalent.
