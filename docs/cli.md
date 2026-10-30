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
| `pymybot mcp --robot SQL` | Standard MCP stdio server, read-only by default | Via `--allow-execution` |
| `pymybot doctor` | Environment/dependency/asset diagnostics, including prompt manifest and safety hashes | No |
| `pymybot sessions [--prune ...]` | List or prune `~/.mybot/sessions` transcripts | No |
| `pymybot prompts list` | List runtime prompt layers, hashes and modification status | No |
| `pymybot prompts restore [--missing-only \| --all --yes]` | Refill missing defaults, or back up and reset all layers | No |

## Runtime prompts

Prompt management needs neither `--robot` nor a model/API key:

```sh
pymybot prompts list
pymybot prompts restore --missing-only    # default restore mode; keep existing edits
pymybot prompts restore --all --yes       # back up first, then replace all defaults
```

The first `prompts list` or agent turn bootstraps `$MYBOT_HOME/prompts`
(default `~/.mybot/prompts`) from the bundled defaults. Existing files are never
silently overwritten. Later listings only report missing files; they do not
repair them. The JSON list result contains `root` and `layers`; each layer reports
`id`, `file`, `editable`, `max_bytes`, `bytes`, `modified`, `mtime`, `sha256` and
`missing`. Restore reports `root`, `created` and `backup` (the latter is populated
for a full reset of an existing home). Full restore without `--yes` asks on a TTY;
non-interactive use returns a `UsageError` (exit 2), without changing files. Full
restore also recovers corrupt runtime safety files/manifests. Prompts and backups
may contain private text; keep them out of shared workspaces and version control.

| Layer | Ownership |
| --- | --- |
| 0 / 100 — safety prefix/suffix | Trusted bundled hashes; agent cannot change them |
| 10 — core | Operator only |
| 97 / 98 / 99 — SOUL / USER / STATS | Operator, or a separately approved `prompt:update_prompt` call |

Action/file auto-approval never approves prompt updates. Updates check the
previous hash (CAS), retain backups and record audit hashes. Automatic STATS is
host-generated, sanitized metadata without arguments or secrets; disable it with
`--no-prompt-stats` on `agent`/`gui` (default: automatic statistics enabled).
The composed prompt is bounded to 128 KiB; its short hash identifies the snapshot
shown by the GUI, while layer listings retain full SHA-256 hashes.

Source checkouts use top-level `prompts/`; wheels, PyInstaller and Nuitka carry
`pymybot/assets/prompts/`, resolved through `paths.asset_path('prompts')`.
`doctor` validates the packaged manifest and safety hashes without initializing
or inspecting the real runtime home; an invalid bundle makes `healthy` false.
See [security.md](security.md#system-prompt-ownership) for the trust limits.

## Global options

| Option | Meaning |
| --- | --- |
| `--module-path DIR` | Replace default module search path; repeatable. Must include a `modules` directory. |
| `--camera-src-dir DIR` | Allow file-backed Camera sources inside this directory. |
| `--timeout SECONDS` | Wall-clock budget for the command/action (where applicable). |
| `--var NAME=VALUE` | Override a structure `Alias`/`Vars` row before activation, and bind a session alias for action scripts; repeatable. |
| `--var-env NAME=ENVVAR` | Same, but read the value from an environment variable at run time; repeatable, values stay out of argv. |
| `--allow-hardware` | Open physical devices, non-loopback HTTP or the Shell driver. |
| `--no-gui` | Keep the terminal interface. |
| `--no-agent` | Bypass the model; with `--robot` and `--input`, run directly. |

`BOT4CJ_MODULE_PATH` is the environment-variable equivalent of repeated
`--module-path` (use the platform path separator).

### Structure variable overrides

`--var`/`--var-env` apply to every command that loads a structure (`check`,
`hardware`, `query`, `run`, `sample`, `apply-sql`, `agent`). A binding whose
name matches an `Alias` or `Vars` row replaces that row's value *before*
`build()`, so drivers that log in during activation receive the injected
value. Other rows are never overridden.

Reference the rows from ordinary structure cells with `$name` (Alias) or
`$(name)` (Vars, numeric):

```sql
CREATE TABLE Alias (name String, alias String);
INSERT INTO Alias (name, alias) VALUES ('user', 'COVER_ME');
INSERT INTO Alias (name, alias) VALUES ('pass', 'COVER_ME');
CREATE TABLE Vars (name String, value String);
INSERT INTO Vars (name, value) VALUES ('device', 1);
-- ... HTTP bus ...
CREATE TABLE Qsont (name String, HTTP String, user String, pass String, device Number);
INSERT INTO Qsont (name, HTTP, user, pass, device)
VALUES ('qs', '$cloud', '$user', '$pass', '$(device)');
```

```sh
export QS_USER=iot_01 QS_PASS=pass123
pymybot run --robot robots/qsont.sql --input scripts/qsont.mt \
  --timeout 30 --allow-hardware \
  --var-env user=QS_USER --var-env pass=QS_PASS --var device=1
```

The declared defaults stay in the tables, so `pymybot hardware`/`query` keep
showing them rather than injected values. Agent mode passes the same bindings
into activation and into every `run_action_script` call; operator bindings win
over model-supplied `vars`. In the GUI, enter them under **设置 → 变量覆盖**;
they stay in memory for this launch and are never written to `settings.json`.

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
semicolon is `SQL: unexpected end of script`. The structure SQL and MT action
grammars are documented in
[`structure-sql.md`](../skills/pymybot-scripting/references/structure-sql.md) and
[`action-mt.md`](../skills/pymybot-scripting/references/action-mt.md).

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
arguments, secrets or images in the final JSON. Full transcripts are written
separately; see [Session transcripts](#session-transcripts).

## `serve` protocol

`pymybot serve` exchanges one JSON-RPC 2.0 object per line on stdin/stdout.
Diagnostics go to stderr. A final non-JSON CLI result line may appear on stdout
when the process exits; clients should ignore lines without `jsonrpc`.

| Method | Parameters | Result |
| --- | --- | --- |
| `initialize` | — | `protocol`, `version`, `agent`, `status` |
| `session.status` | — | `state`, `robot`, `busy`, ... |
| `session.activate` | `robot`, optional `modulePaths`, `cameraSrcDir`, `allowHardware`, `vars` | session state |
| `session.deactivate` | — | cancels work and cleans drivers |
| `run` | `input`, optional `vars`, `timeout` | `outputs` |
| `apply-sql` | `sql` | session mutation |
| `sample` | `name`, optional `count`, `intervalMs`, `timeout` | `sample` notifications |
| `agent.ask` | `task`, `robot`, `scriptsDir`, optional `vars`, `mcpConfig`, `allowMcpTools`, `historyTurns`, `maxHistoryBytes`, `promptFile`, `autoStats` (boolean, default `true`), `contextBytes`, `intent`, `sandbox`, `enableWeb`, `allowWeb`, `searchEndpoint`, `workspaceDir`, `enableShell`, `allowShell`, `allowFileWrites`, agent options | multi-turn result with `intent` metadata and `agent.event` notifications |
| `agent.reset` | — | closes the conversation and releases hardware |
| `cancel` | `id` | cancels a request (`-32800` for the cancelled request) |
| `shutdown` | — | cleanup and exit |

Only one hardware operation runs at a time (`-32001` when busy). An active
session and an agent conversation are mutually exclusive (`-32002` when the
state is wrong). The server may send a `confirm` request to the client; only
`{"approved": true}` executes a gated tool. Changing `autoStats` changes the
conversation configuration and reopens the agent, just like other configuration
changes. Non-boolean values are rejected with `-32602`. Prompt updates always
request a dedicated `prompt:update_prompt` confirmation, regardless of other grants.

## Agent options

Agent mode is documented in the README. The important flags are:

| Option | Meaning |
| --- | --- |
| `--model PROVIDER:MODEL` | `openai`, `openai-chat`, `anthropic` or `deepseek`; defaults to `MYBOT_MODEL`. |
| `--base-url URL` | Custom OpenAI-compatible endpoint; HTTPS required except loopback. |
| `--api-key-env NAME` | Environment variable holding the key; never pass the key itself. |
| `--task TEXT` | One-shot task; without it, start the REPL. |
| `--workspace-dir DIR` | Enable bounded file tools inside `DIR`. |
| `--enable-shell` | Enable the shell tool inside the workspace; protected prompts require usable bubblewrap, with no unisolated fallback. |
| `--allow-actions` | Pre-approve action scripts/reads/captures for this session. |
| `--allow-file-writes` | Pre-approve file creation/editing. |
| `--allow-shell` | Pre-approve shell commands (requires `--enable-shell`). |
| `--max-requests`, `--max-tool-calls`, `--max-history-bytes`, `--timeout` | Budgets. `--max-history-bytes` bounds retained conversation history (64 KiB–64 MiB, default 4 MiB). |
| `--history-turns` | Complete turns retained across tasks (1–20, default 6). |
| `--prompt-file FILE` | Additional operator-owned UTF-8 profile (max 8 KiB); does not replace runtime USER or the safety prefix/suffix. |
| `--no-prompt-stats` | Disable automatic host-generated STATS updates (also accepted by `gui`; default false). |
| `--context-bytes N` | Budget for the generated project inventory (workspace top level, structures, scripts, drivers, skills); 0 disables it (0–64 KiB, default 4096). |
| `--intent MODE` | `auto` (default), `off`, `chat`, `inspect`, `control`, `author` or `diagnose`. Auto narrows the tool allowlist and budget when the request clearly matches an intent; mixed requests union their tools; messages with no keywords stay unrestricted. |
| `--sandbox MODE` | `auto` (default), `off` or `bwrap`. Agent prompt protection requires usable bubblewrap: unavailable backends or `off` refuse shell execution. The host is read-only, the workspace is writable with prompt roots re-mounted read-only, the environment is cleared and network/PID/IPC/UTS namespaces are unshared. This protects prompt integrity, not host-file confidentiality. |
| `--web` | Enable `web_fetch` (HTTPS only) and, with `--search-endpoint`, `web_search`. Requires `pymybot[web]`. Private/link-local/loopback targets, redirects past three hops, non-text content and oversized bodies are refused. |
| `--allow-web` | Pre-approve web requests for this session (requires `--web`). |
| `--search-endpoint URL` | SearXNG base URL used by `web_search`; no endpoint means no search tool. |
| `--mcp-config FILE` | Operator `mcpServers` JSON; exposes external MCP tools to the model. See [mcp.md](mcp.md). |
| `--allow-mcp-tools` | Pre-approve external MCP tool calls (requires `--mcp-config`). |
| `--var`, `--var-env` | Structure `Alias`/`Vars` overrides and action-script bindings, as described above. |
| `--no-session-log` | Do not write a session transcript (also accepted by `serve`). |

A turn blocks the fourth identical tool call with a structured `not_executed`
receipt instead of replaying a stuck loop; the transcript records `intent` and
`loop_guard` events.

## `mcp` server

`pymybot mcp --robot SQL` speaks standard MCP over stdio and reserves stdout for
JSON-RPC; diagnostics stay on stderr. It is read-only unless `--allow-execution`
is passed, and physical hardware still requires `--allow-hardware`. Tools,
resources, client configuration and the agent-side MCP client are documented in
[mcp.md](mcp.md).

## Session transcripts

`agent` and `serve` (`agent.ask`) write each conversation to
`~/.mybot/sessions/<timestamp>-<8-char id>/` by default:

- `meta.json` — start time, structure file, model name (no key), mode (`cli`/`serve`);
- `transcript.jsonl` — one JSON object per line: `session_start`, `user`,
  `assistant`, `tool_call` (with arguments), `tool_result` (bounded result),
  `usage`, `error`, `session_end`;
- `images/<sha256>.jpg|png` — images returned by actions or captures,
  de-duplicated by content; the JSONL only stores hash, MIME type, size and path.

Transcripts are for review and audit only. They are **not** resumable: hardware
state, unfinished actions and model context are never restored from them, and
the GUI has no history browser.

Disable with `--no-session-log` (`agent`, `serve`) or `MYBOT_SESSION_LOG=0`,
which the GUI's `serve` child inherits. `MYBOT_HOME` overrides the root
(default `~/.mybot`). Each event is capped at 64 KiB; each image at 8 MiB and
each session at 256 images / 128 MiB, beyond which only an `omitted` marker is
written. On POSIX, directories are `0700` and files `0600`.

### List and prune

```sh
pymybot sessions                                  # JSON list, newest first
pymybot sessions --delete ID --dry-run            # preview one deletion
pymybot sessions --delete ID --yes                # delete one session
pymybot sessions --delete ID --delete ID2 --yes   # repeatable
pymybot sessions --prune --keep 20 --dry-run      # show what would go
pymybot sessions --prune --keep 20 --yes          # delete older sessions
pymybot sessions --prune --keep 20 --older-than 30 --yes
```

`--prune` and `--delete` are mutually exclusive; both require `--yes` or
`--dry-run`. The GUI's **工具 → 会话管理** uses the same functions with
filtering, preview, delete and prune controls.

The newest `--keep` sessions are always protected. `--older-than DAYS` adds a
second condition among the rest, so a recent overflow is not deleted before it
ages out. Pruning never follows symlinks and ignores directories that do not
look like a session. On POSIX, a live session whose transcript has no
`session_end` is skipped; do not prune while a session is running on Windows.
Deletion requires `--yes`; `--dry-run` previews the same list without touching
disk.

See [`gui.md`](gui.md) for the graphical equivalent.
