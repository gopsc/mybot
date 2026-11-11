# pymybot

**Structure SQL + Python/Lua drivers + MT actions，接真实机器人；一套后端提供 CLI 与 MCP 两个入口。**

[![CI](https://github.com/gopsc/mybot/actions/workflows/ci.yml/badge.svg)](https://github.com/gopsc/mybot/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gopsc/mybot?include_prereleases&sort=semver)](https://github.com/gopsc/mybot/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/python-3.11%E2%80%933.14-3776AB)](pyproject.toml)

[Controller Skill](skills/hardware-controller/SKILL.md) · [中文使用指南](docs/Introduce.md) · [English](docs/README.en.md) · [文档索引](docs/README.md) · [路线图](docs/roadmap.md) · [安全模型](skills/hardware-controller/references/security.md)

## 发起人自白

说来我其实不喜欢用现成框架，我喜欢从零开始手搓。

最开始我只是网上找了个四足蜘蛛机器人，看了下它的代码，是将每个舵机的角度和 sleep 的时间汇总成一个二维数组。我树莓派有文件系统，所以我就把这个数组做成了文本，就是一种矩阵的形态。

所以我表示动作的脚本是 `.mt`。发展到现在，`.mt` 动作脚本已经几乎成了一种编程语言。它调用的对象由 SQL 声明（声明硬件），而 SQL 代码中能够声明的硬件类型由 LuaJIT 或者 Python 构建。

后来又在 MT 中加入了别名、变量、判断、循环、引入这些基本特性，以及控制器、触发器、横向合并、条件反射这些高级特性。这么就构成了一个脚本控制系统。

## 三层

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 结构 | `robots/*.sql` | 声明变量、总线、地址和控制器接线（`CREATE`/`INSERT`） |
| 驱动 | `modules/*.py` / `*.lua` | 实现 build/call，可选 read/destroy/safe；Python 为普通表默认选择 |
| 动作 | `scripts/*.mt` | 设备参数矩阵、捕获、循环与控制流，一行一拍 |

## 快速开始

```sh
pip install -e ".[test]"     # 或 pip install -e ".[test,mcp]"

# 内置示例：Timer/Relay 纯软件模块，不需要任何硬件
python -m pymybot check --robot skills/hardware-controller/assets/robots/relay-test.sql \
                        --input skills/hardware-controller/assets/scripts/relay-test.mt
python -m pymybot run   --robot skills/hardware-controller/assets/robots/relay-test.sql \
                        --input skills/hardware-controller/assets/scripts/relay-test.mt --timeout 10
```

每个命令在 stdout 输出恰好一行 JSON；`check`/`hardware`/`scripts`/`query` 不激活驱动，`run`/`sample`/`apply-sql` 会写硬件。物理设备必须显式加 `--allow-hardware`。

## 两个入口

```sh
# CLI：检查、发现、执行、采样
pymybot doctor
pymybot discover --buses uart,i2c
pymybot hardware --robot assets/robots/relay-test.sql
pymybot run --robot assets/robots/relay-test.sql --input assets/scripts/relay-test.mt

# MCP：给 MCP 客户端使用，默认只读
pymybot mcp --robot assets/robots/relay-test.sql --scripts-dir assets/scripts
```

MCP 工具为 `get_status`、`list_hardware`、`list_action_scripts`、`read_action_script`、
`query_sql`、`run_action_script`、`read_variables`、`deactivate`；默认只读，
`--allow-execution` 才放行执行与变量读取，物理硬件另需 `--allow-hardware`。
细节见 [MCP 指南](skills/hardware-controller/references/mcp.md)。

## 目录

```text
skills/hardware-controller/  自包含控制器：Runtime、资产与权威文档
pymybot/                     安装入口包（版本与 import shim）
tests/                       pytest 套件与虚拟设备夹具，全程无硬件
docs/                        运维与维护文档
tools/                       打包与 CI 自检
```

## 许可证

[MIT](LICENSE)
