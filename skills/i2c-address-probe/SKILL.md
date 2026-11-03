---
name: i2c-address-probe
description: 宿主侧 I2C 总线地址探测技能，提供零第三方依赖的 Python（i2c-dev ioctl 只读读探测）与 sh 包装两套脚本，枚举 /dev/i2c-N 上 0x08~0x77 会应答的从机地址，输出网格或固定字段 JSON，并标注内核已绑定的驱动。当用户说“扫描 I2C”“i2c scan”“i2cdetect”“写个扫 I2C 的脚本”“看看总线上挂了哪些设备”“扫一下 /dev/i2c-1”“I2C 地址冲突/找不到器件”时使用。
---

# 宿主侧 I2C 地址探测（sh / Python）

## 1. 适用范围

- 用于：确认某条**宿主 Linux I2C 总线**（`/dev/i2c-N`）上哪些从机地址在应答；核对地址跳线、上拉、供电；判断“结构里声明了器件但 `build` 失败”是接线问题还是驱动问题；给 `modules/` 里的候选驱动缩小范围；排查 USB-I2C（CH341/FTDI/CP2112）。
- 不用于：识别芯片型号（应答只说明“有东西在线”）；替代 `pymybot hardware`（它只反映结构声明）；扫 `proto='virt'` 虚拟总线（虚拟总线只复述声明，没有发现语义）；写寄存器或配置器件——本技能**只读**。
- 同类技能 `i2c-host-scan` 覆盖同一场景；若本机已安装，二者只保留一个。本技能的增补是：`/sys` 内核绑定标注（网格 `UU`、JSON `bound`）、固定 JSON 契约、sh 包装可直接吃设备路径。**同一场景不并行维护两份**。

## 2. 必须先知道的事实

- **只读探测**：判据是“`I2C_SLAVE` 绑定地址 + SMBus read byte 读 1 字节成功”，适配器不支持 SMBus 时回落为一次纯 I2C 单字节读。**不写任何数据字节**，也**不用** `i2cdetect` 默认的 quick-write 模式（那个模式会向每个地址写 1 字节，可能改 DAC 输出、触发一次转换、写 EEPROM、吸合继电器）。
- 只扫 **0x08~0x77**：0x00~0x07 是广播/保留区，0x78~0x7F 是 10 位地址保留区。越界直接退出码 2，不做静默裁剪。
- **读探测也不是零副作用**：FIFO 型 ADC、状态机型传感器被读一次就会弹出数据或推进状态机。能停机再扫。
- **NACK 与“总线不通”在读取层不可区分**：Linux 对 NACK 也返回 `EREMOTEIO`。0 命中既可能是没器件，也可能是没上拉/没供电/适配器掉线——用已知地址 `--addr 0x48` 交叉验证。
- 权限：`i2c-dev` 以 `O_RDWR` 打开，**只读探测也需要写权限**，即 `root` 或 `i2c` 组。
- 总线必须独占：扫描期间不要跑 pymybot/Daemon 采样，否则结果抖动。
- 本技能**不带 `skill.json`**，`run_skill` 无法启动它。扫描是硬件操作，由操作者亲自在宿主 shell 执行并授权。

## 3. 文件清单

下表路径相对**仓库根**；第 5 节的命令缩写假定当前目录是本技能目录。

| 路径 | 作用 |
| --- | --- |
| `skills/i2c-address-probe/scripts/i2c_probe.py` | 主实现：Python 3 标准库（`fcntl`/`os`/`glob`），零第三方依赖。`--bus` / `--list-buses` / `--addr` / `--range` / `--repeat` / `--json` / `--no-sysfs` |
| `skills/i2c-address-probe/scripts/i2c_probe.sh` | sh 包装：首位参数可给 `/dev/i2c-1`、`i2c-1`、`1`；校验解释器与设备节点；其余参数原样转发。`I2C_PROBE_PYTHON` 可指定解释器 |
| `references/usage.md` | 权限、errno 对照表、0 命中排查顺序、抖动复核、地址→候选驱动流程、与 pymybot 路线的分工 |

## 4. 工作流

1. **找总线**：`sh scripts/i2c_probe.sh --list-buses`（或 `ls /dev/i2c-*`）。不要猜编号。
2. **静态自检**（不碰硬件）：`python3 -m py_compile scripts/i2c_probe.py`、`sh -n scripts/i2c_probe.sh`。
3. **单点确认**：`--addr 0x48` 先验一个已知器件；通路通了再全量扫。
4. **全量扫**：`sh scripts/i2c_probe.sh /dev/i2c-1`（默认 0x08~0x77）。
5. **读结果**：人看网格；程序只解析 `--json` 的 `count` / `found` / `bound` / `failed` / `exit_code`。
6. **按地址缩小候选驱动**：读 `modules/<驱动>.py|.lua` 头注释的 address 说明，不要凭记忆写地址表。
7. **抖动复核**：`--repeat 3`，看 `unstable` 是否为空；非空即物理层问题。

## 5. 用法

```sh
# 枚举可用总线（只读，不需要硬件权限）
sh scripts/i2c_probe.sh --list-buses

# 全量扫 /dev/i2c-1（0x08~0x77）
sh scripts/i2c_probe.sh /dev/i2c-1

# 等价写法：编号 + 范围 + JSON
python3 scripts/i2c_probe.py --bus 1 --range 0x40-0x4f --json

# 单点确认，重复 3 次看稳定性
sh scripts/i2c_probe.sh 1 --addr 0x48 --repeat 3

# 跳过 /sys 绑定标注（探测方式不变，少几次 sysfs 读）
python3 scripts/i2c_probe.py --bus /dev/i2c-1 --no-sysfs
```

人读输出：

```text
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

`1f` 是 0x48 读回的字节，只作“确实读到了东西”的证据，**不是型号 ID**；`UU` 表示该地址已被内核驱动占用（`EBUSY`），本工具没有探测它。

`--json` 输出（字段固定，自动化只认这个）：

```json
{"bus": "/dev/i2c-1", "bus_id": 1, "range": "0x08-0x77", "probed": 112, "repeat": 1,
 "count": 1, "found": ["0x48"], "acks": {"0x48": "read:1F"}, "unstable": [],
 "bound": {"0x68": "ds1307"}, "failed": {"nack": 110}, "exit_code": 0}
```

退出码：

| 码 | 含义 |
| --- | --- |
| `0` | 扫描完成（**0 命中也是 0**） |
| `1` | 内部错误 |
| `2` | 参数错误（含越界地址范围） |
| `3` | 打不开总线：权限、节点不存在、无 `python3` |
| `4` | 有事务，但全部以非 NACK 错误失败（适配器掉线、`i2c-dev` 异常） |

## 6. 判读

| 现象 | 优先怀疑 |
| --- | --- |
| `count=0` 且 `failed: nack=112` | 器件没供电、SDA/SCL 接反、缺上拉、地址跳线不对、扫错总线 |
| `count=0` 且退出码 `4` | 总线本身不通：适配器未加载、`dtoverlay` 未启用、USB-I2C 掉线 |
| 退出码 `3` | 权限（非 root / 不在 `i2c` 组）或设备路径不存在 |
| `failed` 里出现 `set_slave_errno_16` | 该地址已被内核驱动绑定（`EBUSY`），不是 NACK；查 `bound` 与 `/sys/bus/i2c/devices/` |
| 命中但驱动 `build` 失败 | 应答 ≠ 型号正确：地址对了但芯片不是那个，或 ID 寄存器读法不对 |
| `unstable` 非空 | 接触不良、线太长、上拉偏大，或扫描期间有别的进程在用总线 |

## 7. 硬规则

1. 只读探测。禁止改写成写探测，禁止 `i2cdetect` 默认（quick-write）模式；要用 `i2cdetect` 必须带 `-r`。
2. 不扫 0x08~0x77 之外的地址；越界报错，不要“帮用户顺手扫一下”。
3. 不为扫描改 `/dev/i2c-*` 权限、不改 `chmod`、不用 `sudo` 掩盖权限问题；先报告再让操作者决定。
4. 一次一个实例，不与 pymybot 运行/Daemon 采样并发；扫描前确认总线空闲。
5. 扫描结果是**诊断证据**，不写回结构脚本、不当配置来源、不据此自动生成驱动。
6. 自动化只解析 `--json`；网格排版只为给人看，不保证稳定。
7. `0` 只表示“扫完了”。判读必须结合退出码与 `failed` 计数。
8. 不在授权会话里代为执行真机扫描；命令交给操作者在宿主 shell 运行。

## 8. 验证

由操作者在宿主执行（本技能不含自动执行路径）：

```sh
python3 -m py_compile scripts/i2c_probe.py   # 语法
sh -n scripts/i2c_probe.sh                   # 语法
python3 scripts/i2c_probe.py --help          # 参数面
python3 scripts/i2c_probe.py --list-buses    # 只读枚举，无需硬件权限
python3 scripts/i2c_probe.py --range 0x80-0x90   # 应退出 2
# 真机（需权限、需独占总线）：
sh scripts/i2c_probe.sh /dev/i2c-1 --addr 0x48
sh scripts/i2c_probe.sh /dev/i2c-1 --repeat 3
```

## 9. 参考资料

- `read_skill("i2c-address-probe", "references/usage.md")` — 权限、errno 对照、0 命中排查顺序、抖动复核、地址→驱动流程。
- `read_skill("pymybot-scripting", "references/driver-lua.md")` — 命中地址后查/写驱动时的契约。
- `read_skill("i2c-scan")` — pymybot HAL 路线（驱动 + 结构 SQL + 动作脚本）与地址族表。
