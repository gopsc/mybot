# mybot-lite headless：双核、Lua、脚本解析与硬件 HAL

本分支（`mybot-lite-p0`）从 mybot 迁移到 RP2040。**P24 起固件是纯 headless**：
VGA 显示、framebuffer console、USB HID 键盘/鼠标、中文输入法全部移除；
诊断与控制统一走 **UART0 串口控制台**。

已经验证/实现的能力：

1. **core1 阻塞不会影响 core0 的 UART 控制台和日志**
2. **Lua 5.1 能在 RP2040 上启动、加载脚本、执行 `build/call/destroy`，并给出内存水位**
3. **Lua 驱动从 SD 加载，每个驱动有独立 env**
4. **运行期解析 `.sql` / `.mt`，支持 `$ref` / `@Alias` / `@Vars`**
5. **真实 I2C/SPI/UART HAL，以及 PCA9685/ADS1015/AD9833 驱动接入**
6. **`@if` / `@while` 控制流、动作捕获、命令系统与热重载**
7. **`@Struct` JSON 对象/数组与字段选择**
8. **顶层 `@Include` 脚本片段**
9. **算术表达式、括号条件和字符串拼接**
10. **简化版 `@Merge` 相位时间线**
11. **trigger 前置调用**
12. **静态内存收敛（P11 约 166KB → 138KB）**
13. **`@Merge` 主脚本动作对齐**
14. **`@Merge` 片段别名/变量与设备集校验**
15. **`@Reflex` / `@Trigger`**
16. **named `@Reflex(name)`**
17. **反射递归/深度防线**
18. **动态数组下标**
19. **控制台 `/list` / `/help`**
20. **两层 `@Include`**
21. **SQL 与动作脚本分离选择**
22. **命令历史（串口 ANSI ↑/↓）**
23. **条件解析 v2（分组/一元 !/短路）**
24. **统一表达式引擎（条件与 `$(...)` 共用）**
25. **P24：移除 VGA / PIO 视频 / USB HID 键鼠，改为 headless 串口控制台**
26. **P25：`@SQL` 运行期热插拔（INSERT / DELETE）**
27. **P26：取消无 SD 构建，SD 固定启用**
28. **P27：`@SQL` UPDATE / DROP TABLE**
29. **P28：常驻 Lua 状态 + UART `/sql` 热补丁**
30. **P29：`/action` 在 active 结构上重播动作脚本**
31. **P30：`/repeat` 批量重播动作脚本**
32. **P31：active 状态诊断 `/devices` / `/vars` / `/structs`**
33. **P32：`/sql` 事务回滚**
34. **P33：`@SQL` 块事务回滚**
35. **P34：设备列 `@Alias` 解析**
36. **P35：`/loop` 周期动作循环**
37. **P36：`/reload` 重载 active profile**
38. **P37：`/boot.txt` 开机自动周期动作**
39. **P38：`/use` 与 `/autostart` 持久化开机配置**
40. **P39：`@Merge` 容量扩展、负相位与前导 `-` 跳过**
41. **P40：`@Action` 行内 `-` 继承**
42. **P41：`@Reflex` / `@Merge` 的 `-` 继承**
43. **P42：动作行缺列按 `-` 补齐**
44. **P43：全 fake HAL 回归 profile + `/device` 详情**
45. **P44：设备容量 8 → 16**
46. **P45：列头设备位/参数位表达式**
47. **P46：`@Action` 列头表达式按行重算**
48. **P47：递归 `@Include` 与循环检测**
49. **P48：顶层 MT 纳入 include 循环检测**
50. **P49：`@Merge` 主从别名/变量覆盖**
51. **P50：`@Merge` include-once 片段**
52. **P51：`/i2cscan` 硬件总线扫描**

还没有实现：完整 `@Merge` 片段递归/include-once/预算语义、完整 mybot 表达式 AST、trigger 返回值嵌套合并。

## 当前硬件形态

```text
RP2040
  UART0 GP0/GP1   115200 8N1   控制台 + 日志（唯一人机接口）
  SPI0  GP2-5      5MHz        SD 卡（FAT）
  I2C0  GP6/GP7                PCA9685 / ADS1015 等
  UART1 GP8/GP9                串口设备
  SPI1  GP10-13               AD9833 等
  GP25                        板载 LED，500ms 翻转
```

- 不再输出 VGA，不再分配 38.4KB framebuffer。
- 不再枚举 USB HID/CDC；USB 口只用于供电和 BOOTSEL/UF2 烧录。
- 没有物理键盘/鼠标、没有拼音输入法、没有屏幕光标。
- SD 卡是固定功能，不提供无 SD 构建。
- 串口终端里的上/下方向键仍可用于命令历史（ANSI CSI）。

## 当前改动

- `src/main.c`
  - core0 只做 LED、UART 控制台、日志泵。
  - 移除 `video_init()`、`init_tryc()`、`init_console()`、`tusb_init()`、`tuh_task()`、`hid_app_task()`。
  - core1 只运行 `robot_core1()`。
- `src/console.c`
  - 重写为 UART0 行式控制台；没有 `wchar_t`、framebuffer、IME。
  - 命令前导 `/` 可写可不写；回车执行；退格编辑；Ctrl-C 发送停止。
  - 历史命令保存在 RAM，方向键通过 ANSI `ESC [ A/B` 回看。
  - core1 日志打印后自动重画当前输入行。
- `src/robot.c` / `include/robot.h`
  - P28 起 `/run` 后保持 active Lua state 和设备，支持串口 `/sql` 热补丁。
  - core1 16KB BSS 栈 + `multicore_launch_core1_with_stack()`。
  - 日志队列（core1 → core0），core0 统一写 UART。
  - Lua 5.1 单状态机；可选从 SD 读取 `/robot.lua`，失败则回退内嵌 smoke 脚本。
- `CMakeLists.txt`
  - 只编译 `main.c` / `console.c` / `robot.c`（以及可选的 SD 配置）。
  - 移除 TinyUSB host、PIO、DMA 视频、字体/图形/IME/tryC 源文件。
  - `PICO_CORE1_STACK_SIZE=0`（core1 栈改到 BSS），`PICO_STACK_SIZE=0x1000`（core0 4KB）。
  - `pico_enable_stdio_uart(firmware 1)`；`pico_enable_stdio_usb(firmware 0)`。
- 已删除的显示/交互组件：
  - `src/video.c`、`src/pio_video.pio`、`include/video.h`
  - `src/kbd.c`、`include/kbd.h`、`include/keymap.h`
  - `src/hid.c`、`include/tusb_config.h`
  - `src/graph/`、`include/graph.h`
  - `src/chsf*.c`、`src/chsf_trans/`、`src/cncc.c`、IME 头文件
  - `src/interpreter/`、`include/try.h`
- `third_party/lua/`
  - vendored Lua 5.1.5（MIT），不编译 `lua.c` / `luac.c` / `io` / `os` / `linit`。
  - `os.getenv`、`os.time`、`os.clock`、`print` 由 `robot.c` 提供最小实现。
- `third_party/fatfs/`
  - vendored no-OS-FatFS-SD-SPI-RPi-Pico 的 `FatFs_SPI`（Apache-2.0）。
  - 默认 SD 引脚 GP2/3/4/5，5MHz。

## 构建

```sh
cd /home/qing/pico-vga
cmake -S . -B build -G Ninja \
  -DPICO_SDK_PATH=/home/qing/pico/pico-sdk \
  -DPICO_NO_PICOTOOL=1
cmake --build build -j4
```

如果本机有 picotool，可以直接生成 UF2：

```sh
picotool uf2 convert build/firmware.elf build/firmware.uf2 --family rp2040
```

本机已构建出的尺寸（SD 固定开启）：

```text
text   data   bss
276768    0 134940
```

BSS 中主要是 16KB core1 栈、32KB Lua 源码加载缓冲、SQL/MT 解析缓冲和设备表；
VGA framebuffer（38.4KB）已不存在。仍然没有使用 malloc 分配核心运行时结构。

## UART 控制台

默认使用 Pico 的 UART0：

```text
TX GP0
RX GP1
115200 8N1
```

上电后串口输出类似：

```text
[console] mybot-lite headless (UART0)
[console] type /help for commands
[robot] core1: robot runtime started
[robot] SD: mounted 0:
...
[robot] core1: status idle active=1 devices=2 sql=/robots/p3.sql action=/scripts/p3.mt
>
```

命令按行输入，`/` 可写可不写：

```text
/run p4       运行 /robots/p4.sql + /scripts/p4.mt
/run p5c p5   用 /robots/p5c.sql + /scripts/p5.mt
/run          重新读 /profile.txt 并运行
/stop         停止当前运行
/status       查看 core1 状态
/profile      显示 /profile.txt
/mem          core1 栈高水位和上次 Lua 堆
/list         列出 /robots/*.sql
/sql name     对当前 active 结构应用 /sql/name.sql
/action name  在 active 结构上重播 /scripts/name.mt
/action       重播最近一次动作脚本
/repeat name [count] [delay_ms]  批量重播
/loop name period_ms             周期执行动作脚本
/loop stop                       停止周期循环
/reload       重读当前 SQL + 原始动作脚本
/use name     写入 /profile.txt（下次 /run 或开机）
/autostart name period_ms  写入 /boot.txt
/autostart off              禁用开机自动循环
/autostart                  查看当前开机配置
/devices      列出 active 设备
/device name  显示单个设备 meta/拓扑
/i2cscan [0|1] 扫描 I2C 总线 0x08..0x77
/vars         列出 active 变量/别名
/structs      列出 active @Struct 字段
/unload       销毁 active 设备并关闭 Lua
/help         显示命令摘要
↑ / ↓         命令历史（ANSI，最近 8 条）
Ctrl-C        发送停止请求
```

日志行统一带 `[robot]` 前缀；Lua 的 `print("...")` 也会经日志队列变成 `[robot] Lua: ...`。
如果输入过程中有日志到达，控制台会重画 `> ` 和当前半截命令。

### Lua 脚本输出示例

SD 根目录 `/robot.lua`：

```lua
print("hello from robot.lua")

function build(data)
    print("build called")
    return { result = "OK" }
end

function call(data)
    print("call called, delay=" .. tostring(data.delay or 0))
    return { result = "OK", delay = data.delay or 200 }
end

function destroy(data)
    print("destroy called")
    return { result = "OK" }
end
```

串口会看到类似：

```text
[robot] core1: robot runtime started
[robot] SD: loaded /robot.lua (... bytes)
[robot] Lua 5.1 state ready, heap=...KB
[robot] Lua: hello from robot.lua
[robot] Lua: build called
[robot] Lua: call called, delay=0
[robot] Lua: destroy called
[robot] Lua smoke OK, heap=...KB
[robot] core1: stack high-water ... / 16384 bytes
```

## P1-A/P1-B：从 SD 加载真实 Relay 驱动 + 每设备 env

`sdcard/` 目录已经放了一份可直接拷到 FAT 卡根目录的最小布局：

```text
sdcard/
  robot.lua
  modules/
    Relay.lua
    Echo.lua
    Timer.lua
    I2C.lua
    RefCheck.lua
    P3Check.lua
    PCA9685.lua
    ADS1015.lua
    SPI.lua
    UART.lua
    AD9833.lua
    UartCheck.lua
    Switch.lua
    Counter.lua
    P5Check.lua
    bitcompat.lua
    lib/
      HAL.lua
      drv_common.lua
      print_table.lua
  robots/
    relay-test.sql
    p2b.sql
    p3.sql
    p4.sql
    p5.sql
    p5b.sql
    p5c.sql
    p6.sql
    p7.sql
    p8.sql
    p9.sql
    p10.sql
    p12.sql
    p13.sql
    p14.sql
    p15.sql
    p16.sql
    p17.sql
    p19.sql
    p22.sql
    p23.sql
    p25.sql
    p27.sql
    p28.sql
    p33.sql
    p34.sql
    p39.sql
    p40.sql
    p41.sql
    p42.sql
    p43.sql
    p44.sql
    p45.sql
    p46.sql
    p47.sql
    p49.sql
    p50.sql
    pca9685.sql
    pca9685_fake.sql
    ads1015.sql
    spi_fake.sql
    spi.sql
    uart_fake.sql
    uart.sql
  scripts/
    relay-test.mt
    p2b.mt
    p3.mt
    p4.mt
    p5.mt
    p5b.mt
    p5c.mt
    p6.mt
    p7.mt
    p8.mt
    p9.mt
    p10.mt
    p12.mt
    p13.mt
    p14.mt
    p15.mt
    p16.mt
    p17.mt
    p19.mt
    p22.mt
    p23.mt
    p25.mt
    p27.mt
    p28.mt
    p29.mt
    p33.mt
    p34.mt
    p39.mt
    p40.mt
    p41.mt
    p42.mt
    p43.mt
    p44.mt
    p45.mt
    p46.mt
    p47.mt
    p48_self.mt
    p49.mt
    p50.mt
    parts/inc_p6.mt
    parts/merge_ca.mt
    parts/merge_cb.mt
    parts/merge_alias.mt
    parts/merge_39_a.mt
    parts/merge_39_b.mt
    parts/merge_39_c.mt
    parts/merge_39_d.mt
    parts/merge_41_a.mt
    parts/merge_41_b.mt
    parts/merge_49_leg.mt
    parts/level1.mt
    parts/level2.mt
    parts/inc_chain1.mt
    parts/inc_chain2.mt
    parts/inc_chain3.mt
    parts/inc_chain4.mt
    pca9685.mt
    ads1015.mt
    spi.mt
    uart.mt
  sql/
    p28_add.sql
    p28_del.sql
    p32_bad.sql
  boot.txt
  profile.txt
```

`robot.lua` 只做一件事：

```lua
print("P1: loading /modules/Relay.lua")
dofile("/modules/Relay.lua")
```

P1-B 在同一个 `lua_State` 里为每个驱动建立独立环境：

```text
env.__index = _G
env._G      = env
env.dofile  = 带 env 上值的闭包
env.loadfile= 带 env 上值的闭包
```

所以 `Relay.lua` 和 `Echo.lua` 可以同时存在，各自的
`build/call/destroy` 不会互相覆盖。

C 侧随后调用 `build` / `call` / `destroy`，其中 `call` 会传入
`test=200, note=hello`。P1 跑通后串口应出现：

```text
[robot] core1: robot runtime started
[robot] SD: mounted 0:
[robot] Lua 5.1 state ready, heap=...KB
[robot] Lua: P1: loading /modules/Relay.lua
[robot] Lua: Relay: test=200 note=hello -> delay=200
[robot] Lua robot env: OK
[robot] Lua: Echo: build
[robot] Lua: Echo: call test=200
[robot] Lua: Echo: destroy
[robot] Lua echo env: OK
[robot] Lua timer.call slept=200
[robot] Lua timer env: OK
[robot] Lua smoke OK, heap=...KB
```

P1-C 增加了最小 `HAL.lua` + 真实 `Timer.lua`：

- `Timer.lua` 从 SD 加载；
- `HAL.lua` 提供最小 Pico 后端；
- `milli_sleep(200)` 在 core1 分片睡眠；
- UART 控制台在 core0 继续响应；
- Timer 返回 `slept=200`。

这证明：

- Lua 5.1 能加载 mybot 的真实 `Relay.lua` / `Timer.lua`；
- `drv_common.lua` / `print_table.lua` 的 LuaJIT 5.1 语法兼容；
- `dofile` 已改走 FatFS，而不是 newlib `fopen`；
- 每设备 env 隔离生效，两个驱动可以同时存在；
- Lua 的 `print()` 能回到 core0 输出到 UART。

P2 已把运行期 SQL/MT 解析接进来，执行真实 `.sql` / `.mt`。

## P2-A/P2-B：运行期解析与 `$ref` / `@Alias` / `@Vars`

P2 不再依赖 P1 的硬编码三个 env。启动时优先尝试：

```text
/robots/p2b.sql
/scripts/p2b.mt
```

不存在时回退到：

```text
/robots/relay-test.sql
/scripts/relay-test.mt
```

P2 当前使用一个嵌入式精简解析器（不是把 mybot 的 SQLite / C++ 解析器整体搬过来），
覆盖下面的子集：

- `INSERT INTO table (col, ...) VALUES (...);`
- `/* ... */`、`--`、`#` 注释
- `@Action` 叶子块、列头 `device.param`、数据行
- 同设备多参数合并成一次 `call`
- 结构行的 `controller` 列转发
- 结构 `Vars` 表与 `$var` 元数据替换
- 结构 `Alias` 表与动作脚本内联 `@Alias`
- 动作脚本内联 `@Vars` 与 `$(name)` 值替换
- `$ref`：I2C/SPI/UART 总线行 -> 设备行的 fd/path/baud 字段合并

暂不支持：

- `@if` / `@while`
- `@Struct`
- 动态 SQL（DELETE/DROP/UPDATE）
- `@Include` / `@Merge`
- `@Daemon`

### P2-B 示例：fake I2C + `$ref` + alias + var

`/robots/p2b.sql`：

```sql
CREATE TABLE I2C (name String, path String);
INSERT INTO I2C (name, path) VALUES ('i2c-v', '/dev/i2c-fake');

CREATE TABLE Vars (name String, value Number);
INSERT INTO Vars (name, value) VALUES ('spd', 200);

CREATE TABLE RefCheck (name String, I2C String, address String, note String);
INSERT INTO RefCheck (name, I2C, address, note)
  VALUES ('rc0', '$i2c-v', '0x40', '$spd');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');
```

`/scripts/p2b.mt`：

```mt
@Alias
name  alias;
   A  angle;
@

@Vars
name  value;
   n  300;
@

@Action
rc0.A  rc0.n  t0.delay;
   45  $(n)      50;
@
```

预期串口：

```text
P2: using /robots/p2b.sql
P2: device i2c-v driver=I2C controller=-
P2: device rc0 driver=RefCheck controller=-
P2: device t0 driver=Timer controller=-
P2: parsed 3 device(s)
P2: i2c-v.build result=OK
P2: t0.build result=OK
P2: i2c-v.call result=OK
P2: $spd -> 200
P2: $i2c-v -> 1 field(s)
RefCheck: build fd=1 address=0x40 note=200
P2: rc0.build result=OK
P2: @Alias A -> angle
P2: @Vars n = 300
P2: @Action columns=3
RefCheck: call fd=1 angle=45 n=300
P2: rc0.call result=OK
P2: rc0 call ok
P2: t0.call result=OK slept=50
P2: t0 slept=50
P2: t0.destroy result=OK
RefCheck: destroy fd=1
P2: rc0.destroy result=OK
P2: i2c-v.destroy result=OK
P2: script run completed
Lua smoke OK, heap=...KB
```

这证明：

- `$i2c-v` 从 I2C 总线变量的 `call()` 结果里拿到了 `fd=1`；
- `$spd` 从结构 `Vars` 表替换成 `200`；
- 动作脚本 `@Alias A -> angle` 生效；
- 动作脚本 `@Vars n=300` 和 `$(n)` 生效；
- 同一行里的 RefCheck 和 Timer 都按各自 env 执行。

### P2-A Relay 示例

`/robots/relay-test.sql` + `/scripts/relay-test.mt` 仍可运行；输出见
`P2: relay0.call result=- delay=200`、`P2: controller timer-0 result=OK slept=200`。

## P3：真实 I2C HAL

P3 把 P2-B 的假 I2C 换成 Pico `hardware_i2c`：

| 路径 | 总线 | 引脚 |
|---|---|---|
| `/dev/i2c-0` | i2c0 | SDA GP6 / SCL GP7 |
| `/dev/i2c-1` | i2c1 | SDA GP14 / SCL GP15 |
| `/dev/i2c-fake` 或 `*virt*` | fake fd=2 | 无硬件，用于 P2-B 回归 |

外部需要 4.7k 上拉到 3.3V；内部 pull-up 只作辅助。当前速率 100kHz，单次事务超时 50ms。

Lua 侧保留 mybot 驱动使用的接口：

```text
i2c_open / i2c_close / i2c_set_addr
i2c_write_reg / i2c_read_reg
i2c_write_multi / i2c_read_multi / i2c_read_multi_bytes / i2c_read
i2c_probe / i2c_scan
```

### P3 自检脚本

`sdcard/robots/p3.sql`：

```sql
CREATE TABLE I2C (name String, path String);
INSERT INTO I2C (name, path) VALUES ('i2c-0', '/dev/i2c-0');

CREATE TABLE P3Check (name String, I2C String);
INSERT INTO P3Check (name, I2C) VALUES ('p3', '$i2c-0');
```

`sdcard/scripts/p3.mt`：

```mt
@Action
p3.scan;
   1;
@
```

P2 运行器现在按 `p3.sql` → `p2b.sql` → `relay-test.sql` 的顺序选择。

预期串口：

```text
P2: using /robots/p3.sql
P2: device i2c-0 driver=I2C controller=-
P2: device p3 driver=P3Check controller=-
P2: parsed 2 device(s)
I2C: opened /dev/i2c-0 (SDA GP6, SCL GP7)
P2: i2c-0.build result=OK
P2: i2c-0.call result=OK
P2: $i2c-0 -> 1 field(s)
P3Check: build fd=0
P2: p3.build result=OK
P2: @Action columns=1
P3Check: scan fd=0 found=0 []
P2: p3.call result=OK
P2: p3 call ok
P3Check: destroy fd=0
P2: p3.destroy result=OK
P2: i2c-0.destroy result=OK
P2: script run completed
```

如果总线上有 PCA9685（默认 0x40），会变成：

```text
P3Check: scan fd=0 found=1 [0x40]
```

没有外设时 `found=0` 是正常结果，说明总线打开和 probe 都完成了。

> P3 目前只实现 I2C；SPI/UART 仍是 P3 后续步骤。真实 I2C 事务失败会返回 `-1`/`nil`，不会伪装成成功。

## P3-B：PCA9685 / ADS1015 与 profile 选择

SD 根目录的 `/profile.txt` 决定运行哪组脚本：

```text
p3              -> /robots/p3.sql + /scripts/p3.mt
pca9685_fake    -> /robots/pca9685_fake.sql + /scripts/pca9685.mt
pca9685         -> /robots/pca9685.sql + /scripts/pca9685.mt（真实 PCA9685，0x40）
ads1015         -> /robots/ads1015.sql + /scripts/ads1015.mt（真实 ADS1015，0x48）
spi_fake        -> /robots/spi_fake.sql + /scripts/spi.mt
spi             -> /robots/spi.sql + /scripts/spi.mt（真实 AD9833）
uart_fake       -> /robots/uart_fake.sql + /scripts/uart.mt
uart            -> /robots/uart.sql + /scripts/uart.mt（真实 UART1）
p4              -> /robots/p4.sql + /scripts/p4.mt（@if/@while 控制流）
p5              -> /robots/p5.sql + /scripts/p5.mt（平坦 @Struct）
p5b             -> /robots/p5b.sql + /scripts/p5b.mt（嵌套对象/数组）
p5c             -> /robots/p5c.sql + /scripts/p5c.mt（@Struct 字段捕获）
p6              -> /robots/p6.sql + /scripts/p6.mt（@Include）
p7              -> /robots/p7.sql + /scripts/p7.mt（算术表达式）
p8              -> /robots/p8.sql + /scripts/p8.mt（字符串拼接）
p9              -> /robots/p9.sql + /scripts/p9.mt（@Merge 相位时间线）
p10             -> /robots/p10.sql + /scripts/p10.mt（trigger 前置调用）
p12             -> /robots/p12.sql + /scripts/p12.mt（@Merge 主动作对齐）
p13             -> /robots/p13.sql + /scripts/p13.mt（@Merge 别名/变量）
p14             -> /robots/p14.sql + /scripts/p14.mt（@Reflex/@Trigger）
p15             -> /robots/p15.sql + /scripts/p15.mt（named @Reflex）
p16             -> /robots/p16.sql + /scripts/p16.mt（reflex 递归防线）
p17             -> /robots/p17.sql + /scripts/p17.mt（动态数组下标）
p19             -> /robots/p19.sql + /scripts/p19.mt（嵌套 @Include）
p22             -> /robots/p22.sql + /scripts/p22.mt（条件解析 v2）
p23             -> /robots/p23.sql + /scripts/p23.mt（统一表达式引擎）
p25             -> /robots/p25.sql + /scripts/p25.mt（@SQL 热插拔 INSERT/DELETE）
p27             -> /robots/p27.sql + /scripts/p27.mt（@SQL UPDATE/DROP）
p28             -> /robots/p28.sql + /scripts/p28.mt（常驻状态 + /sql）
p29             -> /scripts/p29.mt（/action 重播测试，无独立 SQL）
p33             -> /robots/p33.sql + /scripts/p33.mt（@SQL 事务回滚）
p34             -> /robots/p34.sql + /scripts/p34.mt（设备列 @Alias）
p39             -> /robots/p39.sql + /scripts/p39.mt（@Merge 容量/相位）
p40             -> /robots/p40.sql + /scripts/p40.mt（@Action 行内 - 继承）
p41             -> /robots/p41.sql + /scripts/p41.mt（Reflex/Merge - 继承）
p42             -> /robots/p42.sql + /scripts/p42.mt（缺列按 - 补齐）
p43             -> /robots/p43.sql + /scripts/p43.mt（全 fake HAL 回归）
p44             -> /robots/p44.sql + /scripts/p44.mt（12 设备容量）
p45             -> /robots/p45.sql + /scripts/p45.mt（列头表达式）
p46             -> /robots/p46.sql + /scripts/p46.mt（列头按行重算）
p47             -> /robots/p47.sql + /scripts/p47.mt（递归 @Include）
p48_self        -> /scripts/p48_self.mt（顶层自包含负例）
p49             -> /robots/p49.sql + /scripts/p49.mt（@Merge 主从覆盖）
p50             -> /robots/p50.sql + /scripts/p50.mt（@Merge include-once）
p2b             -> /robots/p2b.sql + /scripts/p2b.mt
```

没有 `/profile.txt` 时按 `p3 -> p2b -> relay-test` 回退。

### PCA9685 无硬件冒烟

`/profile.txt` 写成：

```text
pca9685_fake
```

会走 `/dev/i2c-fake`，真实 `PCA9685.lua` 仍会执行寄存器写序列，但由假总线返回成功。串口应出现：

```text
P2: profile=pca9685_fake
P2: device i2c-f driver=I2C controller=-
P2: device pca-0 driver=PCA9685 controller=-
P2: device t0 driver=Timer controller=-
P2: i2c-f.build result=OK
P2: t0.build result=OK
P2: i2c-f.call result=OK
P2: $i2c-f -> 1 field(s)
P2: pca-0.build result=OK
P2: @Action columns=2
P2: pca-0 call ok
P2: t0.call result=OK slept=50
P2: t0 slept=50
...
```

### PCA9685 真实硬件

`/profile.txt` 写成：

```text
pca9685
```

接线：

```text
Pico GP6 -> PCA9685 SDA
Pico GP7 -> PCA9685 SCL
SDA/SCL 4.7k 上拉到 3.3V
GND 共地
PCA9685 VCC 按模块要求供电
地址默认 0x40
```

`/scripts/pca9685.mt` 会依次写 90/45/135/90 度，每步 Timer 50ms。

### ADS1015 真实硬件

`/profile.txt` 写成：

```text
ads1015
```

ADS1015 地址默认 `0x48`。`build` 会写配置并读回比对，因此**必须接真实器件**；没有器件时会在 build 阶段报 `ERR`，不会伪装成功。

> SPI/UART HAL 仍未实现；P3-B 目前只覆盖 I2C 器件。

## P3-C：SPI / UART HAL

### SPI1

| 信号 | 引脚 |
|---|---|
| SCK | GP10 |
| MOSI | GP11 |
| MISO | GP12 |
| CS | GP13 |

路径：

```text
/dev/spidev1.0 -> SPI1
/dev/spidev-fake -> fake fd=2
```

Lua 接口沿用 mybot 驱动：

```text
spi_open / spi_close / spi_setup
spi_write / spi_write3 / spi_write_multi
spi_read / spi_read_multi / spi_xfer_full
```

`AD9833.lua` 使用 SPI 模式 2、8 位、1MHz，通过 `/profile.txt` 选择：

```text
spi_fake    -> /dev/spidev-fake，无硬件冒烟
spi         -> /dev/spidev1.0，真实 AD9833
```

`/scripts/spi.mt`：

```mt
@Action
sig0.freq;
     2000;
@
```

### UART1

| 信号 | 引脚 |
|---|---|
| TX | GP8 |
| RX | GP9 |

路径：

```text
/dev/ttyS1 或 /dev/ttyAMA1 -> UART1
/dev/tty-fake -> fake fd=2
```

Lua 接口：

```text
uart_open / uart_close / uart_write / uart_read / uart_flush
```

profile：

```text
uart_fake   -> /dev/tty-fake，无硬件冒烟
uart        -> /dev/ttyS1，真实串口
```

`UartCheck` 会写 `0x41 0x42`，然后最多读 4 字节。fake 模式预期：

```text
UartCheck: build fd=2 baud=115200
UartCheck: write=2 read=4 [00,00,00,00]
```

真实 UART 需要外部回环或目标设备；否则 read 超时返回空，不会伪装成收到数据。

### 当前 P3-C 限制

- SPI 目前只映射 SPI1；SPI0 被 SD 卡占用。
- CS 固定 GP13，单设备。
- UART 固定 8N1，无流控。
- SPI/UART 的真实器件验证仍需要上板。

## P4：@if / @while 控制流

P4-A 在精简 MT 解析器里加入块级控制流：

```mt
@Vars
name  value;
 count  0;
@

@while(count<3)
cnt.reading;
 $count=reading;
@

@if(count>0)
cnt.flag;
   1;
@
```

支持：

- `@if(cond)` / `@while(cond)`
- 数值/字符串比较：`== != < > <= >=`
- `&&` / `||`
- `@Vars` 变量作为条件
- 动作格捕获 `$var=field`，把驱动返回字段写回 `@Vars`
- 控制块内直接动作行
- 控制块嵌套
- 循环上限 1000 次，且每轮检查 stop

测试 profile：

```text
p4
```

`p4.sql` 只有一个 `Counter`；`p4.mt` 会：

1. `count=0`
2. `@while(count<3)` 调 `cnt.reading` 三次，每次捕获 `count=reading`
3. `@if(count>0)` 再调一次 `cnt.flag`

预期串口：

```text
P2: profile=p4
P2: device cnt driver=Counter controller=-
P2: cnt.build result=OK
P2: @Vars count = 0
Counter: reading=1
P2: capture count=1
Counter: reading=2
P2: capture count=2
Counter: reading=3
P2: capture count=3
P2: [while] count<3 -> 3 iteration(s)
Counter: reading=4
P2: cnt.call result=OK
```

当前限制：

- 条件解析器只覆盖简单比较/逻辑，不是完整 mybot 表达式 AST
- 不支持括号嵌套表达式
- 不支持 `@Struct` / `@Include` / `@Merge`
- `@if`/`@while` 的条件错误目前是日志 + 跳过，不是完整异常契约

## P4-B：命令系统与热重载

core0 的 UART0 控制台提供行式命令；`/` 可写可不写：

```text
/run p4       运行 /robots/p4.sql + /scripts/p4.mt
/run p5c p5   用 /robots/p5c.sql + /scripts/p5.mt
/run          重新读 /profile.txt 并运行
/stop         停止当前运行
/status       查看 core1 状态
/profile      显示 /profile.txt
/mem          core1 栈高水位和上次 Lua 堆
/list         列出 /robots/*.sql
/sql name     对当前 active 结构应用 /sql/name.sql
/action name  在 active 结构上重播 /scripts/name.mt
/action       重播最近一次动作脚本
/repeat name [count] [delay_ms]  批量重播
/loop name period_ms             周期执行动作脚本
/loop stop                       停止周期循环
/reload       重读当前 SQL + 原始动作脚本
/use name     写入 /profile.txt（下次 /run 或开机）
/autostart name period_ms  写入 /boot.txt
/autostart off              禁用开机自动循环
/autostart                  查看当前开机配置
/devices      列出 active 设备
/device name  显示单个设备 meta/拓扑
/i2cscan [0|1] 扫描 I2C 总线 0x08..0x77
/vars         列出 active 变量/别名
/structs      列出 active @Struct 字段
/unload       销毁 active 设备并关闭 Lua
/help         显示命令摘要
↑ / ↓         命令历史（ANSI，最近 8 条）
Ctrl-C        发送停止请求
```

`/run` 的完整流程：

```text
停止当前动作（stop 标志）
  → 重新挂载/读取 SD
  → 重新读 profile / SQL / MT
  → 重新创建 Lua state 和每个设备 env
  → 执行脚本
  → 返回 active idle（设备保持，等待 /sql 或下一条命令）
```

所以改完 SD 上的 `.sql`/`.mt` 后，不需要重新烧固件，输入 `/run` 即可热重载。

保留几个 profile 简称：

```text
/run pca       -> pca9685
/run pcafake   -> pca9685_fake
/run ads       -> ads1015
/run spifake   -> spi_fake
/run uartfake  -> uart_fake
/run relay     -> relay-test
```

命令反馈会通过 UART 日志返回，例如：

```text
[robot] core1: run sql=p4 script=(same)
...
[robot] core1: run finished, profile active
[robot] core1: status idle active=1 devices=1 sql=/robots/p4.sql action=/scripts/p4.mt
[robot] core1: /profile.txt = p4
[robot] core1: mem stack=.../16384 heap_last=...KB busy=0 stop=0
[robot] core1: profile p4.sql
[robot] core1: profile p9.sql
[robot] core1: 2 profile(s)
```

`/stop` 立即置 stop 标志；`@while`、`milli_sleep` 和动作派发行会在各自的检查点看到它。长时间阻塞在器件驱动内部的 I2C/SPI/UART 调用只能等超时。

## P5：@Struct

新增 `@Struct(name)` JSON 对象支持（平坦对象 + 嵌套对象/数组）。

```mt
@Struct(cfg)
{ "value": 7, "name": "pico" }
@

@Action
p5.value  p5.name;
 $(cfg.value) $(cfg.name);
@

@if(cfg.value>0)
p5.ok;
   1;
@
```

嵌套/数组示例（profile `p5b`）：

```mt
@Struct(cfg)
{
  "value": 7,
  "inner": { "name": "pico" },
  "items": [10, 20]
}
@

@Action
p5b.value  p5b.name  p5b.item;
 $(cfg.value) $(cfg.inner.name) $(cfg.items[1]);
@
```

已实现：

- `@Struct(name)` 块
- 字符串、数字、布尔/null 文本
- 嵌套对象：`cfg.inner.name`
- 数组下标：`cfg.items[1]`
- `$(cfg.field)` 动作值替换
- `cfg.field` 条件表达式
- struct 只在当前 MT 运行内有效

限制：

- JSON 解析器是精简实现，不支持非常复杂的转义/深度
- 数组只支持固定下标，不支持表达式下标

测试 profile：

```text
p5
```

预期串口：

```text
P2: profile=p5
P2: @Struct cfg.value = 7
P2: @Struct cfg.name = pico
P2: device p5 driver=P5Check controller=-
P2: p5.build result=OK
P2: @Action columns=2
P5Check: call value=7 name=pico
P2: p5.call result=OK
P2: p5 call ok
P5Check: call value=nil name=p5
P2: p5.call result=OK
P2: p5 call ok
...
```

嵌套/数组版 `p5b` 的关键输出：

```text
P2: @Struct cfg.value = 7
P2: @Struct cfg.inner.name = pico
P2: @Struct cfg.items[0] = 10
P2: @Struct cfg.items[1] = 20
P5Check: call value=7 name=pico item=20
```

### @Struct 字段捕获

profile `p5c`：

```mt
@Struct(cfg)
{ "value": 0 }
@

@Action
cnt.reading;
 $cfg.value=reading;
@

@Action
p5.value;
 $(cfg.value);
@
```

`Counter` 返回 `reading=1`，捕获写回 `cfg.value`，后续动作读到 `$(cfg.value)=1`。

预期关键输出：

```text
P2: capture cfg.value=1
P5Check: call value=1 name=p5 item=nil
```

## P6：@Include 脚本片段

P6-A 支持顶层 `@Include`：

```mt
@Struct(cfg)
{ "value": 9 }
@

@Include
path;
  parts/inc_p6.mt;
@
```

`/scripts/parts/inc_p6.mt`：

```mt
@Action
p6.value;
 $(cfg.value);
@
```

行为：

- 在解析前把被包含文件的内容拼到 `@Include` 位置
- 路径相对 `/scripts/`，也接受 `/scripts/...` 绝对路径
- 支持多个文件
- 支持 `@Struct` / `@Action` / `@if` / `@while` 等既有语法
- P19 支持两层；P47 起递归深度提升到 4 层并带循环检测

`@Merge` 目前不支持，会明确输出：

```text
P2: @Merge unsupported; use @Include
```

测试 profile：

```text
p6
```

预期关键输出：

```text
P2: profile=p6
P2: @Include merged 1 file(s)
P2: @Struct cfg.value = 9
P2: device p6 driver=P5Check controller=-
P5Check: call value=9 name=p6 item=nil
```

## P7：算术表达式

P7-A 给 `$(...)` 和条件加入数值表达式：

```mt
@Struct(cfg)
{ "value": 7 }
@

@Vars
name  value;
 count  2;
@

@Action
p7.value  p7.item;
 $(cfg.value*count+1) $(cfg.value+1);
@

@if((count+2)*2==8)
p7.ok;
   1;
@
```

支持：

- `+`、`-`、`*`、`/`、`%`
- 括号
- 一元 `+` / `-`
- 变量、struct 字段、数组下标作为操作数
- 比较 `==`、`!=`、`<`、`>`、`<=`、`>=`
- `&&` / `||`

示例结果：

```text
$(cfg.value*count+1) = 15
$(cfg.value+1)       = 8
(count+2)*2==8       = true
```

测试 profile：

```text
p7
```

预期串口：

```text
P2: profile=p7
P2: @Struct cfg.value = 7
P2: @Vars count = 2
P5Check: call value=15 name=p7 item=8
P2: p7.call result=OK
P5Check: call value=nil name=p7 item=nil
P2: p7 call ok
...
```

当前限制：

- 字符串拼接 `+` 尚未实现
- 表达式仍是精简 AST，不是完整 mybot 表达式
- 逻辑运算符对括号内的 `&&`/`||` 支持有限

## P8：字符串拼接

P8-A 在 `$(...)` 和条件里支持 `+` 字符串拼接：

```mt
@Struct(cfg)
{ "value": 7, "name": "pico" }
@

@Vars
name  value;
 count  2;
@

@Action
p8.name  p8.value;
 $(cfg.name + "-" + count) $(count + 1);
@

@if((cfg.name + "-x") == "pico-x")
p8.ok;
   1;
@
```

结果：

```text
$(cfg.name + "-" + count) = pico-2
$(count + 1)               = 3
(cfg.name + "-x") == "pico-x" = true
```

测试 profile：

```text
p8
```

预期串口：

```text
P2: profile=p8
P2: @Struct cfg.name = pico
P2: @Vars count = 2
P5Check: call value=3 name=pico-2 item=nil
...
P5Check: call value=nil name=p8 item=nil
```

当前限制：

- 字符串拼接只支持 `+`
- 字符串比较仍是精确文本比较
- 完整 mybot 表达式 AST 仍未实现

## P9：@Merge 相位时间线

P9-A 支持一个简化版 `@Merge`：

```mt
@Merge
path phase;
  parts/merge_ca.mt 1;
  parts/merge_cb.mt 2;
@
```

`parts/merge_ca.mt`：

```mt
@Action
ca.reading;
  1;
  2;
@
```

`parts/merge_cb.mt`：

```mt
@Action
cb.reading;
  1;
  2;
  3;
@
```

行为：

- 每个片段必须是单个 `@Action`
- `phase` 表示该片段从第几拍开始
- 多个片段按拍合成一次 `call`
- 片段耗尽后保持最后一行（类似姿势保持）
- 设备集最好不相交；重复设备会按现有 `p2_execute_row` 规则合并
- 最多 3 个源（含主脚本）、每源 4 行、每源最多 6 列

预期时间线：

```text
beat 0: 无
beat 1: ca=1
beat 2: ca=2, cb=1
beat 3: ca=2(保持), cb=2
beat 4: ca=2(保持), cb=3
```

测试 profile：

```text
p9
```

预期关键输出：

```text
P2: @Merge /scripts/parts/merge_ca.mt phase=1 rows=2
P2: @Merge /scripts/parts/merge_cb.mt phase=2 rows=3
Counter: reading=1
Counter: reading=2
Counter: reading=1
...
P2: @Merge timeline 5 beat(s)
```

限制：

- 主脚本自己的 `@Action` 不与片段做相位合并
- 片段里不支持 `@Alias`/`@Vars`/`@if`/`@while`
- 不校验设备集是否相交
- 不是完整 mybot `mtmerge` 语义

## P12：@Merge 主脚本动作对齐

P12-A 把 `@Merge` 后面的第一张主脚本 `@Action` 也加入同一条相位时间线：

```mt
@Merge
path phase;
  parts/merge_ca.mt 1;
  parts/merge_cb.mt 2;
@

@Action
t0.delay;
   10;
   10;
@
```

行为：

- 主脚本的 `@Action` 视为 phase=0 的第三个源
- 片段耗尽的源保持最后一行
- `@Merge` 展开完成后，原主脚本 `@Action` 块被跳过，避免重复执行
- 主脚本动作和片段动作在同一拍内一起派发

测试 profile：

```text
p12
```

预期关键输出：

```text
P2: @Merge /scripts/parts/merge_ca.mt phase=1 rows=2
P2: @Merge /scripts/parts/merge_cb.mt phase=2 rows=3
P2: @Merge main action rows=2
...
P2: @Merge timeline 5 beat(s)
```

限制：

- 只对齐 `@Merge` 后面的第一张 `@Action`
- `@Action` 必须在 `@Merge` 之后
- 片段仍只支持单个 `@Action`
- 设备集、别名、变量覆盖的完整 mtmerge 语义仍未实现

## P13：@Merge 片段别名/变量与设备集校验

P13-A 让 `@Merge` 片段携带 `@Alias` / `@Vars`：

```mt
# parts/merge_alias.mt
@Alias
name  alias;
   A  angle;
@

@Vars
name  value;
   n  200;
@

@Action
p13.A;
 $(n);
@
```

主脚本：

```mt
@Merge
path phase;
  parts/merge_alias.mt 0;
@
```

行为：

- 片段里的 `@Alias` / `@Vars` 会加入当前运行会话
- 片段动作头 `p13.A` 解析为 `p13.angle`
- `$(n)` 解析为 `200`
- `@Merge` 前会检查设备集是否相交；相交直接拒绝整次归并

测试 profile：

```text
p13
```

预期关键输出：

```text
P2: @Merge /scripts/parts/merge_alias.mt phase=0 rows=1
P5Check: call value=nil name=p13 item=nil angle=200
P2: p13.call result=OK
P2: @Merge timeline 1 beat(s)
```

当前限制：

- 片段里的 `@Alias` / `@Vars` 没有独立作用域，会影响整个运行会话
- 片段仍只支持单个 `@Action`
- 主脚本的别名/变量仍必须在 `@Merge` 之前定义
- 设备集相交会拒绝，但不会尝试自动拆分

## P10：trigger 前置调用

P10-A 支持结构表里的 `trigger` / `triggerN` 列：

```sql
CREATE TABLE Relay (
    name       String,
    controller String,
    trigger    String,
    note       String,
    test       String
);
INSERT INTO Relay (name, controller, trigger, note, test)
  VALUES ('relay-src', '-', '-', 'src', '300');
INSERT INTO Relay (name, controller, trigger, note, test)
  VALUES ('relay-sink', 'timer-0', 'relay-src', 'sink', '-');
```

动作：

```mt
@Action
relay-sink.junk;
      1;
@
```

执行顺序：

```text
relay-sink build
  → trigger relay-src.call()
  → relay-sink.call()
  → controller timer-0.call()
```

测试 profile：

```text
p10
```

预期关键输出：

```text
P2: device relay-sink driver=Relay controller=timer-0 triggers=1
P2: trigger relay-src before relay-sink
Relay: test=300 note=src -> delay=300
P2: relay-src.call result=- delay=300
Relay: test=- note=sink -> delay=0
...
P2: controller timer-0 result=OK slept=0
```

限制：

- trigger 只执行前置调用，返回字段目前不合并成嵌套表
- 最多 2 个 trigger 列
- trigger 目标必须先声明
- 还没有 trigger 递归深度防线

## P11：内存收敛

P11-A 把静态 BSS 从约 166KB 降到约 138KB：

- Lua 源码缓冲从 32KB 降到 24KB（当前最大 `ADS1015.lua` 约 23KB）
- `@Include` 不再单独保留 work/file 缓冲，复用 `p2_sql_buf`
- `@Merge` 上限收紧为 2 个片段、每片段 4 行、6 列
- 原有 `p2_expanded_buf` 保留，用于文本展开

结果：

```text
text    data   bss
879924     0 138456
```

headless：

```text
text    data   bss
269364     0 102056
```

代价：

- 单个 Lua 驱动源码必须小于 24KB
- `@Merge` 片段数量/行数/列数上限变小
- `/mem` 仍然推荐在真实 profile 跑完后检查 core1 栈和 Lua 堆

## P14：@Reflex / @Trigger

P14-A 支持普通 `@Reflex` 和 `@Trigger`：

```mt
@Reflex
name  p14.value;
blink $(v);
@

@Trigger
trigger;
blink(v=42);
@
```

行为：

- `@Reflex` 第一列是 `name`，后面是动作列
- 同名多行会作为同一个反射的多拍
- `@Trigger` 每行触发一个反射
- `blink(v=42)` 把 `v=42` 临时注入会话变量
- 反射执行完后恢复同名变量；原先不存在则删除
- 支持 `$(param)` 在反射动作里取值

测试 profile：

```text
p14
```

预期关键输出：

```text
P2: @Reflex parsed
P2: @Trigger blink
P5Check: call value=42 name=p14 item=nil angle=nil
P2: p14.call result=OK
P2: p14 call ok
```

当前限制：

- 只支持普通 `@Reflex`，命名 `@Reflex(name)` 会明确报 unsupported
- P16 起有反射递归防线
- 触发器参数只支持简单 `k=v`
- `@Reflex` 只能出现在顶层
- `@Trigger` 目前只做同步调用

## P15：named @Reflex

P15-A 支持命名反射：

```mt
@Reflex(echo)
p15.value;
$(v);
@

@Action
echo.v;
   5;
@
```

行为：

- `@Reflex(echo)` 定义一个名为 `echo` 的反射
- 反射体本身是一个动作网格
- 在 `@Action` 里用 `echo.<param>` 调用它
- 参数 `v=5` 临时注入反射体
- 反射体里的 `$(v)` 读到 `5`
- 调用结束后恢复/删除临时变量
- 外层 `p2_action_cols` 在反射调用后恢复，避免污染当前行

测试 profile：

```text
p15
```

预期关键输出：

```text
P2: named @Reflex echo parsed
P2: named reflex echo
P5Check: call value=5 name=p15 item=nil angle=nil
P2: p15.call result=OK
```

限制：

- P16 起有反射递归/深度防线
- `@Reflex(name)` 只能出现在顶层
- 反射参数只支持简单标量文本

## P16：反射递归防线

P16-A 给 named `@Reflex` 和 `@Trigger` 加上递归/深度防线：

- 同一个反射在调用栈里再次出现 → 拒绝
- 总深度超过 8 → 拒绝
- 拒绝时输出诊断，不执行反射体，不会栈溢出

测试：

```mt
@Reflex(loop)
p16.value;
$(v);
loop.v;
@

@Action
loop.v;
   1;
@
```

`loop` 反射执行一次 `p16.value`，然后尝试递归调用 `loop`；第二次进入被拦截。

测试 profile：

```text
p16
```

预期关键输出：

```text
P2: named @Reflex loop parsed
P2: named reflex loop
P5Check: call value=1 name=p16 item=nil angle=nil
P2: reflex recursion blocked: loop
```

当前限制：

- 深度限制是固定的 8
- 只拦截同一个反射对象；不同反射的互相调用由深度上限兜底
- 被拦截后当前反射继续正常返回，不会作为 ERR 中止整个脚本

## P17：动态数组下标

P17-A 支持 `@Struct` 数组用表达式下标：

```mt
@Struct(cfg)
{ "items": [10, 20, 30] }
@

@Vars
name  value;
 idx  1;
@

@Action
p17.value  p17.item;
 $(cfg.items[idx]) $(cfg.items[idx+1]);
@

@if(cfg.items[idx] > 10)
p17.ok;
   1;
@
```

结果：

```text
cfg.items[idx]   = 20
cfg.items[idx+1] = 30
cfg.items[idx] > 10 = true
```

实现方式：

- 查找字段 `items[expr]`
- 用表达式解析器求 `expr`
- 拼成 `items[1]` 再到 struct 字段里查

测试 profile：

```text
p17
```

预期关键输出：

```text
P5Check: call value=20 name=p17 item=30 angle=nil
P2: p17.call result=OK
P2: p17 call ok
```

限制：

- 下标必须是数值表达式
- 越界会落到 unresolved/空值，不会自动扩展数组
- 只支持一维数组

## P18：命令 UX

P18-A 增加两个控制台命令：

```text
/list    列出 /robots/*.sql
/help    显示命令摘要
```

`/list` 由 core1 通过 FatFS 扫描 `/robots`，最多显示 16 个：

```text
[robot] core1: profile p4.sql
[robot] core1: profile p9.sql
[robot] core1: profile p17.sql
[robot] core1: 3 profile(s)
```

`/help` 直接在 core0 通过 UART 显示：

```text
run [sql] [script] | sql <name> | action [name] | repeat <name> [count] [delay_ms]
loop <name> <period_ms> | loop stop | reload | stop | status | profile | mem | list
use <profile> | autostart <action> <period_ms> | autostart off | autostart
devices | device <name> | i2cscan [0|1] | vars | structs | unload | help
history: terminal up/down (ANSI)
```

当前命令集：

```text
/run [sql] [script]
/stop
/status
/profile
/mem
/list
/sql <name>
/action [name]
/repeat <name> [count] [delay_ms]
/loop <name> <period_ms>
/loop stop
/reload
/use <profile>
/autostart <action> <period_ms>
/autostart off
/autostart
/devices
/device <name>
/i2cscan [0|1]
/vars
/structs
/unload
/help
```

命令按行输入，`/` 可写可不写；Ctrl-C 也可以发送停止请求。

## P19：嵌套 @Include

P19-A 把 `@Include` 扩展到两层：

```mt
# p19.mt
@Struct(cfg)
{ "value": 7 }
@

@Include
path;
  parts/level1.mt;
@
```

```mt
# parts/level1.mt
@Include
path;
  parts/level2.mt;
@
```

```mt
# parts/level2.mt
@Action
p19.value;
 $(cfg.value);
@
```

行为：

- 顶层 `@Include` 读取一级文件
- 一级文件里的 `@Include` 读取二级文件
- 二级文件内容直接拼入，不再继续递归
- 结果与手写展开后的脚本一致

测试 profile：

```text
p19
```

预期关键输出：

```text
P2: @Include merged 2 file(s)
P5Check: call value=7 name=p19 item=nil angle=nil
P2: p19.call result=OK
```

## P20：SQL 与动作脚本分离选择

P20-A 允许 `/run` 同时指定结构 SQL 和动作脚本：

```text
/run p5c p5
```

表示：

```text
结构: /robots/p5c.sql
动作: /scripts/p5.mt
```

用途：

- 同一个动作脚本可以复用不同结构
- 同一个结构可以跑不同动作脚本
- 不需要复制 profile 文件

示例 `p5c.sql + p5.mt`：

```text
P5Check: call value=7 name=pico item=nil angle=nil
P5Check: call value=nil name=p5 item=nil angle=nil
```

`/run p5` 仍然表示 SQL 和动作都用 `p5`。

协议：

- `ROBOT_CMD_RUN.arg = "<sql> <script>"`
- core1 按第一个空格切分
- 空脚本回退到 SQL 同名脚本

## P21：命令历史

P21-A 给串口控制台加上历史：

- 刚才执行过的命令自动进入历史
- `↑` 回看更早的命令
- `↓` 回到更新的命令，越过最新一条时清空输入
- 最多保留 8 条
- 连续重复的命令只保留一条
- 历史只在串口控制台内生效，不影响机器人脚本

实现：

- UART 接收 `ESC [ A` / `ESC [ B`（终端方向键）并转成历史操作
- 历史缓冲区保存去掉行首可选 `/` 后的整行命令（含参数）
- 回看时用 ANSI `\r\x1b[2K` 清行并重画 `> ` 提示符
- 回到最新条目后恢复空白命令输入
- 其他 CSI 序列整段丢弃，不会混入命令文本

测试：

```text
/run p17
/list
↑
↑
↓
```

预期：

- 第一次 `↑` 显示 `> /list`
- 第二次 `↑` 显示 `> /run p17`
- `↓` 回到 `> /list`
- 再 `↓` 清空当前输入

当前限制：

- 只在 RAM 中保存，重启后丢失
- 只支持上/下，不支持搜索
- 回看时当前未提交的半截输入会被覆盖

## P22：条件解析 v2

P22-A 把 `@if` / `@while` 的条件求值换成递归下降解析器，优先级同 C：

```text
一元 ! + -
  > * / %
  > + -
  > 比较 > == !=
  > &&
  > ||
```

支持：

- 括号分组：`(a == 1 || b == 2) && c > 0`
- 一元逻辑非：`!(count == 2)`
- 一元正负：`-3 + 5 == 2`
- `&&` / `||` 短路：被短路的一侧只做语法扫描，不查变量、不做除零
- 字符串里的 `&&` / `||` 不再被误当运算符
- 布尔字面量 `true` / `false`
- 字符串转义：`\n`、`\t`、`\"`、`\\`
- 标识符带表达式下标：`cfg.items[idx+1]`

示例：

```mt
@if((cfg.items[idx] == 20 && !(cfg.items[idx] > 25)) || cfg.name == "a && b")
p22.value;
  $(cfg.items[idx+1]);
@

@if(-3 + 5 == 2 && cfg.name == "pico-x")
p22.item;
  11;
@

@if((1 == 2 && missing > 0) || cfg.name == "pico-x")
p22.name;
  7;
@

@while((count < 3) && !(count == 2))
cnt.reading;
 $count=reading;
@

@if((count == 2) || (count > 5))
p22.angle;
  45;
@
```

测试 profile：

```text
p22
```

预期关键输出：

```text
P5Check: call value=30 name=p22 item=nil angle=nil
P5Check: call value=nil name=p22 item=11 angle=nil
P5Check: call value=nil name=7 item=nil angle=nil
Counter: reading=1
Counter: reading=2
P2: [while] (count < 3) && !(count == 2) -> 2 iteration(s)
P5Check: call value=nil name=p22 item=nil angle=45
P2: p22.call result=OK
```

兼容策略：

- 裸值仍按旧规则取真值（数值非零、文本非空）
- `+` 在两个数值上是加法，否则是文本拼接
- 排序比较两边都是数值时按数值，否则按文本
- `==` / `!=` 数值比数值、布尔比布尔，其余按文本

限制：

- 还不是 mybot 的完整表达式 AST
- 没有函数调用、成员函数、类型系统
- `@if` / `@while` 条件里的空格仍依赖本实现，不保证与 mybot 块头词法完全一致
- 布尔值只在条件语境使用，`$(...)` 文本/数值路径仍不接受布尔

## P23：统一表达式引擎

P23-A 把 `$(...)` 的数值/文本求值也切到 P22 的值解析器，删除旧的
`p2_expr_*` 双份实现：

- 条件与数据格共用同一套词法/优先级/括号/字符串规则
- `$(...)` 支持括号、一元正负、字符串拼接
- 数组下标表达式在数值语境也能直接求值：`cfg.items[idx+1] > 25`
- 布尔结果只允许出现在 `@if` / `@while`，`$(...)` 遇到布尔会拒值
- 旧解析器删除后 flash 减少约 1.2KB

示例：

```mt
@Action
p23.value              p23.item               p23.name          p23.angle;
 $(cfg.items[idx+1]+1) $((cfg.items[idx]+5)*2) $(cfg.name+"-x") $(-3+5);
@

@if(cfg.items[idx+1] > 25 && (cfg.items[idx]*2 == 40) && !(1==2))
p23.value;
  99;
@
```

结果：

```text
value = 31
item  = 50
name  = pico-x
angle = 2
```

测试 profile：

```text
p23
```

预期关键输出：

```text
P5Check: call value=31 name=pico-x item=50 angle=2
P5Check: call value=99 name=p23 item=nil angle=nil
P2: p23.call result=OK
```

限制：

- 文本值缓冲仍是 32 字节，拼接结果超过 31 字节会截断
- 没有函数调用、数组字面量、成员方法
- 布尔值仍只服务条件语境
- 数值是 double，`%` 先截断成 `long long`

## P24：移除 VGA / 键鼠，改为 headless

P24-A 是一次结构性裁剪，不再保留 VGA 版本：

- 删除 VGA/PIO/DMA 视频输出和 38.4KB framebuffer
- 删除 USB HID host：键盘、鼠标、HID 报告解析
- 删除 VGA console、framebuffer 光标、中文输入法、字体/绘图代码
- 删除 tryC 交互解释器（原控制台 shell）
- 删除 TinyUSB host 链接和 `tusb_config.h`
- 删除 `USE_VGA` / `USE_VGA_RES` / `VIDEO_PIN` 构建选项

替代接口：

```text
UART0 GP0 TX / GP1 RX
115200 8N1
```

上电后直接进入行式命令控制台：

```text
/run p22
/run p23
/list
/status
Ctrl-C
```

行为变化：

- 命令不再需要先按 `/` 进入命令模式；每行都是命令，前导 `/` 可选
- 没有 VGA 屏幕，日志和命令反馈都在同一个 UART
- 没有物理键盘/鼠标；串口终端的方向键通过 ANSI CSI 提供历史
- 日志到达时会重画 `> ` 和当前输入，避免半截命令被覆盖
- `Ctrl-C` 直接发送停止请求，替代原来的 Tab 停止键

尺寸变化（SD 固定开启）：

```text
                  text     data      bss
VGA 版本        894804        0   153500
headless 版本   254944        0    99888
```

减少的主要来源：

- VGA framebuffer：约 38.4KB BSS
- 字体/图形/IME/tryC/键鼠代码：约 640KB flash
- 命令历史从 `wchar_t` 改为 `char`：约 0.75KB BSS

限制：

- 没有屏幕，必须接 UART0 才能看到日志和输入命令
- USB 口不再提供 CDC，不能当作串口终端使用
- 串口输入是行式编辑，不支持左右移动光标或行内编辑
- 命令历史依赖终端发送 ANSI 方向键；纯文本终端只能重输命令
- 控制台与机器人日志共用 UART，运行期日志较多时输入可能被重画打断

## P25：@SQL 运行期热插拔

P25-A 增加 `@SQL` 块。动作脚本执行到该位置时，直接对当前设备表做增量变更：

```mt
@Action
cold.value;
   1;
@

@SQL
INSERT INTO P5Check (name, value) VALUES ('hot', '99');
@

@Action
hot.value;
   2;
@

@SQL
DELETE FROM P5Check WHERE name='hot';
@

@Action
cold.value;
   3;
@
```

行为：

- `INSERT INTO ...`：解析后追加设备，立即 `build`
- `build` 失败会回滚刚插入的设备，不影响已有设备
- `DELETE FROM 表 [WHERE name='x']`：逆序 `destroy` 并摘除匹配行
- 不带 `WHERE` 表示删除该表全部行
- 删除前检查 `controller` / `trigger` / 未解析 `$ref`，仍被引用的设备拒绝删除
- SQL 文本复用 `p2_sql_buf`（12KB），不新增 BSS
- `@SQL` 可以出现在顶层，也可以在 `@if` / `@while` 体内

测试 profile：

```text
p25
```

预期关键日志：

```text
P2: device cold driver=P5Check controller=- triggers=0
P5Check: build value=1 name=cold item=nil angle=nil
P2: cold.build result=OK
P5Check: call value=1 name=cold item=nil angle=nil
P2: cold.call result=OK
P25: @SQL block ... bytes
P2: device hot driver=P5Check controller=- triggers=0
P25: hot insert hot driver=P5Check
P5Check: build value=99 name=hot item=nil angle=nil
P2: hot.build result=OK
P5Check: call value=2 name=hot item=nil angle=nil
P2: hot.call result=OK
P25: @SQL block ... bytes
P25: hot remove hot driver=P5Check
Lua: P5Check: destroy
P2: hot.destroy result=OK
P25: DELETE P5Check name=hot -> 1 removed, 0 blocked
P5Check: call value=3 name=cold item=nil angle=nil
P2: cold.call result=OK
P2: profile active, devices=1 heap=...KB
```

限制：

- P25 只覆盖 `INSERT INTO` / `DELETE FROM`；`UPDATE` / `DROP` 见 P27
- `DELETE ... WHERE` 只支持 `name = '...'`，不支持 `AND` / `OR`
- 已解析的总线 `$ref` 会变成 fd/path 文本，删除总线时无法自动识别所有依赖；不要热删仍被使用的 I2C/SPI/UART 总线
- SQL 值里的 `)` 仍会截断 `VALUES (...)`，这是现有最简解析器的限制
- `@SQL` 是 Pico 侧扩展；mybot 原版热 SQL 由宿主 `apply_sql` 调用
- P28 起脚本结束后设备保持 active，可用 `/sql` 继续热补丁，直到 `/run` 或 `/unload`

## P26：取消无 SD 构建

P26-A 把 SD 从可选构建项改成固定功能：

- 删除 `USE_SD` CMake option
- 删除所有 `#if USE_SD` 分支和 “SD support disabled” 回退
- `loadfile` / `dofile` 始终走 FatFS
- `.sql` / `.mt` / `profile.txt` 始终从 SD 读取
- `/list` 始终扫描 `/robots`
- 构建命令不再需要 `-DUSE_SD=ON`

当前只有一种固件（P28 后尺寸）：

```text
text    data     bss
276768     0  134940
```

构建：

```sh
cmake -S . -B build -G Ninja \
  -DPICO_SDK_PATH=/home/qing/pico/pico-sdk \
  -DPICO_NO_PICOTOOL=1
cmake --build build -j4
```

行为：

- SD 卡没插或挂载失败时，日志会输出 `SD: mount failed (...)`
- 没有 `/robot.lua` 时仍会回退内嵌 smoke 脚本，用于确认 Lua 运行时存活
- 没有结构 SQL 时无法运行 profile，这是预期行为
- 不再维护两份固件尺寸/两套分支

限制：

- 没有 SD 卡就不能运行真实机器人脚本
- FatFs/SPI SD 驱动始终链接，flash/BSS 不再有无 SD 版本的小体积优势
- SD 引脚仍是 GP2-5，5MHz，可在 CMake cache 中改

## P27：@SQL UPDATE / DROP TABLE

P27-A 扩展 `@SQL` 的带电变更语句：

```mt
@SQL
UPDATE P5Check SET value='77' WHERE name='hot';
@

@SQL
DROP TABLE P5Check;
@
```

`UPDATE` 语义：

- 解析 `SET 列=值 [, ...]` 和可选 `WHERE name='x'`
- 命中行按“断电摘除 + 重新装配”处理
- `name` 可以改；新名字不能和存活设备重名
- 改 `controller` / `trigger` 列后会重新计算设备拓扑
- 仍被引用的设备拒绝 UPDATE
- 新设备 build 失败时旧设备已经被摘除，日志会如实报告

`DROP TABLE` 语义：

- 删除该表所有设备行
- 不接受 `WHERE`
- 仍被引用的行会阻止删除并记入 `blocked`

测试 profile：

```text
p27
```

预期关键日志：

```text
P2: device hot driver=P5Check controller=- triggers=0
P5Check: build value=1 name=hot item=nil angle=nil
P2: hot.build result=OK
P5Check: call value=1 name=hot item=nil angle=nil
P2: hot.call result=OK
P27: update hot driver=P5Check -> hot
P25: hot remove hot driver=P5Check
Lua: P5Check: destroy
P2: hot.destroy result=OK
P5Check: build value=77 name=hot item=nil angle=nil
P2: hot.build result=OK
P27: UPDATE P5Check name=hot -> 1 updated, 0 blocked, 0 failed
P5Check: call value=2 name=hot item=nil angle=nil
P2: hot.call result=OK
P25: hot remove hot driver=P5Check
Lua: P5Check: destroy
P2: hot.destroy result=OK
P27: DROP TABLE P5Check -> 1 removed, 0 blocked
P2: unknown device hot
```

限制：

- `UPDATE ... WHERE` 只支持 `name = '...'`
- 不支持 `UPDATE` 与同批次其它行级语句的独占检查
- `SET` 值只能是简单文本；不支持表达式求值
- P33 起 `@SQL` 块和 UART `/sql` 都会在失败时回滚到执行前快照
- `DROP TABLE` 只摘设备行，没有单独的“表壳/列定义”需要维护
- SQL 值里的 `)` 仍会截断 `VALUES (...)`

## P28：常驻 Lua 状态 + UART /sql

P28-A 改变 `/run` 的生命周期：

- 脚本执行完后不再立即 `destroy` 设备，也不再 `lua_close`
- core1 保持 active 状态，设备、Lua env、变量和 `@Struct` 都留在内存
- `/run` 会先销毁旧 active 状态，再加载新 profile
- `/unload` 显式销毁设备并关闭 Lua
- `/status` 显示 `active=1 devices=N sql=/robots/xxx.sql`
- `/mem` 读取当前 active Lua state 的实时堆大小
- `/sql <name>` 读取 `/sql/<name>.sql`，对 active 结构执行 P25/P27 的热 SQL
- `/sql` 是事务式应用：任一语句失败会回滚到执行前的设备/变量快照

示例：

```text
/run p28
/sql p28_add
/status
/sql p28_del
/unload
```

`/run p28` 后：

```text
P2: using /robots/p28.sql
P2: device base driver=P5Check controller=- triggers=0
P5Check: build value=1 name=base item=nil angle=nil
P2: base.build result=OK
P5Check: call value=1 name=base item=nil angle=nil
P2: base.call result=OK
P2: profile active, devices=1 heap=...KB
```

`/sql p28_add`：

```text
core1: apply /sql/p28_add.sql
P2: device hot driver=P5Check controller=- triggers=0
P25: hot insert hot driver=P5Check
P5Check: build value=42 name=hot item=nil angle=nil
P2: hot.build result=OK
core1: active sql=/robots/p28.sql devices=2 heap=...KB
```

`/sql p28_del`：

```text
core1: apply /sql/p28_del.sql
P25: hot remove hot driver=P5Check
Lua: P5Check: destroy
P2: hot.destroy result=OK
P25: DELETE P5Check name=hot -> 1 removed, 0 blocked
core1: active sql=/robots/p28.sql devices=1 heap=...KB
```

`/unload`：

```text
Lua: P5Check: destroy
P2: base.destroy result=OK
core1: unloaded, idle
```

SD 布局新增：

```text
/sql/
  p28_add.sql
  p28_del.sql
```

限制：

- 同时只有一个 active profile
- active 状态只保留设备结构；脚本结束后没有后台动作循环
- `/sql` 只做结构热变更，不会重新播放动作脚本
- 热 SQL 没有事务回滚；失败时可能留下部分变更
- 保持 Lua state 会持续占用堆，可用 `/mem` 观察
- `/run` 会隐式 `/unload`，旧设备会先全部 destroy

## P29：/action 重播动作脚本

P29-A 增加 `/action`：

```text
/action p29    读取 /scripts/p29.mt 并在 active 设备上执行
/action        重播最近一次动作脚本
```

行为：

- 不销毁、不重建 active 设备
- 动作脚本可以使用当前已 build 的设备、变量和别名
- 脚本里的 `@SQL` 仍可继续热插拔
- 每次 `/action` 会重置 `@Struct` / `@Reflex` / `@Merge` 的脚本级定义，但保留 active 设备
- 动作脚本本身不改变 `p2_active_sql`
- `/status` 增加 `action=` 字段，显示当前动作脚本
- `/run` 会重新设置动作脚本路径

测试：

```text
/run p28
/action
/action p29
/status
/unload
```

预期关键日志：

```text
core1: action /scripts/p28.mt
P5Check: call value=1 name=base item=nil angle=nil
P2: base.call result=OK
core1: action finished, devices=1 heap=...KB
core1: action /scripts/p29.mt
P5Check: call value=5 name=base item=nil angle=nil
P2: base.call result=OK
core1: action finished, devices=1 heap=...KB
core1: status idle active=1 devices=1 sql=/robots/p28.sql action=/scripts/p29.mt
```

限制：

- 动作脚本不能新增持久设备，除非使用 `@SQL`
- 动作脚本结束后没有后台循环
- 单次 `/action` 只执行一遍；需要批量重播用 `/repeat`
- 没有事务回滚
- `/action` 依赖 active 状态；先 `/run`

## P30：/repeat 批量重播

P30-A 增加：

```text
/repeat <name> [count] [delay_ms]
```

示例：

```text
/run p28
/repeat p29 3 100
/status
/unload
```

行为：

- 从 `/scripts/<name>.mt` 读取动作脚本
- 默认 `count=1`、`delay_ms=0`
- `count` 上限 1000，`delay_ms` 上限 60000
- 每轮重新读 SD 文件，迭代之间可修改脚本
- 迭代之间的延迟按 20ms 分片，`Ctrl-C` 可以及时停止
- 每轮都复用当前 active 设备，不重建结构
- 执行后把 `/scripts/<name>.mt` 设为当前动作脚本，`/action` 可继续重播
- `/repeat` 执行期间 core1 忙，`/stop` 命令要等它结束；`Ctrl-C` 不受影响（走 core0 停止标志）

测试：

```text
/run p28
/repeat p29 3 100
/status
/unload
```

预期关键日志：

```text
core1: repeat /scripts/p29.mt x3 delay=100ms
P5Check: call value=5 name=base item=nil angle=nil
P2: base.call result=OK
P5Check: call value=5 name=base item=nil angle=nil
P2: base.call result=OK
P5Check: call value=5 name=base item=nil angle=nil
P2: base.call result=OK
core1: repeat finished 3/3, devices=1 heap=...KB
core1: status idle active=1 devices=1 sql=/robots/p28.sql action=/scripts/p29.mt
```

限制：

- 没有后台循环；`/repeat` 是同步执行，结束才回到命令循环
- `/stop` 命令在 `/repeat` 期间不会被 core1 处理；需要 `Ctrl-C`
- 脚本里的 `@SQL` 每轮都会执行，可能重复 INSERT / 重复 UPDATE
- `/repeat` 本身没有事务；单次 `@SQL` 失败会回滚，但前面已成功的迭代不会撤销

## P31：active 状态诊断

P31-A 增加三个只读命令：

```text
/devices    列出 active 设备
/vars       列出 active @Vars 和 @Alias
/structs    列出 active @Struct 及字段
```

示例：

```text
/run p22
/devices
/vars
/structs
/unload
```

`/devices`：

```text
core1: dev[0] p22 driver=P5Check controller=- triggers=0 env=yes
core1: dev[1] cnt driver=Counter controller=- triggers=0 env=yes
```

`/vars`：

```text
core1: var idx=1
core1: var count=2
```

`/structs`：

```text
core1: struct cfg fields=4
core1: struct cfg.items[0]=10
core1: struct cfg.items[1]=20
core1: struct cfg.items[2]=30
core1: struct cfg.name=pico-x
```

行为：

- 只读，不改变设备、变量或 struct
- `/devices` 显示设备名、驱动、controller、trigger 数和 env 是否建立
- `/vars` 同时列出 `@Vars` 和 `@Alias`
- `/structs` 先列字段数，再逐字段列出
- 没有 active 状态时显示 no active devices / no active vars/aliases / no active structs
- 日志队列深度从 16 提升到 64、单行从 96 提升到 128 字节，避免一次性列出 struct 字段时丢日志

限制：

- 输出是逐行文本，没有分页
- 设备 meta 的全部字段没有展开；当前只显示名称、驱动、controller、trigger 数
- 大量 struct 字段会占用较长的 UART 输出时间
- 不能通过命令修改这些状态，只能通过 `/sql` / `/action` / `/run`

## P32：/sql 事务回滚

P32-A 给 `/sql` 命令加上事务式应用：

```text
/sql <name>
```

执行流程：

1. 快照当前 `p2_devices`、`@Vars`、`@Alias`
2. 把 `/sql/<name>.sql` 交给 P25/P27 引擎执行
3. 任一错误（语法、无命中行、引用阻止、build 失败）都将 `p2_hot_error` 置位
4. 失败时销毁当前设备，恢复快照，重新 build 全部设备
5. 成功则直接提交

失败示例：

```sql
INSERT INTO P5Check (name, value) VALUES ('hot', '42');
DELETE FROM P5Check WHERE name='missing';
```

第二条 DELETE 0 行命中，触发回滚：

```text
core1: apply /sql/p32_bad.sql
P2: device hot driver=P5Check controller=- triggers=0
P25: hot insert hot driver=P5Check
P5Check: build value=42 name=hot item=nil angle=nil
P2: hot.build result=OK
P25: DELETE P5Check name=missing -> 0 removed, 0 blocked
P25: DELETE P5Check matched no row
P32: rollback start
Lua: P5Check: destroy
P2: hot.destroy result=OK
Lua: P5Check: destroy
P2: base.destroy result=OK
P5Check: build value=1 name=base item=nil angle=nil
P2: base.build result=OK
P32: rollback done, devices=1
core1: /sql p32_bad rolled back, devices=1 heap=...KB
```

测试：

```text
/run p28
/sql p32_bad
/devices
```

预期 `/devices` 只剩：

```text
core1: dev[0] base driver=P5Check controller=- triggers=0 env=yes
```

限制：

- 回滚是“重建快照”，不是保留原 Lua 驱动内部状态；所有设备会重新 destroy/build
- 物理器件会在回滚过程中断电/重新初始化
- P33 起 `@SQL` 块也走同一事务；失败会回滚
- 如果回滚重建本身失败，状态可能不完整，日志会显示 build 失败
- 快照保存在 BSS（约 6KB），只支持当前设备/变量/别名，不包含驱动内部状态

## P33：@SQL 块事务回滚

P33-A 把动作脚本里的 `@SQL` 也接到 P32 事务层：

- 执行前快照设备、`@Vars`、`@Alias`
- 块内任一语句失败 → 销毁当前设备、恢复快照、重新 build
- 回滚后动作脚本继续执行后续块
- 成功则正常提交

测试 profile：

```text
p33
```

脚本：

```mt
@Action
base.value;
   1;
@

@SQL
INSERT INTO P5Check (name, value) VALUES ('hot', '42');
DELETE FROM P5Check WHERE name='missing';
@

@Action
base.value;
   2;
@
```

预期关键日志：

```text
P5Check: call value=1 name=base item=nil angle=nil
P2: base.call result=OK
P25: @SQL block ... bytes
P25: hot insert hot driver=P5Check
P5Check: build value=42 name=hot item=nil angle=nil
P2: hot.build result=OK
P25: DELETE P5Check name=missing -> 0 removed, 0 blocked
P25: DELETE P5Check matched no row
P32: rollback start
Lua: P5Check: destroy
P2: hot.destroy result=OK
Lua: P5Check: destroy
P2: base.destroy result=OK
P5Check: build value=1 name=base item=nil angle=nil
P2: base.build result=OK
P32: rollback done, devices=1
P25: @SQL rolled back
P5Check: call value=2 name=base item=nil angle=nil
P2: base.call result=OK
P2: profile active, devices=1 heap=...KB
```

限制：

- 回滚会重建设备，驱动内部状态丢失
- 物理器件会在回滚时重新初始化
- 回滚重建失败时状态可能不完整
- `@SQL` 仍只支持当前子集（INSERT/DELETE/UPDATE/DROP）
- 事务快照不包含驱动内部状态

## P34：设备列 @Alias 解析

P34-A 支持在动作脚本列头的设备位使用 `@Alias`：

```mt
@Alias
name alias;
  leg base;
  A   angle;
@

@Action
leg.value  base.A;
   7         45;
@
```

行为：

- `leg` 是设备别名，解析为 active 设备 `base`
- `A` 是参数别名，解析为 `angle`
- 设备别名只在目标确实是当前 active 设备时生效，避免把普通参数别名误当设备
- `@Action`、`@Merge` 合并源、`@Reflex` 反射体共用同一套解析
- 同一设备解析后会在动作行内合并参数，不会重复调用

测试 profile：

```text
p34
```

预期关键日志：

```text
P5Check: call value=7 name=base item=nil angle=45
P2: base.call result=OK
```

限制：

- 设备别名只解析一层，不追链
- 目标设备必须在执行时已 build
- `@Alias` 必须在动作块之前定义
- 设备别名和参数别名共用同一张名字表；同名时优先按 active 设备判断
- 还没有 `include-once` / 子块内 `@Merge` 的完整语义

## P35：/loop 周期动作循环

P35-A 增加常驻周期动作：

```text
/loop <name> <period_ms>
/loop stop
```

示例：

```text
/run p28
/loop p29 200
/status
/loop stop
/unload
```

行为：

- `/loop` 先验证 `/scripts/<name>.mt` 存在，然后启动周期调度
- 周期范围 50ms ~ 60000ms
- 每个周期重新读 SD 文件并执行一次动作脚本
- 执行在 core1 命令循环内完成，动作结束后等待到下一个周期
- 命令优先：周期之间仍会处理 `/sql`、`/status`、`/action`、`/stop` 等命令
- `Ctrl-C` 或 `/stop` 会停止循环
- `/run`、`/unload` 会隐式停止循环
- 新 `/loop` 会替换当前循环
- `/status` 会额外输出一行 `core1: loop ... period=... iter=...`
- `/repeat` 执行期间循环暂停，结束后继续

预期关键日志：

```text
core1: loop start /scripts/p29.mt period=200ms
P5Check: call value=5 name=base item=nil angle=nil
P2: base.call result=OK
P5Check: call value=5 name=base item=nil angle=nil
P2: base.call result=OK
core1: status idle active=1 devices=1 sql=/robots/p28.sql action=/scripts/p29.mt
core1: loop /scripts/p29.mt period=200ms iter=2
core1: loop stopped after 2 iteration(s): command
```

限制：

- 不是硬实时，周期从上一轮动作完成后计算
- 周期动作会阻塞 core1 的命令处理，直到当前动作脚本执行完
- 单次动作脚本执行时间超过周期时，下一轮会顺延
- 日志量会随周期频率增加
- 只维护一个周期循环
- `/loop` 需要 active profile
- 回滚/事务只作用于 `/sql`，周期动作本身没有事务

## P36：/reload 重载 active profile

P36-A 增加：

```text
/reload
```

行为：

- 从当前 active 的 `/robots/*.sql` 和原始 `/scripts/*.mt` 重新加载
- 先停止 `/loop`
- 销毁当前 active 设备并关闭旧 Lua state
- 重新读 SD 上的 SQL/MT 文件，重新 build、重新执行一次动作脚本
- 热 SQL 补丁不重放；只重读 SD 文件本身
- 如果 `/action` 换过动作脚本，`/reload` 仍使用 profile 原始动作脚本
- 需要 active profile

测试：

```text
/run p28
/sql p28_add
/devices
/reload
/devices
```

预期：

- 第一次 `/devices` 看到 `base` + `hot`
- `/reload` 后只剩 `base`
- 修改 SD 上的 `p28.sql` / `p28.mt` 后，`/reload` 会读到新内容

关键日志：

```text
core1: reload sql=p28 script=p28
Lua: P5Check: destroy
P2: hot.destroy result=OK
Lua: P5Check: destroy
P2: base.destroy result=OK
P2: using /robots/p28.sql
P2: device base driver=P5Check controller=- triggers=0
P5Check: build value=1 name=base item=nil angle=nil
P2: base.build result=OK
P5Check: call value=1 name=base item=nil angle=nil
P2: base.call result=OK
P2: profile active, devices=1 heap=...KB
core1: reload finished, profile active
```

限制：

- 热 SQL 变更不会保留
- 会重新初始化所有物理设备
- 会重新执行 profile 动作脚本一次
- 加载失败时可能回退到内置 smoke，active 状态丢失
- `/reload` 使用 profile 原始动作脚本，不一定是最近 `/action` 的脚本

## P37：/boot.txt 开机自动周期动作

P37-A 支持 SD 根目录的 `/boot.txt`：

```text
# mybot-lite boot autostart
# format: <action-script> <period_ms>
p29 200
```

行为：

- 上电加载 profile 后读取 `/boot.txt`
- 第一个非空、非 `#` 行按 `<action> <period_ms>` 解析
- 自动启动与 `/loop` 相同的周期调度
- `period_ms` 范围 50 ~ 60000
- 动作脚本来自 `/scripts/<name>.mt`
- `off` / `none` 明确禁用自动启动
- 没有 `/boot.txt`、只有注释或首行无效时不启动，只记录诊断
- `/reload` 不会重新读取 `/boot.txt`，只有重新上电才生效
- 启动后仍可用 `/loop` 替换周期、`/loop stop`、`/stop` 或 `Ctrl-C` 停止

测试：

1. `/profile.txt` 写 `p28`
2. `/boot.txt` 写 `p29 200`
3. 重新上电

预期关键日志：

```text
core1: boot autostart /scripts/p29.mt period=200ms
P5Check: call value=5 name=base item=nil angle=nil
P2: base.call result=OK
...
```

默认 SD 布局里的 `/boot.txt` 只有注释，因此默认不会自动循环。

限制：

- 只读取第一条有效配置行
- `/boot.txt` 最大 128 字节
- 开机自动启动依赖 profile 已经成功 active
- 动作脚本缺失时只报错并保持 idle
- 没有看门狗/失效重启机制

## P38：/use 与 /autostart 持久化开机配置

P38-A 增加两个写 SD 配置的命令：

```text
/use <profile>
/autostart <action> <period_ms>
/autostart off
/autostart
```

`/use`：

- 校验 `/robots/<profile>.sql` 存在
- 写入 `/profile.txt`（内容为 profile 名 + 换行）
- 不立即重载 active profile；下次 `/run`（无参数）或重新开机生效

`/autostart`：

- 校验 `/scripts/<action>.mt` 存在
- 写入 `/boot.txt`（内容为 `<action> <period_ms>`）
- 下次开机由 P37 自动启动
- `off` 写入显式禁用
- 不带参数时读取 `/boot.txt` 并显示第一条有效行

测试：

```text
/use p28
/autostart p29 200
/profile
/autostart
```

预期：

```text
core1: profile set to p28 (next /run)
core1: boot autostart set to p29 200ms (next boot)
core1: /profile.txt = p28
core1: boot autostart = p29 200
```

重新上电后：

```text
core1: boot autostart /scripts/p29.mt period=200ms
```

限制：

- 直接覆盖写，没有临时文件/原子 rename；掉电可能截断
- `/use` 只改 `/profile.txt`，不会立即切 profile
- `/autostart` 只改 `/boot.txt`，不会立即启动循环
- 需要 SD 可写
- 写入失败只报日志，不自动回滚
- 文件内容很小：profile 一行，boot 一行

## P39：@Merge 容量扩展、负相位与前导 `-` 跳过

P39-A 在简化 `@Merge` 上补三件事：

- 源文件上限 3 → 4
- 单源数据行上限 4 → 8
- 支持负 `phase`：丢弃开头 `abs(phase)` 行；整源丢弃会告警
- 支持 `phase` 列写 `-`：继承上一行相位
- 支持前导 `-` 行：源在第一条有数据的行之前不参与派发

测试 profile：

```text
p39
```

源布局：

```mt
@Merge
path phase;
  parts/merge_39_a.mt  0;
  parts/merge_39_b.mt  0;
  parts/merge_39_c.mt -1;
  parts/merge_39_d.mt  1;
@
```

- `a`：1..5，共 5 行
- `b`：前导 `-`，随后 `10`
- `c`：`30, 40`，phase=-1，`30` 被丢弃
- `d`：`50, 60`，phase=1

预期 5 拍：

```text
beat0: a=1 c=40
beat1: a=2 b=10 c=40 d=50
beat2: a=3 b=10 c=40 d=60
beat3: a=4 b=10 c=40 d=60
beat4: a=5 b=10 c=40 d=60
```

关键日志：

```text
P2: @Merge ... phase=-1 rows=2
P2: @Merge source 2 starts at beat 0 (phase=-1)
P2: @Merge timeline 5 beat(s)
P5Check: call value=1 name=a item=nil angle=nil
P5Check: call value=40 name=c item=nil angle=nil
P5Check: call value=2 name=a item=nil angle=nil
P5Check: call value=10 name=b item=nil angle=nil
P5Check: call value=40 name=c item=nil angle=nil
P5Check: call value=50 name=d item=nil angle=nil
...
```

限制：

- 仍不是完整 mybot `@Merge`
- 没有片段递归 `@Merge`、include-once、8MiB 预算、嵌套控制块归并
- 数据格 `-` 只在“前导未起拍”时跳过；P41 起 `@Merge` 行内 `-` 也做框架级继承
- 负相位整源丢弃只告警，不中止脚本
- 列数上限仍为 6

## P40：@Action 行内 `-` 继承

P40-A 给 `@Action` 数据行加上框架级 `-` 继承：

- 某一列写 `-` 时，沿用上一行同一列的原始值
- 第一行就写 `-` 时没有可继承值，保留字面 `-`
- 捕获格 `$var=field` 不参与继承，也不会写上一行缓存
- `@if` / `@while` 里由 `p2_exec_action` 执行的隐式动作块在每次块执行内部同样生效；`@while` 每轮重新开始继承缓存
- `@Reflex` / `@Merge` 的逐行派发暂未接入同一继承逻辑，仍按各自路径处理

测试 profile：

```text
p40
```

脚本：

```mt
@Action
p40.value  p40.item;
   7         10;
   -         20;
   8         -;
@
```

预期三次调用：

```text
P5Check: call value=7 name=p40 item=10 angle=nil
P5Check: call value=7 name=p40 item=20 angle=nil
P5Check: call value=8 name=p40 item=20 angle=nil
```

关键日志：

```text
P2: @Action columns=2
P2: p40.call result=OK
P2: p40.call result=OK
P2: p40.call result=OK
```

限制：

- `-` 继承只在单个 `@Action` / 控制块动作序列内，不跨块
- P41 起 `@Reflex`、`@Merge` 也接入框架级继承
- `-` 缓存是原始文本，不保存 `$(...)` 求值后的结果
- P42 起动作行缺列会补 `-` 并参与继承

## P41：@Reflex / @Merge 的 `-` 继承

P41-A 把 P40 的 `-` 继承接到 `@Reflex` 和 `@Merge`：

- `@Reflex` / named `@Reflex`：每次反射调用维护自己的上一行缓存
- `@Merge`：每个源分别维护缓存，`-` 按“源内同列”继承
- 捕获格仍不参与继承
- 首行没有可继承值时保留字面 `-`

测试 profile：

```text
p41
```

脚本：

```mt
@Reflex
name  p41.value  p41.item;
fire  10         20;
fire  -          30;
@

@Trigger
fire;
@

@Merge
path phase;
  parts/merge_41_a.mt 0;
  parts/merge_41_b.mt 0;
@
```

片段：

```mt
@Action
m1.value;
  100;
  -;
@
```

```mt
@Action
m2.value;
  200;
  -;
@
```

预期：

```text
P5Check: call value=10 name=p41 item=20 angle=nil
P5Check: call value=10 name=p41 item=30 angle=nil
P5Check: call value=100 name=m1 item=nil angle=nil
P5Check: call value=200 name=m2 item=nil angle=nil
P5Check: call value=100 name=m1 item=nil angle=nil
P5Check: call value=200 name=m2 item=nil angle=nil
P2: @Merge timeline 2 beat(s)
```

限制：

- 缓存只在单次反射调用 / 单个 merge 源内有效
- 不跨 `@Action` 块、`@Reflex` 调用或 `/action` 执行
- 缓存的是原始文本，不是 `$(...)` 求值后的结果
- `@Merge` 前导 `-` 跳过逻辑与继承缓存相互独立

## P42：动作行缺列按 `-` 补齐

P42-A 让 `@Action` 数据行少于表头时，缺失列按 `-` 处理：

- 缺列先补 `-`
- 补出的 `-` 再走 P40 的继承逻辑
- 第一行缺列且没有上一行时保留字面 `-`
- 多出的数据格仍被忽略
- `@Reflex` / `@Merge` 在解析阶段本来就按 `-` 补齐，行为保持一致

测试 profile：

```text
p42
```

脚本：

```mt
@Action
p42.value  p42.item  p42.angle;
   7         10        20;
   -         30;
   8;
@
```

预期：

```text
P5Check: call value=7 name=p42 item=10 angle=20
P5Check: call value=7 name=p42 item=30 angle=20
P5Check: call value=8 name=p42 item=30 angle=20
```

关键行为：

- 第二行只写两格：angle 缺列 → 继承上一行 20
- 第三行只写一格：item/angle 缺列 → 继承 30/20

限制：

- 只对 `p2_exec_action` 的 `@Action` / 控制块动作序列生效
- 多余数据格仍忽略，不报错
- 缺列补 `-` 后仍遵循首行无继承的规则
- 缓存仍是原始文本，不是求值结果
- 没有根据表头类型做缺列校验

## P43：全 fake HAL 回归 profile + /device 详情

P43-A 增加一个不需要真实器件的综合回归 profile：

```text
p43
```

设备：

```text
i2c-f    I2C         /dev/i2c-fake
pca-0    PCA9685     $i2c-f 0x40
ads-0    ADS1015     $i2c-f 0x48
t0       Timer
spi-f    SPI         /dev/spidev-fake
sig0     AD9833      $spi-f 1000Hz sine
uart-f   UART        /dev/tty-fake 115200
uc       UartCheck   $uart-f
```

动作：

```mt
@Action
pca-0.angle  ads-0.channel  sig0.freq  uc.send  t0.delay;
   90          0              1000       1        50;
   45          1              2000       2        50;
@
```

运行：

```text
/run p43
```

预期：

- 8 个设备全部 build
- 两拍动作依次驱动 PCA9685、ADS1015、AD9833、UartCheck、Timer
- Timer 两拍各睡 50ms
- profile 保持 active

新增 `/device <name>`：

```text
/device pca-0
```

输出设备级详情：

```text
core1: device pca-0 driver=PCA9685 controller=- triggers=0 env=yes
core1: device pca-0 meta name=pca-0
core1: device pca-0 meta I2C=<fd>
core1: device pca-0 meta address=0x40
core1: device pca-0 meta channel=0
```

限制：

- 只验证 fake HAL 路径，不验证真实器件时序/电气
- fake 驱动仍走真实 Lua 驱动代码，但总线由假后端返回
- 8 个设备已达到当前 `P2_MAX_DEVICES` 上限
- ADS1015/PCA9685 共用同一个 fake I2C fd
- 真实硬件仍需逐器件回归

## P44：设备容量 8 → 16

P44-A 把 `P2_MAX_DEVICES` 从 8 提到 16：

- 支持最多 16 个 active 设备
- `p2_devices` 和热 SQL 快照都随之扩大
- BSS 增加约 11KB
- `P2_MAX_COLS` 仍是 16
- `P2_MAX_FIELDS` 仍是 10

测试 profile：

```text
p44
```

包含 12 个 P5Check 设备 `d00..d11`，单行动作 12 列：

```mt
@Action
d00.value  d01.value  ...  d11.value;
  0          1               11;
@
```

预期 12 次调用：

```text
P5Check: call value=0 name=d00 item=nil angle=nil
P5Check: call value=1 name=d01 item=nil angle=nil
...
P5Check: call value=11 name=d11 item=nil angle=nil
```

尺寸：

```text
text    data     bss
276768     0  134940
```

限制：

- 16 个设备是当前硬上限；超过会拒绝 INSERT
- 热 SQL 快照同时保存 16 个设备，BSS 翻倍成本明显
- `P2_MAX_COLS` 仍为 16，设备数不能超过动作列上限
- RP2040 剩余 RAM 仍要留给 Lua heap，继续扩容需评估
- 尚未上板实测 12 设备脚本

## P45：列头设备位/参数位表达式

P45-A 支持动作列头两个位置写 `$(...)`：

```mt
@Alias
name alias;
  pref p45;
@

@Vars
name value;
  n 7;
@

@Action
$(pref).value  p45.$("it"+"em");
  $(n)           9;
@
```

行为：

- 设备位 `$(pref)` 求值得到 `p45`，再走一层设备别名解析
- 参数位 `$(...)` 求值得到参数名，不再做参数别名解析
- `p2_lookup_value` 现在也能读取 `@Alias` 文本，因此表达式里可引用别名
- 列头切分点会跳过括号/引号内的 `.`，支持 `$(cfg.name).value` 和 `p45.$(cfg.name)`
- `@Action`、`@Reflex`、`@Merge` 三处列头统一使用同一解析器

测试 profile：

```text
p45
```

预期：

```text
P5Check: call value=7 name=p45 item=9 angle=nil
P2: p45.call result=OK
```

限制：

- P46 起 `@Action` 每行重新求值；`@Reflex` / `@Merge` 仍在块/源进入时求值
- 只支持整个设备位或参数位是 `$(...)`；不支持 `pre-$(x)` 这种混合拼接
- 设备表达式结果只再解析一层别名
- 求值失败会记录诊断并回退到原文本，最终可能报 unknown device/param
- 表达式结果受 `P2_MAX_NAME` 长度限制

## P46：@Action 列头表达式按行重算

P46-A 让 `@Action` 的列头表达式在每一行派发前重新求值：

- 上一行捕获写入的 `@Vars` 会影响下一行的设备位/参数位
- 初始表头仍先求值一次用于列数诊断
- 每行开始时重建 `p2_action_cols`
- `@Reflex` / `@Merge` 仍保持块/源进入时求值

测试设备：

```sql
CREATE TABLE P5Check (name String, value String);
INSERT INTO P5Check (name, value) VALUES ('p46', '0');

CREATE TABLE Switch (name String);
INSERT INTO Switch (name) VALUES ('sw');
```

`Switch.lua` 每次 call 交替返回 `param=angle` / `param=item`。

测试脚本：

```mt
@Vars
name value;
  p value;
@

@Action
p46.$(p)  sw.pick;
   5       $p=param;
   6       $p=param;
   7       $p=param;
@
```

预期：

```text
P5Check: call value=5 name=p46 item=nil angle=nil
Switch: pick=angle
P5Check: call value=nil name=p46 item=nil angle=6
Switch: pick=item
P5Check: call value=nil name=p46 item=7 angle=nil
```

解释：

- Row1 表头 `p=value` → `p46.value=5`
- Switch 返回 `param=angle`，捕获 `p=angle`
- Row2 重建表头 → `p46.angle=6`
- Switch 返回 `param=item`，捕获 `p=item`
- Row3 重建表头 → `p46.item=7`

限制：

- 只在行开始时重算；同一行内前面设备的捕获不会改变本行后续列头
- `@Reflex` / `@Merge` 没有按行重算
- 列数诊断仍按初始表头
- 表达式求值失败仍回退原文本
- 结果受 `P2_MAX_NAME` 长度限制

## P47：递归 @Include 与循环检测

P47-A 把 `@Include` 从固定两层改成递归展开：

- 最多展开 4 层被包含文件（顶层 + 4 个 include 层级）
- 使用独立层级缓冲区，避免覆盖上层文本
- 记录当前 include 路径栈，检测 A → B → A 循环
- 超深或循环时记录诊断并中止展开
- `@Include` 仍然是文本拷贝，不是 `@Merge`

测试 profile：

```text
p47
```

链路：

```text
p47.mt
  -> parts/inc_chain1.mt
    -> parts/inc_chain2.mt
      -> parts/inc_chain3.mt
        -> parts/inc_chain4.mt
          @Action p47.value = 47
```

预期：

```text
P2: @Include merged 4 file(s)
P5Check: call value=47 name=p47 item=nil angle=nil
P2: p47.call result=OK
```

主机侧测试：

- 4 层链路展开成功，`p47.value` 出现在最终文本
- `cycle_a -> cycle_b -> cycle_a` 被拒绝

限制：

- 每层都有固定文本缓冲（增加约 12.8KB BSS）
- 只检测 include 路径栈内的循环，顶层文件不在栈内
- 超过 4 层被包含文件会拒绝
- `@Include` 仍只做文本拷贝，不做相位归并
- 被包含文件里的路径仍按 `/scripts/` 解析
- 尚未上板实测

## P48：顶层 MT 纳入 include 循环检测

P48-A 把当前 MT 文件路径压入 include 路径栈：

- `p2_active_mt` 作为栈底路径
- 顶层文件再次 include 自己会在第一次展开时被拒绝
- include 栈容量增到 8 个路径，递归深度仍是 4 层
- `/action` / `/repeat` / `/loop` / boot autostart 都会使用当前动作脚本路径

负例脚本：

```text
/scripts/p48_self.mt
```

内容：

```mt
@Include
path;
  p48_self.mt;
@
```

测试：

```text
/run p28
/action p48_self
```

预期：

```text
P2: @Include cycle: /scripts/p48_self.mt
core1: action finished, devices=1 heap=...KB
```

不会执行任何动作，也不会无限递归。

限制：

- 只把当前 MT 路径纳入栈，不追踪历史上运行过的其它脚本
- include 栈容量 8、递归深度 4；超限拒绝
- `/action` 失败后 active 结构保持不变
- `@Include` 仍是文本拷贝
- 尚未上板实测

## P49：@Merge 主从别名/变量覆盖

P49-A 修正 `@Merge` 片段与主脚本的标量优先级：

- 主脚本在 `@Merge` 执行前已有的 `@Alias` / `@Vars` 优先
- 片段里的同名定义被跳过，并记录 `keeps main binding/value`
- 两个片段之间定义同名的新别名/变量会中止整次 `@Merge`
- 仍保持 `@Merge` 设备集不相交检查

测试 profile：

```text
p49
```

主脚本：

```mt
@Alias
name alias;
  leg a;
@

@Merge
path phase;
  parts/merge_49_leg.mt 0;
@
```

片段：

```mt
@Alias
name alias;
  leg b;
@

@Action
leg.value;
  49;
@
```

预期：

```text
P2: @Merge alias leg keeps main binding
P2: @Merge ... rows=1
P5Check: call value=49 name=a item=nil angle=nil
P2: a.call result=OK
```

不会调用设备 `b`。

限制：

- 主脚本定义必须已在 `@Merge` 执行前注册
- 片段之间重复的新别名/变量会整次中止
- 结构层已有同名定义也按主绑定处理
- 变量查找仍是首个定义优先，主脚本后置 `@Vars` 的行为不在本阶段保证
- 尚未上板实测

## P50：@Merge include-once 片段

P50-A 给 `@Merge` 加 include-once：

- 同一路径第二次出现时，如果文件后缀是 `.once.mt`，跳过并记录
- 同一路径第二次出现且不是 `.once.mt`，拒绝并中止整次 `@Merge`
- 检查按路径字符串精确比较，不做 canonicalize
- 仍然没有片段递归 `@Merge`

测试 profile：

```text
p50
```

片段文件：

```text
/scripts/parts/merge_50_once.once.mt
```

内容：

```mt
@Action
a.value;
  50;
@
```

主脚本：

```mt
@Merge
path phase;
  parts/merge_50_once.once.mt 0;
  parts/merge_50_once.once.mt 0;
@
```

预期只加载一次：

```text
P2: @Merge /scripts/parts/merge_50_once.once.mt phase=0 rows=1
P2: @Merge once fragment skipped: /scripts/parts/merge_50_once.once.mt
P2: @Merge timeline 1 beat(s)
P5Check: call value=50 name=a item=nil angle=nil
P2: a.call result=OK
```

非 `.once.mt` 重复会输出：

```text
P2: @Merge duplicate fragment: ...
P2: @Merge aborted by fragment duplicate
```

限制：

- 按路径文本精确匹配，`./x.mt` 与 `x.mt` 不视为同一文件
- include-once 只跳过重复，不做菱形依赖递归
- 片段递归 `@Merge` 仍未实现
- 主脚本动作表不算片段路径
- 尚未上板实测

## P51：/i2cscan 硬件总线扫描

P51-A 增加 I2C 总线扫描：

```text
/i2cscan 0
/i2cscan 1
```

行为：

- 不带参数默认扫描 bus 0
- bus 0 使用 GP6/GP7，bus 1 使用 GP14/GP15
- 以 100kHz 初始化（如果总线尚未打开）
- 扫描地址 `0x08..0x77`
- 每发现一个 ACK 地址输出一行：

```text
core1: i2cscan bus 0 addr=0x40
core1: i2cscan bus 0 addr=0x48
core1: i2cscan bus 0 -> 2 device(s)
```

- 不需要 active profile
- 如果总线已被 Lua 驱动打开，会复用现有实例
- 不扫描 fake 总线；fake 路径仍由 Lua 驱动内部处理

测试（真实硬件）：

```text
/i2cscan 0
```

如果 PCA9685 / ADS1015 已接好且地址分别是 0x40 / 0x48，应看到这两个地址。

限制：

- 扫描会向总线发读探测；运行中扫描可能干扰正在工作的器件，建议 idle 时使用
- 只支持 bus 0/1
- 只报告 ACK 地址，不识别器件型号
- 地址范围固定 0x08..0x77
- 没有上拉/电气诊断
- 尚未上板实测

## 运行现象

上电后所有输出都在 UART0（GP0/GP1，115200 8N1），没有 VGA 输出：

```text
[console] mybot-lite headless (UART0)
[console] type /help for commands
[robot] core1: robot runtime started
[robot] SD: mounted 0:
[robot] P2: using /robots/p3.sql
...
[robot] core1: status idle active=1 devices=2 sql=/robots/p3.sql action=/scripts/p3.mt
>
```

- SD 卡没插或挂载失败时，core1 会输出 `SD: mount failed`；没有 `/robot.lua` 时会回退内嵌 smoke 脚本，但没有结构 SQL 时无法运行 profile。
- 输入 `/stop` 或按 **Ctrl-C**，core1 会在 `@while`、`milli_sleep` 和动作派发检查点退出。
- core1 运行期间，core0 仍会继续轮询 UART、输出日志、响应 `Ctrl-C`。
- 当前固件不初始化 USB CDC/HID；USB 口只用于供电和 BOOTSEL/UF2 烧录。

## SD 目录建议

FAT 卡根目录放：

```text
/robot.lua
/modules/       # P1 起使用
/robots/        # P1 起使用
/scripts/       # P1 起使用
/sql/           # P28 起使用：/sql <name> 读取 /sql/<name>.sql
```

P0 的 `/robot.lua` 只需要定义：

```lua
function build(data) return { result = "OK" } end
function call(data) return { result = "OK", delay = 200 } end
function destroy(data) return { result = "OK" } end
```

## P0 之后

1. 把 `robot.lua` 替换成真正的 Relay/Timer 驱动加载。
2. 接入 mybot 的 `sqlparse`（不经过 SQLite）与 `matrix` 解析器。
3. 移植 `HAL.lua` 的 Pico 后端（I2C/SPI/UART）。
4. 建立每设备 Lua env 与 Action 执行器。
