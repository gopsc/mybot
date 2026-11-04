# 平台支持与限制

脚本只依赖 Python 标准库，但**操作系统能力差异是硬限制**，不能靠代码抹平。

## 能力矩阵

| 能力 | Linux | macOS | Windows |
| --- | --- | --- | --- |
| 列适配器 | 是（`/dev/i2c-*` + sysfs） | 否 | 否 |
| 列内核已绑定客户端 | 是（`/sys/bus/i2c/devices/*-*`） | 否 | 否 |
| 扫描地址 | 是（i2c-dev ioctl） | 否 | 否 |
| 列 USB 桥候选 | `lsusb`（可选） | `ioreg -p IOUSB` | `Get-PnpDevice` |

`supported: false` 的含义是"该平台不提供 i2c-dev 接口"，**不是**"总线上没有设备"。这个区别必须在汇报时说清楚。

## Linux

- 节点来源：`/dev/i2c-N`（glob）+ `/sys/bus/i2c/devices/i2c-N/name`（适配器名）。
- 两者不一致时以组合集为准：节点存在但 sysfs 无记录 → 仍列出；sysfs 有但节点不可见 → `node_visibility: "masked"`，`source: "sysfs"`，`readable`/`writable` 为 `null`。
- 已绑定客户端从 `/sys/bus/i2c/devices/N-XXXX/` 目录名解析：前缀是总线号，后 4 位十六进制是该总线上地址左移 1 位（含读写位），脚本已还原成 7 位地址。
- 驱动未加载时看不到节点：`i2c-dev` 是通用字符设备接口，`i2c-i801`（Intel PCH）、`i2c-bcm2835`（树莓派）、`i2c-designware`（多数 ARM SoC）、`i2c-nvidia-gpu` 等是控制器驱动。缺节点先查这两层，由操作者处理。
- 树莓派还需要 `dtparam=i2c_arm=on`；不要用脚本改 `/boot/firmware/config.txt`。

## 容器与沙箱

- 容器默认不传 `/dev/i2c-*`。需要 `--device /dev/i2c-1` 或 `--privileged`（后者权限过大，不推荐）。
- 只读挂载 `/dev` 时会出现"sysfs 有、节点不可见"的 `masked` 状态。这是本脚本设计支持的场景：**枚举可用，探测不可用**。
- 判定方法：`--list --json` 里 `adapters[].node_present` 全为 `false` 而 `adapter_name` 非空，就是被裁剪了。

## macOS

- 内核不导出 I2C 字符设备，没有 `/dev/i2c-*`，也没有等价 ioctl。这是设计，不是缺驱动。
- Apple Silicon 上的内部 I2C（触摸板、传感器、电源管理）由 SMC/私有 kext 管理，用户态不可访问。
- 要让脚本"真的"扫地址，只有两条路，都需要操作者安装东西：
  - USB-I2C 桥 + 厂商库：FTDI 的 D2XX/libmpsse、Total Phase Aardvark、CH341 第三方驱动。
  - 用另一台 Linux 主机（树莓派等）做扫描端。
- 脚本能做的：通过 `ioreg` 列出 USB 设备并按 Vendor ID 标注是否为潜在 I2C 桥。这是**线索**，不是能力证明。

## Windows

- 同样没有 i2c-dev。WMI/`Get-PnpDevice` 只能看到 PnP 设备树，看不到 I2C 总线拓扑。
- MCP2221A（Microchip）、FT232H（FTDI）等 USB-I2C 桥在 Windows 上有官方 DLL/驱动，可做 I2C；但那是厂商 API，不在本脚本范围内。
- `Get-PnpDevice` 需要 PowerShell 5+。脚本失败时只写 warning，不阻断其余输出。
- WSL2 没有 USB 直通也没有 i2c-dev；WSL1 同样不行。要扫 I2C 用原生 Linux。

## 权限（仅 Linux）

| 现象 | 原因 | 正确做法 |
| --- | --- | --- |
| `error: permission denied` | 当前用户不在 `i2c` / `dialout` / `plugdev` 组 | 操作者 `usermod -aG i2c $USER`，重新登录 |
| 只有 root 能扫 | 默认 udev 规则把 `/dev/i2c-*` 设为 `root:root 600` | 加 udev 规则（由操作者做），不要 `sudo` 跑扫描 |

不要为了省事用 root 跑扫描：扫描进程拿到的是整条总线的写权限，容易在别处出事。
