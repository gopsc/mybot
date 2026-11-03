---
name: hardware-controller
description: Control and program robots through the self-contained pymybot Runtime, Structure SQL, MT actions, Python/Lua drivers, HAL, MCP, and virtual devices. Use for hardware inspection, robot actions, sensor sampling, MCP integration, driver development, and controller troubleshooting.
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

MCP 默认只读。执行动作和读取变量需要 `--allow-execution`；物理硬件另需 `--allow-hardware`。

## Agent 原生 run_skill

当根 Agent 发现本 Skill 标记为 `runnable` 时，可调用：

根 Agent 不再暴露直接的硬件工具，硬件能力全部通过本 Skill 的 action 提供：

```text
run_skill(skill="hardware-controller", action="doctor")
run_skill(skill="hardware-controller", action="scripts")
run_skill(skill="hardware-controller", action="hardware", arguments={
  "robot": {"scope": "skill_assets", "path": "robots/relay-test.sql"}
})
run_skill(skill="hardware-controller", action="query", arguments={
  "robot": {"scope": "skill_assets", "path": "robots/relay-test.sql"},
  "sql": "SHOW TABLES;"
})
run_skill(skill="hardware-controller", action="check", arguments={
  "robot": {"scope": "robots", "path": "relay-test.sql"},
  "script": {"scope": "scripts", "path": "relay-test.mt"}
})
run_skill(skill="hardware-controller", action="run", arguments={
  "robot": {"scope": "robots", "path": "relay-test.sql"},
  "script": {"scope": "scripts", "path": "relay-test.mt"},
  "timeout": 30
})
run_skill(skill="hardware-controller", action="sample", arguments={
  "robot": {"scope": "robots", "path": "relay-test.sql"},
  "name": "relay0", "count": 1
})
```

允许的 action 为 `doctor`、`scripts`、`hardware`、`query`、`check`、`run`、`sample`，定义在 `skill.json`。技能是操作者可信内容，因此 `run_skill` 不弹审批，路径/参数/输出/超时限制已移除，`run` 和 `sample` 直接获得 `--allow-hardware`。模型仍只能选择已声明的 action；entrypoint 和 argv 由技能清单固定。操作员应只安装可信技能，因为运行技能等同于运行宿主代码并可直接操作真实硬件。摄像头不属于控制器：Agent 使用内置的 `list_cameras` / `capture_camera` 工具直接访问宿主设备。

## 安全与兼容性

- 优先复用 HAL、`context.call()` 和 `context.check()`，不要用临时 I/O 绕过权限、预算、句柄所有权或清理。
- I2C、SPI、UART、TCP、HTTP、Shell 的普通表 Driver 使用 Python；保留其他传感器 Lua Driver、共享 Lua 库和 Lua Daemon。
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
