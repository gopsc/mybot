# 更新日志

> 本文件是精简版，只保留版本级要点。2026-09-29 及以前的完整每日记录见
> [changelog-detail.md](changelog-detail.md)；此后的变更以 `git log` 与 docs/ 各现行文档为准。
> 设计论证、守门明细（用例名单、反向验证过程、测试计数快照）不在此复述，以 docs/ 各文档、
> `bash test/run_all.sh` 与 `./build/mybot_tests` 的实时输出为准。

## v1.x（C++ 移植版）

从苍颉语言完整移植至 C++17，同时完成 agent 子系统从 C++ 到 Rust 的迁移（两进程拓扑）。

### 关键里程碑

| 日期 | 要点 |
|------|------|
| 09-20 | 审计收口四阶段 + 安全缺省翻转（`run_command` 默认关闭、`--llm-key` 移除）+ 破坏性：动作脚本内联 `@Alias`/`@Vars` 作用域收敛到本次执行；NaN 防线、门禁硬化（UBSan 硬门禁、常量自检 Lua 源生成） |
| 09-21 | agent 子系统第二/三/七轮审计修复（AG-1~AG-27 系列）：UTF-8 消毒、图像内存降副本（219→163 MiB）、HTTP 连接池化、覆盖率口径修正、零断言即失败 |
| 09-22 | agent 重构 A1~C7 + SAN 系列：子进程单点化、图片游标降副本、`--check-config`、审计补会话边界与模型轮次、重试认识真实错误 |
| 09-23 | SQL 方言扩展（WHERE / DELETE / DROP / UPDATE / SHOW TABLES）、回读通道（`--read-var` + `read_variables`）、会话持久化（`--session-file` / `--resume`）、三协议驱动（OpenAI / DeepSeek / Anthropic） |
| 09-24 | agent 迁移 Rust（`mybot-agent`）：批次 A/B/C 落地（context.get 路由、骨架、循环语义对齐），C++ 侧死代码清退 -2331 行；H1 掩蔽引号绕过 + H2 Rust stdout panic 修复 |
| 09-25 | 批次 D 落地（Rust 会话持久化 `--session-file`/`--resume`，C++ 参考清退）+ 决策 agent over TCP 不做；删除 Lua 协议驱动轨道（11 文件）；CI 六条软门禁全转硬；流式输出缺省；REPL 行编辑（rustyline）；`PR_SET_DUMPABLE=0`；`--on-disconnect` 停机安全动作；会话历史压缩（摘要挂系统提示词）；`wait_variable` 工具 |
| 09-29 | MCP 首帧共享密钥 `BOT4CJ_MCP_TOKEN`；停机灭火协议（`quiesce` 位）；信任前提体检（文件权限告警） |
| 10-16 | 多传感器聚合（路线图阶段 2）：共享槽 ABI v2（`values` 指针化 + `capacity` 字段，头 96B 永久稳定）、`@Daemon` `maxvals` 列（每守护槽容量 1..1024，缺省 64，65+ 字段不再是架构上限）、`sources` 列 + `lib/sensor_aggregate.lua` 多守护聚合器（peer 槽强引用保活 + `DAEMON_PEER_SLOTS` 注入；peer 停止/失败即响亮永久失败，不发布陈旧快照） |
| 10-16 | 仿真器 IMU/里程计桥（第一档 sim 感知）：sim 侧 `ImuBridge`/`OdomBridge` 两座一问一答桥（argv[5]/[6]、`MYBOT_SIM_IMU_SOCK`/`MYBOT_SIM_ODOM_SOCK`，帧即运动学如实口径：无磁力计不编造）；Robot 累计里程与前向加速度（帧差分实导数）；mybot 侧 `Sim.lua` 的 `imu()`/`odom()` 客户端 + `lib/sim_sensor_daemon.lua` 守护采样 chunk（`kind` 列加载期校验，仿真器缺席=可恢复逐拍错误）；`robots/spider_sim_nav.sql` 全栈示例（imu+odom+`sources` 聚合+Monitor）；主干守门扩到五路径/五关键字，sim_tests 442 断言，新增 sim_nav e2e（`sim_responder.lua` 应答桩顶替 GL 壳） |

### 主题概览

#### agent 模式

两进程拓扑：`mybot --mcp-backend`（C++，管硬件与工具执行）+ `mybot-agent`（Rust，管模型循环与会话记忆）。工具集由 C++ 后端承载（`list_action_scripts` / `run_action_script` / `capture_image` / `query_sql` / `apply_sql` / `read_variables` / `wait_variable` / `run_command` / `list_dir` / `read_file` / `write_file`，后三个为文件通道 Phase 4/5 新增），模型调用唯一路径是 Rust agent（rig 直连，reqwest + rustls）。Lua 协议驱动轨道已删除（2026-09-25），`LlmOpenAI`/`LlmDeepSeek`/`LlmAnthropic` 现为协议族名。

#### 语言与 DSL

- `$(...)` 表达式（四则 + 括号，双上限）；`@Action` 设备列 `@Alias` 模板复用
- `@Merge` 归并（嵌套 + `*.once.mt` + 主从覆盖）与 `@Include` 内容拷贝（2026-10-12 由旧 `@Include` v2 拆分）；controller/trigger 多列扇出
- `@Vars` 命名数值变量；词法器引号内字面量与 8 MiB 上限

#### 执行引擎与安全

- 守护槽地址注入改 `lightuserdata`；TCP 加固（非回环强制口令 + 恒时比较 + 超时）
- 动作脚本路径沙箱（`O_NOFOLLOW`）；浮点有限性前置判据；`destroy` 元数据恢复引用列
- 停机灭火协议（`quiesce` 位，弃管守护触总线窗口收敛）；MCP 首帧共享密钥；信任前提体检
- 异常体系归口 `IllegalArgumentException`

#### 驱动与总线

- 26 个器件驱动 51 处内联类型检查迁 `arg_table` + lint 防线
- 多路径布局定位逐段探测；PCA9685 退出 SLEEP 按 datasheet；UART 波特率改 `B*` 常量
- 新增 SCSCL 总线舵机驱动；virtbus/驱动加固

#### 工程化与守门

- 大文件拆分（`robot.cpp` 拆四 TU、`agent_subprocess.*` 独立）；结构重构（`CliOptions` 类型化、`HwRegistry` 三容器、守护状态机收敛）
- 守门基建：HAL 常量编译期自检、CI 十硬门禁、agent CLI 负路径守门
- 重复代码九类收敛单点；覆盖补齐（守护并发压测 + TSan、TCP 异常注入七场景、fd 泄漏检测）
