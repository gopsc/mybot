# 设计决策与沿革存档

> 以下整块从 docs/agent.md 逐字迁出，保留作者的原始论证与历史决策，不改写、不精简。

## 远程对话（已评估，不做）

> **决策（2026-09-25）**：agent over TCP 远程 REPL **不做**——随 C++ agent 移除后
> 它曾规划由 Rust agent 承担（原批次 E），本次经维护者评估正式关闭，设计存档下架
> （历史全文见本决策提交之前的 git 历史）。远程场景回归既有路径：ssh 到机器人侧
> 本地运行 `mybot-agent`（stdin 交互）；动作脚本的远程投递走 `--tcp` 动作源
> （安全口径不变：回环缺省、跨机必须 `--tcp-token`）。批次字母 E 作废，不再复用。


### 沿革存档：为什么当初不把 HTTP 写进 C++ 宿主

当初（C++ agent 时代）的决策记录，解释这条链为什么曾经存在：

- 换模型/换厂商 = **换一个 Lua 文件**，宿主不重编、不链接任何 HTTP 库；
- 项目「零第三方 C++ 依赖（仅 LuaJIT + pthread + dl）」的承诺在这条路径上依然成立；
- 驱动生态的一切照旧适用：`build/call/destroy` 契约、`guard_build` 回滚、
  `test/test_*.lua` 离线用例；模型驱动也能被 `.mt` 动作脚本或 `@Daemon` 调用；
- 协议差异（如 DeepSeek 的思考模式）**只能**由驱动承担——它有状态，宿主一无所知。

```
【沿革存档：C++ --agent 时代的调用链（已全删；2026-09-25 #8 删最后一段）】
  agentloop（C++）      工具循环（已删）
  └─ agentproto         规范化消息/工具 ⇄ Json（传输层部分已删）
       └─ agentdriver   ChatTransport：把请求交给驱动变量（已删）
            └─ llm0 = modules/LlmOpenAI.lua      ← 普通硬件变量（#8 已删）
                 └─ lib/llm_wire_openai.lua      ← 协议整形（#8 已删）
                      └─ lib/llm_http.lua        ← ffi 直驱 libcurl（#8 已删）
```

规范化请求/响应契约、A1b 出站一致性自检、响应形变矩阵（SAN-6/PL-3/PL-6）等
协议文档随轨道删除。它们的现役对应物在 Rust 侧：出站形状由写入不变量保证
（`agent/src/history.rs` + SAN-12 的 id 唯一性三条来源），响应形变由 rig 的
provider 解析承担，回归在 Rust 单测与 agent E2E（R1–R20）。


为什么是 JSON 而不是 Lua：配置文件是**数据**，不是代码。Lua 配置要由宿主内嵌状态机去执行，
等于让一份常被复制/分发的文件获得任意代码执行能力；而仓库已有严格 JSON 解析器，复用它零成本。

