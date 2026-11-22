# mybot-lite headless（RP2040）

这是从 [pico-umac](https://github.com/evansm7/pico-umac) 分支演化出的
mybot-lite 固件。**当前版本已移除 VGA 显示、USB HID 键盘/鼠标和中文输入法**，
只保留 UART 串口控制台与机器人运行时。

原始 pico-umac 代码版权归 Matt Evans，MIT 许可；后续修改归 qing。

## 当前形态

```text
RP2040
  UART0 GP0/GP1   115200 8N1   控制台 + 日志
  SPI0  GP2-5      5MHz        SD 卡（FAT）
  I2C0  GP6/GP7                PCA9685 / ADS1015
  UART1 GP8/GP9                串口设备
  SPI1  GP10-13               AD9833
  GP25                        板载 LED
```

- 没有 VGA、PIO 视频、DMA framebuffer。
- 没有物理键盘/鼠标、USB HID、USB CDC；USB 口只用于供电和 BOOTSEL/UF2 烧录。
- core0：UART 控制台、日志、LED。
- core1：Lua 5.1、运行期 SQL/MT 解析、I2C/SPI/UART 驱动。

## 构建

需要 Pico SDK 和 ARM 工具链：

```sh
cd /home/qing/pico-vga
cmake -S . -B build -G Ninja \
  -DPICO_SDK_PATH=/home/qing/pico/pico-sdk \
  -DPICO_NO_PICOTOOL=1
cmake --build build -j4
```

有 picotool 时生成 UF2：

```sh
picotool uf2 convert build/firmware.elf build/firmware.uf2 --family rp2040
```

本机尺寸（SD 固定开启）：

```text
text    data     bss
266752     0  100020
```

## SD 卡（必需）

SD 支持是固定功能，没有无 SD 构建。把 `sdcard/` 下的内容拷到 FAT 卡根目录：

```text
/profile.txt
/robot.lua
/modules/
/robots/
/scripts/
/sql/
```

`/profile.txt` 只写 profile 名，例如：

```text
p23
```

没有可用 profile 时会依次尝试内置 fallback。

## 串口控制台

接 UART0（GP0 TX、GP1 RX），115200 8N1。上电后：

```text
[console] mybot-lite headless (UART0)
[console] type /help for commands
[robot] core1: robot runtime started
>
```

命令按行输入，`/` 可写可不写：

```text
/run p23     运行 /robots/p23.sql + /scripts/p23.mt
/run p5c p5   用 /robots/p5c.sql + /scripts/p5.mt
/run         重新读 /profile.txt
/stop        停止当前运行
/status      查看 core1 状态
/profile     显示 /profile.txt
/mem         core1 栈高水位和 Lua 堆
/list        列出 /robots/*.sql
/sql name    对 active 结构应用 /sql/name.sql
/action name 在 active 结构上重播 /scripts/name.mt
/action      重播最近一次动作脚本
/repeat name [count] [delay_ms]  批量重播
/unload      销毁 active 设备并关闭 Lua
/help        命令摘要
↑ / ↓        命令历史（ANSI）
Ctrl-C       发送停止请求
```

日志行统一带 `[robot]` 前缀。运行期有日志到达时，控制台会重画当前输入行。

## 脚本

结构脚本是 `.sql`，运行期解析 `CREATE TABLE` / `INSERT INTO`，不依赖 SQLite。
动作脚本是 `.mt`，支持 `@Action`、`@if`、`@while`、`@Struct`、`@Vars`、
`@Alias`、`@Include`、`@Merge`、`@Reflex`、`@Trigger` 等当前子集。

`/run` 执行完后设备保持 active；用 `/sql <name>` 应用 `/sql/<name>.sql` 热补丁，
用 `/unload` 销毁设备并关闭 Lua。完整阶段说明见
[docs/p0-mybot-lite.md](docs/p0-mybot-lite.md)。

## 许可

本项目沿用上游 MIT 许可；原始 pico-umac 版权归 Matt Evans。
