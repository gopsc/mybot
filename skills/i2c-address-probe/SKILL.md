---
name: i2c-address-probe
description: 用 Python 标准库只读发现 I2C 适配器并扫描从机地址：Linux 走 i2c-dev ioctl（零长度 quick-write 探测，ENXIO/EREMOTEIO 归为 NAK，内核已绑定地址报 busy，容器里 /dev 被裁剪时仍从 sysfs 列总线），macOS/Windows 诚实报告无 i2c-dev 并只列 USB-I2C 桥候选，不伪造扫描结果。当用户说「I2C 扫描」「探一下 I2C 地址」「i2cdetect 替代」「这个地址上有没有设备」「扫 0x48」「总线上挂了什么」「probe i2c address」「i2c scan」「address scan」时使用。
---

# I2C 地址探测

## 1. 适用范围

| 做 | 不做 |
| --- | --- |
| 列出 Linux I2C 适配器（`/dev/i2c-*` + sysfs 回退）、内核已绑定客户端、权限状态 | 读写寄存器、初始化设备、加载内核模块 |
| 可选：扫描 7 位地址区间，区分 `ack` / `nak` / `busy` / `error` | 在 macOS/Windows 上假装能扫地址 |
| 扫描到的地址给出**标注为推测**的常见型号提示 | 把地址猜测当成已确认型号上报 |
| macOS/Windows 列出 USB-I2C 桥候选 | 安装驱动、装 pyserial/smbus2、`sudo` |

分工：只做 I2C 地址层面的事。需要一次看 I2C+UART+SPI 全景，用 `i2c-uart-spi-enum`；需要真正驱动设备、改硬件结构或采样，用 `hardware-controller`。

## 2. 快速开始

脚本：`scripts/i2c_probe.py`，只依赖 Python 3.8+ 标准库，无第三方依赖。

```sh
python3 scripts/i2c_probe.py --list                      # 被动：适配器 + 已绑定客户端
python3 scripts/i2c_probe.py --list --json               # 单行 JSON
python3 scripts/i2c_probe.py --probe                     # 主动：扫描 0x08-0x77
python3 scripts/i2c_probe.py --probe --i2c-device /dev/i2c-1
python3 scripts/i2c_probe.py --probe --addresses 0x48,0x68-0x69 --json
python3 scripts/i2c_probe.py --bridges                   # macOS/Windows 自动开启
```

## 3. 参数

| 参数 | 含义 |
| --- | --- |
| `--list` | 只做被动枚举，不碰总线（默认行为） |
| `--probe` | 主动扫描，关闭状态下永不上总线 |
| `--i2c-device NODE` | 只探测指定节点，可重复；默认探测所有可见适配器 |
| `--addresses SPEC` | `0x08-0x77` 区间或 `0x48,0x68` 列表；带 `0x` 按十六进制，不带按十进制 |
| `--bridges` | 额外列 USB-I2C 桥候选（macOS/Windows 默认已开） |
| `--json` | 单行 JSON 到 stdout，告警进 `warnings` |

退出码：`0` 成功；`1` 有请求的动作失败（节点打不开、地址返回 `error:`）；`2` 参数错误。

## 4. 工作流

1. **先被动**：`--list --json`。确认适配器存在、节点可见、权限正常。
2. **看 `node_present` / `node_visibility`**：`masked` 说明内核 sysfs 有这条总线，但当前进程看不到 `/dev` 节点（容器、沙箱、或 `/dev` 被裁剪）。此时清单来自 sysfs，`--probe` 必须在宿主机执行，不要在沙箱里反复重试。
3. **看权限**：`readable` 为 `false` 时报告权限问题，让操作者把自己加进 `i2c` 组；**不要**用 root 跑扫描。
4. **确认用户确实要主动探测后**，才加 `--probe`。先扫小范围（如 `--addresses 0x48`）验证通路，再扫全区间。
5. **读结果**：`ack` = 该地址有应答；`nak` = 主要现象，不计入 `detail`；`busy` = 该地址已被内核驱动占用，去 `clients` 里查是谁。
6. **解释型号**：`hints` 里的条目一律标注为推测（`confidence: "speculation"`），必须同时说明依据（地址、`clients` 里的绑定驱动名、用户描述），不能只报型号。
7. **交接**：需要后续读写时，把总线号、节点、地址交给 `hardware-controller`。

## 5. 输出解读

```json
{
  "platform": "linux", "python": "3.11.2", "supported": true, "ok": true,
  "probes": [{
    "device": "/dev/i2c-1", "ok": true, "addresses_scanned": 112,
    "found": ["0x48", "0x68"],
    "detail": {"0x48": "ack", "0x68": "busy"},
    "hints": {"0x48": {"guess": "ADS1115/ADS1015 (ADDR=GND), LM75, PCF8591", "confidence": "speculation"}},
    "reserved": {}
  }],
  "clients": [{"bus": 1, "address": "0x68", "name": "rtc", "driver": "rtc-ds1307", "state": null}],
  "warnings": []
}
```

| 字段 | 含义 |
| --- | --- |
| `supported: false` | 平台不提供 i2c-dev（macOS/Windows），不是"总线上没设备" |
| `probes[].ok: false` | 该节点打不开，`error` 给原因；`ok: false` 的探测不算成功 |
| `detail` 只含非 `nak` 项 | `nak` 是常态，不占空间；要看全量就扫小区间 |
| `hints` | 地址 → 常见型号**推测**，不是识别结果 |
| `reserved` | 落在保留地址却回了 `ack`，通常意味着地址计算或接线有问题 |
| `bridges[].possible_i2c` | 按 Vendor ID 匹配的桥能力提示，不代表这台设备可用 I2C |

## 6. 硬规则

- 默认不碰总线。`--probe` 必须由用户明确要求或确认后才加。
- 探测方式优先零长度 `I2C_RDWR` quick-write（总线上不出现数据字节）；适配器拒绝时才降级到 1 字节读，降级会写进 `warnings`，要一并告知用户——1 字节读对某些设备有副作用。
- 扫描结果为空**不要**断言"没有设备"。先看 `warnings`、权限、`node_visibility`，再换总线号重试一次。
- `busy` 不是故障，是被内核驱动占了；必须去 `clients` 里指明是谁。
- 不要把 `hints` 当结论。用户问"这是什么芯片"时，先问型号丝印或看 `clients`。
- 不为跑脚本而 `pip install`、`sudo` 或改 udev/设备树；缺什么就如实说明。
- 退出码 1 要如实上报失败，不要描述成扫描成功。
- 全区间输出 112 行，向用户汇报时只摘要 `found` 和异常项。

## 7. 排障

| 现象 | 处理 |
| --- | --- |
| `no /dev/i2c-* node` | 驱动未加载（`i2c-dev`、`i2c-i801`、`i2c-bcm2835`）或设备树未启用，由操作者在宿主机处理 |
| 全是 `masked` | 容器/沙箱裁剪了 `/dev`；到宿主机跑，或加 `--device /dev/i2c-1` |
| 全部 `nak` | 接线、上拉、供电，或总线号选错；确认 3.3V 与 GND，换 `/dev/i2c-0` 再试 |
| `error: permission denied` | 加入 `i2c` 组或由操作者配 udev 规则，不要用 root |
| `busy` | 已被内核驱动绑定，见 `clients`；要直连需先解绑驱动 |
| `error: Inappropriate ioctl for device` | 参数给错了节点（如 `/dev/null`），不是 I2C 设备 |
| macOS/Windows 报不支持 | 正常行为：内核无 i2c-dev。看 `bridges`，或改用桥厂商 SDK / 树莓派等 Linux 主机 |

平台差异、桥能力、容器与权限细节：`references/platform-support.md`。
保留地址、常见地址表与判读方法：`references/address-map.md`。
