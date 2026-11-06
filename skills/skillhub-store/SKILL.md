---
name: skillhub-store
description: 通过 SkillHub（国内优先的 AI Skill 商店）搜索、安装、校验和升级 Agent Skills。当用户提出“找技能 / 安装 skill / 有没有能做某事的技能 / 搜索 skill / 升级已安装的 skill”，或需要把商店中的 Skill 装入当前 Agent 的 skills 目录时使用。包含 Windows 与 POSIX 跨平台 CLI 安装、skills 目录解析和来源校验。
---

# SkillHub 商店

SkillHub 是面向中文网络的 Agent Skill 商店（[https://skillhub.cn](https://skillhub.cn)），提供加速、合规的技能搜索与安装。本 Skill 覆盖完整链路：确认 CLI → 搜索 → 安装到当前 Agent 的 skills 目录 → 校验 → 升级。

## 快速路由

| 用户意图 | 子命令 | 说明 |
| --- | --- | --- |
| “有没有能做 X 的技能” | `search` | 只搜索并给候选，不安装 |
| “安装 X 这个技能” | `install` | 必须带 `--dir` |
| “我装了哪些技能” | `list` | 读取安装目录的 lockfile |
| “升级到最新版” | `upgrade` | 先 `--check-only` 再执行 |
| “这个包安全吗 / 校验一下” | `verify` | 与平台签名比对 |
| “发布我写的技能” | `publish` | 需要登录 Token |
| 首次使用、CLI 不存在 | 安装 CLI | 见第二节 |

> 触发词：技能、skill、插件、能力扩展、find-skill、install skill。出现这些词时先走本流程，不要直接当作普通问答。

## 一、确认 CLI

所有命令都通过本 Skill 的包装器执行，无需关心 `skillhub` 是否在 PATH 中。下文的 `<SKILL_ROOT>` 指本 `SKILL.md` 所在目录：

```powershell
python <SKILL_ROOT>/scripts/skillhub_cli.py --version

```

包装器按以下顺序解析真实 CLI，并把参数原样转发：

1.  环境变量 `SKILLHUB_CLI`（指向 `skills_store_cli.py`）
2.  `~/.skillhub/skills_store_cli.py`
3.  PATH 中的 `skillhub`
4.  `~/.local/bin/skillhub`

返回非 0 或提示未安装 → 执行第二节。

## 二、安装 CLI（仅首次）

**官方脚本（macOS / Linux / Git Bash）**

```bash
# 仅 CLI（推荐，不改写其他 Agent 配置）
curl -fsSL https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/install.sh | bash -s -- --cli-only

# 完整安装（CLI + 官方 find-skills 模板）
curl -fsSL https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/install.sh | bash

```

**Windows（无 bash）或需要固定版本时**

```powershell
python <SKILL_ROOT>\scripts\skillhub_setup.py --cli-only

```

该安装器与官方 `install.sh` 的 CLI 部分等价：下载 kit → 解压 → 安装到 `~/.skillhub/` → 生成 `config.json` 与启动器。

常用选项：

| 选项 | 作用 |
| --- | --- |
| `--cli-only` | 只安装 CLI，不安装官方 find-skills 模板（默认） |
| `--with-official-skills --dir <skills>` | 额外安装官方 find-skills 与 skillhub-preference 模板 |
| `--kit-version <ver>` | 固定版本，例如 `2026.8.5` |
| `--no-self-upgrade` | 关闭启动时自动升级，写入 `auto_self_upgrade=false` |
| `--kit <tar.gz或目录>` | 离线/内网安装 |
| `--dry-run` | 只打印安装计划 |
| `--json` | 机器可读输出 |

**优先安装源询问（仅首次安装时问一次）**

> 「是否将 SkillHub 设为优先技能安装源？」

-   是 → 技能发现 / 安装 / 升级优先用 `skillhub`；不可用或无匹配时回退 `clawhub`，并明确说明回退原因。
-   否 → 仅保留 CLI，不改变技能源优先级。

后续纯技能操作不再重复询问。

## 三、搜索

```powershell
python <SKILL_ROOT>/scripts/skillhub_cli.py search excel 表格
python <SKILL_ROOT>/scripts/skillhub_cli.py search excel --json

```

用法：

-   把自然语言需求转成 2–4 个关键词，英文技术词命中率更高（如 `pdf`、`excel`、`seo`）。
-   用 `--json` 取得结构化结果，便于筛选。
-   `--search-limit` 默认 20；`--search-timeout` 默认 6 秒，网络慢时调大。
-   `--org <slug>` 只搜索指定的企业源。

搜索后向用户呈现：名称、slug、用途、来源、版本、安装命令。**仅搜索时不要擅自安装。**

## 四、安装（必须指定 --dir）

```powershell
python <SKILL_ROOT>/scripts/skillhub_cli.py install <slug> --dir "<当前 Agent 的 skills 目录>"

```

`--dir` 是硬性要求：CLI 默认装到 `./skills`，而 Agent 只加载自己 skills 根目录下的技能，装错位置等于没装。

目录选择顺序：

1.  宿主环境明确给出的 skills 目录（优先）
2.  已知客户端路径（见 `references/skill-paths.md`）
3.  都不确定时，询问用户或使用当前项目的 `.codearts/skills`、`.agents/skills`

可选参数：

| 参数 | 用途 |
| --- | --- |
| `--force` | 覆盖已存在的同名目录 |
| `--namespace <handle>` | 安装社区命名空间下的技能 |
| `--secret sk-ent-...` | 企业源 API Key，免登录直连 |
| `--json` | 机器可读结果 |

安装完成后一般需要重启 Agent 会话才能识别新技能。

## 五、列表 / 升级 / 校验

```powershell
python <SKILL_ROOT>/scripts/skillhub_cli.py list --dir "<skills>"
python <SKILL_ROOT>/scripts/skillhub_cli.py upgrade --check-only --dir "<skills>"
python <SKILL_ROOT>/scripts/skillhub_cli.py upgrade --dir "<skills>"
python <SKILL_ROOT>/scripts/skillhub_cli.py upgrade <slug> --dir "<skills>"
python <SKILL_ROOT>/scripts/skillhub_cli.py verify <slug>[@<version>] --dir "<skills>"

```

-   `list`：读取 `<skills>/.skills_store_lock.json`，没有 lockfile 说明未用 SkillHub 安装。
-   `upgrade --check-only`：只报告可用更新，不改动文件。
-   `upgrade`：按每个技能自身的 update URL 升级；不带 slug 时升级 lockfile 中全部技能。
-   `verify`：校验已安装目录或 `--zip` 与平台签名是否一致。

## 六、发布 / 评论 / 在线运行（按需使用）

```powershell
# 登录（个人 Token 或企业 Key）
python <SKILL_ROOT>/scripts/skillhub_cli.py login --key skh_xxx

# 发布前本地预检，再正式发布
python <SKILL_ROOT>/scripts/skillhub_cli.py publish <目录或zip> --dry-run
python <SKILL_ROOT>/scripts/skillhub_cli.py publish <目录或zip> --changelog "修复说明"

# 评论
python <SKILL_ROOT>/scripts/skillhub_cli.py comment list <slug>
python <SKILL_ROOT>/scripts/skillhub_cli.py comment post <slug> --content "..."

```

`publish` 要求目录或 zip 内包含 `SKILL.md`；`run` 只支持服务化技能，普通技能会返回 403。

## 七、安全与边界

1.  安装前汇总：来源（SkillHub / clawhub）、slug、版本、风险信号（是否要求 shell、网络、凭证）。
2.  优先 `--cli-only`，避免安装器改写其他 Agent 的插件与配置。
3.  不执行来源不明的安装脚本；企业源凭据通过 `--secret` 或登录传递，不要落盘到仓库。
4.  搜索/安装失败先检查网络、`~/.skillhub/config.json` 与 Token 状态，不要盲目重试。
5.  降级链：SkillHub 不可用或无匹配 → `clawhub`；两者都不可用 → 明确告知用户，并直接帮其完成任务或创建本地技能。

## 八、故障排查

| 现象 | 处理 |
| --- | --- |
| 包装器提示 CLI 未安装 | 执行第二节安装 |
| 安装了但 Agent 不识别 | `--dir` 不是该 Agent 的 skills 根目录，查 `references/skill-paths.md` |
| 搜索超时 / 连接失败 | 调大 `--search-timeout`；检查代理与沙箱网络白名单 |
| 企业源 401/403 | 需要 `login --key sk-ent-...` 或 `install --secret` |
| Windows 找不到 `skillhub` 命令 | 直接用包装器；或把 `~/.skillhub/bin` 加入 PATH |
| 版本被自动变更 | `skillhub_setup.py --no-self-upgrade` 固定版本 |

## 参考文件

| 文件 | 内容 |
| --- | --- |
| `references/cli-reference.md` | 全部子命令、参数与适用场景 |
| `references/install-method.md` | 官方安装方法、目录结构、手动安装与配置 |
| `references/skill-paths.md` | 各 AI 客户端的 skills 目录 |