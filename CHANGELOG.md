# Changelog

All notable changes to the Python reference implementation are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `pymybot roles delete NAME --yes` permanently removes a role directory, and
  the GUI's **删除** button does the same after confirmation, closing the Agent
  conversation first. Both cover prompts, skills, workspace files and history.
- The Agent gains a `create_directory` workspace tool. It creates one directory
  below an existing, already-verified parent, applies the same traversal, link
  and protected-prompt checks as the file tools, and stays behind the file-write
  approval gate. Windows sessions can now create directories without the
  bubblewrap-gated `shell` tool.
- `i2c-address-probe` skill: a read-only host-side I2C address prober with a
  zero-dependency Python implementation, an `sh` wrapper, `/sys` kernel-binding
  annotation, a fixed JSON contract and `skill.json` actions `list-buses` and
  `scan`, so the Agent can run it through `run_skill`.
- `pymybot roles repair NAME [--skills-dir DIR] --yes` fills missing files in a
  role's installed runnable skills (manifest, entrypoint, assets) from a
  complete source without overwriting existing files.

### Changed

- The bundled core prompt now routes hardware work through `run_skill`, removes
  the stale `run_action_script` reference, and describes the shell sandbox and
  the prompt/skill approval gates as implemented.
- The Agent only advertises `run_skill` and hardware access when at least one
  installed skill declares `skill.json`; otherwise the runtime guide says the
  skills are reference-only instead of naming a tool that was not registered.
- Wheel and frozen builds now ship skill entrypoints for runnable skills that do
  not use the `packaged: "cli"` fallback, so `run_skill` works outside a source
  checkout.
- Roles now own a `workspace/` directory. Selecting a role uses that workspace,
  and `install_skill(path)` copies a complete workspace-authored skill into the
  role's skills root. Role creation copies complete skill directories, including
  `skill.json`, `scripts/` and `assets/`, so runnable skills stay runnable. The
  `control` intent also exposes `write_file`, `edit_file` and `shell`.
- The GUI no longer shows the structure selector, hardware tree, scripts root or
  module path, and the script/structure editor tab is removed. The Agent starts
  without a selected structure; scripts and modules use the packaged/source
  defaults, and the command panel and resource browser remain. The timeout,
  request, tool and history-turn controls are gone.
- The Agent no longer enforces request, tool-call, history-turn or wall-clock
  turn limits, and variable reads no longer use an allowlist. Provider/MCP
  request timeouts and the history byte cap remain; direct tools, MCP and the
  CLI expose no budget flags or `--read-var` gate.
- Cameras are now Agent built-in tools. `list_cameras` enumerates host devices
  and `capture_camera` returns a bounded JPEG image block, backed by PyAV/Pillow
  (`pymybot[camera]`). The controller no longer declares cameras, exposes HAL
  camera operations, or ships `Camera.py` / `Camera.mt` / camera example
  structures; CLI, MCP, serve and the GUI no longer expose camera parameters,
  capture tools or preview controls.
- The GUI no longer shows permission checkboxes. File, Shell, web and MCP tools
  are enabled whenever their prerequisite exists and their calls run without
  approval; prompt updates and skill installation still ask per call. The CLI
  keeps its opt-in flags and approval gates.
- Trusted skills now execute without approval: `run_skill` no longer prompts,
  hardware flags are granted automatically, path/parameter/output/timeout checks
  are removed, and skill directories are no longer write-protected. Provider and
  MCP request timeouts and the file-write/MCP/prompt approval gates remain.
  Installing a skill is equivalent to installing trusted host code with hardware
  access.
- The Agent core is now generic. Direct hardware tools (`list_hardware`,
  `list_action_scripts`, `query_sql`, `run_action_script`, `read_variables`,
  `capture_image`) are no longer model tools; all hardware work goes through
  `run_skill("hardware-controller", ...)`. The agent can start without a robot
  and keeps workspace, shell, web, skill and MCP tools. `hardware-controller`
  adds `scripts`, `query` and `sample` actions, and Skill arguments now support
  bounded strings. The controller keeps no camera surface.
- The Agent backend now uses LangGraph/LangChain instead of PydanticAI. Tool
  approval uses LangGraph interrupts with an in-memory checkpointer; the
  serve/GUI protocol, receipt shapes and streaming event names are unchanged.
  Model specs (`openai:`, `openai-chat:`, `anthropic:`, `deepseek:`) and the
  `--base-url`/`--api-key-env` contract keep working.
- Role history format is now version 2 and stores LangChain messages. Version 1
  PydanticAI history is detected and ignored, so affected roles start a fresh
  conversation without failing to load.

### Changed

- **Agent conversations now require a role at every entry point.** `pymybot
  agent` without `--role`, `serve` `agent.ask` without `role` and the GUI
  composer without a selected role are rejected with an actionable message;
  the global default conversation is gone. The GUI role selector lists only
  real roles, auto-selects the first one and asks you to create a role when
  none exists. Since a role owns its workspace, skills and MCP file, combining
  `--role` with `--workspace-dir`/`--skills-dir`/`--mcp-config` stays an error.

### Removed

- The `pydantic-ai-slim` dependency; install `pymybot[agent]` for
  `langchain`, `langgraph` and the provider integrations.

### Fixed

- Frozen builds merge the root `pymybot` package and the hardware-controller
  Skill sources into one staging package before PyInstaller analysis, so
  `pymybot.cli`, the Agent modules and the GUI are present in the bundle
  instead of failing at startup. `sqlparse` is an explicit hidden import for
  the controller's SQL grammar.

- `pymybot new` printed follow-up `check`/`run` commands without
  `--module-path modules`, so they failed with "Driver module not found" in the
  generated project. The commands now include the module root, with a CLI
  regression test.
- `roles show` reports `runnable` and `incomplete` skills, and role creation
  refuses a copied manifest whose declared entrypoint is missing. Previously a
  role created from an older role could silently lose every `skill.json` (and
  with it `run_skill`).
- `agent.reset` with `clearHistory` erased the active conversation's role even
  when the caller named a different role, so switching roles and pressing
  **新对话** kept the selected role's history and the model still answered with
  old context. The explicitly named role now wins; the active role is only a
  fallback.
- The GUI's **新对话** did nothing when `serve` was still starting. The reset is
  now queued and sent once the server is ready, and a successful reset clears
  the visible transcript as well. **清空对话** still only clears the window and
  now says so, since it keeps the model context.

## [0.6.0] – 2026-11-02

### Added

- Agent `run_skill` executes only actions declared by a trusted `skill.json`,
  with typed parameters, scoped paths, per-call approval, host-injected hardware
  grants, bounded subprocess output and timeout/unknown-outcome semantics.
  `hardware-controller` registers `doctor`, `hardware`, `check` and `run`.

### Changed

- Moved the self-contained controller and MCP Runtime to
  `skills/hardware-controller/scripts/pymybot/`, with authoritative controller
  docs in `references/` and default robots/scripts/modules in
  `assets/`. Existing `pymybot.*` imports, CLI/GUI/Agent entries and
  packaged asset layouts remain compatible.

## [0.5.1] – 2026-11-02

### Added

- Native Camera capture is available without a model request or MT script through
  `AgentSession.capture()` and `serve.agent.capture`. The GUI lists allowlisted
  Camera variables, keeps the existing approval flow and previews the captured
  image locally; Camera MT actions remain supported for automation.

## [0.5.0] – 2026-11-02

### Added

- The bundled `skill-authoring` skill (技能编写规范) defines the SKILL.md
  layout, frontmatter, trigger descriptions, references and the approved
  `create_skill` workflow. The core prompt now names it explicitly instead of
  referring to an unspecified authoring skill. Operator skill roots are protected from generic workspace
  file tools and shell writes, so skills must go through the approved skill
  tools.
- GUI script/structure editor tab: opens and saves `.mt` actions and
  `robots/*.sql` structures with line numbers, MT/SQL highlighting and
  unsaved-change tracking. **检查** runs the static check without activation
  (`check --robot` for a structure, `check --robot --input` for an action);
  **运行** executes through the same one-shot CLI child, stays virtual-only
  unless **允许硬件** is confirmed, renders the JSON receipt and can be stopped.
  With a structure open, choose an action script to run against it. It does not
  touch the agent's long-lived `serve` session, and it follows toolbar structure
  and workspace context changes.
- First-class best-effort abort: `Robot.abort()`, optional driver `safe(data)`
  hooks (Python and Lua), and `abort` / `session.abort` / `agent.abort` serve
  methods. The GUI adds a red **急停** button without a confirmation dialog.
  Abort sets the stop flag before waiting, calls `safe()` in reverse activation
  order with a fresh bounded budget, then destroys drivers and latches the
  robot. It is not a hardware emergency stop.
- `pymybot new NAME` generates a runnable structure SQL, MT action and Python
  driver skeleton without touching hardware.
- Struct, object and array values can be used directly as text parameters and
  captured into Alias variables as compact JSON; field selection still returns
  text/number/bool, while arithmetic, logical operators and Reflex arguments
  continue to reject containers.

### Fixed

- GUI role creation now falls back to the packaged default skills when no
  custom skills root is selected (or the current role's skills directory is
  empty), instead of creating a role with no reference skills.
- An explicitly configured loopback SearXNG endpoint (`http://127.0.0.1:PORT`)
  is now accepted by `web_search`; the configuration layer already allowed it,
  but the generic web policy rejected loopback targets.
- The Lua runtime now falls back to standard Lua when the `lupa` wheel has no
  `luajit21` module (notably macOS arm64). Python drivers keep working; Lua
  drivers that depend on LuaJIT FFI/HAL report a clear error, and `doctor`
  warns instead of marking the base install unhealthy. The macOS CI smoke uses
  the pure-Python `Time` driver for the same reason.

## [0.4.1] – 2026-10-31

### Changed

- Modernized the desktop GUI theme and splash screen; refreshed the robot
  branding assets and startup animation.

## [0.4.0] – 2026-10-31

### Fixed

- The headless Docker image copies `prompts/`, so the packaged defaults are
  present and validate; the Docker CI job now fails when `doctor` is unhealthy
  or the prompt bundle is incomplete.
- Keep legal 32-level `if`/`while` nesting executable through Agent/serve/MCP
  snapshots: freezing a control body no longer adds an extra `@Action` wrapper
  around its sole nonempty matrix. Empty blocks and adjacent matrix boundaries
  remain intact, and the original nesting limit is unchanged.

### Added

- Runtime prompt layers with bundled Markdown/JSON defaults for source, wheel,
  PyInstaller and Nuitka: `pymybot prompts list`, missing-only refill and confirmed,
  backed-up full restore, including recovery from corrupt runtime safety/manifest
  files. `doctor` validates bundled manifest/safety hashes without creating a home.
- Safety layers 0/100 pinned to trusted hashes, operator-only core, and dedicated
  per-call approvals for agent SOUL/USER/STATS updates with CAS, backups and audit
  hashes. Automatic sanitized host-only STATS can be disabled with
  `--no-prompt-stats`, GUI settings or serve `autoStats: false` (default true).
  GUI prompt management shows layer state and the composed prompt's short hash.
- Named, top-level `@Reflex(name)` blocks called through `reflexName.parameter`
  headers, including aliases and dynamic headers. Reflex and Action bodies can
  mix matrices with nested Action/if/while blocks. Reflex-root Alias/Vars defaults,
  typed arguments and all inner captures (including global Struct writes) are
  isolated per call; outer captures explicitly read the final device result.
  Recursive calls share execution, cancellation and output budgets with a
  32-level limit. See the MT scripting reference, section 7.
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
- Agent prompt composition combines manifest-ordered runtime layers with an
  optional operator `--prompt-file`, explicitly untrusted project inventory and
  runtime guidance, bounded to 128 KiB. The inventory
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
- Shell sandbox (`pymybot/sandbox.py`): `--sandbox auto` probes bubblewrap.
  Agent prompt protection requires it and refuses unisolated fallback, including
  on Windows or with `off`. The profile mounts the host read-only, keeps prompt
  roots read-only inside the writable workspace, clears the environment, and
  unshares network, PID, IPC and UTS namespaces. `doctor` reports availability,
  shell receipts include `sandbox`, and GUI/serve/CLI expose the mode. Standalone
  workspace APIs without protected roots retain the legacy workspace fallback.
- Opt-in web tools (`pymybot/agent_web.py`, `pip install pymybot[web]`):
  `--web` adds `web_fetch` (HTTPS, SSRF private/loopback/link-local checks,
  three re-validated redirects, text-only content, 512 KiB/16k-char caps) and
  `web_search` when `--search-endpoint` names a SearXNG instance. Approval is
  per call unless `--allow-web`; `serve.agent.ask` accepts `enableWeb`,
  `allowWeb` and `searchEndpoint`; the GUI exposes all three. No provider means
  no search tool, and results are never fabricated.
- Harness reliability: a turn blocks the fourth identical tool call with a
  structured `not_executed` receipt and a `loop_guard` transcript event instead
  of replaying a stuck loop. `tests/test_agent_harness_eval.py` is an offline
  matrix covering intent gating, the loop guard, prompt/context injection and
  the web/sandbox surfaces.
- The resource browser indexes structures (`robots/*.sql`) and Python/Lua drivers
  (`modules/**/*.py`, `modules/**/*.lua`) alongside scripts, skills and docs, watches roots with
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

- `smbus2` is now a base dependency on Linux, so `/dev/i2c-*` works after a
  normal install instead of requiring the `linux` extra. `spidev` stays opt-in
  because most Linux/Python combinations build it from source. `doctor` now
  reports both before a driver open fails, and treats a missing `smbus2` as
  unhealthy while `spidev` stays a warning.
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

- **BREAKING:** Duplicate top-level Lua drivers for I2C, SPI, UART, Camera and
  HTTP are removed; the corresponding `.py` drivers are now the only built-in
  implementations. Custom module roots that explicitly load these deleted
  `.lua` files must use the Python equivalents. Lua chip drivers, Lua HAL
  adapters, virtual device models and Lua daemons remain supported.
- **BREAKING:** MT `@Trigger` parsing/execution and the unnamed `@Reflex` table
  syntax with a `name` column are removed and rejected at parse time, without
  compatibility support. Migrate to `@Reflex(name)` and ordinary Action calls;
  SQL structure triggers and their reference protections remain unchanged.
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

[0.4.0]: https://github.com/gopsc/mybot/releases/tag/v0.4.0
[0.3.1]: https://github.com/gopsc/mybot/releases/tag/v0.3.1
[0.3.0]: https://github.com/gopsc/mybot/releases/tag/v0.3.0
[0.2.0]: https://github.com/gopsc/mybot/releases/tag/v0.2.0
[0.1.0]: https://github.com/gopsc/mybot/releases/tag/v0.1.0
