# FAQ

## Why does `pymybot` open a window instead of the terminal agent?

The GUI is the default entry point. Use `pymybot --no-gui ...` for the terminal
agent or a controller command. `pymybot check|run|...` subcommands are always
terminal.

## The GUI says “智能体不可用”

The selected interpreter does not have the agent extras. Install them into that
interpreter:

```sh
python -m pip install -e ".[agent,test]"
```

Then choose the same interpreter in **设置**.

## `pymybot mcp` says MCP dependencies are unavailable

The MCP SDK is optional. Install it into the interpreter that starts the server:

```sh
python -m pip install -e ".[mcp]"
```

For the agent’s external MCP client, install `.[agent,mcp]`. Restart the client
after upgrading so it launches the new process.

## An external MCP tool was denied or reported `unknown`

Denied means the operator (or the missing approval channel) rejected the call
before it ran; do not retry or work around it. `unknown` means the call may
already have had side effects; inspect the host and the MCP server before
restarting. External MCP servers run with host-user permissions and are not a
sandbox. See [mcp.md](mcp.md).

## Can I use pymybot without any API key?

Yes. `check`, `hardware`, `scripts`, `query`, `run`, `sample`, `apply-sql`, the
GUI’s hardware view and the virtual-bus tests need no model. Only the agent
needs a provider key.

## Why can’t the GUI change the system prompt?

The system prompt is operator-owned. A model or remote app must not be able to
rewrite its own safety instructions. Put custom instructions in the operator
configuration/skill files and restart the session; do not expose a
“model sets the prompt” tool.

## Hardware is not detected

- UART: check the port name (`COMn`, `/dev/tty*`) and permissions.
- I2C/SPI: pymybot uses pyftdi/MPSSE; install the FTDI driver and use
  `ftdi://ftdi:232h/1`.
- Linux `/dev/i2c-*` / `/dev/spidev*`: install `.[linux]` and add the user to
  the `i2c`/`spi` groups.
- Camera: install `.[camera]`; on Windows the device index (`0`) must be
  correct and some cameras need administrator access.
- Remember that physical access requires `--allow-hardware` (CLI) or the GUI
  “允许硬件” toggle.

## Why did a virtual run write to a device?

`proto='virt'` chooses a virtual model only when the driver declares one. A
real structure without `proto='virt'` activates the physical device. Use the
provided `*_virt.sql` examples for hardware-free work.

## A long conversation hits the model context limit

pymybot bounds history to six complete turns and a byte budget,
and returns a structured JSON error instead of crashing when the provider
rejects a request. Use `--max-history-bytes` (64 KiB–64 MiB, default 4 MiB),
start a new conversation, or lower `--max-requests` / `--max-tool-calls` for a
smaller working set. The runtime does not guess a model’s context window; the
byte budget is an explicit, provider-independent guard.

## Where are logs and session history?

Diagnostics go to stderr and the GUI “日志” tab. Agent conversations are also
transcribed to `~/.mybot/sessions/` by default (tool arguments, bounded results
and images). API keys in environment variables are not read into the
transcript, but tool output may contain other sensitive data. Disable with
`--no-session-log`, `MYBOT_SESSION_LOG=0`, or the GUI settings toggle; list and
prune old transcripts with `pymybot sessions` and
`pymybot sessions --prune --keep 20 --yes`. Transcripts are not resumable and
the GUI has no history browser; see
[`cli.md`](cli.md#session-transcripts).

## Why is the Windows build unsigned?

Code signing requires a certificate owned by the maintainer. Verify the
published SHA-256 checksum and build from source if your policy requires it.
