# USER

此层由智能体自动维护，记录用户偏好和特征。
内容会随着对话自动更新，无需手动编辑。

---
# USER (User Profile Layer)

This layer is automatically maintained by the agent. It tracks:
- **primary_language**: User's preferred language (zh/en)
- **languages**: Language usage counts
- **topics**: Topics the user frequently discusses
- **communication_style**: terse/moderate/verbose
- **total_messages**: Number of user messages processed
- **last_active**: Timestamp of last interaction

The agent updates this layer after each conversation turn to build
a persistent user preference profile.
