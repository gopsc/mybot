# i2c-address-probe 使用与判读

Source: 实现是 `skills/i2c-address-probe/scripts/i2c_probe.py`（i2c-dev ioctl 绑定地址 +
SMBus read byte），内核语义以 Linux `Documentation/i2c/dev-interface` 与
`Documentation/i2c/smbus-protocol` 为准；本文件只写权限、输出判读与排查顺序。

## 1. 权限

`i2c-dev` 以 `O_RDWR` 打开设备节点，**即使只做读探测也需要写权限**。满足任一条件即可：

- 以 `root` 运行（不推荐长期这样）；
- 当前用户在 `i2c` 组：`groups | grep i2c`，缺则 `sudo usermod -aG i2c $USER` 后**重新登录**。

本技能不改权限、不改 `/dev/i2c-*` 的 `chmod`、不用 `sudo` 掩盖问题。打不开就报告，由操作者决定。

检查节点：

```sh
ls -l /dev/i2c-*
```

没有节点通常是适配器没加载：树莓派看 `dtparam=i2c_arm=on` / `dtoverlay=i2c-...`，USB-I2C（CH341/FTDI/CP2112）看 `dmesg | tail` 是否枚举成功。

## 2. 探测方式与副作用

对每个地址：

1. `ioctl(fd, I2C_SLAVE, addr)` 绑定从机地址；
2. `ioctl(fd, I2C_SMBUS, {read_write=READ, command=0, size=BYTE})` 读 1 字节；
3. 若适配器不支持 SMBus（`EINVAL`/`ENOTSUP`），回落到一次纯 I2C 单字节读。

**不写任何数据字节。** 这与 `i2cdetect` 的默认 quick-write 模式不同：那个模式会向每个地址写 1 字节，可能改变 DAC 输出、触发一次转换、写进 EEPROM、吸合继电器。要用 `i2cdetect` 必须显式带 `-r`（读模式）。

但读也不是绝对无副作用：

| 器件类型 | 读一次的后果 |
| --- | --- |
| FIFO 型 ADC（如 ADS1x15 连续模式） | 弹出一个采样值 |
| 状态机传感器（如部分温湿度） | 推进一次测量状态 |
| 中断状态寄存器 | 可能清中断标志 |
| 带自动递增指针的器件 | 指针前移 |

能停机再扫。运行中的闭环控制不要边跑边扫。

## 3. 输出

### 网格（给人看）

```
bus: /dev/i2c-1   range: 0x08-0x77   probed: 112 x 1
       0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
00:                           -- -- -- -- -- -- -- --
10:   -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
20:   -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
30:   -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
40:   -- -- -- -- -- -- -- -- 1f -- -- -- -- -- -- --
50:   -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
60:   -- -- -- -- -- -- -- -- UU -- -- -- -- -- -- --
legend: XX=read value  --=NACK  UU=kernel driver bound  ??=flapping  EE=error  blank=out of range
found: 1  0x48
kernel-bound: 0x68=ds1307
failed: nack=110
```

`XX` 的两位是该器件返回的字节，仅作“确实读到了东西”的证据，**不是型号 ID**——除非你已经在驱动里确认了 ID 寄存器语义。

### JSON（给程序）

字段固定，可直接 `json.loads`：

```json
{"bus": "/dev/i2c-1", "bus_id": 1, "range": "0x08-0x77", "probed": 112, "repeat": 1,
 "count": 1, "found": ["0x48"], "acks": {"0x48": "read:1F"}, "unstable": [],
 "bound": {"0x68": "ds1307"}, "failed": {"nack": 110}, "exit_code": 0}
```

- `found`：稳定应答的地址；
- `acks`：每个命中地址的读回证据；
- `unstable`：`--repeat > 1` 时，有时应答有时不应答的地址；
- `bound`：被内核驱动占用（`EBUSY`）的地址及其驱动名（`--no-sysfs` 时不查名字）；
- `failed`：失败原因的计数，`nack` 最常见，其余形如 `errno_5`、`set_slave_errno_16`。

## 4. 退出码

| 码 | 含义 | 下一步 |
| --- | --- | --- |
| `0` | 扫描完成（**0 命中也是 0**） | 看 `count` 与 `failed` 再下结论 |
| `1` | 内部错误 | 看 stderr 的异常信息 |
| `2` | 参数错误（含越界地址范围） | 修参数；范围不会被静默裁剪 |
| `3` | 打不开总线：权限 / 节点不存在 / 无 `python3` | 第 1 节 |
| `4` | 有事务，但全部非 NACK 失败 | 总线本身不通：适配器掉线、`i2c-dev` 异常 |

`0` 只表示“扫完了”，**不表示“扫到了”**。判读必须结合退出码和 `failed` 计数。

## 5. errno 对照

| errno | 值 | 在本工具里的含义 | 处置 |
| --- | --- | --- | --- |
| `EREMOTEIO` | 121 | 从机 NACK（最常见）；Linux 对 NACK 统一报这个 | 见第 6 节 |
| `ENXIO` | 6 | 地址无器件应答 | 同上 |
| `EBUSY` | 16 | 地址已被内核驱动绑定，`I2C_SLAVE` 被拒 | 不是 NACK；查 `bound` 与 `/sys/bus/i2c/devices/` |
| `EACCES`/`EPERM` | 13/1 | 权限不足 | 第 1 节 |
| `ENOENT` | 2 | 设备节点不存在 | 适配器未加载 |
| `EINVAL`/`ENOTSUP` | 22/95 | 适配器不支持该 SMBus 事务 | 工具自动回落到纯读；仍失败即适配器缺陷 |
| `EIO`/`ENODEV` | 5/19 | 适配器在事务中途掉线 | USB 接触、供电、线长 |

关键陷阱：**NACK 和“总线不通”在读取层不可区分**。所以 0 命中既可能是没器件，也可能是没上拉/没供电/扫错总线。用已知地址交叉验证：

```sh
sh scripts/i2c_probe.sh /dev/i2c-1 --addr 0x48
```

已知器件也不应答 → 问题在物理层或总线选择，不在地址表。

## 6. 0 命中怎么查

按这个顺序，别跳步：

1. **供电**：用万用表量器件 VCC/GND，别信“应该是有电的”。
2. **扫对总线了吗**：`--list-buses` 看清编号；树莓派 1 和 0 经常是两条不同总线（`i2c-1` 是 GPIO2/3 的那条）。
3. **上拉**：多数模块自带 4.7k–10k；裸芯片必须外接。缺上拉时空闲电平浮空，结果常是“有时有有时没有”。
4. **SDA/SCL 是否接反**：接反通常表现为全 NACK，且不损坏器件（多数器件 I/O 有保护），逐条排除即可。
5. **地址跳线**：同一颗芯片常见 2–4 个可选地址（A0/A1 引脚或焊盘），对照数据手册，不要照抄别人的地址。
6. **器件是否被 Hold 在复位/关断**：有些传感器有 EN/RESET 引脚。
7. **总线占用**：扫描期间跑着 pymybot/Daemon 采样，或别的进程开着同一节点，结果会抖。
8. **线长与速率**：>30cm 的杜邦线在 400kHz 下经常不稳，降到 100kHz 再试。

跑 3 次看稳定性：

```sh
sh scripts/i2c_probe.sh /dev/i2c-1 --repeat 3
```

`unstable` 非空 = 物理层问题（接触、线长、上拉），不是地址问题。

## 7. 命中之后：地址 → 候选驱动

1. 读候选驱动的头注释，**不要凭记忆写地址表**：

   ```sh
   head -40 modules/<driver>.py
   head -40 modules/<driver>.lua
   ```

2. 读 `read_skill("hardware-controller", "references/driver-lua.md")` 了解驱动契约；
   需要 pymybot HAL 路线（结构 SQL + 动作脚本 + 驱动）时读 `read_skill("i2c-scan")`。

3. 同一地址常有多家芯片（0x40 既有 CHT8305 也有 INA219 族，0x68 既有 DS1307 也有 MPU6050），**必须靠 ID 寄存器或行为区分**。

4. 最终以驱动 `build` 后能读回合理 ID 为准。ACK ≠ 型号正确：地址对了，芯片可能是另一个。

## 8. 与 pymybot 路线的分工

| | 本技能 / `i2c-host-scan` | `i2c-scan` |
| --- | --- | --- |
| 访问层 | 宿主 `/dev/i2c-N`（`i2c-dev`） | pymybot HAL |
| 产物 | 地址清单 + 诊断证据 | 驱动 + 结构 SQL + 动作脚本 |
| 需要 | `/dev/i2c-*` 权限 | `--allow-hardware` 与审批 |
| 适合 | 接线排查、适配器验证、装机前点检 | 接入器件、长期采样 |

`pymybot hardware` 反映的是**结构声明**，不是真实发现——两者不一致时，以本工具的总线扫描结果为准。

## 9. 自检

不碰硬件：

```sh
python3 -m py_compile scripts/i2c_probe.py
sh -n scripts/i2c_probe.sh
python3 scripts/i2c_probe.py --help
python3 scripts/i2c_probe.py --list-buses
python3 scripts/i2c_probe.py --range 0x80-0x90      # 应退出 2
python3 scripts/i2c_probe.py --bus 99 --list-buses  # 只列总线，不打开
```

真机（需权限，操作者执行）：

```sh
sh scripts/i2c_probe.sh /dev/i2c-1 --addr 0x48
sh scripts/i2c_probe.sh /dev/i2c-1 --repeat 3
```
