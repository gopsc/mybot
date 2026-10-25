# Testing

## Test layers

| Layer | Location | What it proves |
| --- | --- | --- |
| Unit | `tests/test_{sql,dsl,expr,matrix,...}.py` | Parser/typing/error semantics |
| HAL | `tests/test_hal.py` | Bus framing, URL/gating, camera and shell boundaries |
| Virtual devices | `tests/fixtures/virt/*.sql` + `*.mt` | Real driver build/call/destroy paths without hardware |
| Robot integration | `tests/test_robot.py`, `tests/test_daemon.py` | Activation, inheritance, controllers, sampling |
| Agent | `tests/test_agent*.py` | Offline model loop, approval, budgets, cleanup |
| Serve/GUI | `tests/test_serve.py`, `tests/test_gui.py` | JSON-RPC lifecycle, restart races, dialogs |
| Packaging | `scripts/ci_smoke.py` | sdist → wheel → isolated venv → assets/CLI |

The suite must run without physical hardware. Tests that need a display skip
cleanly on headless CI; they are not allowed to be silently skipped when the
agent dependencies are missing in the agent channel—`ci_smoke.py agent` fails
instead.

## General commands

```sh
python -m pytest -q
python -m pytest tests/test_hal.py -q
python -m pytest -q -k camera
python -m pytest --durations=10 -q
```

## CI channels

| Channel | OS / Python | Purpose |
| --- | --- | --- |
| base | Ubuntu 3.11, 3.12, 3.13, 3.14 | No `pydantic_ai` installed; controller regression |
| windows | Windows / 3.13 | faulthandler, UTF-8 and Tk behaviour |
| agent | Ubuntu 3.11; Windows 3.13 | Offline model/agent integration |
| wheel | Ubuntu 3.11; Windows 3.13 | Build from sdist, install into clean venv |
| quickstart | Ubuntu 3.14 | README commands actually run |
| lint | Ubuntu | syntax/undefined names; no style churn |
| cpp-rust | Ubuntu | C++17 `-Werror` build + 808 tests; Rust `cargo test/clippy/fmt` |
| docker | Ubuntu | headless image builds and `doctor` runs inside it |

The Cangjie edition is not built in the top-level workflow: the Cangjie
toolchain is not available on standard GitHub runners. Build it locally with
`cjpm` as described in `implementations/cangjie/README.md`.

## Virtual device fixtures

Each fixture declares `proto='virt'` in the SQL structure and drives a
registered register map. A fixture should be small, deterministic and assert
both a successful read and at least one failure mode (NACK, short read or
timeout) when the driver supports it.

## Windows notes

- LuaJIT raises Lua errors as SEH `0xE24C4A02`; the CLI disables
  `faulthandler`. See [`windows-faulthandler-luajit.md`](windows-faulthandler-luajit.md).
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
