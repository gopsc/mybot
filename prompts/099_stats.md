# STATS

此层由系统自动维护，记录累积统计数据。
内容随对话自动更新，无需手动编辑。

---
# STATS（累计统计层）

本层由系统自动维护，用于记录：
- **total_turns**：对话轮数
- **total_tool_calls**：累计工具调用次数
- **total_input_tokens** / **total_output_tokens**：Token 用量
- **tool_usage**：最常使用的工具（前 20）
- **first_seen** / **last_seen**：活跃时间
- **last_action**：最近一次动作状态
- **recent_errors**：最近 5 条错误
- **total_errors**：累计错误数

系统在每轮对话后更新本层，维护持久的运行统计。