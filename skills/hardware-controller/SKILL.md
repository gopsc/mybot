---
name: hardware-controller
description: Control and program robots through the self-contained pymybot Runtime, Structure SQL, MT actions, Python/Lua drivers, HAL, MCP, and virtual devices. Use for hardware inspection, robot actions, sensor sampling, Camera capture, MCP integration, driver development, and controller troubleshooting.
---

# Hardware Controller

使用 `scripts/` 内的 Python Runtime 控制机器人。Structure SQL 声明硬件，Python/Lua driver 实现设备行为，MT action 描述时序动作。默认 robots、scripts 和 modules 位于 `references/assets/`。

## 运行入口

在仓库根目录使用自包含入口：

```sh
python skills/hardware-controller/scripts/hardware_controller.py doctor
python skills/hardware-controller/scripts/hardware_controller.py hardware --robot skills/hardware-controller/references/assets/robots/relay-test.sql
```

也可以继续使用兼容入口 `python -m pymybot`；两者共享同一套 Runtime，不要复制或另建控制器实现。

## 工作流

1. 用 `doctor` 检查解释器、依赖和 assets。
2. 用 `hardware`、`query` 或 `check` 静态检查结构与动作；这些命令不得激活硬件。
3. 编写 SQL、MT 或 Driver 前，阅读 `../pymybot-scripting/SKILL.md` 及对应 reference。
4. 先用 `references/assets/` 的虚拟设备或项目 fixtures 验证，再考虑物理设备。
5. 先 `check`，再 `run`。物理设备、非回环网络及 Shell 必须显式授权。
6. 检查单行 JSON、退出码和测试。动作派发后异常可能意味着结果未知，不自动重试，也不声称已回滚。

## MCP

将 `scripts/` 加入 Python 模块搜索路径后，使用标准模块入口：

```sh
python -m pymybot mcp --robot references/assets/robots/relay-test.sql --scripts-dir references/assets/scripts
```

在仓库根目录也可使用：

```sh
python skills/hardware-controller/scripts/hardware_controller.py mcp --robot skills/hardware-controller/references/assets/robots/relay-test.sql --scripts-dir skills/hardware-controller/references/assets/scripts
```

MCP 默认只读。执行动作、读取变量和抓图需要 `--allow-execution`；物理硬件另需 `--allow-hardware`。Camera 和变量读取继续使用白名单。

## 安全与兼容性

- 优先复用 HAL、`context.call()` 和 `context.check()`，不要用临时 I/O 绕过权限、预算、句柄所有权或清理。
- I2C、SPI、UART、TCP、HTTP、Camera、Shell 的普通表 Driver 使用 Python；保留其他传感器 Lua Driver、共享 Lua 库和 Lua Daemon。
- Python/Lua Driver 都是可信进程内代码，不是沙箱。静态 `check` 不执行 Python 模块、构造器或生命周期方法。
- 用户工作区仍可使用自己的 `robots/`、`scripts/`、`modules/`；`pymybot new` 的用户项目布局不变。
- wheel 和 frozen build 内的 `pymybot/assets/` 布局保持不变。

## References

- 架构与 Runtime flow：`references/architecture.md`
- CLI 与 serve 协议：`references/cli.md`
- MCP 配置、工具和资源：`references/mcp.md`
- 安全与权限：`references/security.md`
- 测试与虚拟设备：`references/testing.md`
- SQL、MT、Driver 硬规则：`../pymybot-scripting/SKILL.md`

详细规则以对应 reference 和 Runtime 实现为准。
