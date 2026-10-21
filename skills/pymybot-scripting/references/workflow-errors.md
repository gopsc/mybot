# 开发工作流、常见错误与速查表

技能 `pymybot-scripting` 参考文件。仓库根为 `mybot/`（Python 主线）。

## 1. 推荐路径：从虚拟到真机

```
写驱动（内嵌 _VIRT 模型）
    │
    ▼
写 proto='virt' 结构 + 动作脚本          ← 全程无硬件
    │  pymybot check   （静态：语法/模块/引用）
    │  pymybot run     （端到端：build/call/destroy 全链路）
    │  pymybot sample --name th0   （守护采样链路）
    ▼
（可选）加 tests/fixtures/virt/ 夹具进 pytest
    │  约定：<驱动小写>_virt.sql + <驱动小写>_virt.mt 成对；
    │  机制见 tests/test_migrated_drivers.py（40 对既有夹具）
    ▼
写真机结构（与虚拟 SQL 分别命名！）
    │  pymybot run --allow-hardware --robot robots/<任务>_real.sql ...
```

## 2. 在项目外目录开发

```sh
cd ~/robots/<任务>
pymybot check --robot robots/<任务>.sql --input scripts/<任务>.mt \
  --module-path modules --module-path /path/to/pymybot/modules
```

显式 `--module-path` 会**替换**默认搜索路径，自定义目录与基础 `modules` 都要给出；
或用环境变量 `BOT4CJ_MODULE_PATH`（按系统路径分隔符连接）。
`@Include` 只能引用动作脚本所在目录内的文件；图片只能来自 `--camera-src-dir`。

## 3. 平台要点

- I2C/SPI 真机：pyftdi 需要 MPSSE 型 FTDI 适配器（`ftdi://ftdi:232h/1`，SPI 可带 `?cs=0`）；
  Linux 原生 `/dev/i2c-*` / `/dev/spidev*` 需装 `.[linux]`。
- UART：Windows 用 `COMn`；`loop://` 回环不需要硬件。
- Camera：OpenCV；文件输入必须 `--camera-src-dir`。
- Windows：CLI 自动关闭 faulthandler（LuaJIT SEH 与 CPython 冲突，详见
  `docs/windows-faulthandler-luajit.md`）；stdout/stderr 固定 UTF-8。
- Lua 指令预算与可取消等待**不能中断阻塞的原生库调用**；进程退出不是物理急停。

## 4. 常见错误对照

| 报错 | 原因与处置 |
| --- | --- |
| `SQL: unexpected end of script` | 语句漏了结尾 `;`（单条也要） |
| `Expected a literal value (quote text containing punctuation)` | 值含标点未加引号 |
| `Reserved name must be quoted` | 表/列名撞保留字 |
| `INSERT into 'X': missing columns [...]` | INSERT 必须列全所有声明列 |
| `Lua module not found: X.lua` | 表名没有对应 `modules/X.lua`，或 `--module-path` 不含基础 modules |
| `'x' references undefined variable 'y'` | `$y` / 流向列引用了后面才声明的变量；调整声明顺序 |
| `UART path '...' has multiple independent consumers` | 同一串口被两个变量打开；合并为一个或改共享结构 |
| `Single-consumer conflict` | 带 `SINGLE_CONSUMER` 标记的驱动同 `(总线,地址)` 被声明两次 |
| `Cannot parse matrix cell ... as Float64` | MT 数据格写了裸文本；文本要写成 `$("...")` |
| `@Action cell $(...) cannot produce a boolean result` | 参数表达式算出布尔；布尔只用于 `@if/@while` |
| `expression '==' cannot compare a number with a text` | 跨类型比较；先统一类型 |
| `Hardware 'x' returned a non-table or empty table` | 驱动返回 nil/空表；返回 `{result="OK", ...}` |
| `Hardware 'x' failed: '...'` | 驱动返回 `result≠"OK"`；`'...'` 是 message |
| `@if requires a closed condition without spaces` | 写成 `@if (x>0)` 了；条件须紧跟 `@if(` |
| `proto=virt setup failed: ... no embedded <DRIVER>_VIRT model` | 驱动没内嵌虚拟模型 |
| `Include path must be a relative .mt path ...` | 绝对路径/穿越/反斜杠/冒号 |
| `Matrix line N: got M cells, expected K` | 数据行单元格数与表头不符 |
| `HAL: xxx is not supported by the portable backend` | 用了未迁移的 GPIO/PWM/Speaker 等后端 |

## 附录 A. 速查表

**结构 SQL 值的三种引用**

| 写法 | 出现位置 | 语义 |
| --- | --- | --- |
| `$name` | 任意值列 | 引用先前变量；结果表合并进 data / 标量填列 |
| `$(表达式)` | Number 列、任意值列 | 激活/调用时求数值 |
| `controller` / `trigger`/`controller2`… | **列名** | 值为目标变量名；结果转发 / 预取注入 |
| `-` | 数据格 | 继承上一行同列 |

**MT 数据格取值**

| 写法 | 语义 |
| --- | --- |
| 数字（十进制/`0x`十六进制） | 直接作为参数值 |
| `-` | 继承上一行；从未设值则本拍不发该参数 |
| `$(表达式)` | 求值（数字或文本，禁布尔） |
| `$var=字段.路径` | 捕获该设备本次结果的字段 |

**驱动四入口**

| 函数 | 时机 | 返回 |
| --- | --- | --- |
| `build(data)` | 激活 | `{result="OK"}` 或 `err()`；异常经 `guard_build` 折 ERR 并回滚 |
| `call(data)` | 每次 play | 非空表，推荐 `{result="OK", ...}` |
| `destroy(data)` | 去激活 | 尽力释放；资源不可用仍 `{result="OK"}` |
| `read(data)`（可选） | sample/守护 | 快照表；缺省回退 `call` |

**限额**

| 项 | 上限 |
| --- | --- |
| 结构/动作/SQL/Include 总字节 | 各 8 MiB |
| MT 块嵌套 / Include 条数与深度 | 各 32 |
| 表达式运算符 / 括号嵌套 | 512 / 128 |
| Merge 输出 | 20000 行、200000 格 |
| Daemon interval | 1..3600000 ms（缺省 5） |
| Daemon fields | ≤64 个（槽 maxvals） |

## 附录 B. 示例索引

| 想看什么 | 位置 |
| --- | --- |
| 纯软件模块 + controller 转发 | `modules/Relay.lua` + `robots/relay-test.sql` + `scripts/relay-test.mt` |
| 软件定时器（参数校验范本） | `modules/Timer.lua` |
| 声明式 I2C 驱动 + 内嵌 VIRT 模型 | `modules/CHT8305.lua` |
| 守护采样 + 滤波 + 监视全链路 | `tests/fixtures/virt/cht8305_virt.sql` + `.mt` |
| 驱动框架源码 | `modules/lib/drv_common.lua` |
| HAL 桥接 | `modules/lib/HAL.lua`、`modules/lib/hal/{i2c,spi}.lua` |
| 虚拟总线 | `modules/lib/virtbus.lua`、`modules/lib/virtbus/regmap.lua` |
| 采样 chunk | `modules/lib/sensor_daemon.lua`、`modules/lib/sensor_aggregate.lua` |
| 文法实现 | `pymybot/{sql,matrix,expr,actions,include}.py` |
| 逐驱动无硬件夹具（40 对） | `tests/fixtures/virt/`（机制见 `tests/test_migrated_drivers.py`） |
