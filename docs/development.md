# Development guide

## Toolchain

| Requirement | Version |
| --- | --- |
| Python | 3.11–3.14 |
| Lua runtime | provided by the `lupa` wheel; LuaJIT where available, otherwise standard Lua (FFI drivers require LuaJIT) |
| MCP SDK | 1.30–1.x, included in the `mcp` extra |
| Node/npm | not required |

## Setup

```sh
git clone https://github.com/gopsc/mybot.git
cd mybot
python -m venv .venv
.venv/bin/pip install -e ".[test]"
# MCP server:
.venv/bin/pip install -e ".[mcp,test]"
```

Use the platform paths under Windows (`.venv\Scripts\pip`).

## Everyday commands

```sh
python -m pytest -q                       # full suite, no hardware
python -m pymybot check --robot assets/robots/relay-test.sql --input assets/scripts/relay-test.mt
python -m pymybot run --robot assets/robots/relay-test.sql --input assets/scripts/relay-test.mt --timeout 10
python -I tools/ci_smoke.py wheel       # sdist -> wheel -> clean venv
python -I tools/check_docs_skill_sync.py  # docs/skill links resolve, references declare a Source
python -I tools/check_release_metadata.py # pyproject/__init__/CITATION/CHANGELOG agree
```

`pymybot` with no subcommand is a usage error (exit code 2); use `pymybot --help`
for help. Each subcommand writes one JSON object to stdout.

## Code layout

```text
SKILL.md                        skill manifest and topic index; links every reference
assets/                         default modules, robots and MT scripts
references/                     controller authority documents
scripts/                        self-contained launcher and requirements
pymybot/                        controller and MCP Runtime
tests/                          pytest suite and virtual-device fixtures
docs/                           operator and maintainer documentation
tools/                          CI, documentation checks and release helpers
```

## Style and quality

- Python 3.11+, no mandatory third-party formatter. Keep imports grouped,
  functions focused and docstrings short and factual.
- Comments should explain *why*, not restate *what*.
- No duplicate JSON/path/process helpers: reuse `security.py`, `process.py` and
  `paths.py`.
- Do not add a broad `except Exception: pass` unless it is cleanup that cannot
  affect the result; log or surface the failure instead.
- Public operator-visible text is Chinese; code identifiers and commit messages
  are English.

A narrow lint gate runs in CI (`ruff` with syntax/undefined-name rules). Full
`ruff` output is advisory because the repository predates a formatter baseline;
do not reformat unrelated files in a behaviour PR.

Behaviour changes belong in the authority that owns the topic first. Controller
architecture, CLI, MCP, security and testing are authored under
[`references/`](../references/); operator topics (development, release,
versioning, FAQ) stay in `docs/`. The skill manifest [`SKILL.md`](../SKILL.md)
maps every topic to the document that owns it instead of restating it. The same
lint job runs
[`tools/check_docs_skill_sync.py`](../tools/check_docs_skill_sync.py),
which fails on dead skill links, missing repository paths, a reference without a
`Source:` line and references that [`SKILL.md`](../SKILL.md) does not register.

## Adding a driver

1. Add `assets/modules/<Name>.py` implementing `Driver(context)`, or
   `assets/modules/<Name>.lua` using `assets/modules/lib/drv_common.lua` and
   `assets/modules/lib/bus_contract.lua`.
2. Add `tests/fixtures/virt/<name>_virt.sql` and
   `tests/fixtures/virt/<name>_virt.mt`; register the virtual device model in
   `assets/modules/lib/virtbus/regmap.lua` when applicable.
3. Run `python -m pytest tests/test_migrated_drivers.py -q` and the fixture
   directly. Use `tests/test_virtual_drivers.py` for synthetic bus/protocol models.
4. Document the device, address range, units and known limitations in the driver
   header or the relevant `references/` document.
5. Never make a virtual result look like a real measurement; use clearly named
   files (`*_virt`).

## Frozen builds

Frozen executables are not a supported artifact. Releases publish an sdist and a
wheel; install the wheel into a virtual environment, or use an editable checkout
for development. The wheel packages the Runtime from `pymybot/` and copies the
repository-root `assets/` tree into `pymybot/assets/` at build time, so there is
no skill-directory copy step. `pymybot doctor` is the quickest way to check a
fresh install.

## Dependency policy

- Runtime dependencies use compatible ranges (`>=current,<next-major`).
- Update ranges deliberately; run the full suite and the wheel channel.
- Do not add a dependency for something the standard library already does well
  (JSON, HTTP, paths) unless it materially improves safety or portability.
- Dependabot opens weekly PRs; a human must review security-sensitive changes.

## Branches and releases

The default branch (`gui-mybot`; the owner may rename it to `main`) is the only
long-lived branch. Feature branches are short-lived.
Releases are tagged `vX.Y.Z`; the workflow builds and publishes artifacts from
the tag. See [`release.md`](release.md).
