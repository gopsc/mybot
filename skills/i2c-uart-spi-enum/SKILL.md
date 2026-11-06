---
name: i2c-uart-spi-enum
description: 跨平台（Linux/macOS/Windows）枚举 I2C、UART/串口、SPI 设备的只读脚本与流程，含 Linux i2c-dev 地址扫描、pyserial 串口清单与 VID/PID、spidev 节点与回环自检，并给出各系统依赖安装命令。当用户说「枚举外设」「扫描 I2C 地址」「i2cdetect」「列出串口或 COM 口」「找 SPI 设备」「看看总线挂了什么设备」「装 pyserial」，或提到 enumerate i2c uart spi devices、bus scan、serial port list、spidev 时使用。
---

# I2C / UART / SPI 设备枚举

## 1. 适用范围

| 做 | 不做 |
| --- | --- |
| 列出操作系统已暴露的 I2C 适配器、已绑定客户端、串口（含 VID/PID）、SPI 控制器与 spidev 节点 | 寄存器级读写、驱动开发、加载内核模块 |
| 可选：I2C 地址扫描、串口打开权限检查、SPI 回环自检 | 改 udev 规则、改设备树、安装系统驱动 |
| 输出文本摘要或单行 JSON | 猜测未知设备型号并当作事实 |

枚举完还要真正驱动设备、改硬件结构或采样传感器，转到 `hardware-controller` 技能。

## 2. 平台能力矩阵

脚本在三个平台都能运行；平台没有对应内核接口时输出 `supported=false` 并给出原因，这是平台限制，不是接线问题。

| 能力 | Linux | macOS | Windows |
| --- | --- | --- | --- |
| I2C 适配器 / 已绑定客户端 | `/dev/i2c-N` + sysfs | 不支持 | 不支持 |
| I2C 地址扫描（`--probe`） | `i2c-dev` ioctl | 不支持 | 不支持 |
| 串口枚举 | `/dev/tty*`、`/dev/serial/by-id` | `/dev/cu.*`、`/dev/tty.*` | `COMx`（pyserial 或注册表） |
| 串口打开检查（`--check-open`） | 支持 | 支持 | 支持（自动用 `\\.\COMx`） |
| SPI 控制器 / spidev 节点 | sysfs + `/dev/spidev*` | 不支持 | 不支持 |
| SPI 回环（`--loopback`） | spidev ioctl | 不支持 | 不支持 |

macOS/Windows 的 I2C/SPI 只能经厂商 SDK 或 USB 桥（FTDI、CH341/CH347、Aardvark）访问，本脚本不封装这些 SDK；需要时由操作者在宿主机用厂商工具枚举。

## 3. 安装依赖

脚本只用 Python 标准库即可运行，以下依赖都是**可选**的增强项。安装属于环境变更：由**操作者**在宿主机执行；Agent 不得自行 `pip install` 或 `sudo`，缺依赖时说明影响即可。

### 3.1 运行时

Python 3.8+。命令按平台区分：Linux/macOS 用 `python3`，Windows 用 `py -3`（或已配置好的 `python`）。

### 3.2 可选依赖

| 依赖 | pip 包名 | 用途 | 生效平台 |
| --- | --- | --- | --- |
| pyserial | `pyserial` | 串口 VID/PID、序列号、厂商、产品名；过滤幽灵端口 | Linux / macOS / Windows |
| smbus2 | `smbus2` | 用 SMBus quick write 做 I2C 探测（无 smbus2 时走 ctypes ioctl） | 仅 Linux |

### 3.3 各平台安装

Linux（Debian/Ubuntu 示例，其他发行版把包名换成 `python3-pyserial` 对应包）：

```sh
sudo apt install python3-serial        # 可选：发行版包
sudo usermod -aG i2c,dialout "$USER"   # 重新登录后生效
python3 -m pip install --user pyserial smbus2   # 或装进 venv
```

macOS（Homebrew 的 Python 受 PEP 668 保护，优先用 venv）：

```sh
brew install python
python3 -m venv .venv
. .venv/bin/activate
python -m pip install pyserial smbus2
```

Windows（PowerShell）：

```powershell
py -3 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install pyserial smbus2
```

`smbus2` 在 macOS/Windows 装了也用不上：那里没有 `i2c-dev`，`--probe` 本来就不执行。

### 3.4 验证与缺失影响

```sh
python3 -c "import serial; print(serial.__version__)"    # Windows: py -3 -c ...
```

| 缺失项 | 运行表现 | 影响 |
| --- | --- | --- |
| 无 pyserial | `backend=os`，stderr 告警 | 没有 VID/PID/产品名；Linux 可能列出内核占位的 `ttyS*` |
| 无 smbus2 | 自动改用 ctypes ioctl | 探测仍可用；适配器拒绝零长度传输时降级 1 字节读（有副作用告警） |
| 无 `i2c`/`dialout` 组权限 | `readable=false`、`EACCES` | `--probe` 失败；由操作者修组权限或 udev 规则 |

Node 运行时之外的一切安装（内核模块、udev、设备树 overlay）都不属于本技能，见 `references/i2c.md`、`references/spi.md` 的说明。

## 4. 快速开始

脚本：[scripts/bus_enum.py](scripts/bus_enum.py)。

```sh
python3 scripts/bus_enum.py --bus all            # 文本摘要
python3 scripts/bus_enum.py --bus all --json     # 单行 JSON
python3 scripts/bus_enum.py --bus uart
python3 scripts/bus_enum.py --bus uart --include-phantom
python3 scripts/bus_enum.py --bus i2c --probe
python3 scripts/bus_enum.py --bus i2c --probe --i2c-device /dev/i2c-1 --addresses 0x48,0x68-0x69
python3 scripts/bus_enum.py --bus spi --loopback /dev/spidev0.0 --spi-speed 500000
```

Windows 把 `python3` 换成 `py -3`，设备名换成 `COM3`。参数约定：

- `--bus`：`all`/`i2c`/`uart`/`spi`，可重复；默认 `all`。
- `--addresses`：`0x08-0x77` 区间或 `0x48,0x68` 列表；带 `0x` 按十六进制，不带按十进制。
- `--probe`、`--check-open`、`--loopback` 是**主动**操作，默认全部关闭。
- `--include-phantom` 才会列出 `uart_type=0`（背后没有 UART）的 `ttyS*` 占位节点，默认隐藏。
- `--json` 输出一行 JSON 到 stdout；所有告警另写 stderr，并同时收进 JSON 的 `warnings`。

## 5. Agent 调用方式

宿主把入口脚本暴露为 `i2c_uart_spi_enum_run(command, args)`。脚本**没有子命令**，`command` 就是第一个 CLI token：

```text
i2c_uart_spi_enum_run(command="--bus", args=["i2c", "--json"])
i2c_uart_spi_enum_run(command="--json", args=["--bus", "all"])
```

- `args` 一个列表项对应一个 token，不要拼成整串。
- **总是带 `--json`**：宿主按 JSON 解析 stdout，文本模式会得到 `Invalid JSON output`。
- 主动操作只在用户明确要求时追加 `--probe` / `--check-open` / `--loopback`。

## 6. 工作流

1. **先被动枚举**：`--bus all --json`，确认适配器/端口/节点是否真存在。
2. **读 `notes` 与 `node_visibility`**：`notes` 为空说明总线可用；有 note 通常是驱动没加载、节点没导出或平台本身不提供（macOS/Windows 无 i2c-dev、spidev）。`node_visibility=masked` 表示内核 sysfs 里有该总线，但当前进程看不到 `/dev` 节点（容器/沙箱裁剪了 `/dev`）——清单来自 sysfs，`--probe`/`--check-open`/`--loopback` 必须回宿主机执行。
3. **权限**：`readable`/`writable` 为 false 时报告权限问题，让操作者把自己加入 `i2c`/`dialout` 组，**不要**用 root 跑扫描。
4. **需要确认设备真的在线**时，才加 `--probe`（I2C）或 `--loopback`（SPI，需 MOSI↔MISO 短接），或 `--check-open`（UART，会拉 DTR）。
5. **解释结果**：扫描到的地址只代表“该地址有应答”，不等于已知型号。给出型号推断时必须标注为推测，并说明依据（绑定驱动名、`by-id` 路径、`modalias`、常见地址表见 `references/i2c.md`）。
6. **交接**：需要后续读写时，把设备节点和总线号交给 `hardware-controller` 技能，由它做驱动/动作。

## 7. 硬规则

- 默认不主动碰总线；主动操作必须由用户明确要求或确认后再加参数。
- `--check-open` 会打开串口，可能拉 DTR 复位 Arduino/ESP32；对正在跑控制台的端口要提醒风险。
- `--loopback` 只在 MOSI 与 MISO 短接时才有意义；有真实从设备接着时只代表一次普通传输，`echo=false` 不是故障。
- 扫描结果为空时不要断言“没有设备”，先看 `notes` 与权限，再换总线号重试一次。
- 不要为跑脚本而 `pip install` 或 `sudo`：把 §3 的命令交给操作者，并说明缺依赖的影响。
- 退出码 1 表示某个请求的动作失败（打不开节点、传输报错），要如实上报，不要谎称扫描成功。
- 单条命令的输出可能很长（112 个地址），向用户汇报时摘要关键行，不要整段倾倒。

## 8. 输出结构

```json
{
  "platform": "linux",
  "python": "3.11.2",
  "buses": ["i2c", "uart", "spi"],
  "ok": true,
  "warnings": [],
  "i2c": {
    "supported": true,
    "adapters": [
      {"device": "/dev/i2c-1", "bus": 1, "adapter_name": "bcm2835 I2C adapter",
       "readable": true, "writable": true,
       "probe": {"addresses_scanned": 112, "found": ["0x48"],
                 "detail": {"0x48": "ack"}, "warnings": {"0x48": "reserved ..."}}}
    ],
    "clients": [{"bus": 1, "address": "0x68", "name": "rtc", "driver": "rtc-ds1307"}],
    "notes": []
  },
  "uart": {
    "supported": true,
    "backend": "pyserial",
    "ports": [{"device": "/dev/ttyUSB0", "description": "USB Serial", "hwid": "USB VID:PID=0403:6001",
               "vid": "0x0403", "pid": "0x6001", "serial_number": "A123", "manufacturer": "FTDI",
               "product": "FT232R USB UART", "interface": null}],
    "symlinks": [{"path": "/dev/serial/by-id/usb-FTDI_...", "target": "/dev/ttyUSB0"}],
    "notes": []
  },
  "spi": {
    "supported": true,
    "controllers": [{"name": "spi0", "driver": "spi-bcm2835"}],
    "devices": [{"device": "/dev/spidev0.0", "bus": 0, "chip_select": 0, "modalias": "spi:spidev",
                 "device_tree_node": "spidev@0", "readable": true, "writable": true}],
    "notes": [],
    "loopback": {"/dev/spidev0.0": {"ok": true, "echo": true, "tx": "a55a...", "rx": "a55a..."}}
  }
}
```

字段要点：`supported=false` 表示平台不提供该总线接口（不是设备不存在）；`backend=os` 表示没有 pyserial、走系统兜底清单；`probe.detail` 只列应答项与错误，`nak` 不占空间。

补充字段：

| 字段 | 含义 |
| --- | --- |
| `node_present: false` | 内核 sysfs 有该设备，但当前进程看不到对应 `/dev` 节点（容器/沙箱），此时 `readable`/`writable` 为 `null` |
| `node_visibility: "masked"` | 出现在 `i2c`/`uart` 段，表示该总线整体存在 `/dev` 不可见，清单来自 sysfs |
| `source: "sysfs"` | 该条目来自 sysfs 回退，不是 `/dev` glob |
| `uart_type` | sysfs `type`：`4`=16550A 真实串口，`0`=背后没有 UART（幽灵端口，默认隐藏） |
| `clients[].state` | 例如 `waiting_for_supplier (no driver bound)`，说明 ACPI 声明了设备但没有驱动接管 |

## 9. 排障

| 现象 | 处理 |
| --- | --- |
| `no /dev/i2c-* node` | 驱动未加载（`i2c-dev`、`i2c-i801`、`i2c-bcm2835`）或设备树未启用；由操作者在宿主机处理 |
| 全部地址 `nak` | 供电/上拉/接线问题，或总线号选错；换 `/dev/i2c-0`、确认 3.3V 与 GND |
| `error: Permission denied` | 用 `i2c`/`dialout`/`plugdev` 组或 udev 规则修权限，不要用 root |
| `error: Device or resource busy` | 该地址已被内核驱动绑定，见 `clients` 列表 |
| 探测时出现 `EREMOTEIO`/`ENXIO` | 正常的 NAK（无从机应答），脚本已归为 `nak` |
| `no /dev/spidev* node` | 需要 `CONFIG_SPI_SPIDEV`、`modprobe spidev` 或设备树 overlay |
| UART 端口看着重复/幽灵 | `uart_type=0` 就是幽灵端口，默认已隐藏；`--include-phantom` 可查看 |
| 清单有设备但 `/dev` 里没有 | `node_visibility=masked`：`/dev` 被容器或沙箱裁剪，清单取自 sysfs；探测/打开必须回宿主机 |
| 只有 `spi0 (intel-spi)` | PCH 固件/BIOS flash 控制器，不是通用 SPI 总线，没有 spidev 是正常的；**不要**往上面写数据 |
| Windows 没有 `python3` 命令 | 用 `py -3` 或 `python`；见 §3.1 |
| macOS 上 `pip install` 报 `externally-managed-environment` | 用 §3.3 的 venv，不要加 `--break-system-packages` |

## 10. 参考资料

- `references/i2c.md`：节点与 sysfs 结构、权限、保留地址表、三种探测方式的副作用与 errno 含义。
- `references/uart.md`：各系统端口命名、pyserial 字段、by-id/by-path、常见 USB 串口 VID/PID。
- `references/spi.md`：spidev 命名、ioctl 常量与结构体布局、回环自检原理与常见坑。