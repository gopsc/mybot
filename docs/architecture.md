# Architecture

pymybot separates *what the robot is* from *how a part is driven* and *what
should happen over time*. The same three-layer model is implemented by every
edition in [`../implementations/`](../implementations).

## Three layers

```mermaid
flowchart LR
    SQL["Structure SQL<br/>robots/*.sql"] --> ROBOT["Robot<br/>variables + buses"]
    LUA["Lua driver<br/>modules/*.lua"] --> ROBOT
    MT["Action script<br/>scripts/*.mt"] --> RUNNER["Action runner"]
    ROBOT --> RUNNER
    RUNNER --> HAL["HAL / buses"]
    HAL --> DEV["I2C · SPI · UART · HTTP · Camera · Shell"]
```

| Layer | File | Responsibility | Trust level |
| --- | --- | --- | --- |
| Structure | `robots/*.sql` | Declares variables, buses, addresses and controller links | Operator-authored |
| Driver | `modules/*.lua` | Implements build/call/destroy/read for one device family | Reviewed code |
| Action | `scripts/*.mt` | Matrices of device parameters, captures, loops and control flow | Operator-authored |

The robot is assembled from the SQL rows; each ordinary table maps to a
`modules/<table>.lua` driver. A row is a variable instance. `$name` references a
previously declared bus/controller, and `-` inherits the previous row's value.

## Runtime flow

```mermaid
sequenceDiagram
    participant CLI as CLI / GUI / serve
    participant Robot
    participant Registry
    participant Lua as Lua runtime
    participant HAL
    participant Device

    CLI->>Robot: load structure SQL
    Robot->>Robot: validate tables, references, controller graph
    CLI->>Robot: active()
    Robot->>Lua: create state per variable
    Lua->>HAL: open bus / device (build)
    HAL->>Device: configure
    CLI->>Robot: run MT action
    Robot->>Registry: resolve variables and expressions
    Robot->>Lua: call(device, params)
    Lua->>HAL: transfer
    HAL->>Device: I2C/SPI/UART/HTTP/Camera
    Device-->>Lua: result
    Lua-->>Robot: result table
    Robot-->>CLI: outputs (one JSON envelope)
    CLI->>Robot: deactivate()
    Robot->>Lua: destroy
```

Key invariants:

- The whole command emits exactly **one JSON line** on stdout. Diagnostics go
  to stderr; Lua `print` is redirected.
- `check`, `hardware`, `scripts` and `query` never activate drivers.
- `run`, `sample` and `apply-sql` activate the robot; activation itself may
  write to hardware.
- Driver calls are serialised per robot; daemon sampling uses dedicated worker
  threads with independent Lua states.
- An exception after an action starts is latched as “result unknown”; the
  runtime never claims a rollback.

## Python package map

| Module | Responsibility |
| --- | --- |
| `pymybot/cli.py` | Argument parsing, JSON contract, command dispatch |
| `pymybot/robot.py` | Structure loading, validation, activation, HMI |
| `pymybot/sql.py` | Strict in-memory SQL grammar and table operations |
| `pymybot/matrix.py` | MT action matrix parser and validator |
| `pymybot/actions.py` | Action runner: aliases, captures, control flow |
| `pymybot/expr.py` | Expression parser/evaluator and numeric rendering |
| `pymybot/runtime.py` | Lupa/LuaJIT bootstrap, sandbox hygiene, Python↔Lua conversion |
| `pymybot/hal.py` | I2C/SPI/UART/HTTP/Camera/Shell host operations |
| `pymybot/daemon.py` | Background sampling workers and snapshots |
| `pymybot/agent.py` | PydanticAI agent, model configuration, tool loop |
| `pymybot/agent_executor.py` | Approval-gated tool implementations |
| `pymybot/agent_workspace.py` | Bounded, link-safe workspace file tools and shell |
| `pymybot/serve.py` | Long-lived stdio JSON-RPC 2.0 backend |
| `pymybot/gui/` | Tkinter front-end: protocol client, settings, approvals |
| `pymybot/security.py` | Bounded reads and strict JSON output |
| `pymybot/paths.py` | Source/frozen asset resolution |

## Entry points

```mermaid
flowchart TB
    U[User] --> G[GUI]
    U --> C[CLI]
    U --> A[Agent REPL]
    U --> S[serve JSON-RPC]
    G -->|spawn + stdio| S
    C --> R[Robot]
    A --> E[Agent executor]
    S --> E
    E --> R
    R --> L[Lua drivers]
    L --> H[HAL]
```

- **GUI** never executes robot logic itself; it drives one `serve` child process
  and marshals all callbacks onto the Tk thread.
- **Agent modes** execute tools through `AgentExecutor`, which runs hardware
  work on a dedicated owner thread and asks for approval through a callback.
- **CLI controller mode** skips the model entirely and is suitable for CI.

## Asset and path resolution

Packaged assets live in `pymybot/assets/{modules,robots,scripts,skills}`. In a
source checkout the code falls back to the repository directories. Frozen
builds use `pymybot/paths.py` and `sys._MEIPASS`; never rely on the current
working directory. See [`development.md`](development.md) for the packaging
flow.

## Multi-edition boundaries

The Cangjie and C++17 + Rust editions share the DSL and operator model but have
independent HAL ABIs, build systems and binaries. Do not copy a driver between
editions without checking its HAL calls. See
[`../implementations/README.md`](../implementations/README.md).

## Further reading

- [CLI reference](cli.md)
- [GUI guide](gui.md)
- [Security model](security.md)
- [Testing](testing.md)
- [Scripting reference](../skills/pymybot-scripting/SKILL.md)
