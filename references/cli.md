# CLI reference

Source: This is the authoritative controller CLI document; the implementation lives in `scripts/pymybot/cli.py`.

The CLI is the automation-friendly control surface. Every controller command
prints exactly one JSON object on stdout per invocation; diagnostics go to
stderr. `--version` prints a plain version line, `--help` prints usage, and
`mcp` speaks JSON-RPC instead (see below).

```sh
python -m pymybot --help
python -m pymybot --version
python -m pymybot doctor
```

The Skill also ships a self-contained launcher that runs the same parser and
JSON contract: `python scripts/hardware_controller.py <command> [options]`.

## Entry points

| Command | Purpose | Activates hardware? |
| --- | --- | --- |
| `pymybot --version` (`-V`) | Print the version and exit | No |
| `pymybot check --robot FILE [--input MT] [--module-path DIR]...` | Static validation of SQL, modules, references and MT/Include syntax | No |
| `pymybot discover [--buses i2c,spi,uart,ftdi] [--probe]` | Read-only host device enumeration with structure-SQL hints | No |
| `pymybot hardware --robot FILE` | List declared hardware and metadata | No |
| `pymybot scripts [--scripts-dir DIR]` | List `.mt` action scripts | No |
| `pymybot query --robot FILE --sql "..."` | `SHOW TABLES;` or `SELECT * FROM table [WHERE ...];` | No |
| `pymybot run --robot FILE --input MT [--timeout S] [--allow-hardware] [--var NAME=VALUE] [--var-env NAME=ENVVAR] [--module-path DIR]...` | Activate, run one action, deactivate | Yes |
| `pymybot sample --robot FILE --name NAME [--count N] [--interval-ms MS] [--timeout S] [--allow-hardware]` | Read a named variable | Yes |
| `pymybot apply-sql --robot FILE --sql "..." [--allow-hardware]` | Apply restricted SQL to a temporarily active robot | Yes |
| `pymybot mcp --robot FILE [--module-path DIR]... [--scripts-dir DIR] [--allow-execution] [--allow-hardware] [--timeout S] [--var NAME=VALUE] [--var-env NAME=ENVVAR]` | Standard MCP stdio server, read-only by default | Only when an execution tool runs |
| `pymybot doctor` | Environment/dependency/asset diagnostics | No |
| `pymybot new --dir DIR NAME [--force]` | Generate a runnable `robots/`, `scripts/` and `modules/` skeleton | No |
| `pymybot assets list/read/write/delete --kind robots\|modules\|scripts` | List, read, create, overwrite or delete bundled asset files | No |

`check`, `discover`, `hardware`, `scripts`, `query`, `doctor`, `new` and `assets`
never activate hardware; `run`, `sample` and `apply-sql` do, and activation
itself may write to devices. See [security.md](security.md) for the trust model.

## Asset files

`pymybot assets` manages the bundled `robots` (`.sql`), `modules` (`.py`/`.lua`) and
`scripts` (`.mt`) asset files in place, so the Skill can create, retrieve, overwrite and
delete robot scripts without leaving the controller:

```sh
pymybot assets list [--kind robots|modules|scripts|all]
pymybot assets read   --kind robots  --path relay-test.sql
pymybot assets write  --kind scripts --path mybot-arm.mt --content "@Action ..."   # create
pymybot assets write  --kind scripts --path mybot-arm.mt --content-file arm.mt --force  # overwrite
pymybot assets delete --kind scripts --path mybot-arm.mt --yes
```

`--path` is relative to the kind's asset root; traversal, absolute paths, symlink escape
and wrong suffixes are refused. `write` creates and refuses an existing file unless
`--force`; `delete` requires `--yes`. Content is bounded UTF-8 (`--content` inline or
`--content-file` for larger bodies). The command never activates hardware.

`--robot` and `--input` resolve against these roots: an absolute path or a path that
already exists relative to CWD is used as-is, otherwise a bare or relative name falls
back to `assets/robots` (`--robot`) or `assets/scripts` (`--input`). This keeps the
Skill self-contained without breaking absolute or CWD-relative callers.

## Shared options

Each subcommand accepts the subset shown in the reference above; these flags recur
across commands.

| Option | Meaning |
| --- | --- |
| `--module-path DIR` | Trusted Python/Lua module root; repeatable. Roots are searched in order, Python before Lua within each root. |
| `--timeout SECONDS` | Cooperative wall-clock budget for an activating command or an MCP request; positive and at most 3600. `run` and `mcp` default to 180. |
| `--var NAME=VALUE` | Override a structure `Alias`/`Vars` row before activation, and bind a value that action scripts see by name during the run; repeatable with distinct names. |
| `--var-env NAME=ENVVAR` | Same, but read the value from an environment variable at run time; repeatable, values stay out of argv. |
| `--allow-hardware` | Open physical devices, non-loopback HTTP/TCP or the Shell driver. |

`BOT4CJ_MODULE_PATH` is the environment-variable equivalent of repeated
`--module-path` (use the platform path separator).

### Structure variable overrides

`--var`/`--var-env` apply to every command that loads a structure (`check`,
`hardware`, `query`, `run`, `sample`, `apply-sql` and `mcp`). A binding whose
name matches an `Alias` or `Vars` row replaces that row's value *before*
`build()`, so drivers that log in during activation receive the injected
value. Other rows are never overridden.

Reference the rows from ordinary structure cells with `$name` (Alias) or
`$(name)` (Vars, numeric):

```sql
CREATE TABLE Alias (name String, alias String);
INSERT INTO Alias (name, alias) VALUES ('tcp0_host', 'COVER_ME');
CREATE TABLE Vars (name String, value String);
INSERT INTO Vars (name, value) VALUES ('tcp0_port', -1);
-- ... 设备表用 $tcp0_host / $(tcp0_port) 引用 ...
CREATE TABLE TCP (name String, host String, port Number);
INSERT INTO TCP (name, host, port) VALUES ('tcp0', '$tcp0_host', '$(tcp0_port)');
```

```sh
export RELAY_HOST=192.0.2.10
pymybot run --robot assets/robots/famer.sql --input assets/scripts/famer.mt \
  --timeout 30 --allow-hardware \
  --var-env tcp0_host=RELAY_HOST --var tcp0_port=8080
```

The declared defaults stay in the tables, so `pymybot hardware`/`query` keep
showing them rather than injected values. In `mcp`, launch-time bindings are
merged with per-call `run_action_script` `vars`, and the operator's launch-time
bindings win.

## Examples

```sh
# Create a runnable pure-software skeleton
python -m pymybot new --dir . mybot-arm

# Static validation, no hardware
python -m pymybot check \
  --robot assets/robots/relay-test.sql \
  --input assets/scripts/relay-test.mt

# Pure-software end-to-end run (Timer + Relay)
python -m pymybot run \
  --robot assets/robots/relay-test.sql \
  --input assets/scripts/relay-test.mt \
  --timeout 10

# Query the structure without activating it
python -m pymybot query --robot assets/robots/relay-test.sql --sql "SHOW TABLES;"

# Expose one robot to an MCP client (read-only by default)
python -m pymybot mcp \
  --robot assets/robots/relay-test.sql \
  --scripts-dir assets/scripts
```

Every SQL statement must end with `;`, including a single statement. A missing
semicolon is `SQL: unexpected end of script`. The structure SQL and MT action
grammars are documented in
[`structure-sql.md`](structure-sql.md) and
[`action-mt.md`](action-mt.md).

## JSON contract

Success:

```json
{"ok":true,"command":"run","outputs":[{"slept":1,"result":"OK"}]}
```

Failure:

```json
{"ok":false,"error":{"type":"ScriptError","message":"..."}}
```

Exit codes: `0` success, `1` runtime error, `2` usage error, `130` interrupted.
A Ctrl+C/SIGTERM during an activating command stops the action and attempts the
same `safe()` hooks as `abort` before releasing hardware; ordinary action errors
keep the historical destroy-only cleanup. A Python driver's `print`, Lua output
and library output are redirected to stderr, but trusted Python code must still
keep direct/imported-library output off stdout.

`mcp` is the exception to the CLI contract: stdout carries MCP JSON-RPC and no
CLI JSON line is written; diagnostics and startup failures go to stderr.

## `doctor`

`doctor` checks the interpreter, optional dependencies and bundled assets
without touching hardware. It reports:

- `version`, `python` and `platform`, plus `python_supported` (Python ≥ 3.11) and
  `healthy`;
- `assets` for `modules`, `robots` and `scripts` only, each with its resolved
  path, whether the root exists and a file count;
- `module_paths` and `checks`.

`checks` lists the required dependencies (`lupa`/Lua backend, `sqlparse`,
`pyserial`, `pyftdi`, `pillow`, and Linux `smbus2`), the optional `mcp` SDK, and
optional platform/Lua extras (`lua.ffi`, `spidev`). `healthy` is false when
Python is too old, a required check is not `ok`, or an asset root is missing or
empty. A missing `mcp` SDK only warns; `pymybot mcp` then fails with an
installation hint.

## `discover` command

```sh
pymybot discover                       # every bus, passive enumeration
pymybot discover --buses uart,ftdi     # subset of i2c,spi,uart,ftdi
pymybot discover --probe               # also open/close each real UART port
```

Read-only host enumeration shared with the hardware-controller skill:
I2C/SPI/UART come from the bundled `Dev_enum` driver, FTDI USB adapters are
listed by pyftdi and mapped to HAL-ready `ftdi://` URLs, and `hints` maps every
found device to the `CREATE TABLE UART/I2C/SPI` declaration that uses it.
Nothing is opened unless `--probe` is set; probing never writes, but an open
can pulse DTR/RTS, so boards that reset on those lines should not be probed.

## `mcp` server

`pymybot mcp --robot SQL` speaks standard MCP over stdio and reserves stdout for
JSON-RPC; diagnostics stay on stderr. It is read-only unless `--allow-execution`
is passed, and physical hardware still requires `--allow-hardware`, which itself
requires `--allow-execution`. Tools, resources, permissions and client
configuration are documented in [mcp.md](mcp.md).
