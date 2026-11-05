# STATS

此层由系统自动维护，记录累积统计数据。
内容会随着对话自动更新，无需手动编辑。

---
# STATS (Cumulative Statistics Layer)

This layer is automatically maintained by the system. It tracks:
- **total_turns**: Number of conversation turns
- **total_tool_calls**: Cumulative tool invocations
- **total_input_tokens** / **total_output_tokens**: Token usage
- **tool_usage**: Most frequently used tools (top 20)
- **first_seen** / **last_seen**: Activity timestamps
- **last_action**: Most recent action state
- **recent_errors**: Last 5 errors encountered
- **total_errors**: Cumulative error count

The system updates this layer after each conversation turn to maintain
persistent operational statistics.
