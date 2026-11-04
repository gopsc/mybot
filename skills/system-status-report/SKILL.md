---
name: system-status-report
description: 用 Python 标准库跨平台（Linux/macOS/Windows）只读采集主机系统状态，输出文本或单行 JSON：OS/内核/主机名/启动时间/uptime、CPU 逻辑核与亲和核、负载与利用率、内存与 swap、磁盘占用、网卡与主 IPv4/IPv6。零第三方依赖、不写文件、不发网络流量。当用户说「看下系统状态」「采集系统信息」「CPU/内存/磁盘占用多少」「机器体检」「system status」「sysinfo」「host metrics」「system health」时使用。
---

# 系统状态采集

## 适用范围

- 目标：一次调用拿到主机健康快照，供人工阅读或上游程序解析。
- 适用：Linux / macOS / Windows 本机；容器内也可运行（数据反映容器可见的系统层）。
- 不适用：远程主机（需 SSH 或 agent）、进程级明细、GPU 温度、硬件传感器（另见 `i2c-uart-spi-enum` 一类技能）。
- 判定：只读快照，不排查、不调优、不改配置。

## 目录

```text
system-status-report/
├── SKILL.md
├── scripts/sys_status.py        # 唯一入口，标准库实现
└── references/platform-notes.md # 各平台数据源、精度与已知限制
```

## 快速开始

```sh
# 全量文本报告
python system-status-report/scripts/sys_status.py

# 单行 JSON，便于管道处理
python system-status-report/scripts/sys_status.py --json

# 只关心 CPU + 内存，跳过网络
python system-status-report/scripts/sys_status.py --section cpu --section memory --no-network --json

# 指定挂载点，缩短采样窗口
python system-status-report/scripts/sys_status.py --disk-path /data --disk-path /var --interval 0.2
```

要求 Python 3.8+，无第三方依赖。脚本不读 stdin，可非交互运行。

## 参数

| 参数 | 作用 | 默认 |
| --- | --- | --- |
| `--section NAME` | 只采集指定段，可重复：`os`/`cpu`/`memory`/`disk`/`network` | 全部 |
| `--json` | 输出单行 JSON | 文本 |
| `--pretty` | 缩进 JSON（隐含 `--json`） | 关 |
| `--disk-path PATH` | 指定测量路径，可重复，覆盖默认值 | `C:\`+用户目录 / `/`+`$HOME` |
| `--interval SEC` | CPU 利用率采样窗口，`0` 关闭增量采样 | `0.5` |
| `--no-network` | 跳过网络段 | 关 |

## 输出

JSON 顶层固定字段：`schema_version`、`generated_at`（UTC，`YYYY-MM-DDTHH:MM:SSZ`）、`notes`、以及 `os`/`cpu`/`memory`/`disk`/`network`。

| 段 | 关键字段 |
| --- | --- |
| `os` | `system`、`release`、`version`、`machine`、`node`、`python_version`、`boot_epoch`、`uptime_seconds` |
| `cpu` | `logical_cpus`、`affinity_cpus`、`load_average[3]`、`utilization_since_boot_percent`、`utilization_percent`、`sample_seconds` |
| `memory` | `source`、`total_bytes`、`available_bytes`、`used_bytes`、`percent_used`、`swap_total_bytes`、`swap_free_bytes` |
| `disk` | 数组：`path`、`total_bytes`、`used_bytes`、`free_bytes`、`percent_used` |
| `network` | `hostname`、`primary_ipv4`、`primary_ipv6`、`interfaces[]` |

- 所有 `*_bytes` 为字节整数；所有 `*percent` 为一位小数百分比。
- **无法测量的字段一律为 `null`**，原因写进 `notes`；不要用 0 代替未知。
- 文本模式同样渲染这些字段，`notes` 打印在末尾 `[notes]` 段。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 至少一个段采集成功（其余缺失见 `notes`） |
| `1` | 所有请求段都失败，stderr 给出原因 |
| `2` | 参数错误（argparse） |

## 硬规则

- 只读：不写文件、不改系统设置、不启停服务。需要写入时由操作者在宿主机完成。
- 不伪造：`/proc`、`sysctl`、Win32 API 读不到就报 `null` + `notes`，绝不补默认值。
- 不装依赖：只用标准库；不引入 `psutil` 之类，避免目标机装包。
- 不发流量：`primary_ipv4/v6` 只用连接 UDP 套接字选路（`connect()` 不发送数据包），探测地址取文档保留网段（`198.51.100.1`、`2001:db8::1`）。不要改成真实主机或加 ping。
- 不加超时外的副作用：外部命令仅限 `sysctl`、`vm_stat`，超时 5 秒。
- 单位统一：内部一律字节/秒/百分比，格式化只在渲染层做。

## 阅读结果时注意

1. `utilization_since_boot_percent` 是开机以来均值，`utilization_percent` 才是当前窗口值；回答「现在负载高吗」用后者。
2. `load_average` 在 Windows 必然为 `null`（平台无此指标），这不算故障。
3. `memory.available_bytes` 与 `free` 不同：Linux 用 `MemAvailable`，macOS 用 free+inactive+speculative，Windows 用 `ullAvailPhys`；三者不可逐字节对比。
4. 容器内 CPU 核数是宿主配额视图，内存可能是 cgroup 限额而非物理总量。
5. 磁盘 `percent_used` 来自文件系统层级，overlay/tmpfs 的数值不能当物理盘容量。
6. 各平台细节与已知误差见 `references/platform-notes.md`。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 全部段 `null`、退出码 1 | 非三大平台或受限环境；看 stderr 与 `notes`，换用平台原生命令 |
| `os.uptime_seconds` 为 `null` | `/proc/uptime`、`kern.boottime`、`GetTickCount64` 均不可用；不要靠日志猜 |
| `notes` 出现 `command exited ...` | `sysctl`/`vm_stat` 返回非零（键缺失或被裁剪的容器）；该段其余字段仍可能有效 |
| `disk` 为空数组 | 路径不存在或无权限；用 `--disk-path` 指定可读路径 |
| JSON 解析失败 | 确认未混入文本诊断——诊断只走 `notes`/stderr |

## 扩展方式

- 加新指标：在对应 `collect_*` 里追加字段，同步更新本文档字段表，保持「读不到 = `null` + `notes`」。
- 加新平台：新增 `_memory_<system>()` 之类分支，并在 `references/platform-notes.md` 登记数据源。
- 该技能只有文档 + 脚本，没有 `skill.json`：宿主会把 `scripts/` 顶层首个 Python 脚本暴露为 `<name>_run` 工具，用 `command`/`args` 传入 CLI 参数。
