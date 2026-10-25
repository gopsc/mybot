# 最小可跑示例：三层架构一屏看清

三个文件跑通「结构脚本 → 动作脚本 → 驱动」整条链路，**不接任何硬件、不需要大模型**。
第二层（驱动 `modules/dummy.lua`）是现成的，示例只带另外两层——写新机器人时你改的也正是这两层。

| 文件 | 层 | 一句话 |
|---|---|---|
| `robot.sql` | 结构脚本（舞台接线图） | 一张表 = 一类器件，**表名 = 驱动文件名**：`dummy` 表 → `modules/dummy.lua` |
| `modules/dummy.lua`（仓库自带） | 驱动（零件说明书） | `build`/`call`/`destroy` 三件套；Dummy 只回显参数、统计次数 |
| `hello.mt` | 动作脚本（演员剧本） | `@Alias` 给文本值起名，`@Action` 播一帧 |

## 跑

```bash
# 构建过即可（cmake -S . -B build && cmake --build build）
./build/mybot --robot=examples/minimal/robot.sql --input examples/minimal/hello.mt

# 管道形态等价
cat examples/minimal/hello.mt | ./build/mybot --robot=examples/minimal/robot.sql
```

预期输出（退出码 0）：

```text
从文件读取动作脚本：examples/minimal/hello.mt
----------
{"count":1,"result":"OK","echo":"你好，三层架构"}
Dummy served 1 call(s) in its meaningless life
```

（若 `modules/` 下驱动/库文件组或其他人可写，前面还会多几行权限警告，见
[HAL](../../docs/hal.md) 沙箱加载的权限前提。）

末行是驱动 `destroy` 打的：上电 → 播一帧 → `call` 回显 → 断电，完整生命周期走了一遍。

## 发生了什么

1. `robot.sql` 里的 `CREATE TABLE dummy` 让装配器去模块路径（缺省 `./modules`，可用
   `BOT4CJ_MODULE_PATH` 改）找 `dummy.lua`，`INSERT` 的那行声明了一台名叫 `d0` 的设备。
2. `hello.mt` 的 `@Action` 矩阵列头 `d0.echo` 意思是「把这一帧投给设备 d0 的 echo 参数」。
   数据格只认数值，所以文本 `"你好，三层架构"` 先在 `@Alias` 表里起名 `greet`，
   数据格写 `$(greet)` 间接引用（`docs/dsl.md` 的文本参数规则）。
3. 驱动 `call` 收到 `{echo="你好，三层架构"}`，原样回显并计数，结果以 JSON 回传。

## 改着玩

- 把 `d0.echo` 那行的值换成别的问候（改 `@Alias` 表或直接换数值格试试数值）。
- 多播几帧：`@Action` 矩阵里加行，一行一帧，`-` 表示继承上一行。
- 换真器件：把 `robot.sql` 换成 `robots/relay-test.sql`（虚拟继电器，走虚拟总线，
  仍无需硬件），或照 [README](../../README.md)「接真实硬件」写 PCA9685 舵机结构。
- 接大模型：后端加 `--mcp-backend --mcp-socket /tmp/mybot.sock`，另起
  `mybot-agent --socket /tmp/mybot.sock` 用自然语言驱动同一套三层（配好
  `BOT4CJ_LLM_KEY/ENDPOINT/MODEL` 三件套），见根 README 快速开始。
