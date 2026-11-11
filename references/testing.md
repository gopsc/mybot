# Testing

Source: This is the authoritative controller testing document; fixtures and tests live in the repository `tests/`.

## Test layers

| Layer | Location | What it proves |
| --- | --- | --- |
| Unit | `tests/test_{sql,dsl}.py` | Parser/typing/error semantics |
| HAL | `tests/test_hal.py` | Bus framing, URL/gating and shell boundaries |
| Virtual devices | `tests/fixtures/virt/*.sql` + `*.mt` | Real driver build/call/destroy paths without hardware |
| Robot integration | `tests/test_robot.py`, `tests/test_daemon.py` | Activation, inheritance, controllers, sampling |
| Native drivers | `tests/test_native.py` | Compile-only validation, per-row modules and the Driver context |
| MCP / executor | `tests/test_mcp_server.py` | A real stdio MCP client, permissions, script resources and receipts |
| CLI | `tests/test_cli.py` | Command dispatch, JSON envelope and exit codes |
| Packaging | `tools/ci_smoke.py` | sdist → wheel → isolated venv → assets/CLI |
| Docs/skill sync | `tests/test_docs_skill_sync.py`, `tools/check_docs_skill_sync.py` | Skill links/paths resolve, references declare and register their authority |

The suite must run without physical hardware: virtual fixtures, `proto='virt'`
and `loop://` transports cover device paths. The only optional runtime dependency
the suite needs is the MCP SDK; `tests/test_mcp_server.py` skips itself when the
`mcp` extra is absent, and the CI `test`/`windows` jobs install `.[mcp,test]` so
it runs there.

## General commands

```sh
python -m pytest -q
python -m pytest tests/test_hal.py -q
python -m pytest --durations=10 -q
```

## CI channels

| Channel | OS / Python | Purpose |
| --- | --- | --- |
| base | Ubuntu / 3.12 | Base install only; MCP-dependent tests skip themselves |
| test | Ubuntu / 3.12 | Full regression with `.[mcp,test]` |
| windows | Windows / 3.13 | `.[mcp,test]`, faulthandler, UTF-8 and Windows behaviour |
| macos | macOS / 3.13 | Base install, `doctor`, and the Python-only `time` `check`/`run` smoke |
| wheel | Ubuntu / 3.12 | Build from sdist, install into a clean venv |
| quickstart | Ubuntu / 3.14 | README commands actually run |
| lint | Ubuntu / 3.12 | Ruff, docs/skill sync and release metadata |
| docker | Ubuntu | Headless image build and `doctor` runs inside it |

## Virtual device fixtures

Each fixture declares `proto='virt'` in the SQL structure and drives a
registered register map. A fixture should be small, deterministic and assert
both a successful read and at least one failure mode (NACK, short read or
timeout) when the driver supports it.

## Windows notes

- LuaJIT raises Lua errors as SEH `0xE24C4A02`; the CLI disables
  `faulthandler`. See [`windows-faulthandler.md`](../docs/history/windows-faulthandler.md).
- stdout/stderr are forced to UTF-8. Tests assert JSON survives non-ASCII output
  on a GBK console.
- Symlink creation may be unavailable; `tests/conftest.py` converts that into a
  skip instead of a failure.

## Adding a regression test

1. Reproduce the failure with the smallest input.
2. Assert the exact JSON/error shape, not just “raises”.
3. Add a comment explaining the real-world failure mode.
4. Run the full suite; if a test now passes only because a mock was weakened,
   fix the mock.
