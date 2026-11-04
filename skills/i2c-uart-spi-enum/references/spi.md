Source: `i2c-uart-spi-enum/scripts/bus_enum.py` SPI 分支与 Linux spidev ioctl

# SPI 枚举与回环自检细节

## 1. 平台差异

| 平台 | 接口 |
| --- | --- |
| Linux | `/dev/spidev<bus>.<cs>` 字符设备，需 `CONFIG_SPI_SPIDEV` 或 `modprobe spidev` |
| macOS | 无通用 spidev；需厂商驱动或 USB-SPI 桥（FTDI/CH347/Aardvark） |
| Windows | 无通用 spidev；走厂商 SDK |

## 2. 命名与 sysfs

```text
/dev/spidev0.0              # 总线 0，片选 0
/sys/class/spidev/spidev0.0/device/modalias      # 例如 "spi:spidev" 或 "spi:spidev,...."
/sys/class/spidev/spidev0.0/device/of_node       # 设备树节点符号链接
/sys/class/spi_master/spi0/device/driver         # 控制器驱动（spi-bcm2835、spi-pxa2xx-pci ...）
```

只有当设备树/ACPI 里存在 spidev 子节点（或平台代码注册了 spidev）时才会出现 `/dev/spidev*`。控制器存在而设备节点不存在是**正常**状态：说明还没有为某个片选导出用户态节点。

树莓派上典型做法（由操作者在宿主机执行，不要在本技能里改配置）：

```ini
# /boot/firmware/config.txt
dtparam=spi=on
dtoverlay=spi1-3cs
```

## 3. 权限

`/dev/spidev*` 通常 `root:spi` 或 `root:gpio`，`crw-rw----`。把用户加入对应组；避免用 root 跑传输。

## 4. spidev ioctl 常量

| 常量 | 值 | 参数 |
| --- | --- | --- |
| `SPI_IOC_RD_MODE` / `SPI_IOC_WR_MODE` | `0x80016B01` / `0x40016B01` | `__u8`（0–3） |
| `SPI_IOC_RD_BITS_PER_WORD` / `WR` | `0x80016B03` / `0x40016B03` | `__u8` |
| `SPI_IOC_RD_MAX_SPEED_HZ` / `WR` | `0x80046B04` / `0x40046B04` | `__u32` |
| `SPI_IOC_MESSAGE(n)` | `_IOW('k', 0, struct spi_ioc_transfer[n])` | 传输数组 |

`SPI_IOC_MESSAGE(n)` 的大小取决于体系结构，所以脚本动态计算：

```python
size = struct.calcsize("PPIIHBBBBBB")          # 64 位: 32，32 位: 24
ioctl = (1 << 30) | (size << 16) | (ord("k") << 8)   # nr = 0
```

结构体布局（内核 `include/uapi/linux/spi/spidev.h`）：

```c
struct spi_ioc_transfer {
    __u64 tx_buf; __u64 rx_buf;
    __u32 len;    __u32 speed_hz;
    __u16 delay_usecs;
    __u8 bits_per_word, cs_change, tx_nbits, rx_nbits;
    __u8 word_delay_usecs, pad;
};
```

## 5. 回环自检（`--loopback`）

原理：把 MOSI 与 MISO 用杜邦线短接，发一串字节，收到的应当是同一串字节（`echo=true`）。

- 必须用**一次全双工传输**（`SPI_IOC_MESSAGE`）。`write()` 后再 `read()` 是两次独立传输：读阶段发的是无关字节，回读值不会等于发送值。
- `echo=false` 不一定是故障：总线上有真实从设备、或 MOSI/MISO 未短接时都会不一致。
- 有真实从设备时不要跑回环测试，发送的字节可能被解释成命令。
- 从 1 MHz、mode 0、8 bit 起试；高速下杜邦线/长排线容易出误码。

## 6. 常见问题

| 现象 | 可能原因 |
| --- | --- |
| 没有 `/dev/spidev*` | 未加载 spidev、设备树无子节点、`CONFIG_SPI_SPIDEV=m` 但未 modprobe |
| `Permission denied` | 组权限不对，或 SELinux/AppArmor 限制 |
| `Invalid argument` | mode/bits 超出控制器能力，或速度过高 |
| 传输成功但读回全 `0x00`/`0xFF` | MISO 未接、从设备未供电、CS 接错 |
| `Device or resource busy` | 该片选已被内核驱动绑定（如 spidev 已用于 framebuffer） |

## 7. 枚举之后

真正的寄存器时序、片选控制、DMA/中断、以及把 SPI 设备纳入机器人结构，属于 `hardware-controller` 技能；本技能只负责列出控制器与节点、并验证通道是否通畅。
