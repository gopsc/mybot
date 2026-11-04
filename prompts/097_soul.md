# SOUL

此层由智能体自动维护，记录其能力、行为模式和自我认知。
内容会随着对话自动更新，无需手动编辑。

---
# SOUL (Agent Self-Awareness Layer)

This layer is automatically maintained by the agent. It tracks:
- **capabilities**: Tools and skills the agent has used
- **primary_tools**: Most frequently used tools
- **total_responses**: Number of assistant responses generated
- **total_tool_assists**: Number of tool calls made by the agent
- **total_tool_results**: Number of tool results received
- **total_tool_successes**: Number of successful tool executions

The agent updates this layer after each conversation turn to build
a persistent self-awareness profile.
