# SkillHub 安装方法与目录结构

Source: SkillHub 官方安装文档（https://skillhub.cn/install/skillhub.md）；本仓库的跨平台安装器实现见 `scripts/skillhub_setup.py`。

本文对应官方文档 <https://skillhub.cn/install/skillhub.md>，并补充 Windows 与手动安装说明。

## 官方安装命令

```bash
# 完整安装：CLI + 默认 workspace skill 模板
curl -fsSL https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/install.sh | bash

# 仅安装 CLI
curl -fsSL https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/install.sh | bash -s -- --cli-only

# 固定 kit 版本
curl -fsSL https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/install.sh | bash -s -- --kit-version 2026.8.5
```

官方脚本依赖：`bash`、`curl`、`tar`、`python3`。任一缺失都会失败。

### 官方脚本参数

| 参数 | 作用 |
| --- | --- |
| `--cli-only` | 只安装 CLI |
| `--skill-only` | 只安装官方 skill 模板 |
| `--plugin-only` | 安装旧版 OpenClaw 插件（显式需要时才用） |
| `--no-skills` | 跳过模板安装，并持久化该偏好 |
| `--with-skills` | 强制安装模板 |
| `--kit-version <ver>` | 固定 kit 版本；远程模式下载对应 tarball |
| `--no-self-upgrade` | 写入 `auto_self_upgrade=false`，启动时不再自动升级 |
| `--restart-gateway` | 安装后重启 OpenClaw gateway |

## Windows 安装

官方脚本是 bash 脚本，Windows 上有三种方式：

1. **Git Bash / WSL**：直接执行官方命令。
2. **本 Skill 的跨平台安装器**（推荐，纯 Python）：
   ```powershell
   python <SKILL_ROOT>\scripts\skillhub_setup.py --cli-only
   ```
3. **手动安装**：见下文。

跨平台安装器与官方脚本的 CLI 部分等价，并且不会修改 OpenClaw 插件配置。

## 安装目录结构

```
~/.skillhub/
├── skills_store_cli.py     # CLI 主程序
├── skills_upgrade.py       # 技能升级模块
├── version.json            # CLI 版本
├── metadata.json           # 索引 / 搜索 / 下载地址
├── skills_index.local.json # 可选：本地索引
├── config.json             # CLI 配置
├── credentials.json        # 登录凭据（login 后生成）
├── bin/
│   └── skillhub.cmd        # Windows 启动器（跨平台安装器生成）
└── ...

~/.local/bin/skillhub        # POSIX 启动器（官方脚本生成）
```

旧版脚本还会写入：

- `~/.openclaw/extensions/skillhub/`（插件）
- `~/.openclaw/workspace/skills/find-skills/`
- `~/.openclaw/workspace/skills/skillhub-preference/`

## config.json 字段

| 字段 | 说明 |
| --- | --- |
| `self_update_url` | CLI 自升级清单地址 |
| `client_id` | 安装时生成的客户端标识（UUID） |
| `auto_self_upgrade` | `false` 时启动不检查更新 |
| `install_workspace_skills` | 是否安装官方 workspace skill 模板 |

`login` 后凭据写在 `~/.skillhub/credentials.json`，与 `config.json` 分离。

## 下载源

| 用途 | 地址 |
| --- | --- |
| kit 下载 | `https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/latest.tar.gz` |
| 固定版本 kit | `https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/skillhub-cli-<version>.tar.gz` |
| 技能索引 / 包 | `https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/skills.json`、`.../skills/<slug>.zip` |
| 搜索 API | `https://api.skillhub.cn/api/v1/search` |
| 主下载 API | `https://api.skillhub.cn/api/v1/download?slug={slug}` |

`metadata.json` 中保存了同样的地址，测试或内网环境可整体替换。

## 手动安装（无脚本）

```bash
# 1. 下载并解压
curl -fsSL https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/latest.tar.gz -o kit.tar.gz
mkdir -p kit && tar -xzf kit.tar.gz -C kit

# 2. 复制核心文件
mkdir -p ~/.skillhub
cp kit/cli/skills_store_cli.py kit/cli/skills_upgrade.py kit/cli/version.json kit/cli/metadata.json ~/.skillhub/

# 3. 写最小配置
python3 - <<'PY'
import json, uuid
from pathlib import Path
p = Path.home() / ".skillhub" / "config.json"
p.write_text(json.dumps({
    "self_update_url": "https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/version.json",
    "client_id": str(uuid.uuid4()),
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

# 4. 直接运行
python3 ~/.skillhub/skills_store_cli.py --version
```

Windows 对应把第 4 步换成 `python "$env:USERPROFILE\.skillhub\skills_store_cli.py" --version`。

## 首次安装后的优先源策略

官方文档要求：**仅首次安装 CLI，或用户明确要求配置优先源时**，询问一次：

> 是否将 SkillHub 设为优先技能安装源？

- 是：技能发现 / 安装 / 升级优先用 `skillhub`；不可用或无匹配时回退 `clawhub`，并说明回退原因。
- 否：只保留 CLI，不改变默认源优先级。

后续纯技能操作不再重复询问。

## 卸载

```bash
rm -rf ~/.skillhub
rm -f ~/.local/bin/skillhub
```

Windows：

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.skillhub"
```

已安装到各 Agent skills 目录的技能需要单独删除（连同 `.skills_store_lock.json` 中的记录）。

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `curl: command not found` | Windows 使用跨平台安装器或手动安装 |
| 下载超时 | 沙箱或企业网络限制，需放行 `*.myqcloud.com` 与 `api.skillhub.cn` |
| `python3: command not found` | Windows 上通常命令是 `python`；POSIX 需安装 python3 |
| 安装后命令仍不可用 | 启动器目录不在 PATH；直接用 `python ~/.skillhub/skills_store_cli.py` |
| 启动时总提示升级 | 用 `--no-self-upgrade` 重装，或 `skillhub self-upgrade --check-only` 后手动升级 |