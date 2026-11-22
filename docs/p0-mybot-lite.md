# P0：mybot-lite 双核、Lua、脚本解析与硬件 HAL

本分支（`mybot-lite-p0`）从 mybot 迁移到 pico-vga 的 P0/P1/P2/P3/P4/P5/P6/P7/P8/P9/P10/P11/P12/P13/P14/P15/P16/P17/P18/P19/P20/P21/P22 阶段，验证：

1. **core1 阻塞不会影响 core0 的 VGA / 键盘 / 控制台**
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
12. **静态内存收敛（约 166KB → 138KB）**
13. **`@Merge` 主脚本动作对齐**
14. **`@Merge` 片段别名/变量与设备集校验**
15. **`@Reflex` / `@Trigger`**
16. **named `@Reflex(name)`**
17. **反射递归/深度防线**
18. **动态数组下标**
19. **控制台 `/list` / `/help`**
20. **两层 `@Include`**
21. **SQL 与动作脚本分离选择**
22. **命令历史（↑/↓）**
23. **条件解析 v2（分组/一元 !/短路）**

还没有实现：完整 `@Merge` 语义、动态 SQL、完整 mybot 表达式 AST、trigger 返回值嵌套合并。那些属于后续阶段。

## 改动

- `src/main.c`
  - VGA、DMA IRQ、console、tryC、USB 全部留在 core0。
  - core1 只运行 `robot_core1()`。
  - core0 主循环增加 `console_poll()` / `robot_poll_ui()`。
- `src/console.c`
  - `loop_console()` 的循环体拆成 `console_poll()`，core0 不再被 console 死循环独占。
  - 输入法候选刷新拆成 `update_ime()`。
  - P0 临时停止键：拼音缓冲区为空时按 **Tab**，发送停止请求。
- `src/robot.c` / `include/robot.h`
  - core1 16KB BSS 栈 + `multicore_launch_core1_with_stack()`。
  - 日志队列（core1 → core0），不跨核调用 `printtovga`。
  - Lua 5.1 单状态机；可选从 SD 读取 `/robot.lua`，失败则回退内嵌 smoke 脚本。
  - P0 心跳：每 1s 输出一条日志，睡眠按 50ms 分片，便于观察停止延迟。
- `third_party/lua/`
  - vendored Lua 5.1.5（MIT），不编译 `lua.c` / `luac.c` / `io` / `os` / `linit`。
  - `os.getenv`、`os.time`、`os.clock`、`print` 由 `robot.c` 提供最小实现。
- `third_party/fatfs/`
  - vendored no-OS-FatFS-SD-SPI-RPi-Pico 的 `FatFs_SPI`（Apache-2.0）。
  - 默认 SD 引脚仍是 GP2/3/4/5，5MHz。
- `CMakeLists.txt`
  - `lua51` 静态库、`pico_util`。
  - `PICO_CORE1_STACK_SIZE=0`（core1 栈改到 BSS），`PICO_STACK_SIZE=0x1000`（core0 4KB）。

## 构建

```sh
cd /home/qing/pico-vga
cmake -S . -B build -G Ninja \
  -DPICO_SDK_PATH=/home/qing/pico/pico-sdk \
  -DUSE_SD=ON
cmake --build build -j4
```

没有安装 picotool 时，可以先关闭 UF2 生成来构建 ELF：

```sh
cmake -S . -B build -G Ninja \
  -DPICO_SDK_PATH=/home/qing/pico/pico-sdk \
  -DUSE_SD=ON \
  -DPICO_NO_PICOTOOL=1
```

如果本机有 picotool，可以直接生成 UF2：

```sh
picotool uf2 convert build/firmware.elf build/firmware.uf2 --family rp2040
```

本机已构建出的尺寸（`-DUSE_SD=ON`）：

```text
text   data   bss
896044    0 153500
```

BSS 中包含 16KB core1 栈、38.4KB VGA framebuffer、32KB Lua 源码加载缓冲和其他静态缓冲。

## 无 VGA / 串口输出（可选）

> 默认 `USE_VGA=ON`，VGA 和 framebuffer console 正常保留；下面只是没有显示器时的可选构建，不影响 VGA 版本。

P0 可以完全关掉 VGA、framebuffer console 和对应的 38.4KB framebuffer：

```sh
cmake -S . -B build-headless -G Ninja \
  -DPICO_SDK_PATH=/home/qing/pico/pico-sdk \
  -DUSE_SD=ON \
  -DUSE_VGA=OFF \
  -DPICO_NO_PICOTOOL=1
cmake --build build-headless -j4
```

本机关闭 VGA 后的尺寸：

```text
text    data   bss
270604     0 102056
```

此时：

- 不初始化 video/PIO/DMA，不分配 framebuffer。
- `robot_poll_ui()` 仍把 core1 日志通过 `printf("[robot] ...")` 输出到 **UART0（GP0/1）**。
- Lua 脚本里的 `print("...")` 会经日志队列走到同一个串口输出。
- 适合没有 VGA 显示器时验证 Lua、SD 和后续 I2C/SPI/UART。

串口参数沿用 `pico_enable_stdio_uart(firmware 1)` 的默认值（通常 115200 8N1）。  
注意 Pico 的 USB 口当前用于 TinyUSB host（键盘/鼠标），不要把 UART0 和 USB-CDC 混在一起期待同一路输出。

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

> P0 的 `call` 目前是直接用空表调用，所以 `data.delay` 为 0；P1 接入 Action 执行器后才会传真实参数。

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
    parts/inc_p5.mt
    parts/merge_ca.mt
    parts/merge_cb.mt
    parts/merge_alias.mt
    parts/level1.mt
    parts/level2.mt
    pca9685.mt
    ads1015.mt
    spi.mt
    uart.mt
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
`test=200, note=hello`。P1 跑通后 VGA/串口应出现：

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
- VGA/USB 在 core0 继续响应；
- Timer 返回 `slept=200`。

这证明：

- Lua 5.1 能加载 mybot 的真实 `Relay.lua` / `Timer.lua`；
- `drv_common.lua` / `print_table.lua` 的 LuaJIT 5.1 语法兼容；
- `dofile` 已改走 FatFS，而不是 newlib `fopen`；
- 每设备 env 隔离生效，两个驱动可以同时存在；
- Lua 的 `print()` 能回到 core0 显示到 VGA。

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

预期 VGA：

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

预期 VGA：

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
p2b             -> /robots/p2b.sql + /scripts/p2b.mt
```

没有 `/profile.txt` 时按 `p3 -> p2b -> relay-test` 回退。

### PCA9685 无硬件冒烟

`/profile.txt` 写成：

```text
pca9685_fake
```

会走 `/dev/i2c-fake`，真实 `PCA9685.lua` 仍会执行寄存器写序列，但由假总线返回成功。VGA 应出现：

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

预期 VGA：

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

core0 控制台新增 `/` 命令模式。拼音缓冲区为空时按 `/`：

```text
/run p4       运行 /robots/p4.sql + /scripts/p4.mt
/run p5 p8    用 /robots/p5.sql + /scripts/p8.mt
/run          重新读 /profile.txt 并运行
/stop         停止当前运行
/status       查看 core1 状态
/profile      显示 /profile.txt
/mem          core1 栈高水位和上次 Lua 堆
/list         列出 /robots/*.sql
/help         显示命令摘要
↑ / ↓         命令历史（最近 8 条）
```

`/run` 的完整流程：

```text
停止当前动作（stop 标志）
  → 重新挂载/读取 SD
  → 重新读 profile / SQL / MT
  → 重新创建 Lua state 和每个设备 env
  → 执行脚本
  → 返回 idle，等待下一条命令
```

所以改完 SD 上的 `.sql`/`.mt` 后，不需要重新烧固件，输入 `/run` 即可热重载。

键盘没有下划线，提供几个简称：

```text
/run pca       -> pca9685
/run pcafake   -> pca9685_fake
/run ads       -> ads1015
/run spifake   -> spi_fake
/run uartfake  -> uart_fake
/run relay     -> relay-test
```

命令反馈会回到 VGA/串口日志，例如：

```text
core1: run profile p4
...
core1: run finished, idle
core1: status idle
core1: /profile.txt = p4
core1: mem stack=.../16384 heap_last=...KB busy=0 stop=0
core1: profile p4.sql
core1: profile p9.sql
core1: 2 profile(s)
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
p5.value  p5.name  p5.item;
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

预期 VGA：

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
P5Check: call value=nil name=nil
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
P5Check: call value=1 name=nil item=nil
```

## P6：@Include 脚本片段

P6-A 支持顶层 `@Include`：

```mt
@Struct(cfg)
{ "value": 9 }
@

@Include
path;
  parts/inc_p5.mt;
@
```

`/scripts/parts/inc_p5.mt`：

```mt
@Action
p5.value;
 $(cfg.value);
@
```

行为：

- 在解析前把被包含文件的内容拼到 `@Include` 位置
- 路径相对 `/scripts/`，也接受 `/scripts/...` 绝对路径
- 支持多个文件
- 支持 `@Struct` / `@Action` / `@if` / `@while` 等既有语法
- 支持两层：顶层 -> 一级包含 -> 二级包含；二级内容不再继续递归

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
P5Check: call value=9 name=nil item=nil
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
p5.value  p5.item;
 $(cfg.value*count+1) $(cfg.value+1);
@

@if((count+2)*2==8)
p5.ok;
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

预期 VGA：

```text
P2: profile=p7
P2: @Struct cfg.value = 7
P2: @Vars count = 2
P5Check: call value=15 name=nil item=8
P2: p7.call result=OK
P5Check: call value=nil name=nil item=nil
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
p5.name  p5.value;
 $(cfg.name + "-" + count) $(count + 1);
@

@if((cfg.name + "-x") == "pico-x")
p5.ok;
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

预期 VGA：

```text
P2: profile=p8
P2: @Struct cfg.name = pico
P2: @Vars count = 2
P5Check: call value=3 name=pico-2 item=nil
...
P5Check: call value=nil name=nil item=nil
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
p5.A;
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
- 片段动作头 `p5.A` 解析为 `p5.angle`
- `$(n)` 解析为 `200`
- `@Merge` 前会检查设备集是否相交；相交直接拒绝整次归并

测试 profile：

```text
p13
```

预期关键输出：

```text
P2: @Merge /scripts/parts/merge_alias.mt phase=0 rows=1
P5Check: call value=nil name=nil item=nil angle=200
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
270604     0 102056
```

代价：

- 单个 Lua 驱动源码必须小于 24KB
- `@Merge` 片段数量/行数/列数上限变小
- `/mem` 仍然推荐在真实 profile 跑完后检查 core1 栈和 Lua 堆

## P14：@Reflex / @Trigger

P14-A 支持普通 `@Reflex` 和 `@Trigger`：

```mt
@Reflex
name  p5.value;
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
P5Check: call value=42 name=nil item=nil angle=nil
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
p5.value;
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
P5Check: call value=5 name=nil item=nil angle=nil
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
p5.value;
$(v);
loop.v;
@

@Action
loop.v;
   1;
@
```

`loop` 反射执行一次 `p5.value`，然后尝试递归调用 `loop`；第二次进入被拦截。

测试 profile：

```text
p16
```

预期关键输出：

```text
P2: named @Reflex loop parsed
P2: named reflex loop
P5Check: call value=1 name=nil item=nil angle=nil
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
p5.value  p5.item;
 $(cfg.items[idx]) $(cfg.items[idx+1]);
@

@if(cfg.items[idx] > 10)
p5.ok;
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
P5Check: call value=20 name=nil item=30 angle=nil
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
core1: profile p4.sql
core1: profile p9.sql
core1: profile p17.sql
core1: 3 profile(s)
```

`/help` 直接在 core0 显示：

```text
run [sql] [script] / stop / status / profile / mem / list
```

当前命令集：

```text
/run [profile]
/stop
/status
/profile
/mem
/list
/help
```

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
p5.value;
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
P5Check: call value=7 name=nil item=nil angle=nil
P2: p19.call result=OK
```

## P20：SQL 与动作脚本分离选择

P20-A 允许 `/run` 同时指定结构 SQL 和动作脚本：

```text
/run p5 p8
```

表示：

```text
结构: /robots/p5.sql
动作: /scripts/p8.mt
```

用途：

- 同一个动作脚本可以复用不同结构
- 同一个结构可以跑不同动作脚本
- 不需要复制 profile 文件

示例 `p5.sql + p8.mt`：

```text
P5Check: call value=3 name=pico-2 item=nil angle=nil
```

`/run p5` 仍然表示 SQL 和动作都用 `p5`。

协议：

- `ROBOT_CMD_RUN.arg = "<sql> <script>"`
- core1 按第一个空格切分
- 空脚本回退到 SQL 同名脚本

## P21：命令历史

P21-A 给控制台命令模式加上历史：

- 刚才执行过的命令自动进入历史
- `↑` 回看更早的命令
- `↓` 回到更新的命令，越过最新一条时清空输入
- 最多保留 8 条
- 连续重复的命令只保留一条
- 历史只在命令模式内生效，普通拼音输入不受影响

实现：

- 键盘映射里把 `HID_KEY_ARROW_UP/DOWN` 映射成 `0x11/0x12` 事件
- 历史缓冲区保存去掉 `/` 提示符后的命令文本
- 回看时重画 `/` 提示符并逐字符重放
- 回到最新条目后恢复空白命令输入

测试：

```text
/run p17
/list
↑
↑
↓
```

预期：

- 第一次 `↑` 显示 `/list`
- 第二次 `↑` 显示 `/run p17`
- `↓` 回到 `/list`
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
p5.value;
  $(cfg.items[idx+1]);
@

@if((1 == 2 && missing > 0) || cfg.name == "pico-x")
p5.ok;
  7;
@

@while((count < 3) && !(count == 2))
cnt.reading;
 $count=reading;
@
```

测试 profile：

```text
p22
```

预期关键输出：

```text
P5Check: call value=30 name=nil item=nil angle=nil
P5Check: call value=nil name=nil item=11 angle=nil
P5Check: call value=nil name=nil item=nil angle=7
Counter: reading=1
Counter: reading=2
P2: [while] (count < 3) && !(count == 2) -> 2 iteration(s)
P5Check: call value=nil name=nil item=nil angle=45
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

## 运行现象

如果 `USE_VGA=ON`，上电后 VGA 应出现类似；如果 `USE_VGA=OFF`，同样的内容会出现在 UART0 串口（每行带 `[robot]` 前缀）。

```text
core1: robot runtime started
SD: loaded /robot.lua (... bytes)     # 或 SD: /robot.lua not found
Lua 5.1 state ready, heap=...KB
Lua: Lua smoke script loaded
Lua smoke OK, heap=...KB
core1: heartbeat (idle)
core1: heartbeat (idle)
...
```

- 没有 SD 卡或没有 `/robot.lua` 时，会使用内嵌 smoke 脚本，仍能完成验证。
- 拼音输入缓冲区为空时按 **Tab**，VGA 显示 `[robot stop]`，core1 输出
  `core1: stop requested, runtime idle`。
- core1 心跳期间，键盘输入、VGA 刷屏、输入法都应由 core0 正常处理。

## SD 目录建议

FAT 卡根目录放：

```text
/robot.lua
/modules/       # P1 起使用
/robots/        # P1 起使用
/scripts/       # P1 起使用
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
