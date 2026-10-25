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

## Where are logs and session history?

Diagnostics go to stderr and the GUI “日志” tab. The reference edition does not
persist conversation transcripts. The withdrawn 2026-10-25 GUI binary wrote
`~/.mybot/sessions`; that behaviour is not part of the source release.

## Why is the Windows build unsigned?

Code signing requires a certificate owned by the maintainer. Verify the
published SHA-256 checksum and build from source if your policy requires it.
