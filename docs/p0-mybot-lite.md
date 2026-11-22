# P0：mybot-lite 双核与 Lua 冒烟

本分支（`mybot-lite-p0`）是 mybot 迁移到 pico-vga 的第一阶段，只验证两件事：

1. **core1 阻塞不会影响 core0 的 VGA / 键盘 / 控制台**
2. **Lua 5.1 能在 RP2040 上启动、加载脚本、执行 `build/call/destroy`，并给出内存水位**

还没有实现：SQL/MT 解析、I2C/SPI/UART HAL、Lua 驱动环境、命令系统。那些属于 P1/P2。

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
844700    0 103776
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
222828     0  53508
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
    lib/
      HAL.lua
      drv_common.lua
      print_table.lua
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

下一步 P2 会把 mybot 的 `sqlparse` + `matrix` 接进来，执行真实 `.sql` / `.mt`。

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
