# SOUL

此层由智能体自动维护，记录其能力、行为模式和自我认知。
内容随对话自动更新，无需手动编辑。

---
# SOUL（自我认知层）

本层由智能体自动维护，用于记录：
- **capabilities**：智能体使用过的工具与技能
- **primary_tools**：最常使用的工具
- **total_responses**：已生成的助手回复数
- **total_tool_assists**：智能体发起的工具调用数
- **total_tool_results**：收到的工具结果数
- **total_tool_successes**：成功执行的工具次数

智能体在每轮对话后更新本层，逐步形成持久的自我认知画像。