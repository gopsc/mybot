# Development guide

## Toolchain

| Requirement | Version |
| --- | --- |
| Python | 3.11–3.14 |
| LuaJIT | provided by the `lupa` wheel |
| PySide6 | 6.10–6.x, included in `gui`, `test` and `package` extras |
| MCP SDK | 1.30–1.x, included in `mcp` and `agent` extras |
| Node/npm | not required |
| PyInstaller | 6.x, only for frozen builds |

## Setup

```sh
git clone https://github.com/gopsc/mybot.git
cd mybot
python -m venv .venv
.venv/bin/pip install -e ".[test]"
# agent, MCP and GUI:
.venv/bin/pip install -e ".[agent,mcp,test]"
```

Use the platform paths under Windows (`.venv\Scripts\pip`).

## Everyday commands

```sh
python -m pytest -q                       # full suite, no hardware
python -m pytest tests/test_gui.py -q     # Qt widgets tested offscreen, including headless CI
python -m pymybot check --robot robots/relay-test.sql --input scripts/relay-test.mt
python -m pymybot run --robot robots/relay-test.sql --input scripts/relay-test.mt --timeout 10
python -I tools/ci_smoke.py base        # fail if pydantic_ai leaked into base env
python -I tools/ci_smoke.py agent       # fail if agent imports are missing
python -I tools/ci_smoke.py wheel       # sdist -> wheel -> clean venv
python -I tools/check_docs_skill_sync.py  # skill links/paths resolve, references declare a Source
```

`--no-gui` is required for the terminal agent when no subcommand is given;
controller subcommands such as `check` and `run` always use the terminal.

## Code layout

```text
pymybot/            Python package
modules/            Python and Lua bus/driver modules and shared libraries
robots/             structure SQL examples
scripts/            MT action examples
skills/             operator-trusted agent reference skills
tests/              pytest suite and virtual-device fixtures
docs/               operator and maintainer documentation
tools/              packaging helpers and PyInstaller spec
```

## Style and quality

- Python 3.11+, no mandatory third-party formatter. Keep imports grouped,
  functions focused and docstrings short and factual.
- Comments should explain *why*, not restate *what*.
- No duplicate JSON/path/process helpers: reuse `security.py`, `process.py`,
  `agent_workspace.py` and `paths.py`.
- Do not add a broad `except Exception: pass` unless it is cleanup that cannot
  affect the result; log or surface the failure instead.
- Public operator-visible text is Chinese; code identifiers and commit messages
  are English.

A narrow lint gate runs in CI (`ruff` with syntax/undefined-name rules). Full
`ruff` output is advisory because the repository predates a formatter baseline;
do not reformat unrelated files in a behaviour PR.

Behaviour changes belong in `docs/` first; the agent-facing files under
`skills/` then summarise and link instead of restating them. The same lint job
runs [`tools/check_docs_skill_sync.py`](../tools/check_docs_skill_sync.py),
which fails on dead skill links, missing repository paths, a reference without a
`Source:` line and references that
[`skills/README.md`](../skills/README.md) does not register.

## Adding a driver

1. Add `modules/<Name>.py` implementing `Driver(context)`, or `modules/<Name>.lua`
   using `lib/drv_common.lua` and `lib/bus_contract.lua`.
2. Add `tests/fixtures/virt/<name>_virt.sql` and
   `tests/fixtures/virt/<name>_virt.mt`; register the virtual device model in
   `modules/lib/virtbus/regmap.lua` when applicable.
3. Run `python -m pytest tests/test_migrated_drivers.py -q` and the fixture
   directly. Use `tests/test_virtual_drivers.py` for synthetic bus/protocol models.
4. Document the device, address range, units and known limitations in
   `docs/` or the driver header.
5. Never make a virtual result look like a real measurement; use clearly named
   files (`*_virt`).

## Frozen builds

```sh
python -m pip install -e ".[agent,camera,package]"
python -m PyInstaller --noconfirm --clean tools/mybot.spec
```

The spec produces `dist/mybot/` with:

- `pymybot.exe` — console CLI; no arguments opens the GUI and hides its console;
- `_internal/pymybot/assets/` — modules, robots, scripts, skills and prompts (Markdown plus manifest JSON);
- `robots/`, `scripts/`, `README.md`, `LICENSE` next to the executable;
- the GUI launches `pymybot.exe serve` with `CREATE_NO_WINDOW`, so no console
  flashes behind the window.

The `package` extra includes PySide6; PyInstaller's Qt hooks collect the
Widgets libraries and platform plugins. The `camera` extra keeps PyAV and its
FFmpeg libraries in the bundle; omit it only for a build that will never capture
images.

`pymybot/paths.py` resolves assets via `sys._MEIPASS` in frozen builds. Keep it
as the only place that knows about frozen paths; other modules call
`paths.frozen()` instead of reading `sys.frozen`.

Nuitka standalone builds also work: Nuitka does not set `sys.frozen` but injects
`__compiled__` into every compiled module, which `paths.frozen()` recognises.
Place the data next to the executable as `pymybot/assets/` (the same layout
`asset_dir()` probes when `_MEIPASS` is absent). An experimental Windows
command lives in
[`tools/nuitka_compile_test.ps1`](../tools/nuitka_compile_test.ps1); it is not
part of release CI and is not a supported release artifact.

### Prompt asset checks

`paths.asset_path('prompts')` is the common source/wheel/PyInstaller/Nuitka lookup.
The bundle must include every default Markdown layer and `manifest.json`:
`BuildPy`, `MANIFEST.in`, the PyInstaller suffix table and Nuitka data-directory
arguments all include them. Do not package a developer's `MYBOT_HOME` or backups.
`doctor` validates the bundled manifest and trusted safety hashes without creating
runtime files; first-use copies belong only in the selected `MYBOT_HOME/prompts`.

```sh
python -I tools/ci_smoke.py wheel
python -I tools/ci_smoke.py frozen --executable /absolute/path/to/pymybot
```

Wheel smoke uses fresh temporary dist/venv/work directories outside the checkout,
compares all asset hashes, and exercises first-use copying with isolated
`MYBOT_HOME`. Frozen smoke accepts an already-built executable (Windows:
`pymybot.exe`), runs from a temporary working directory and checks the same prompt
copy/manifest/hash contract. Use fresh explicit `--distpath`/`--workpath` directories
for PyInstaller experiments; never point build cleanup at an operator's prompt home.

## Dependency policy

- Runtime dependencies use compatible ranges (`>=current,<next-major`).
- Update ranges deliberately; run the full suite and the agent/wheel channels.
- Do not add a dependency for something the standard library already does well
  (JSON, HTTP, paths) unless it materially improves safety or portability.
- Dependabot opens weekly PRs; a human must review security-sensitive changes.

## Branches and releases

The default branch (`gui-mybot`; the owner may rename it to `main`) is the only
long-lived branch. Feature branches are short-lived.
Releases are tagged `vX.Y.Z`; the workflow builds and publishes artifacts from
the tag. See [`release.md`](release.md).
