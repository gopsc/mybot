Source: `i2c-uart-spi-enum/scripts/bus_enum.py` I2C 分支与 Linux i2c-dev/sysfs 接口

# I2C 枚举与探测细节

## 1. 各平台的接口形态

| 平台 | 接口 | 说明 |
| --- | --- | --- |
| Linux | `/dev/i2c-N` 字符设备 | `i2c-dev` 驱动导出；N 是适配器编号 |
| Linux | `/sys/bus/i2c/devices/` | 适配器 `i2c-N` 与已绑定客户端 `N-00XX` 都在这里 |
| macOS | 无 | 没有通用 i2c-dev；需 FTDI/CH34x/Aardvark 等厂商 SDK 或内核扩展 |
| Windows | 无 | 无通用 I2C 命名空间；走厂商 SDK（FTDI D2XX、CH341/CH347、Total Phase） |

因此“枚举不到 I2C”在 macOS/Windows 上是平台限制，不是接线问题。

## 2. sysfs 结构

```text
/sys/class/i2c-dev/i2c-1/name          -> "bcm2835 I2C adapter"（人读名称）
/sys/bus/i2c/devices/i2c-1/            -> 适配器本身
/sys/bus/i2c/devices/1-0068/name       -> "rtc"（已绑定客户端）
/sys/bus/i2c/devices/1-0068/driver     -> 符号链接到驱动目录
```

`N-00XX` 中 `N` 是总线号、`00XX` 是十六进制地址。已经出现在这里的地址通常**不要**再用 `i2cdetect` 之类的工具乱探——内核驱动正在占用它。

## 3. 权限

- 节点通常 `crw-rw---- root:i2c`。把用户加入 `i2c` 组（Debian/Raspberry Pi OS）或 `plugdev`。
- 临时验证可用 udev 规则：

```ini
# /etc/udev/rules.d/60-i2c.rules
KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
```

- 不要用 root 跑扫描：探测会对所有地址发信号，root 下还可能误绑驱动。

## 4. 地址空间与保留地址

7 位地址有效范围 `0x00`–`0x7F`，可用区间通常是 `0x08`–`0x77`。保留/特殊地址：

| 范围 | 含义 |
| --- | --- |
| `0x00` | 通用广播（general call） |
| `0x01` | CBUS 地址 |
| `0x02` | 保留（不同总线格式） |
| `0x03` | 保留 |
| `0x04`–`0x07` | 保留（Hs-mode 主机代码） |
| `0x08` | SMBus Host Notify |
| `0x09`–`0x0F` | 保留 |
| `0x10`–`0x1F` | 保留（CBus / 10 位地址前缀） |
| `0x78`–`0x7F` | 保留（10 位寻址） |

脚本对这些范围会打 `warnings` 标注，出现应答时优先怀疑误报或地址冲突。

## 5. 三种探测方式的语义

| 方式 | 发出的内容 | 副作用 | 备注 |
| --- | --- | --- | --- |
| SMBus quick write | 起始 + 地址+W + 停止 | 无数据字节 | 部分适配器不支持 `SMBUS_QUICK` |
| 零长度 `I2C_RDWR` 写 | 起始 + 地址+W + 停止 | 无数据字节 | 脚本默认路径，最通用 |
| `I2C_SLAVE` + `read(1)` | 起始 + 地址+R + 读 1 字节 | **可能**复位寄存器指针/触发转换 | 仅作兜底，脚本会告警 |

探测只能证明“该地址有器件应答”，不能证明型号。型号推断应结合：`clients` 里的绑定驱动、`/dev/serial/by-id`、SPI `modalias`、设备树节点名，或用户提供的资料。

## 6. errno 对照

| errno | 名称 | 含义 |
| --- | --- | --- |
| 6 | `ENXIO` | 地址无应答（NAK），正常结果 |
| 121 | `EREMOTEIO` | 同上，i2c 子系统常见的 NAK 表现 |
| 13 | `EACCES` | 权限不足 |
| 16 | `EBUSY` | 设备被内核驱动占用 |
| 19 | `ENODEV` | 适配器不存在 / 驱动未绑定 |
| 25 | `ENOTTY` | ioctl 不被该适配器支持 |
| 95 | `EOPNOTSUPP` | 不支持该传输类型（如 quick write） |

## 7. 常见地址速查（推断用，不是保证）

| 地址 | 常见器件 |
| --- | --- |
| `0x1D`/`0x53` | ADXL345、LIS3DH 类加速度计 |
| `0x3C`/`0x3D` | SSD1306 OLED |
| `0x40` | INA219、PCA9685、SI7021 |
| `0x48`–`0x4B` | LM75/TMP102/ADS1115（地址由 ADDR 引脚决定） |
| `0x50`–`0x57` | AT24Cxx EEPROM |
| `0x68`/`0x69` | DS1307/DS3231 RTC、MPU-6050/MPU-9250 |
| `0x76`/`0x77` | BME280/BMP280/BME680 |
| `0x29` | VL53L0X、TCS34725 |

同一地址可能对应多种器件，报告时必须说明这是候选，而非结论。

## 8. 与后续步骤的衔接

枚举完成后，寄存器读写、驱动开发、结构 SQL 声明属于 `hardware-controller` 技能的职责；本技能只负责“有什么总线、挂了什么地址”。
