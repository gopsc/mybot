# FAQ

## Why did `pymybot` fail with “the following arguments are required: command”?

`pymybot` has no default action. Run a subcommand such as `pymybot check ...` or
`pymybot run ...`; `pymybot --help` lists them. A usage error exits with code 2
and still writes one JSON object to stdout.

## `pymybot mcp` says MCP dependencies are unavailable

The MCP SDK is optional. Install it into the interpreter that starts the server:

```sh
python -m pip install -e ".[mcp]"
```

Restart the client after upgrading so it launches the new process.

## An MCP tool returned `unknown`

`unknown` means the call may already have had side effects; inspect the robot
before doing anything else, and do not retry automatically. A `not_executed`
result means the call did not run: `run_action_script` and `read_variables` need
`--allow-execution`, and physical hardware additionally needs `--allow-hardware`.
See [the MCP guide](../skills/hardware-controller/references/mcp.md).

## Can I use pymybot without any API key?

Yes. Every command, including `run`, `sample`, `apply-sql` and `pymybot mcp`, works
without a model or a key. pymybot is a hardware controller only.

## Hardware is not detected

- UART: check the port name (`COMn`, `/dev/tty*`) and permissions.
- I2C/SPI: pymybot uses pyftdi/MPSSE; install the FTDI driver and use
  `ftdi://ftdi:232h/1`.
- Linux `/dev/i2c-*`: `smbus2` comes with the base install; make sure the bus
  is enabled (`/dev/i2c-*` exists) and add the user to the `i2c` group.
- Linux `/dev/spidev*`: install `.[linux]` for `spidev` (it usually builds from
  source, so you may need gcc and kernel headers) and add the user to the `spi`
  group.
- Direct commands that activate hardware (`run`, `sample`, `apply-sql`) require
  `--allow-hardware`; `check`, `hardware`, `scripts` and `query` never activate a
  driver.

## `doctor` warns about LuaJIT FFI

The `lupa` wheel sometimes ships standard Lua instead of LuaJIT, for example on
macOS arm64. Python drivers still work, but Lua drivers that rely on the LuaJIT
FFI are unavailable. Install a `lupa` build that includes LuaJIT if you need
those drivers; `doctor` reports `LuaJIT FFI` when LuaJIT is unavailable.

## A driver is not loaded

Ordinary table names resolve to `modules/<Table>.py` or `.lua`, searched per root
with Python before Lua; earlier roots win. `Alias`, `Vars` and `Daemon` do not
resolve to a module. Use `--module-path DIR` (repeatable) to add roots, and
`pymybot check` to see the resolution errors before activating anything. The
driver contract is in
[the driver reference](../skills/hardware-controller/references/driver-lua.md).

## Why did a virtual run write to a device?

`proto='virt'` chooses a virtual model only when the driver declares one. A
real structure without `proto='virt'` activates the physical device. Use the
provided `*_virt.sql` examples for hardware-free work.

## Where do logs go?

Diagnostics go to stderr; stdout carries exactly one JSON object per command.
There is no separate log file to inspect, so redirect stderr if you need a
record. See [the CLI reference](../skills/hardware-controller/references/cli.md)
for the JSON envelope and exit codes.

## Should I document a change in `docs/` or in `skills/`?

It depends on who owns the topic. Controller architecture, CLI, MCP, security and
testing are authored under `skills/hardware-controller/references/`; the
same-named pages in `docs/` are redirect stubs. Operator-facing topics
(development, release, versioning, FAQ) are authored in `docs/`.

Each `references/*.md` declares its authority in a `Source:` line and is
registered in [`../skills/README.md`](../skills/README.md).
`tools/check_docs_skill_sync.py` runs in the CI lint job and fails on dead
links, missing repository paths, a missing `Source:` line or an unregistered
reference. A reference should keep the hard rules it needs — exact error strings,
limits, worked examples — and link to the authority that owns the behaviour
instead of restating it.

## How do I verify a release?

Releases publish SHA-256 checksums. Compare them against the downloaded
artifacts, and build from the tagged source if your policy requires it.
