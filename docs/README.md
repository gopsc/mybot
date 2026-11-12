# bot4cj 文档索引

> 这里收录 README 之外的全部深入文档。初次接触请先看 [README](../README.md) 跑通快速开始，再按需深入。

## 按角色选读

| 你是 | 建议顺序 |
| ---- | -------- |
| 第一次上手 | [README 快速开始](../README.md#快速开始) → [DSL 参考](dsl.md) → [驱动清单](drivers.md) |
| 接硬件 / 写驱动 | [HAL](hal.md) → [驱动清单](drivers.md)（驱动契约）→ [虚拟总线](virtbus.md) → [开发与贡献](development.md) |
| 用守护线程做后台采样 | [@Daemon 守护线程](daemon.md) → [虚拟总线](virtbus.md)（`proto=virt`） |
| 用大模型驱动机器人 | [agent 模式](agent.md) → [命令行参考](reference.md) |
| 排障 | [已知限制与 FAQ](faq.md) → [命令行与环境变量参考](reference.md) |
| 改代码 / 提 PR | [开发与贡献](development.md) → [回归测试手册](testing.md) |

## 使用与参考

- [命令行与环境变量参考](reference.md)——动作输入源（TCP/文件/stdin）、CLI 参数、安全约束、`BOT4CJ_*` 环境变量
- [DSL 参考：结构脚本与动作脚本](dsl.md)——占位符、引号字面量、`@Alias`/`@Vars`、`$(...)` 表达式、controller/trigger 与 `$` 引用完整语义、`@Trigger`/`@Reflex` 条件反射
- [硬件变量（驱动）清单](drivers.md)——`modules/` 下 **60 个模块**（49 款器件/执行器/系统接口驱动 + 3 条总线 + 8 个框架/工具驱动）按类别速查；
  含驱动契约（入口函数集 / 返回值 / 校验顺序 / destroy）、`SINGLE_CONSUMER` 名单与收敛豁免清单——
  **计数口径与推导写在 drivers.md 开头**，权威清单是 `ls modules/*.lua`
- [已知限制与常见问题](faq.md)——平台/运行时边界与排障问答
- [Web SSH 语义契约](webssh.md)——wsproto / webterm / webshell 行为不变式（#24，供 Rust 重写对照）

## 机制深入

- [agent 体系](agent.md)——`mybot --mcp-backend` + `mybot-agent` 两进程：C++ 工具后端管理**常驻**硬件，Rust 直连模型并运行工具循环；内置工具、配置归属与安全边界
- [仿真器 sim/](sim.md)——三条 AF_UNIX 桥（命令/拍照/测距）的协议与成败口径、动作码表、simcore/GL 壳分层、socat 手测法
- [设计文档](design/)——agent 体系的设计意图与历史决策（安全论证、选型理由、已评估不做的功能）
- [@Daemon 守护线程](daemon.md)——并发模型、万能采样 chunk、滤波器链路、采样→滤波→消费闭环
- [HAL 硬件抽象层](hal.md)——ffi 直调 glibc、I2C_RDWR 原子事务、驱动沙箱
- [虚拟总线 virtbus](virtbus.md)——无真机验证驱动链路的完整参考手册（含器件模型库与回归清单）

## 架构与路线图

- [架构分析与扩展开发路线图](architecture_analysis.html)——C++17 版全景分析（正文与配套两图按 2026-09-25 的两进程架构重绘：`mybot --mcp-backend` + Rust `mybot-agent`）。
  **该页与两张图已于 2026-10-04 冻结为历史快照**，不含此后的 `sim/` 迁入、多机器人、`~/.mybot` 持久化与领域门面拆分，页内计数亦为该日快照；
  现行口径以下面各篇 md 为准（页首有同样的冻结声明）
- [分层架构全景图](architecture_layers.svg)——L1–L7 分层 + 主数据流 + 守护并发引用（同上，2026-09-25 快照）
- [一次 play 的数据流 / 时序展开](architecture_dataflow.svg)——四阶段调用链 + @Daemon 并发分支（600B 共享槽 IPC；同上，2026-09-25 快照）

## 测试与贡献

- [回归测试手册](testing.md)——守门分段明细、守门完整性规则、ctest 逐用例入口、sanitizer 与 CI 跑法
- [开发与贡献](development.md)——pre-push 钩子、提交信息规范、新增驱动/回归/单测流程、代码规范
- [ICA 证据账本原型](ica.md)——Rust agent 侧实验特性（BOT4CJ_ICA=1）的事实边界
- [更新日志](changelog.md)——精简版版本要点（完整版见 [changelog-detail.md](changelog-detail.md)）
