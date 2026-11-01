# pymybot

**把「结构 SQL + Python/Lua 驱动 + MT 动作」三层脚本接到真实机器人；同一套后端提供 GUI、CLI、AI Agent 和 MCP 四种入口。**

[![CI](https://github.com/gopsc/mybot/actions/workflows/ci.yml/badge.svg)](https://github.com/gopsc/mybot/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gopsc/mybot?include_prereleases&sort=semver)](https://github.com/gopsc/mybot/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/python-3.11%E2%80%933.14-3776AB)](pyproject.toml)

[中文使用指南](docs/Introduce.md) · [English](docs/README.en.md) · [文档索引](docs/README.md) · [路线图](docs/roadmap.md) · [安全模型](docs/security.md)

![pymybot GUI](docs/screenshots/gui.png)

## 快速开始

要求 Python 3.11+，不需要先接硬件：

```sh
git clone https://github.com/gopsc/mybot.git
cd mybot
python -m venv .venv
.venv/bin/pip install -e ".[test]"

.venv/bin/python -m pymybot doctor
.venv/bin/python -m pymybot check \
  --robot robots/relay-test.sql --input scripts/relay-test.mt
.venv/bin/python -m pymybot run \
  --robot robots/relay-test.sql --input scripts/relay-test.mt --timeout 10
```

Windows 使用 `.venv\Scripts\pip` 和 `.venv\Scripts\python`。`run` 会输出一行 JSON：

```json
{"ok":true,"command":"run","outputs":[{"result":"OK","slept":1}]}
```

打开 GUI（PySide6）：

```sh
.venv/bin/pip install -e ".[gui]"
.venv/bin/python -m pymybot
```

启用终端 Agent（模型可选）：

```sh
.venv/bin/pip install -e ".[agent]"
export MYBOT_MODEL="deepseek:deepseek-chat"
export DEEPSEEK_API_KEY="sk-..."
.venv/bin/python -m pymybot --no-gui \
  --robot robots/relay-test.sql --task "列出硬件并解释每个变量的作用"
```

第一次写出自己的机器人：

```sh
.venv/bin/python -m pymybot new mybot-arm
```

它会在当前目录生成 `robots/mybot-arm.sql`、`scripts/mybot-arm.mt` 和
`modules/MybotArm.py`，然后就可以运行上面的 `check` / `run` 命令。

## 为什么是三层

| 层 | 文件 | 负责什么 |
| --- | --- | --- |
| 结构 | `robots/*.sql` | 机器人上有哪些变量、接在哪条总线、谁引用谁 |
| 驱动 | `modules/*.py` / `*.lua` | 一个器件怎么 `build / call / read / destroy` |
| 动作 | `scripts/*.mt` | 一轮动作中第几行对哪个变量发什么参数，支持捕获、条件、循环和 Struct |

结构 SQL 是接线图，驱动是器件说明书，MT 动作是操作清单。三层分开后，换器件不必重写动作，换动作也不必改结构。

默认关闭物理硬件和危险操作，按需显式开启：

```sh
pymybot run --allow-hardware ...
```

**软件 abort 和超时都不是硬件急停**。真实的运动设备应保留独立的安全回路和物理急停。

## 文档

- [使用指南](docs/Introduce.md) — 安装、第一个动作、GUI、Agent、MCP
- [架构](docs/architecture.md) — 分层、线程模型、包结构
- [CLI](docs/cli.md) — 命令、JSON 契约、`serve` 协议
- [GUI](docs/gui.md) — 设置、资源预览、审批和急停
- [安全模型](docs/security.md) — 信任边界和已知限制
- [开发](docs/development.md) — 测试、lint、打包和冻结构建

## 仓库结构

```text
pymybot/      Python 包：CLI、SQL、MT、HAL、Daemon、Agent、GUI、MCP
modules/      Python/Lua 驱动、Lua 驱动库和虚拟设备模型
robots/       结构示例（含虚拟设备）
scripts/      MT 动作示例
skills/       Agent 参考技能
prompts/      默认提示词层和 manifest
tests/        pytest 与虚拟夹具
docs/         架构、CLI、GUI、开发、测试、发布、安全文档
tools/        打包、CI 和清理辅助
```

## 发起人自白

说来我其实不喜欢用现成框架，我喜欢从零开始手搓。

最开始我只是网上找了个四足蜘蛛机器人，看了下它的代码，是将每个舵机的角度和 sleep 的时间汇总成一个二维数组。我树莓派有文件系统，所以我就把这个数组做成了文本，就是一种矩阵的形态。

所以我表示动作的脚本是 `.mt`。发展到现在，`.mt` 动作脚本已经几乎成了一种编程语言。它调用的对象由 SQL 声明（声明硬件），而 SQL 代码中能够声明的硬件类型由 LuaJIT 或者 Python 构建。

后来又在 MT 中加入了别名、变量、判断、循环、引入这些基本特性，以及控制器、触发器、横向合并、条件反射这些高级特性。这么就构成了一个脚本控制系统。

## 许可证

[MIT](LICENSE)
