---
name: hardware-controller
description: Control and program robots through the self-contained pymybot Runtime, Structure SQL, MT actions, Python/Lua drivers, HAL, MCP, and virtual devices. Use for hardware inspection, robot actions, sensor sampling, MCP integration, driver development, and controller troubleshooting.
---

# Hardware Controller

使用 `scripts/` 内的 Python Runtime 控制机器人。Structure SQL 声明硬件，Python/Lua driver 实现设备行为，MT action 描述时序动作。默认 robots、scripts 和 modules 位于 `assets/`。

## 运行入口

在仓库根目录使用自包含入口：

```sh
python skills/hardware-controller/scripts/hardware_controller.py doctor
python skills/hardware-controller/scripts/hardware_controller.py hardware --robot skills/hardware-controller/assets/robots/relay-test.sql
```

也可以继续使用兼容入口 `python -m pymybot`；两者共享同一套 Runtime，不要复制或另建控制器实现。

## 工作流

1. 用 `doctor` 检查解释器、依赖和 assets。
2. 用 `hardware`、`query` 或 `check` 静态检查结构与动作；这些命令不得激活硬件。
3. 编写 SQL、MT 或 Driver 前，阅读下方「三层脚本开发」表指向的 reference。
4. 先用 `assets/` 的虚拟设备或项目 fixtures 验证，再考虑物理设备。
5. 先 `check`，再 `run`。物理设备、非回环网络及 Shell 必须显式授权。
6. 检查单行 JSON、退出码和测试。动作派发后异常可能意味着结果未知，不自动重试，也不声称已回滚。

## MCP

将 `scripts/` 加入 Python 模块搜索路径后，使用标准模块入口：

```sh
python -m pymybot mcp --robot assets/robots/relay-test.sql --scripts-dir assets/scripts
```

在仓库根目录也可使用：

```sh
python skills/hardware-controller/scripts/hardware_controller.py mcp --robot skills/hardware-controller/assets/robots/relay-test.sql --scripts-dir skills/hardware-controller/assets/scripts
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

技能还能创建、检索、覆盖和删除 `assets/` 下的机器人脚本，让智能体自足地编写并调用脚本：

```text
run_skill(skill="hardware-controller", action="assets_list", arguments={"kind": "robots"})
run_skill(skill="hardware-controller", action="assets_read", arguments={
  "kind": "scripts", "path": "relay-test.mt"})
run_skill(skill="hardware-controller", action="assets_write", arguments={
  "kind": "robots", "path": "mybot-arm.sql", "content": "CREATE TABLE ..."})
run_skill(skill="hardware-controller", action="assets_overwrite", arguments={
  "kind": "scripts", "path": "mybot-arm.mt", "content": "@Action ..."})
run_skill(skill="hardware-controller", action="assets_delete", arguments={
  "kind": "robots", "path": "mybot-arm.sql"})
```

`kind` 为 `robots`（`.sql`）、`modules`（`.py`/`.lua`）或 `scripts`（`.mt`）；`assets_list`
的 `kind` 还可为 `all`。`path` 是相对该资产根的路径，禁止越界与错误后缀。`assets_write`
新建、已存在则失败；`assets_overwrite` 显式覆盖（`--force`）；`assets_delete` 显式删除
（`--yes`）。这些是可信技能动作、不弹审批，因此覆盖与删除各自是独立的显式 action 名，
模型必须主动选择。`--content` 经 argv 传递，Windows 命令行上限约 32 KiB；更大的文件请由
操作员用 CLI 的 `--content-file` 写入。

允许的 action 为 `doctor`、`scripts`、`hardware`、`query`、`check`、`run`、`sample`、
`assets_list`、`assets_read`、`assets_write`、`assets_overwrite`、`assets_delete`，定义在
`skill.json`。直接 CLI 里 `--robot` 默认相对 `assets/robots`、`--input` 默认相对
`assets/scripts`：绝对路径与已存在的 CWD 相对路径原样使用，裸名或未命中的相对名落到对应
资产根，因此技能无需绝对路径即可自足运行。技能是操作者可信内容，因此 `run_skill` 不弹审批，路径/参数/输出/超时限制已移除，`run` 和 `sample` 直接获得 `--allow-hardware`。模型仍只能选择已声明的 action；entrypoint 和 argv 由技能清单固定。操作员应只安装可信技能，因为运行技能等同于运行宿主代码并可直接操作真实硬件。摄像头不属于控制器：Agent 使用内置的 `list_cameras` / `capture_camera` 工具直接访问宿主设备。

## 安全与兼容性

- 优先复用 HAL、`context.call()` 和 `context.check()`，不要用临时 I/O 绕过权限、预算、句柄所有权或清理。
- I2C、SPI、UART、TCP、HTTP、Shell 的普通表 Driver 使用 Python；保留其他传感器 Lua Driver、共享 Lua 库和 Lua Daemon。
- Python/Lua Driver 都是可信进程内代码，不是沙箱。静态 `check` 不执行 Python 模块、构造器或生命周期方法。
- 用户工作区仍可使用自己的 `robots/`、`scripts/`、`modules/`；`pymybot new` 的用户项目布局不变。
- wheel 和 frozen build 内的 `pymybot/assets/` 布局保持不变。

## 三层脚本开发

三层模型：`robots/*.sql` 结构（舞台：声明零件与接线）→ `modules/*.py` 或 `*.lua`
驱动（演员：build/call/destroy，可加 safe）→ `scripts/*.mt` 动作（剧本：一行一拍）。
控制器架构、CLI、安全、测试的权威文档在本技能 `references/`；`docs/` 下同名页面只是跳转。
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

新驱动应配 `tests/fixtures/virt/<驱动小写>_virt.{sql,mt}` 夹具（机制见 `references/virt-model.md`）。
行为存疑时以各 reference `Source:` 指向的实现裁定，HAL 细节见 `modules/lib/HAL.lua` 与 `modules/lib/hal/`。

## References

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
