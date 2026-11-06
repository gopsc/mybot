# CLI reference

Source: This is the authoritative controller CLI and serve protocol document; the implementation lives in `scripts/pymybot/{cli,serve}.py`.

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
| `pymybot discover [--buses i2c,spi,uart,ftdi] [--probe]` | Read-only host device enumeration with structure-SQL hints | No |
| `pymybot hardware --robot SQL` | List declared hardware and metadata | No |
| `pymybot scripts [--scripts-dir DIR]` | List `.mt` action scripts | No |
| `pymybot query --robot SQL --sql "..."` | `SHOW TABLES;` or `SELECT * FROM table [WHERE ...];` | No |
| `pymybot run --robot SQL --input MT` | Activate, run one action, deactivate | Yes |
| `pymybot sample --robot SQL --name VAR` | Read a named variable (`--count`, `--interval-ms`) | Yes |
| `pymybot apply-sql --robot SQL --sql "..."` | Apply restricted SQL to a temporary session | Yes |
| `pymybot agent ...` | Dual-agent autonomous run (or one seeded mission with `--task`) | Via approved tools |
| `pymybot serve` | Long-lived stdio JSON-RPC backend | Via requests |
| `pymybot mcp --robot SQL` | Standard MCP stdio server, read-only by default | Via `--allow-execution` |
| `pymybot new NAME [--dir DIR] [--force]` | Generate a runnable `robots/`, `scripts/` and `modules/` skeleton | No |
| `pymybot assets list/read/write/delete` | List, read, create, overwrite or delete bundled `robots`/`modules`/`scripts` asset files | No |
| `pymybot doctor` | Environment/dependency/asset diagnostics, including prompt manifest and safety hashes | No |
| `pymybot sessions [--prune ...]` | List or prune `~/.mybot/sessions` transcripts | No |
| `pymybot prompts list` | List runtime prompt layers, hashes and modification status | No |
| `pymybot prompts restore [--missing-only \| --all --yes]` | Refill missing defaults, or back up and reset all layers | No |
| `pymybot roles list/create/show/repair/clear-history/delete` | Manage role-owned prompts, skills, MCP and resumable history; `repair` fills missing skill files and `delete` removes the role directory (both need `--yes`) | No |

## Asset files

`pymybot assets` manages the bundled `robots` (`.sql`), `modules` (`.py`/`.lua`) and
`scripts` (`.mt`) asset files in place, so the Skill can create, retrieve, overwrite and
delete robot scripts without leaving the controller:

```sh
pymybot assets list [--kind robots|modules|scripts|all]
pymybot assets read   --kind robots  --path relay-test.sql
pymybot assets write  --kind scripts --path mybot-arm.mt --content "@Action ..."   # create
pymybot assets write  --kind scripts --path mybot-arm.mt --content-file arm.mt --force  # overwrite
pymybot assets delete --kind scripts --path mybot-arm.mt --yes
```

`--path` is relative to the kind's asset root; traversal, absolute paths, symlink escape
and wrong suffixes are refused. `write` creates and refuses an existing file unless
`--force`; `delete` requires `--yes`. Content is bounded UTF-8 (`--content` inline or
`--content-file` for larger bodies). The command never activates hardware.

`--robot` and `--input` on every command resolve against these roots: an absolute path or
a path that already exists relative to CWD is used as-is, otherwise a bare or relative
name falls back to `assets/robots` (`--robot`) or `assets/scripts` (`--input`). This keeps
the Skill self-contained without breaking absolute or CWD-relative callers.

## Agent roles

See [roles.md](../../../docs/roles.md) for the directory format, GUI behavior and history
semantics. Typical usage:

```sh
pymybot roles create technician --description "Field technician"
pymybot roles list
pymybot agent --role technician --task "用 hardware-controller skill 列出 relay-test 的硬件"
pymybot agent --role technician --task "运行自检"
pymybot roles clear-history technician --yes
pymybot roles delete technician --yes        # permanently remove the role directory
```

Autonomous runs require a role: `pymybot agent` without `--role` and
`serve` `agent.start`/`agent.ask` without `role` fail with a usage/invalid-params
error. There is no global default conversation, no chat composer and no
single-agent path: the memory and worker agents talk to each other after the
operator clicks 启动 or runs the command.

Creation copies the bundled prompt baseline. Optional `--skills-dir` and
`--mcp-config` on `roles create` import those capabilities into the role. Once
loaded, `--role` owns these resources and is therefore not combined with the
agent-level `--skills-dir`/`--mcp-config` overrides. `roles delete` removes the
whole role directory (prompts, skills, workspace and history) and requires
`--yes`; close that role's conversation first.

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
INSERT INTO Alias (name, alias) VALUES ('tcp0_host', 'COVER_ME');
CREATE TABLE Vars (name String, value String);
INSERT INTO Vars (name, value) VALUES ('tcp0_port', -1);
-- ... 设备表用 $tcp0_host / $(tcp0_port) 引用 ...
CREATE TABLE TCP (name String, host String, port Number);
INSERT INTO TCP (name, host, port) VALUES ('tcp0', '$tcp0_host', '$(tcp0_port)');
```

```sh
export RELAY_HOST=192.0.2.10
pymybot run --robot assets/robots/famer.sql --input assets/scripts/famer.mt \
  --timeout 30 --allow-hardware \
  --var-env tcp0_host=RELAY_HOST --var tcp0_port=8080
```

The declared defaults stay in the tables, so `pymybot hardware`/`query` keep
showing them rather than injected values. Agent mode forwards operator bindings
to skill subprocesses as `--var` arguments; they are applied before activation.
In the GUI, enter them under **设置 → 变量覆盖**; they stay in memory for this
launch and are never written to `settings.json`.

## Examples

```sh
# Create a runnable pure-software skeleton
python -m pymybot new mybot-arm

# Static validation, no hardware
python -m pymybot check \
  --robot assets/robots/relay-test.sql \
  --input assets/scripts/relay-test.mt

# Pure-software end-to-end run (Timer + Relay)
python -m pymybot run \
  --robot assets/robots/relay-test.sql \
  --input assets/scripts/relay-test.mt \
  --timeout 10

# Query the structure without activating it
python -m pymybot query --robot assets/robots/relay-test.sql --sql "SHOW TABLES;"

# Serve a long-lived session to an IDE
python -m pymybot serve
```

Every SQL statement must end with `;`, including a single statement. A missing
semicolon is `SQL: unexpected end of script`. The structure SQL and MT action
grammars are documented in
[`structure-sql.md`](structure-sql.md) and
[`action-mt.md`](action-mt.md).

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
A Ctrl+C/SIGTERM during an activating command stops the action and attempts the
same `safe()` hooks as `abort` before releasing hardware; ordinary action errors
keep the historical destroy-only cleanup.
The agent may add `tool_events` and `cleanup_errors`; it never includes tool
arguments, secrets or images in the final JSON. Full transcripts are written
separately; see [Session transcripts](#session-transcripts).

## `serve` protocol

`pymybot serve` exchanges one JSON-RPC 2.0 object per line on stdin/stdout.
Diagnostics go to stderr. A final non-JSON CLI result line may appear on stdout
when the process exits; clients should ignore lines without `jsonrpc`.

| Method | Parameters | Result |
| --- | --- | --- |
| `initialize` | — | `protocol`, `version`, `agent`, `mcp`, `status` |
| `session.status` | — | `state`, `robot`, `busy`, `sessions` (one `{session, robot, busy}` per active session) |
| `session.activate` | `robot`, optional `session` (name, default `default`), `modulePaths`, `allowHardware`, `vars` | session state; several named sessions may be active side by side |
| `session.deactivate` | optional `session` (omitted: deactivate every session) | cancels that session's work and cleans its drivers |
| `abort` | — | best-effort stop for every active session or the Agent executor; returns `state`, `aborted`, `safe_failures`, `destroy_failures` |
| `session.abort` | optional `session` (omitted: every session) | abort direct robot sessions; aborted sessions end |
| `agent.abort` | — | stop the Agent executor; closes an idle conversation |
| `run` | `input`, optional `session`, `vars`, `timeout` | `outputs` |
| `apply-sql` | `sql`, optional `session` | session mutation |
| `sample` | `name`, optional `session`, `count`, `intervalMs`, `timeout` | `sample` notifications |
| `agent.ask` | `task`, `role` (required), optional `robot`, `modulePaths`, `scriptsDir`, `skillsDir`, `vars`, `mcpConfig`, `allowMcpTools`, `allowHardware`, `allowActions`, `allowShell`, `allowFileWrites`, `enableShell`, `enableWeb`, `allowWeb`, `workspaceDir`, `model`, `baseUrl`, `apiKeyEnv`, `timeout`, `maxHistoryBytes`, `maxContextTokens`, `contextReserveTokens`, `hotTurns`, `warmTurns`, `promptFile`, `autoStats` (boolean, default `true`), `contextBytes`, `intent`, `sandbox`, `protectPrompts`, `searchEndpoint` | runs one memory/worker mission to completion without starting the loop; `agent.event` notifications carry `agent: memory\|worker\|system` |
| `agent.start` | `role` (required), optional `task` seed, `maxMissions`, `maxSeconds`, `pauseSeconds`, `maxRequests`, `maxToolCalls`, `turnTimeout`, `modelRetries`, `fallbackModels`, `requirePlanApproval`, agent options | starts the self-directed loop and returns its status; `team.message`, `mission.*`, `plan.*` and `team.stopped` events follow |
| `agent.stop` | — | stops the autonomous loop cooperatively and clears the worker stop latch |
| `agent.status` | — | current loop state, active mission and memory statistics |
| `agent.memory` | optional `limit`, `kinds`, `tags` | long-term memory entries and statistics |
| `agent.memory.forget` | `ids` or `kinds`/`tags` | remove matching long-term memories; rejected while the loop runs |
| `agent.missions` | optional `limit` | persisted mission history |
| `agent.reset` | optional `role`, `clearHistory` | closes the conversation and releases hardware; clears role history only when requested, preferring the named role over the active conversation's role |
| `roles.list` | — | list role-owned resources |
| `roles.show` | `name` (required) | inspect one role's resources |
| `roles.create` | `name`, optional `description`, `skillsDir`, `mcpConfig` | create from the bundled prompt baseline |
| `roles.clear_history` | `name` | clear an inactive role's resumable history |
| `cancel` | `id` | cancels a request (`-32800` for the cancelled request) |
| `shutdown` | — | cleanup and exit |

One robot operation runs at a time **per named session** (`-32001` when that
session is busy); different sessions never block each other, while an agent
conversation remains mutually exclusive with every session (`-32002` when the
state is wrong). Sessions are isolated: each owns its Robot, owner thread and
hot-SQL lifetime; omitting `session` addresses the default session.

`abort` is the client-facing stop: it chooses the current owner, sets the stop
flag immediately, waits for the active action to unwind, calls optional driver
`safe()` hooks in reverse activation order, and releases the hardware. A direct
session is ended; an idle Agent conversation is closed. It is **best effort, not
a hardware emergency stop**: a blocking native call or uncooperative Python loop
can still delay it. `session.deactivate` is ordinary cleanup and does not call
`safe()`. The server may send a `confirm` request to the client; only
`{"approved": true}` executes a gated tool. Changing `autoStats` changes the
conversation configuration and reopens the agent, just like other configuration
changes. Non-boolean values are rejected with `-32602`. Prompt updates always
request a dedicated `prompt:update_prompt` confirmation, regardless of other grants.

## Agent options

Agent mode is documented in the README. The important flags are:

| Option | Meaning |
| --- | --- |
| `--model PROVIDER:MODEL` | `openai`, `openai-chat`, `anthropic` or `deepseek` plus any registered provider; defaults to `MYBOT_MODEL`. |
| `--base-url URL` | Custom OpenAI-compatible endpoint; HTTPS required except loopback. |
| `--api-key-env NAME` | Environment variable holding the key; never pass the key itself. |
| `--task TEXT` | One-shot task; without it, start the REPL. `/clear` explicitly clears the current role history. |
| `--role NAME` | Load role-owned prompts, skills, MCP and resumable model history from `~/.mybot/roles/NAME`. Required for agent conversations. |
| `--workspace-dir DIR` | Enable bounded file tools inside `DIR`. |
| `--enable-shell` | Enable the shell tool inside the workspace; protected prompts require usable bubblewrap, with no unisolated fallback. |
| `--allow-actions` | Legacy compatibility flag for the executor's action-script and variable-read tools; they are no longer model tools and trusted skills need no approval. |
| `--allow-file-writes` | Pre-approve file creation/editing. |
| `--max-history-bytes` | Retained conversation history byte cap (64 KiB–64 MiB). |
| `--timeout` | Per-operation timeout for direct commands and provider/MCP requests; Agent turns have no wall-clock limit. |
| `--max-context-tokens` | Optional model context-window budget (1024–2 MiB tokens, disabled by default). Prunes old complete turns before every model request; must exceed output plus reserve tokens. |
| `--context-reserve-tokens` | Safety reserve within the context window (0–65536, default 2048), in addition to the 4096-token output budget. |
| `--prompt-file FILE` | Additional operator-owned UTF-8 profile (max 8 KiB); does not replace runtime USER or the safety prefix/suffix. |
| `--max-requests` | Maximum provider requests in one worker turn (1–10000, default 64). |
| `--max-tool-calls` | Maximum tool calls in one worker turn (1–100000, default 128). |
| `--turn-timeout` | Optional wall-clock budget for one worker turn; 0 disables it (default 0). |
| `--model-retries` | Optional provider retries for transient model failures (0–10, default 0; dispatched tool outcomes are never retried). |
| `--fallback-model` | Optional `provider:model` fallback tried after the primary model fails; repeatable. |
| `--require-plan-approval` | Ask the operator to approve each autonomous mission plan before the worker acts. |
| `--no-prompt-stats` | Disable automatic host-generated STATS updates (also accepted by `gui`; default false). |
| `--context-bytes N` | Budget for the generated project inventory (workspace top level, structures, scripts, drivers, skills); 0 disables it (0–64 KiB, default 4096). |
| `--intent MODE` | `auto` (default), `off`, `chat`, `inspect`, `control`, `author` or `diagnose`. Auto narrows the tool allowlist when the request clearly matches an intent; mixed requests union their tools; messages with no keywords fall back to the read-only `chat` allowlist. `off` removes all routing restrictions. |
| `--sandbox MODE` | `auto` (default), `off` or `bwrap`. With prompt protection enabled (the default), a missing/unusable bubblewrap or `off` refuses shell execution; disabling prompt protection allows the workspace-jail fallback. The bubblewrap profile makes the host read-only, gives the workspace a writable mount, re-mounts prompt roots read-only, clears the environment and unshares network/PID/IPC/UTS namespaces. This protects prompt integrity, not host-file confidentiality. |
| `--web` | Enable `web_fetch` (HTTPS only) and, with `--search-endpoint`, `web_search`. Requires `pymybot[web]`. Private/link-local/loopback targets, redirects past three hops, non-text content and oversized bodies are refused. |
| `--allow-web` | Pre-approve web requests for this session (requires `--web`). |
| `--search-endpoint URL` | SearXNG base URL used by `web_search`; no endpoint means no search tool. |
| `--mcp-config FILE` | Operator `mcpServers` JSON; exposes external MCP tools to the model. See [mcp.md](mcp.md). |
| `--allow-mcp-tools` | Pre-approve external MCP tool calls (requires `--mcp-config` or `--role`). |
| `--var`, `--var-env` | Structure `Alias`/`Vars` overrides and action-script bindings, as described above. |
| `--no-session-log` | Do not write a session transcript (also accepted by `serve`). |

`web_search` calls `GET <endpoint>/search?format=json&q=...&safesearch=1`, so a
self-hosted SearXNG must enable the `json` output format. An explicitly
configured loopback endpoint may use `http://127.0.0.1:PORT` (also `localhost`
or `::1`); other endpoints must be HTTPS on port 443. `web_fetch` still refuses
loopback and private targets independently of the configured search endpoint.
Configuration failures name the fix: 404 (endpoint must be the instance base
URL — `/search` is appended), 403 and non-JSON bodies (enable the `json` format
in `settings.yml` or use a private instance), and unreachable endpoints name
the URL that refused the connection.

A turn blocks the fourth identical tool call with a structured `not_executed`
receipt instead of replaying a stuck loop; the transcript records `intent` and
`loop_guard` events.

## Custom model providers

Beyond the four built-ins, extra OpenAI-compatible endpoints are pluggable
without duplicating transport code:

```python
from pymybot.agent import register_provider

# Reuses the hardened openai HTTP path (client, timeouts, proxy handling):
register_provider("moonshot", key_env="MOONSHOT_API_KEY",
                  base_url="https://api.moonshot.cn/v1/")

# Or supply a builder for a non-OpenAI SDK; it must return a bindable
# chat model and own the client resources it creates:
register_provider("gemini", key_env="GEMINI_API_KEY", build=build_gemini_model)
```

After registration `--model moonshot:kimi-k2` (and fallback chains) work like
any built-in. A package can also ship a `pymybot.model_providers` entry point
whose callable performs the registration; plugins load once per process and a
broken plugin never blocks the built-ins.

## `discover` command

```sh
pymybot discover                       # every bus, passive enumeration
pymybot discover --buses uart,ftdi     # subset of i2c,spi,uart,ftdi
pymybot discover --probe               # also open/close each real UART port
```

Read-only host enumeration shared with the hardware-controller skill:
I2C/SPI/UART come from the bundled `Dev_enum` driver, FTDI USB adapters are
listed by pyftdi and mapped to HAL-ready `ftdi://` URLs, and `hints` maps every
found device to the `CREATE TABLE UART/I2C/SPI` declaration that uses it.
Nothing is opened unless `--probe` is set; probing never writes, but an open
can pulse DTR/RTS, so boards that reset on those lines should not be probed.

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
state, unfinished actions and model context are never restored from them.
Resumable model messages are instead stored in the selected role's `history.json`;
see [roles.md](../../../docs/roles.md#resumable-history).

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

See [`gui.md`](../../../docs/gui.md) for the graphical equivalent.
