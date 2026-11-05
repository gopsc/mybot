---
name: hardware-controller
description: 通过自包含的 pymybot Runtime 控制与编程机器人：Structure SQL 声明硬件，Python/Lua driver 实现设备，MT action 描述时序。用于硬件检查、动作执行、传感器采样、静态校验、MCP 集成、驱动开发与控制器排障；当用户提到机器人控制、硬件、I2C/SPI/UART 设备、动作脚本或 hardware-controller 时使用。
---

# Hardware Controller

使用 `scripts/` 内的 Python Runtime 控制机器人。Structure SQL 声明硬件，Python/Lua driver 实现设备行为，MT action 描述时序动作。默认 robots、scripts 和 modules 位于 `assets/`。

## 1. 入口

三种入口共享同一套 Runtime，不要复制或另建控制器实现：

```sh
# 仓库根目录：自包含入口（本技能推荐）
python skills/hardware-controller/scripts/hardware_controller.py <command> [options]

# 兼容入口：同一 Runtime
python -m pymybot <command> [options]
```

Agent 会话中不再暴露细粒度硬件工具，统一调用本技能的一个通用工具：

```text
hardware_controller_run(command="check", args=[
  "--robot", "assets/robots/relay-test.sql",
  "--input", "assets/scripts/relay-test.mt"
])
```

`command` 是下文的 CLI 子命令，`args` 是该子命令的原始参数，一个列表元素对应一个 token。工具的工作目录是技能目录，因此路径写 `assets/...` 即可；不要传 entrypoint、绝对宿主路径或自行拼接命令。一次调用只执行一个子命令。

Agent 通用工具只开放 `doctor`、`discover`、`scripts`、`hardware`、`query`、`check`、`run`、`sample`，以及只读的 `assets list` / `assets read`。`apply-sql`、`assets write/delete`、`new`、`prompts`、`roles`、`sessions`、`mcp`、`serve`、`agent` 属于操作员管理面或长驻入口，只能由操作员直接使用 CLI，不能从 Agent 工具调用。

MCP 入口见第 5 节。

## 2. 子命令速查

| 子命令 | 在什么情况下使用 | 激活硬件 |
| --- | --- | --- |
| `doctor` | 第一次使用；解释器/依赖/资产/prompt 清单异常；任何命令报环境类错误前 | 否 |
| `discover` | 写结构 SQL 前枚举宿主串口/FTDI/I2C/SPI 设备，`hints` 直接给出可用的建表 SQL（只读，不加 `--probe`） | 否 |
| `scripts` | 不知道有哪些 `.mt` 动作脚本，或确认脚本目录是否被正确加载 | 否 |
| `hardware` | 写动作前确认变量名、总线、地址、controller/trigger 接线 | 否 |
| `query` | 只想查看结构内容（`SHOW TABLES`、`SELECT`），不需要动作 | 否 |
| `check` | 写完或改完 SQL、MT、driver 后，`run` 之前的第一道关卡 | 否 |
| `run` | `check` 通过，且已用 `proto='virt'` 或 fixtures 验证后，执行一个动作 | 是 |
| `sample` | 读取某个命名变量的当前值或 Daemon 快照 | 是 |
| `apply-sql` | 在临时会话中改变量、建表或删表做实验（仅操作员 CLI） | 是 |
| `assets list/read` | 查看或读取内置 robots/modules/scripts 资产（Agent 也可用） | 否 |
| `assets write/delete` | 新建、覆盖或删除内置资产脚本（仅操作员 CLI） | 否 |
| `new` | 为用户自己的项目生成 `robots/`、`scripts/`、`modules/` 骨架（仅操作员 CLI） | 否 |
| `mcp` | 把控制器暴露给 MCP 客户端或其他 Agent（仅操作员 CLI） | 视开关 |
| `serve` | 给 GUI/IDE 提供长驻 stdio JSON-RPC 后端（仅操作员 CLI） | 视请求 |
| `agent` | 使用内置 LangGraph Agent（需要 `--role`，仅操作员 CLI） | 视审批 |

所有命令在 stdout 输出**恰好一行 JSON**；诊断写 stderr。退出码非零表示命令失败，但动作已派发后的异常代表“结果未知”，不要自动重试，也不要声称已回滚。

## 3. 命令详解

### 3.1 `doctor`

检查解释器、依赖、Lua 运行时、默认资产目录和 prompt manifest。没有硬件也可以运行。

```sh
python skills/hardware-controller/scripts/hardware_controller.py doctor
```

报告缺依赖或资产时先修环境，不要继续 `run`。

### 3.2 `scripts` / `hardware` / `query`

三者都只读，不激活驱动：

```sh
# 列出动作脚本（默认 assets/scripts，可用 --scripts-dir 指定）
... scripts
... scripts --scripts-dir assets/scripts

# 列出结构 SQL 声明的硬件及元数据
... hardware --robot assets/robots/relay-test.sql

# 只读查询：SHOW TABLES 或 SELECT
... query --robot assets/robots/relay-test.sql --sql "SHOW TABLES;"
... query --robot assets/robots/relay-test.sql --sql "SELECT * FROM Relay;"
```

- 写 MT 前用 `hardware` 确认变量名和列名，避免引用不存在的设备。
- `query` 只接受只读语句；需要写入时用 `apply-sql`。

### 3.3 `check`

静态校验 SQL 结构、driver 存在性、`$`/controller/trigger 引用和 MT 语法。**不激活硬件，也不执行 Python 模块、构造器或生命周期方法。**

```sh
... check --robot assets/robots/relay-test.sql --input assets/scripts/relay-test.mt
```

每次改完 SQL、MT 或 driver 都先跑 `check`。它通过不代表驱动运行期一定正确，但能挡住绝大多数语法和引用错误。

### 3.4 `run`

激活机器人并执行一个 MT 动作，结束后去激活。会写硬件。

```sh
... run --robot assets/robots/relay-test.sql --input assets/scripts/relay-test.mt --timeout 30
... run --robot robots/arm.sql --input scripts/pick.mt --allow-hardware --timeout 60
```

- `--timeout` 单位为秒，默认 180。
- 物理设备必须显式加 `--allow-hardware`；`proto='virt'`、`loop://` 和回环 HTTP/TCP 不需要。
- 先用虚拟结构验证全链路，再写真机结构；两者分别命名，不要用同一份 SQL 切换。
- 动作派发后发生异常时，运行时会锁存“结果未知”，必须新建会话后重新确认现场。

### 3.5 `sample`

读取一个命名变量的当前值，可多次采样。

```sh
... sample --robot assets/robots/relay-test.sql --name relay0 --count 1
... sample --robot robots/sensors.sql --name th0 --count 10 --interval-ms 200 --allow-hardware
```

用于确认传感器读数、Daemon 快照或变量接线是否符合预期。会激活硬件。

### 3.6 `apply-sql`

在一个临时会话中执行受限 SQL（`UPDATE`、`DELETE`、`DROP` 等），用于实验或临时改变量。会激活硬件。

```sh
... apply-sql --robot assets/robots/relay-test.sql --sql "UPDATE Timer SET name='timer-1' WHERE name='timer-0';"
```

结构文件本身只允许 `CREATE`/`INSERT`；不要把 `apply-sql` 的语句写进 `robots/*.sql`。

### 3.7 `assets`

管理内置资产文件，不激活硬件：

```sh
... assets list --kind all
... assets read --kind robots --path relay-test.sql
... assets write --kind scripts --path my-arm.mt --content "@Action ..."
... assets write --kind scripts --path my-arm.mt --content-file arm.mt --force
... assets delete --kind scripts --path my-arm.mt --yes
```

- `kind` 为 `robots`（`.sql`）、`modules`（`.py`/`.lua`）或 `scripts`（`.mt`）；`list` 还可为 `all`。
- `path` 相对该资产根；拒绝越界、绝对路径、符号链接和错误后缀。
- `write` 新建，已存在则失败；`overwrite` 用 `--force`；`delete` 必须 `--yes`。
- `--content` 经 argv 传递，Windows 命令行上限约 32 KiB；更大的文件用 `--content-file`。

### 3.8 `new`

在用户工作区生成可运行的 SQL/MT/driver 骨架，不修改内置资产：

```sh
... new mybot-arm --dir /path/to/project
... new demo --dir . --force
```

生成后按骨架自带的命令先 `check`、再 `run`。

## 4. 路径与权限

- `--robot` 默认相对 `assets/robots`，`--input` 默认相对 `assets/scripts`。绝对路径，或已存在的 CWD 相对路径，原样使用；裸名或未命中的相对名回落到对应资产根。
- 默认拒绝物理设备、非回环网络和宿主 Shell；只有 `--allow-hardware` 才放开。虚拟总线、`loop://` 和回环 HTTP/TCP 不受限。
- 优先复用 HAL、`context.call()` 和 `context.check()`，不要用临时 I/O 绕过权限、预算、句柄所有权或清理。
- I2C、SPI、UART、TCP、HTTP、Shell 的普通表 driver 使用 Python；其他传感器 Lua driver、共享 Lua 库和 Lua Daemon 保持 Lua。
- Python/Lua driver 都是可信进程内代码，不是沙箱。`check` 只编译 Python 源码，不执行导入、构造器或生命周期方法。
- 摄像头不属于控制器：Agent 使用内置的 `list_cameras` / `capture_camera` 工具直接访问宿主设备。

## 5. MCP

把 `scripts/` 加入 Python 模块搜索路径后，使用标准模块入口：

```sh
python -m pymybot mcp --robot assets/robots/relay-test.sql --scripts-dir assets/scripts
```

在仓库根目录也可用自包含入口：

```sh
python skills/hardware-controller/scripts/hardware_controller.py mcp \
  --robot skills/hardware-controller/assets/robots/relay-test.sql \
  --scripts-dir skills/hardware-controller/assets/scripts
```

MCP 默认只读。执行动作和读取变量需要 `--allow-execution`；物理硬件另需 `--allow-hardware`。工具、资源和客户端配置见 `references/mcp.md`。

## 6. 三层脚本开发

三层模型：`robots/*.sql` 结构（舞台：声明零件与接线）→ `modules/*.py` 或 `*.lua` 驱动（演员：build/call/destroy，可加 safe）→ `scripts/*.mt` 动作（剧本：一行一拍）。

推荐流程：

1. 写 driver（内嵌 `*_VIRT` 模型）。
2. 写 `proto='virt'` 结构 + 动作脚本，全程无硬件。
3. `check` → `run`（虚拟）→ `sample`（需要采样时）。
4. 加 `tests/fixtures/virt/<驱动小写>_virt.{sql,mt}` 夹具。
5. 写真机结构（与虚拟 SQL 分别命名），再 `run --allow-hardware`。

文法细节、错误对照与硬纪律按任务先读对应 reference（每个 reference 开头 `Source:` 行标明权威位置）：

| 任务 | 先读 |
| --- | --- |
| 写/改结构脚本、Daemon 表配置、排查加载报错 | `references/structure-sql.md` |
| 写/改动作脚本、表达式、嵌套 Action/if/while、命名 Reflex、Include/Merge | `references/action-mt.md` |
| 写/改 Python/Lua 驱动、HAL 调用、drv_common 工具 | `references/driver-lua.md` |
| 写虚拟器件模型 `*_VIRT`、`proto='virt'` | `references/virt-model.md` |
| Daemon 后台采样、滤波/监视消费者 | `references/daemon.md` |
| 验证流程、常见报错对照、速查表 | `references/workflow-errors.md` |

### 硬纪律（高频翻车点）

1. SQL 每条语句必须 `;` 结尾；结构文件只允许 CREATE/INSERT。
2. MT 数据格裸文本直接报错——文本必须写 `$("...")`；单元格以空白分隔、`;` 结行，行格数须等于表头列数。
3. SQL 的 `$变量`、controller/trigger 引用须先声明。MT 顶层声明在动作前统一注册，Reflex 可先调用后定义；表达式求值时名字必须可见，捕获可创建数值/文本标量，不能隐式创建 Struct。
4. 驱动返回值必须是非空表，含 `result` 键时必须恰为 `"OK"`；失败返回 `err("原因")`。
5. 数值入参一律过 `finite_of`/`int_or`/`num_or`——NaN 是 truthy，`tonumber(v) or def` 挡不住。
6. 普通表对应 `modules/<表名>.py` 或 `.lua`：逐根查找，同根 Python 优先；原生入口是 `Driver(context)`。表名不带连字符。
7. `proto='virt'` 找不到内嵌 `*_VIRT` 模型会响亮报错，**绝不静默回落真机**；虚拟与真机用分别命名的 SQL。
8. `destroy` 是尽力释放：资源不可用就跳过动作、仍返回 OK。可选 `safe(data)` 在 abort 时、`destroy` 之前按激活逆序调用；它拿到 `mode="safe"`，但仍是协作式软件停止，不是硬件急停。
9. `@if`/`@while` 条件写在块名内且中间无空格：`@if(x>0)`；Action、控制块和 Reflex body 均可混排矩阵与嵌套块。Include 只在最外层，body 内 Merge 只合并其后的纯矩阵。
10. 默认拒绝物理设备、非回环网络与宿主命令执行（`--allow-hardware` 才放开）；virt 总线、`loop://` 与回环 HTTP 不需要该开关。
11. 使用顶层 `@Reflex(name)` 命名块，无 `name` 列，可声明多个但不得重名或嵌套声明；仅由 `reflexName.varName` 表头调用。MT `@Trigger` 和旧无名 `@Reflex` 在解析时拒绝；SQL trigger 完全保留。
12. Reflex 根 body 可声明 Alias/Vars 局部默认值，实参按类型覆盖；Action/控制块内不可声明，Struct 仍仅顶层。默认值、参数及内部捕获逐次调用隔离，退出即恢复；完整规则见 `references/action-mt.md` 第 7 节。

## 7. References

- 架构与 Runtime flow：`references/architecture.md`
- CLI 与 serve 协议：`references/cli.md`
- MCP 配置、工具和资源：`references/mcp.md`
- 安全与权限：`references/security.md`
- 测试与虚拟设备：`references/testing.md`
- 结构 SQL 文法：`references/structure-sql.md`
- MT 动作文法：`references/action-mt.md`
- Python/Lua 驱动契约：`references/driver-lua.md`
- 虚拟器件模型：`references/virt-model.md`
- Daemon 采样：`references/daemon.md`
- 验证流程与报错对照：`references/workflow-errors.md`

详细规则以对应 reference 和 Runtime 实现为准。