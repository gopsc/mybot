# Changelog

All notable changes to the Python reference implementation are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Standard MCP over stdio (`pip install pymybot[mcp]`): `pymybot mcp` exposes
  the controller to Claude Desktop, Cursor and other MCP clients. It is
  read-only by default, reuses `RobotExecutor` receipts and fault latching, and
  publishes trusted `.mt` scripts and skills as resources. Physical hardware
  still requires `--allow-hardware` plus `--allow-execution`.
- The agent can call operator-configured external MCP servers via
  `--mcp-config` (Claude Desktop/Cursor `mcpServers` shape), with per-call
  approval, bounded results and `unknown` receipts on transport failures;
  `--allow-mcp-tools` pre-approves a session. `agent.ask` accepts `mcpConfig`,
  `allowMcpTools` and `historyTurns`, and the GUI stores an MCP config path.
- `--history-turns` exposes the retained-turn budget (1–20) instead of the
  previously fixed 6.
- The GUI now exposes the full backend surface: tabbed settings (model/budgets,
  permissions, MCP), workspace file tools, file writes, shell and MCP
  auto-approval, history-turn/byte budgets, a command panel for the one-shot
  CLI commands, an MCP JSON editor that reuses the agent validator, a session
  manager (filter/view/delete/prune), environment diagnostics, and a lazy
  resource browser with Markdown preview, syntax
  highlighting and mtime-based caching. Streaming only auto-scrolls when the
  transcript is at the bottom; retry, clear and copy actions were added.
- The GUI opens with a retro entry screen (`pymybot/gui/splash.py`): SVG robot
  logo, animated scanline and grid, live `serve` boot status, indeterminate
  progress and an `进入控制台` button (Enter/Escape shortcuts, fade-out into
  the main window). Set `--no-splash` or `MYBOT_GUI_SPLASH=0` to skip it; the
  main window and About dialog share the same branding asset.
- Agent prompts are layered (`pymybot/agent_prompt.py`): the immutable `SOUL`
  safety contract, an optional operator `--prompt-file`, a generated and
  explicitly untrusted project inventory, and runtime guidance. Only optional
  layers are truncated to the 16 KiB budget. The inventory
  (`pymybot/agent_context.py`) lists workspace entries, structures, scripts,
  drivers and skills, is mtime-cached and bounded by `--context-bytes`
  (default 4096, 0 disables). `serve.agent.ask` accepts `promptFile` and
  `contextBytes`, and the GUI exposes both under 设置.
- Intent routing (`pymybot/agent_intent.py`) classifies Chinese/English requests
  as chat, inspect, control, author or diagnose before each model request. It
  narrows the tool allowlist and request/tool budgets, unions tools for mixed
  requests, leaves keyword-free messages unrestricted, and rejects out-of-intent
  tool calls with a structured not-executed receipt. `--intent`, the GUI
  dropdown and `serve.agent.ask` expose the mode; results carry intent metadata.
- Shell sandbox (`pymybot/sandbox.py`): `--sandbox auto` probes bubblewrap and
  falls back to the workspace jail; `bwrap` fails instead of running
  unsandboxed. The bubblewrap profile mounts the host read-only, gives the
  workspace a read-write overlay, clears the environment, and unshares network,
  PID, IPC and UTS namespaces. `doctor` reports the active backend, Shell
  receipts include `sandbox`, and the GUI/serve/CLI expose the mode. The
  workspace jail remains the honest Windows fallback.
- Opt-in web tools (`pymybot/agent_web.py`, `pip install pymybot[web]`):
  `--web` adds `web_fetch` (HTTPS, SSRF private/loopback/link-local checks,
  three re-validated redirects, text-only content, 512 KiB/16k-char caps) and
  `web_search` when `--search-endpoint` names a SearXNG instance. Approval is
  per call unless `--allow-web`; `serve.agent.ask` accepts `enableWeb`,
  `allowWeb` and `searchEndpoint`; the GUI exposes all three. No provider means
  no search tool, and results are never fabricated.
- The resource browser indexes structures (`robots/*.sql`) and Lua drivers
  (`modules/**/*.lua`) alongside scripts, skills and docs, watches roots with
  `QFileSystemWatcher` and reloads after a 400 ms debounce.
- `pymybot sessions --delete ID --yes|--dry-run` deletes named transcripts
  safely (repeatable; never follows links or removes an active session).
- Structure `Alias`/`Vars` rows can be overridden with `--var`/`--var-env`
  before activation, so drivers that authenticate during `build()` receive
  values supplied at run time. `--var` now applies to every command that loads
  a structure and to agent mode (operator bindings also reach every
  `run_action_script` call). `serve` accepts `vars` in `session.activate` and
  `agent.ask`, and the GUI exposes a runtime-only “变量覆盖” settings field.
- Qsont supports `op=create` with `device=0`, and the register, create-device
  and push/pull samples now share `robots/qsont.sql`. First-time account
  registration stays manual because activation logs in before any action runs.

### Changed

- Pin the MCP SDK to `>=1.30,<2`. SDK 2 renamed the low-level `Server` callbacks
  and `McpError`, which breaks the `pymybot mcp` stdio server; Dependabot now
  ignores major MCP bumps until the adapter is ported. The agent-side client
  keeps working with either SDK version.
- Migrate the desktop GUI from Tkinter to PySide6 (Qt 6), retaining the serve
  protocol, streaming chat, settings and per-tool approvals. Install the `gui`
  extra for desktop use; CLI-only installations do not require Qt.
- GUI tests run offscreen; test and packaging extras include PySide6.
- GUI responsiveness: hardware refreshes are debounced (140 ms), command-panel
  runs use `QThreadPool` instead of a raw thread, resource reloads are debounced
  and previews fade in, and session timestamps parse with `datetime.fromisoformat`
  instead of manual slicing.
- `$alias` cells may now fill structure columns; previously only `$vars`
  scalars were accepted, which blocked Alias-based credential injection.

### Removed

- The unmaintained Cangjie and C++17 + Rust implementations, their CI jobs,
  Dependabot Cargo updates, issue/PR edition fields and edition-specific docs.
  The shared Lua drivers keep working; only their legacy framework header was
  renamed.

## [0.3.1] – 2026-10-26

### Added

- Session transcripts for `agent` and `serve`: `~/.mybot/sessions/<id>/` holds
  `meta.json`, `transcript.jsonl` and content-addressed images, with per-event
  and per-session size caps. Disable with `--no-session-log` or
  `MYBOT_SESSION_LOG=0`; `MYBOT_HOME` moves the root. Ported from the archived
  `release` prototype without its built-in endpoint.
- `pymybot sessions` lists transcripts newest-first and can prune them with
  `--keep N [--older-than DAYS]`; deletion requires `--yes`, and `--dry-run`
  previews it. The newest N sessions are always protected and symlinks are
  never followed.
- GUI settings toggle for session transcripts; turning it off starts `serve`
  with `--no-session-log`.
- Nuitka standalone builds are recognised as frozen (`paths.frozen()` checks
  `__compiled__`), so asset lookup, console hiding and the GUI's `serve` child
  behave as in PyInstaller builds.
- The Windows release bundle now installs `.[camera]` and collects PyAV, and the
  release workflow verifies that `doctor` reports `av` as importable before
  publishing.
- Reference for the generic `scripts/Camera.mt` action and `robots/camwin.sql`.

### Changed

- An “unknown outcome” receipt now names the failure class, and a failure after
  dispatch prints its exception type (never the message) to stderr.
- A missing agent dependency names the module that failed to import.
- Repository layout: community files moved to `.github/`, the English README to
  `docs/README.en.md`, the roadmap to `docs/roadmap.md`, and completed migration
  notes to `docs/history/`. Root-level files are now limited to build entry
  points, licensing and the main README.
- The CI helper moved from `scripts/ci_smoke.py` to `tools/ci_smoke.py`, so
  `scripts/` contains only MT action examples. Lint and packaging now include
  `tools/`.
- Packaging includes the moved docs and tools in the sdist; the Windows bundle
  and Docker image no longer carry community files they cannot display.
- Release tags must now match both `pyproject.toml` and `pymybot.__version__`;
  beta/RC tags are published as GitHub prereleases. This makes the manually
  built `v0.3.1beta` asset superseded by a reproducible `v0.3.1` release.

### Fixed

- `pymybot serve` no longer aborts at interpreter shutdown with
  `_enter_buffered_busy` when a client sends `shutdown` but keeps stdin open.
  The JSONL reader uses raw `os.read`, so a daemon thread never owns the
  BufferedReader lock during finalization. A final request without a trailing
  newline is still processed at EOF.
- `pymybot sessions --prune` skips the newest `--keep` sessions, sessions whose
  process is still alive on POSIX, symlinks and malformed directories.
- Saving GUI settings no longer restarts `serve` unless the workspace,
  interpreter or transcript preference actually changed.
- DirectShow cameras listed as `(none)` by some FFmpeg builds are recognised via
  the video-input category GUID.
- Windowed builds without console streams no longer fail on the first `print`.
- The README edition table reports the actual C++17 + Rust version (`0.1.0`)
  instead of `1.x`.
- Session-transcript wording no longer promises that tool output can never
  contain secrets; API keys in environment variables are not read, but
  operator-supplied content is logged.

## [0.3.0] – 2026-10-26

### Added

- `--max-history-bytes` for agent conversations (64 KiB–64 MiB, default 4 MiB).
  The byte budget is provider-independent and prunes complete turns only, so a
  context-length rejection no longer requires guessing a model’s window (closes
  #10).

### Changed

- Documentation now describes context handling and the explicit history budget.

## [0.2.0] – 2026-10-26

“Open-source ready” release. The Python reference edition, documentation,
packaging and automation were consolidated into a reproducible monorepo.

### Added

- Multi-language monorepo layout: Cangjie and C++17 + Rust editions now live
  under `implementations/` with their own build systems, tests and docs.
- Complete project documentation: architecture, CLI, GUI, development, testing,
  release, versioning, security and FAQ guides.
- Community health files: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
  `SECURITY.md`, `SUPPORT.md`, issue forms and a pull-request template.
- `pymybot doctor` for environment/dependency/asset diagnostics and
  `pymybot --version`.
- Optional `precision` column for `@Vars` scalars (structure SQL and MT),
  controlling the rendered decimal places without changing expression math
  (closes #4).
- Reproducible release workflow for sdist, wheel and Windows GUI artifacts,
  with SHA-256 checksums.
- Windows `camwin.sql` and generic `Camera.mt` examples.
- Real GUI screenshot in the README.

### Changed

- Default branch remains `gui-mybot` for now; renaming it to `main` requires
  repository-owner/admin access and is tracked as maintenance.
- GUI is the default entry point; `--no-gui` keeps the terminal experience.
- Python, GUI and agent dependencies updated to current compatible releases.
- README rewritten around the three entry points, architecture and
  multi-language editions.
- CI now runs Python 3.11–3.14 on Linux, plus Windows, agent, wheel and
  quick-start gates; duplicate push/pull-request runs were removed.

### Fixed

- GUI could stay on “启动中…” forever when a restart was requested while the
  `serve` child was still starting; the stale client is now stopped and the
  replacement launch is deferred until cleanup completes.
- GUI restart during a running turn left `busy`/`turn_id` set and the composer
  permanently disabled.
- Frozen builds now resolve bundled assets and the sibling CLI launcher through
  `pymybot.paths` instead of assuming a source checkout.

### Security

- Withdrew the `gui-v1` binary release that contained an unpublished source
  tree and a shared built-in API key. Releases are now built from a tagged
  public commit and publish checksums.
- Documented the trust model: operator-approved tools, no sandbox claims, and
  explicit confirmation for hardware/file/shell actions.
- System prompts remain operator-owned; remote/model prompt replacement is
  rejected by design (closes #5).

### Removed

- Obsolete long-lived implementation branches (`pymybot`, `cangjie`,
  `cangjie_new`, `cpp_rust_agent`); their history is preserved under
  `archive/*` tags and their code is available in `implementations/`.
- The undocumented `session_log.py` behaviour from the `gui-v1` binary. The
  source tree does not persist conversation transcripts.

## [0.1.0] – 2026-10-18

Initial public Python edition.

### Added

- Three-layer script model: structure SQL, Lua drivers, MT action scripts.
- Lupa/LuaJIT runtime with a restricted bootstrap and instruction budget.
- 45 migrated chip drivers plus Qsont, Shell, Timer, Relay, Servo and H03ARR.
- Virtual bus, register maps and no-hardware end-to-end fixtures.
- PydanticAI agent with approval-gated tools, budgets and confirmation flow.
- `serve` stdio JSON-RPC 2.0 backend for IDE/front-end integration.
- HTTP bus, PyAV/Pillow camera pipeline, UART/I2C/SPI HAL.
- Tkinter GUI with agent chat, tool approval dialogs, settings and logs.
- Linux/Windows CI, wheel/sdist smoke tests and README quick-start checks.

[0.3.1]: https://github.com/gopsc/mybot/releases/tag/v0.3.1
[0.3.0]: https://github.com/gopsc/mybot/releases/tag/v0.3.0
[0.2.0]: https://github.com/gopsc/mybot/releases/tag/v0.2.0
[0.1.0]: https://github.com/gopsc/mybot/releases/tag/v0.1.0
