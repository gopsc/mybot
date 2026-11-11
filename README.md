# hardware-controller

**用结构 SQL 声明硬件，用 Python/Lua 驱动实现设备，用 MT 动作脚本描述时序——同一套 Runtime 提供 CLI 与 MCP 两个入口。**

这个仓库就是 `hardware-controller` 技能本体：`SKILL.md` 是技能入口与主题索引，
`references/` 是权威文档，`assets/` 是可直接运行的示例，`scripts/` 是自包含启动器与 Runtime。

## 三层

| 层 | 文件 | 作用 |
| --- | --- | --- |
| 结构 | `assets/robots/*.sql` | `CREATE`/`INSERT` 声明变量、总线、地址与 controller/trigger 接线 |
| 驱动 | `assets/modules/*.py` / `*.lua` | 实现 `build`/`call`，可选 `read`/`destroy`/`safe`；普通表默认选 Python |
| 动作 | `assets/scripts/*.mt` | 设备参数矩阵、捕获、条件、循环、Reflex，一行一拍 |

换传感器只改结构和驱动，换动作只改 MT；三层都是数据，硬件写操作统一经过 HAL 与权限门。

## 目录

```text
SKILL.md              技能清单与主题索引
assets/               默认驱动、结构 SQL 与 MT 动作示例
references/           控制器权威文档（架构、CLI、MCP、安全、测试、文法）
scripts/              hardware_controller.py 启动器、requirements.txt、pymybot Runtime
tests/                pytest 套件与逐驱动虚拟夹具，全程不需要硬件
tools/                wheel 冒烟与文档/链接一致性检查
pyproject.toml        打包与 pytest 配置（包来自 scripts/pymybot）
```

## 快速开始

要求 Python 3.11–3.14。内置示例只用 Timer/Relay 两个纯软件模块，不需要任何硬件：

```sh
pip install -r scripts/requirements.txt

# 静态校验：不激活驱动
python scripts/hardware_controller.py check \
  --robot assets/robots/relay-test.sql \
  --input assets/scripts/relay-test.mt

# 执行：激活 → 跑一个动作 → 去激活
python scripts/hardware_controller.py run \
  --robot assets/robots/relay-test.sql \
  --input assets/scripts/relay-test.mt \
  --timeout 10
```

输出：

```json
{"ok":true,"command":"check","valid":true,"activated":false,"tables":["Timer","Relay"],"action_blocks":["Action"]}
{"ok":true,"command":"run","outputs":[{"result":"OK","slept":1}]}
```

也可以安装后走标准模块入口：

```sh
pip install -e ".[test,mcp]"
python -m pymybot doctor
```

`--robot` / `--input` 默认相对 `assets/robots`、`assets/scripts`；绝对路径或已存在的 CWD
相对路径原样使用。

## 命令

| 命令 | 作用 | 激活硬件 |
| --- | --- | --- |
| `doctor` | 解释器、依赖、Lua 后端与资产清单诊断 | 否 |
| `discover` | 只读枚举宿主 UART/FTDI/I2C/SPI 设备，直接给出建表 SQL 提示 | 否 |
| `check` | 静态校验 SQL、模块、引用与 MT 语法 | 否 |
| `hardware` | 列出声明的变量与接线 | 否 |
| `scripts` | 列出动作脚本 | 否 |
| `query` | `SHOW TABLES;` / `SELECT * FROM 表` | 否 |
| `run` | 激活、执行一个动作、清理 | 是 |
| `sample` | 读取命名变量，可多次采样 | 是 |
| `apply-sql` | 对临时激活的机器人执行受限 SQL，不写结构文件 | 是 |
| `assets` | 列出/读取/新建/删除内置资产 | 否 |
| `new` | 生成 `robots/`、`scripts/`、`modules/` 骨架 | 否 |
| `mcp` | 标准 MCP stdio 服务端，默认只读 | 视开关 |

每个命令在 stdout 输出**恰好一行 JSON**，诊断写 stderr；退出码 `0` 成功、`1` 运行错误、
`2` 用法错误、`130` 中断。

## MCP

```sh
python scripts/hardware_controller.py mcp \
  --robot assets/robots/relay-test.sql \
  --scripts-dir assets/scripts
```

默认只读：`get_status`、`list_hardware`、`list_action_scripts`、`read_action_script`、
`query_sql` 可直接用；`run_action_script`、`read_variables` 需要 `--allow-execution`，
物理硬件另需 `--allow-hardware`（它要求同时给出 `--allow-execution`）。资源只暴露
`mybot://scripts/...`。

## 安全边界

| 能力 | 默认 | 打开方式 |
| --- | --- | --- |
| 物理 I2C/SPI/UART、非回环 HTTP/TCP、Shell 驱动 | 关闭 | `--allow-hardware` |
| MCP 执行与变量读取 | 关闭 | `--allow-execution` |
| `proto='virt'`、`loop://`、回环 HTTP/TCP | 可用 | 无需开关 |

- `check`/`hardware`/`scripts`/`query` 从不激活驱动；`run`/`sample`/`apply-sql` 会写硬件。
- 动作派发后异常锁存为「结果未知」：不自动重试，也不声称回滚。
- Python/Lua 驱动是可信进程内代码，**不是沙箱**；只运行审阅过的驱动。

## 开发与测试

```sh
python -m pytest -q                        # 全量，无硬件
python -m pytest tests/test_dsl.py -q      # 只跑 MT/表达式文法
python -I tools/check_docs_skill_sync.py   # 引用登记、链接与 Source 行
python -I tools/ci_smoke.py wheel          # sdist → wheel → 干净 venv
```

新增驱动：在 `assets/modules/` 放 `Driver(context)` 实现或 `lib/` 下的 Lua 驱动，配套
`tests/fixtures/virt/<名字>_virt.{sql,mt}` 夹具，先跑虚拟结构再加 `--allow-hardware`。
细节见 [references/driver-lua.md](references/driver-lua.md) 与
[references/testing.md](references/testing.md)。

## 文档

- 技能入口与索引：[SKILL.md](SKILL.md)
- 架构与 Runtime flow：[references/architecture.md](references/architecture.md)
- CLI 与 JSON 契约：[references/cli.md](references/cli.md)
- MCP 工具与资源：[references/mcp.md](references/mcp.md)
- 安全与权限：[references/security.md](references/security.md)
- 文法：结构 SQL [references/structure-sql.md](references/structure-sql.md)、MT 动作
  [references/action-mt.md](references/action-mt.md)
- 排错与验证流程：[references/workflow-errors.md](references/workflow-errors.md)

## 许可证

[MIT](LICENSE)
