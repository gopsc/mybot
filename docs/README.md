# bot4cj 文档索引

> 这里收录 README 之外的全部深入文档。初次接触请先看 [README](../README.md) 跑通快速开始，再按需深入。

## 按角色选读

| 你是 | 建议顺序 |
| ---- | -------- |
| 第一次上手 | [README 快速开始](../README.md#-快速开始) → [DSL 参考](dsl.md) → [驱动清单](drivers.md) |
| 接硬件 / 写驱动 | [HAL](hal.md) → [驱动清单](drivers.md)（驱动契约）→ [虚拟总线](virtbus.md) → [开发与贡献](development.md) |
| 用守护线程做后台采样 | [@Daemon 守护线程](daemon.md) → [虚拟总线](virtbus.md)（`proto=virt`） |
| 用大模型驱动机器人 | [agent 模式](agent.md) → [命令行参考](reference.md) |
| 排障 | [已知限制与 FAQ](faq.md) → [命令行与环境变量参考](reference.md) |
| 改代码 / 提 PR | [开发与贡献](development.md) → [回归测试手册](testing.md) |

## 使用与参考

- [命令行与环境变量参考](reference.md)——动作输入源（TCP/文件/stdin）、CLI 参数、安全约束、`BOT4CJ_*` 环境变量
- [DSL 参考：结构脚本与动作脚本](dsl.md)——占位符、引号字面量、`@Alias`/`@Vars`、`$(...)` 表达式、controller/trigger 与 `$` 引用完整语义
- [硬件变量（驱动）清单](drivers.md)——`modules/` 下 **60 个模块**（47 款器件/执行器/系统接口驱动 + 3 条总线 + 10 个框架与模型驱动）按类别速查；
  含驱动契约（入口函数集 / 返回值 / 校验顺序 / destroy）、`SINGLE_CONSUMER` 名单与收敛豁免清单——
  **计数口径与推导写在 drivers.md 开头**，权威清单是 `ls modules/*.lua`
- [已知限制与常见问题](faq.md)——平台/运行时边界与排障问答
- [Web SSH 语义契约](webssh.md)——wsproto / webterm / webshell 行为不变式（#24，供 Rust 重写对照）

## 机制深入

- [agent 模式](agent.md)——`--agent`：大模型工具循环驱动**常驻**机器人、Lua 协议驱动（`LlmOpenAI`/`LlmDeepSeek`）、内置工具与安全边界、运行期 libcurl
- [@Daemon 守护线程](daemon.md)——并发模型、万能采样 chunk、滤波器链路、采样→滤波→消费闭环
- [HAL 硬件抽象层](hal.md)——ffi 直调 glibc、I2C_RDWR 原子事务、驱动沙箱
- [虚拟总线 virtbus](virtbus.md)——无真机验证驱动链路的完整参考手册（含器件模型库与回归清单）

## 架构与路线图

- [架构分析与扩展开发路线图](architecture_analysis.html)——C++17 版全景分析（正文与配套两图按现行 `src/*.cpp` 分层重绘，2026-09-21 逐条复核更新）
- [分层架构全景图](architecture_layers.svg)——L1–L7 分层 + 主数据流 + 守护并发引用
- [一次 play 的数据流 / 时序展开](architecture_dataflow.svg)——四阶段调用链 + @Daemon 并发分支（336B 共享槽 IPC）

## 测试与贡献

- [回归测试手册](testing.md)——守门分段明细、守门完整性规则、ctest 逐用例入口、sanitizer 与 CI 跑法
- [开发与贡献](development.md)——pre-push 钩子、提交信息规范、新增驱动/回归/单测流程、代码规范
- [更新日志](changelog.md)——按主题分组的版本演进记录
