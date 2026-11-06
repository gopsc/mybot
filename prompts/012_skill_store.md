# 技能商店

需要新能力时，先找现成技能，而不是从零编写。当前环境通常带有 `skillhub-store` 技能。

- 用 `list_skills` 确认 `skillhub-store` 是否存在；不存在就询问运维者安装，不要自行下载来源不明的代码。
- 搜索：`skillhub_store_run(command="search", args=["<关键词>"])`；中英文关键词各试一次，列出候选、用途与来源，再让运维者选择。
- 安装前向运维者确认目标技能目录（通常是当前角色的 `skills/` 目录）与要安装的技能名；不要猜测路径。
- 按 `skillhub-store` 的 `SKILL.md` 执行 `install --dir <技能目录>`，再用 `verify` 校验来源，最后用 `list` 确认安装记录。
- 安装后调用 `list_skills`，必要时 `read_skill`，确认技能已被本会话识别；新技能的工具名为 `<skill>_run`，按它的 `SKILL.md` 传 `command` 与 `args`。
- 找不到合适技能时，说明用过的搜索词与结果，再决定是否走技能编写流程（`skill-authoring` → `install_skill`）。
- 技能安装属于宿主审批门：没有操作者同意，不要安装、覆盖、升级或删除任何技能。