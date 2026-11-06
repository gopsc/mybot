# 各 AI 客户端的 Skills 目录

Source: SkillHub 官方安装文档与各客户端约定；本仓库的目录解析规则见 `pymybot/agent_skills.py`。

安装技能时必须用 `--dir` 指向当前 Agent 真正加载的 skills 根目录。以下路径来自 SkillHub 官方安装文档。

| AI 客户端 | Skills 目录 |
| --- | --- |
| Claude Code | `~/.claude/skills/` |
| Cursor | `~/.cursor/skills/` 或项目下 `.cursor/skills/` |
| Windsurf | `~/.codeium/windsurf/skills/` 或项目下 `.windsurf/skills/` |
| Codex | `~/.codex/skills/` 或项目下 `.agents/skills/` |
| Google Antigravity | `~/.gemini/antigravity/skills/` |
| Gemini CLI | `~/.gemini/skills/` |
| QoderWork | `~/.qoderwork/skills/` |
| workbuddy | `~/.workbuddy/skills/` |
| OpenClaw | `~/.openclaw/workspace/skills/` |
| OpenClaw 变体（NanoBot、PicoClaw、memUBot、MaxClaw、CoPaw、AutoClaw、KimiClaw、QClaw、EasyClaw 等） | 各自工作区下的 `skills/` 目录 |

## 选择顺序

1. 宿主环境已经明确告知的 skills 目录（最可靠，优先使用）。
2. 当前项目内的技能目录：`.codearts/skills`、`.agents/skills`、`.claude/skills`。
3. 上表中的用户级目录。
4. 仍无法确定时，询问用户，不要猜测。

## 验证安装位置

```bash
# 安装后确认目录与 lockfile
ls "<skills 目录>/<slug>/SKILL.md"
ls "<skills 目录>/.skills_store_lock.json"
```

- 没有 `SKILL.md`：包结构异常或安装失败。
- 没有 `.skills_store_lock.json`：该技能不是由 SkillHub 安装，`list` / `upgrade` 不会管理它。
- 安装后 Agent 仍不识别：通常需要重启会话，或目录不是该 Agent 的 skills 根目录。