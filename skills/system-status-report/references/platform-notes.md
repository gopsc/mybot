# 平台数据源与已知限制

按平台记录 `scripts/sys_status.py` 实际读取的来源、精度与不可采集项。字段为 `null` 时，先查本表确认是不是平台本身没有该项。

## 通用

| 项目 | 说明 |
| --- | --- |
| 依赖 | 仅 Python 3.8+ 标准库 |
| 外部命令 | 仅 `sysctl`、`vm_stat`（macOS），`subprocess.run` 直接传 argv，不经 shell，超时 5 s |
| 写入 | 无。不创建临时文件、不改配置 |
| 网络 | 无出站流量。UDP `connect()` 只做路由查找 |

## Linux

| 指标 | 来源 | 备注 |
| --- | --- | --- |
| OS / 内核 | `platform` 模块 | 容器内 `release` 是宿主内核 |
| uptime | `/proc/uptime` 第一列 | 秒，含 suspend 时间 |
| CPU 核数 | `os.cpu_count()` / `os.sched_getaffinity(0)` | 后者受 `taskset`/cgroup 限制 |
| CPU 时间 | `/proc/stat` 聚合 `cpu` 行 | `idle` = idle + iowait；利用率 = 1 − Δidle/Δtotal |
| 负载 | `os.getloadavg()` | 1/5/15 分钟，受 cgroup 无感知（宿主口径） |
| 内存 | `/proc/meminfo` | `MemAvailable` 缺失时回退 free+buffers+cached 并写 note |
| swap | `MemTotal`-同表的 `SwapTotal`/`SwapFree` | 未启用 swap 时为 0 |
| 磁盘 | `shutil.disk_usage()` → `statvfs` | 目录级，非整盘 |
| 网卡 | `socket.if_nameindex()` | 只列名字，不逐卡取地址（逐卡地址需 `ioctl`/netlink） |

裁剪过的容器里 `/proc/stat`、`/proc/meminfo` 可能缺行；`lxcfs` 之类会改写数值，此时看到的是限额而非物理量。

## macOS

| 指标 | 来源 | 备注 |
| --- | --- | --- |
| uptime | `sysctl -n kern.boottime` 的 `sec=` | 正则解析 |
| CPU 时间 | `sysctl -n kern.cp_time` | 四元组 user/nice/sys/idle，ticks 累加值，比率有效 |
| 负载 | `os.getloadavg()` | 原生支持 |
| 内存总量 | `sysctl -n hw.memsize` | 精确 |
| 内存明细 | `vm_stat` | 页大小取自首行 `page size of N bytes`，回退 `hw.pagesize`→4096 |
| 已用内存 | active + wired + compressor 页 | 文件缓存未计入，数值偏保守；口径与 `top` 的 "Memory Used" 接近但不必相等 |
| 可用内存 | free + inactive + speculative 页 | 近似值 |
| swap | `sysctl -n vm.swapusage` | 形如 `total = 2048.00M  used = ...  free = ...`，按单位换算成字节 |
| 磁盘 | `shutil.disk_usage()` | APFS 容器共享空间，多卷数值会重叠 |
| 外部命令键缺失 | 无 T2/Apple Silicon 差异 | `sysctl` 键在受限沙箱中可能被拒，此时报 note |

## Windows

| 指标 | 来源 | 备注 |
| --- | --- | --- |
| OS / 版本 | `platform` | `platform.release()` 可能是 `10` 而非 `11`，看 `version` 构建号 |
| uptime | `kernel32.GetTickCount64()` | 毫秒，含睡眠时间 |
| CPU 时间 | `kernel32.GetSystemTimes()` | FILETIME 计数；kernel 时间已含 idle，故 total = kernel + user |
| 负载 | 无 | `os.getloadavg()` 抛 `OSError`，字段恒为 `null`，属预期 |
| 内存 | `kernel32.GlobalMemoryStatusEx` | `ullTotalPhys`/`ullAvailPhys`，另附 `dwMemoryLoad` 未使用 |
| swap / 页面文件 | `ullTotalPageFile`/`ullAvailPageFile` | 是页面文件口径，不等于 Linux swap |
| 磁盘 | `shutil.disk_usage()` | 默认 `%SystemDrive%\` + 用户目录；网络盘可能很慢 |
| 网卡 | `socket.if_nameindex()` | 旧版本 Python 可能无此函数，回退为 `null` + note |
| 编码 | 输出纯 ASCII | 避免控制台代码页问题 |

## 其他平台

FreeBSD/OpenBSD/Solaris 等：`os` 与 `disk` 段通常仍可用（`platform` + `shutil`），`cpu`/`memory`/网络地址探测会返回 `null` 并写 `notes`。不要凭空补值。

## 单位与精度

| 量 | 单位 | 精度 |
| --- | --- | --- |
| `*_bytes` | 字节 | 整数，不做四舍五入 |
| `*_percent` | % | 一位小数，分母为 0 时 `null` |
| `uptime_seconds` | 秒 | 一位小数 |
| `boot_epoch` | Unix 秒 | 三位小数 |
| `load_average` | 无量纲 | 两位小数 |
| `generated_at` | UTC | 秒级，`Z` 结尾，无时区偏移 |

## CPU 采样语义

1. 先读一次累计计数 `(total, idle)`，得开机以来均值。
2. `--interval > 0` 时 `sleep` 后再读一次，用差分算当前窗口利用率。
3. 差分 `Δtotal <= 0`（高频 tick 源精度不足）时报 `null` + note，不外推。
4. 采样窗口越长越平滑；`0.5 s` 是噪声与耗时的折中，批量采集建议 `0.1`–`0.2`。

## 容器与虚拟化

- cgroup 限额不会体现为「内存总量」，`/proc/meminfo` 若被 lxcfs 挂载则反映限额。
- 宿主内核与用户态版本不一致时，`os.release`/`os.version` 描述的是内核。
- 磁盘 `percent_used` 对 overlayfs 反映底层文件系统，多容器共享同一数字。
