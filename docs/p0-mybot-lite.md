# P0：mybot-lite 双核、Lua、脚本解析与硬件 HAL

本分支（`mybot-lite-p0`）从 mybot 迁移到 pico-vga 的 P0/P1/P2/P3/P4-B 阶段，验证：

1. **core1 阻塞不会影响 core0 的 VGA / 键盘 / 控制台**
2. **Lua 5.1 能在 RP2040 上启动、加载脚本、执行 `build/call/destroy`，并给出内存水位**
3. **Lua 驱动从 SD 加载，每个驱动有独立 env**
4. **运行期解析 `.sql` / `.mt`，支持 `$ref` / `@Alias` / `@Vars`**
5. **真实 I2C/SPI/UART HAL，以及 PCA9685/ADS1015/AD9833 驱动接入**
6. **`@if` / `@while` 控制流、动作捕获、命令系统与热重载**

还没有实现：`@Struct`、动态 SQL、完整 mybot 表达式 AST。那些属于后续阶段。

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
870564    0 129444
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
247268     0  79032
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
/run          重新读 /profile.txt 并运行
/stop         停止当前运行
/status       查看 core1 状态
/profile      显示 /profile.txt
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
```

`/stop` 立即置 stop 标志；`@while`、`milli_sleep` 和动作派发行会在各自的检查点看到它。长时间阻塞在器件驱动内部的 I2C/SPI/UART 调用只能等超时。

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
