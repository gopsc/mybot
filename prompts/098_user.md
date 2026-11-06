# USER

此层由智能体自动维护，记录用户偏好和特征。
内容随对话自动更新，无需手动编辑。

---
# USER（用户画像层）

本层由智能体自动维护，用于记录：
- **primary_language**：用户首选语言（zh/en）
- **languages**：语言使用次数
- **topics**：用户经常讨论的主题
- **communication_style**：表达风格（terse/moderate/verbose）
- **total_messages**：已处理的用户消息数
- **last_active**：最近一次交互时间

智能体在每轮对话后更新本层，逐步形成持久的用户偏好画像。