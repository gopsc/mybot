Source: `i2c-uart-spi-enum/scripts/bus_enum.py` UART 分支与 pyserial/系统端口命名

# UART / 串口枚举细节

## 1. 各平台的端口命名

| 平台 | 典型节点 | 说明 |
| --- | --- | --- |
| Linux | `/dev/ttyS0`–`ttyS31` | 主板/SoC 自带 UART；未接线的编号常是幽灵端口 |
| Linux | `/dev/ttyUSB0` | USB 转串口（FTDI/CH340/CP210x） |
| Linux | `/dev/ttyACM0` | USB CDC-ACM（Arduino、ESP32-S2/S3、多数开发板） |
| Linux | `/dev/ttyAMA0`、`/dev/ttySAC0`、`/dev/ttyTHS0` | SoC 厂商命名（树莓派、三星、Jetson） |
| Linux | `/dev/rfcomm0` | 蓝牙串口 |
| macOS | `/dev/cu.*` | 拨出（call-out）设备，**打开串口应优先用 `cu.`** |
| macOS | `/dev/tty.*` | 拨入设备，等待 DCD，可能阻塞 |
| Windows | `COM3`、`COM10` | 打开时建议用 `\\.\COM10` 形式，`COM10` 以上必须如此 |

## 2. 两种枚举后端

| backend | 来源 | 优点 | 缺点 |
| --- | --- | --- | --- |
| `pyserial` | `serial.tools.list_ports.comports()` | 有 VID/PID、序列号、厂商、产品名、`hwid`；过滤幽灵端口 | 需要 `pip install pyserial` |
| `os` | 文件系统 glob / Windows 注册表 `HARDWARE\DEVICEMAP\SERIALCOMM` | 零依赖 | 无 VID/PID；Linux 会列出内核占位的 `ttyS*` |

`backend=os` 时结果偏噪，报告里要说明“缺少 pyserial，端口清单可能包含无效项”。

## 3. 稳定节点（Linux）

`/dev/serial/by-id/*`（USB 序列号相关）与 `/dev/serial/by-path/*`（物理端口路径）是指向真实节点的符号链接，重启不漂移。脚本会列出 `symlinks`。

设备重插后 `ttyUSB0` 可能变成 `ttyUSB1`，所以自动化脚本应使用 `by-id` 路径，而不是写死编号。

## 4. 权限

- Linux：`/dev/ttyUSB*` 通常 `root:dialout`（Debian/Ubuntu）或 `root:uucp`（Arch/openSUSE）。加入对应组后重新登录。
- `brltty` 会抢占 CH340/CP210x 设备，导致端口“消失”或 `EBUSY`；必要时屏蔽该服务（由操作者决定）。
- macOS：一般无需额外权限。
- Windows：端口被其他程序占用时报 `Access is denied`。

## 5. `--check-open` 的副作用

打开串口本身就会：

- 断言 DTR/RTS（`O_NONBLOCK` 不改变这一点）；
- 很多板子把 DTR 接到 EN/RESET，于是**会复位** Arduino、ESP32、ESP8266；
- 打断正在使用的控制台会话（串口只能被一个进程独占）。

因此默认不打开端口，只在用户要求确认权限/可用性时使用，并提前说明风险。

## 6. 常见 USB 串口 VID:PID

| VID:PID | 器件 |
| --- | --- |
| `0403:6001` | FTDI FT232R |
| `0403:6014` | FTDI FT232H（支持 MPSSE，可转 I2C/SPI） |
| `1A86:7523` | CH340/CH341 |
| `1A86:55D4` | CH9102 |
| `10C4:EA60` | Silicon Labs CP2102/CP2104 |
| `067B:2303` | Prolific PL2303 |
| `2341:0043` | Arduino Uno R3 |
| `303A:1001` | Espressif USB JTAG/serial |
| `2E8A:000A` | Raspberry Pi Pico（CDC） |

VID/PID 只能给出候选，同名芯片可能被不同产品复用。

## 7. 枚举之后

通信参数（波特率、数据位、校验、流控）与协议握手不属于枚举范围。需要持续采样或与设备对话时，交给 `hardware-controller` 技能的驱动/动作层，而不是在本技能里加长脚本。
