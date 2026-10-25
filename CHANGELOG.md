# Changelog

All notable changes to the Python reference implementation are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Per-edition histories live next to each implementation:

- Cangjie: [`implementations/cangjie/CHANGELOG.md`](implementations/cangjie/CHANGELOG.md)
- C++17 + Rust agent: [`implementations/cpp-rust/docs/changelog.md`](implementations/cpp-rust/docs/changelog.md)

## [Unreleased]

### Added

- Session transcripts for `agent` and `serve`: `~/.mybot/sessions/<id>/` holds
  `meta.json`, `transcript.jsonl` and content-addressed images, with per-event
  and per-session size caps. Disable with `--no-session-log` or
  `MYBOT_SESSION_LOG=0`; `MYBOT_HOME` moves the root. Ported from the archived
  `release` prototype without its built-in endpoint.
- Nuitka standalone builds are recognised as frozen (`paths.frozen()` checks
  `__compiled__`), so asset lookup, console hiding and the GUI's `serve` child
  behave as in PyInstaller builds.
- Reference for the generic `scripts/Camera.mt` action and `robots/camwin.sql`.

### Changed

- An “unknown outcome” receipt now names the failure class, and a failure after
  dispatch prints its exception type (never the message) to stderr.
- A missing agent dependency names the module that failed to import.

### Fixed

- DirectShow cameras listed as `(none)` by some FFmpeg builds are recognised via
  the video-input category GUID.
- Windowed builds without console streams no longer fail on the first `print`.

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

[0.3.0]: https://github.com/gopsc/mybot/releases/tag/v0.3.0
[0.2.0]: https://github.com/gopsc/mybot/releases/tag/v0.2.0
[0.1.0]: https://github.com/gopsc/mybot/releases/tag/v0.1.0
