# 双智能体（记忆体 + 执行体）

pymybot 的 Agent 默认拆成两个互相说话的智能体：**记忆体**负责长期记忆、规划与反思，
**执行体**负责动手。两者属于同一个角色，共享工作区、审批边界和硬件所有权。

## 为什么拆

单智能体把“记住什么”和“做什么”混在一次对话里：上下文一长，历史被压缩成摘要；
任务一多，长期经验留在某次会话里带不走。拆开之后：

- **记忆体不碰硬件**：它没有工具，只做判断，出错也伤不到设备。
- **执行体不被长期记忆污染**：它只看到本轮简报和自己的工作窗口，上下文更短、更聚焦。
- **经验可累积**：每轮结论写进角色的长期记忆，下次任务按相关度召回。

## 两个角色

| | 记忆体 memory | 执行体 worker |
| --- | --- | --- |
| 实现 | `pymybot/agent_team.py::MemoryAgent` | `pymybot/agent.py::AgentSession` |
| 工具 | 无 | 技能、文件、Shell、Web、摄像头、MCP |
| 记忆 | 长期记忆库（跨会话） | 单角色分层对话历史（热/温/冷） |
| 审批 | 不适用 | 沿用原有逐次审批 |
| 输出 | `continue` / `done` / `blocked` 决策 | 动作回执与自然语言回报 |

每次决策是一次单独模型调用，要求只返回 JSON：

```json
{"action": "continue|done|blocked",
 "brief": "给执行体的下一步指令",
 "reasoning": "判断依据",
 "summary": "给用户的最终答复",
 "memories": [{"text": "一句话事实", "kind": "fact", "tags": ["relay"], "salience": 0.7}],
 "next_goal": "无人值守时建议的下一个目标"}
```

模型输出不是合法 JSON 时走确定性回退（先让执行体查环境，再收尾），不会死循环。

## 自主循环

```text
点「启动」→ 记忆体自拟目标 → 执行体执行 → 记忆体反思
                ↑                              │
                └──── continue / 下一个目标 ────┘
```

没有人类输入。启动后记忆体根据角色描述、长期记忆和上一轮结果决定下一个具体目标；
执行体完成后记忆体判断 `done` / `blocked`，再提出下一个目标。停止只有两种方式：
点「停止」或触及预算上限。

- 每次任务有步数、墙钟、token、模型请求数和工具调用数五个上限。墙钟按次尝试计时，
  耗尽记为 `paused`（可续跑）；步数与 token 是跨恢复累计的额度，耗尽记为 `blocked`
  （恢复不可能推进；由记忆体拆小目标或人工提高上限），不会在自主循环里被反复认领空转；
  后两个由 `AgentConfig` 逐轮硬性拒绝。
- 执行体失败不再重试，任务记为 `failed`；任务结束事件带有 `attempts`（执行体被调用次数）
  和失败原因，GUI/JSON 都能看到，不会表现成“记忆体独奏”。
- 任务状态持久化到角色目录的 `missions/<id>.json`，进程重启后可查；重启后 `running`
  且已派发动作的任务变成 `failed`/结果未知，绝不自动重放。`paused` 任务可被下一次
  `agent.start` 自动续跑。
- 停止会清除执行体的协作停止事件；再次启动不会立刻被上一次 stop 拦住。
- 无人值守可开启 `--require-plan-approval`：每个自主任务先向 GUI/终端请求计划批准，
  拒绝即记为 `blocked`，执行体不会收到任何指令。
- 上一轮 `failed`/`blocked` 时，记忆体被要求提出修复目标；换不出目标就明确报告原因并停止。
- 取消沿用协作式停止：`cancel()` / GUI「停止」/ `Ctrl+C` 都会在下一次 `_check()` 生效。

## 长期记忆与检索

存储：`~/.mybot/roles/<角色>/memory/entries.jsonl`，一行一条，追加写；`id` 去重，
重复写入只提升 salience。超过上限时按 salience/时间淘汰并原子重写。

检索是**纯词法 RAG**，不依赖向量库或嵌入服务：

- 分词 = ASCII 单词 + 中日韩字符二元组；
- 打分 = BM25 + 0.25×salience + 0.15×时间衰减；
- 结果按条数与字节预算截断，直接拼进记忆体的提示词。

这是有意的取舍：离线可跑、可审计、无新增密钥；代价是语义泛化弱于向量检索。

## 启动与停止

GUI：点「启动」。没有输入框、没有发送按钮，人类只观察和停止。

CLI：

```sh
pymybot agent --role NAME                     # 记忆体自拟目标，一直跑到预算上限或 Ctrl+C
pymybot agent --role NAME --task "巡检传感器"  # 可选：只跑这一个种子任务
```

serve：

- `agent.start` 启动后台自主循环，可带可选 `task` 种子；
- `agent.stop` 停止；`agent.status` 查询；
- `agent.ask` 只跑一个任务（给外部客户端用），不启动循环；
- `agent.memory` 查看长期记忆与统计，`agent.memory.forget` 按 id/kind/tag 删除记忆；
- `agent.missions` 查看持久任务历史。

记忆体输出优先使用 provider 的结构化输出（Pydantic schema），失败时只修复一次，最后
回退到文档化的 JSON 文本解析。模型/传输错误不会被伪装成解析错误而额外重试。

自主运行受五道上限：单任务步数、单任务墙钟、单任务 token、单轮模型请求数、
单轮工具调用数，另有自动任务总数（`--max-missions`，默认 20）。记忆体可以用
`next_goal` 提议下一个目标，但只会在上限内入队，不会无限自我续命；连续没有可做
目标时循环自行停止。

## 可观测与回归评测

安装 `pip install "pymybot[observability]"` 并配置 OpenTelemetry exporter 后，
`agent.mission`、`agent.model_call`、`agent.tool` 会生成 span；事件和任务结果同时带
`trace_id`。没有该依赖时所有追踪调用是无副作用的 no-op。

`tools/agent_eval.py` 用确定性工具回执评分，不调用模型：

```sh
python -m tools.agent_eval \
  --cases tests/fixtures/agent_eval/cases.json \
  --runs  tests/fixtures/agent_eval/runs.json
```

评分覆盖缺失/禁止工具、`unknown` 结果、失败工具、重复调用和工具预算，适合作为 CI
回归门禁。

## 安全边界

- 记忆体无工具，不能触发任何动作。
- 执行体的工具调用仍走原有审批；无人值守不会绕过提示词更新、技能安装等专用审批。
- 长期记忆是普通文本，可能被写入错误内容；它只作为数据进入提示词，不构成授权。
- 无人值守是成本与风险的放大器：先用小 `--max-missions` 试跑，确认行为后再放大。
