# SkillHub CLI 命令参考

Source: SkillHub 官方 CLI 文档（https://skillhub.cn）；本仓库的包装器实现见 `scripts/skillhub_cli.py`。

> 所有命令建议通过本 Skill 的包装器执行，避免 PATH 与平台差异：
>
> ```powershell
> python <SKILL_ROOT>/scripts/skillhub_cli.py <子命令> [参数]
> ```
>
> 下文示例省略前缀，只写 `skillhub <子命令>`。

## 全局选项

| 选项 | 位置 | 说明 |
| --- | --- | --- |
| `-v` / `--version` | 任意 | 打印 CLI 版本 |
| `--skip-self-upgrade` | **必须在子命令之前** | 本次运行跳过启动自升级检查，如 `skillhub --skip-self-upgrade search pdf` |
| `--dir <path>` | 子命令前后均可 | 安装根目录，默认 `./skills` |
| `--index <uri>` | 子命令之前 | 自定义索引（http/https/file/本地路径） |

## 子命令总览

| 子命令 | 何时使用 | 关键参数 |
| --- | --- | --- |
| `search` | 用户想找技能，但还不确定装哪个 | `--json`、`--org`、`--search-limit` |
| `install` | 已确定 slug，需要装入某个 skills 目录 | `--dir`、`--force`、`--namespace`、`--secret` |
| `list` | 查看某目录下由 SkillHub 安装的技能 | `--dir` |
| `upgrade` | 升级已安装技能 | `--check-only`、`--dir`、`slug` |
| `verify` | 安装前后校验包与平台签名一致 | `--zip`、`--version`、`--namespace` |
| `skill rankings` | 探索热门 / 精选 / 最新技能 | `--type` |
| `skill reports` | 查看某技能的安全报告链接 | `slug`、`--json` |
| `skill evaluation` | 查看某技能的平台评测 | `slug`、`--json` |
| `pack install` | 安装技能包（多个技能一组） | `slug`、`--dir`、`--force` |
| `soul install` | 安装 SOUL 模板到安装根目录的父目录 | `slug`、`--output`、`--dir` |
| `publish` | 把自己写的技能发布到社区 | `path`、`--dry-run`、`--version` |
| `login` / `logout` | 发布、评论、企业源鉴权 | `--key`、`--org` |
| `auth whoami` / `auth token` | 确认当前身份 / 调试 Token | 无 |
| `comment` | 技能评论区的读、写、赞 | `slug`、`commentID` |
| `run` | 在线调用“服务化”技能（SSE 流式） | `input`、`--skill`、`--new` |
| `config list` | 查看已配置的企业源 | 无 |
| `self-upgrade` | 手动升级 CLI 本体 | `--check-only`、`--timeout` |

## search

```bash
skillhub search excel 表格
skillhub search pdf --json
skillhub search --org mycorp 报销
```

- 查询词可多个，空格分隔；英文技术词命中率更高。
- `--search-limit` 默认 20，`--search-timeout` 默认 6 秒。
- `--org <slug>` 只在指定企业源内搜索。
- `--json` 便于程序化筛选。

**只在用户明确要安装时才进入下一步；纯搜索不要自动安装。**

## install

```bash
skillhub install excel-tool --dir "<skills 目录>"
skillhub install payment-sdk --namespace alice --dir "<skills 目录>"
skillhub install excel-tool --force --dir "<skills 目录>"
```

- `slug` 必填；先在本机索引中查找，找不到时回退到远程搜索。
- `--dir` 指向当前 Agent 的 skills 根目录，否则装到 `./skills` 不会被加载。
- `--force` 覆盖已存在的同名目录。
- `--secret sk-ent-...` 用于企业源直连下载；也可用 `SKILLHUB_SECRET` 环境变量。
- 安装规则会写入 `<dir>/.skills_store_lock.json`，`list` 与 `upgrade` 依赖它。

## list

```bash
skillhub list --dir "<skills 目录>"
```

读取 lockfile 并列出已安装技能。目录中没有 `.skills_store_lock.json` 时说明这些技能不是用 SkillHub 安装的。

## upgrade

```bash
skillhub upgrade --check-only --dir "<skills 目录>"
skillhub upgrade --dir "<skills 目录>"
skillhub upgrade <slug> --dir "<skills 目录>"
```

- 不带 `slug` 时升级 lockfile 中的全部技能。
- `--check-only` 只报告可用更新，不写文件。
- `--timeout` 控制 manifest 拉取超时，默认 20 秒。
- 每个技能依据自身的 `config.json` 中的 update URL 升级。

## verify

```bash
skillhub verify excel-tool --dir "<skills 目录>"
skillhub verify excel-tool@2026.8.5 --dir "<skills 目录>"
skillhub verify excel-tool --zip ./excel-tool.zip
```

默认校验已安装目录；`--zip` 校验本地压缩包。`--json` 输出结构化结果，适合安装前的准入检查。

## skill rankings / reports / evaluation

```bash
skillhub skill rankings --type hot
skillhub skill rankings --type recommended
skillhub skill reports excel-tool --json
skillhub skill evaluation excel-tool --json
```

- `rankings` 类型：`all`、`hot`、`featured`、`newest`、`recommended`、`trending`、`paid`。
- `reports` 返回 Keen / Yunding 等安全报告链接。
- `evaluation` 返回平台评测结论。

用于“推荐几个技能”或“这个技能靠不靠谱”的场景。

## pack install / soul install

```bash
skillhub pack install gaokao-expert --dir "<skills 目录>"
skillhub soul install coder-soul --dir "<skills 目录>"
```

- `pack` 安装一整套技能；`--force` 覆盖包内同名技能。
- `soul` 默认把 `SOUL.md` 写到安装根目录的父目录，可用 `--output` 指定。

## publish

```bash
skillhub publish ./my-skill --dry-run
skillhub publish ./my-skill --version 1.0.1 --changelog "修复解析问题"
skillhub publish ./my-skill.zip
```

- 目录或 zip 内必须包含 `SKILL.md`。
- 先 `--dry-run` 做本地预检（校验 metadata + 打包，不发 HTTP 请求）。
- 需要已登录 Token，或 `--token skh_...`。
- `--host` 默认 `https://api.skillhub.cn`。

## login / logout / auth

```bash
skillhub login --key skh_xxx
skillhub login --key sk-ent-xxx --host https://api.skillhub.cn
skillhub logout --org mycorp
skillhub auth whoami
skillhub auth token
```

- 个人 Token 前缀 `skh_`，企业 API Key 前缀 `sk-ent-`。
- 凭据保存在 `~/.skillhub/credentials.json`，不要提交到仓库。
- `auth token` 仅用于 CI 调试，输出即敏感信息。

## comment

```bash
skillhub comment list <slug> --sort hot --limit 20
skillhub comment post <slug> --content "很好用"
skillhub comment reply <slug> <commentID> --content "同感"
skillhub comment replies-more <slug> <commentID> --cursor <cursor>
skillhub comment like <slug> <commentID>
skillhub comment delete <slug> <commentID>
```

- 内容长度 ≤ 500 字；图片 `--image` 可重复，jpeg/png/webp，单张 ≤ 5MB，最多 9 张。
- `list` 的 `--sort new` 用 `--cursor` 翻页，`--sort hot` 用 `--offset`（上限 1000）。

## run

```bash
skillhub run "帮我做一份季度总结" --skill ppt
skillhub run - --skill ppt < input.txt
skillhub run "继续上一轮" --skill ppt --session <session_id>
```

- 只支持服务化技能，普通技能返回 403。
- 默认 30 分钟内相同技能组合复用同一会话；`--new` 强制新建，`--no-reuse` 不复用也不写缓存。
- `--json` 输出原始 SSE 帧，`--timeout` 为单次流式空闲超时（默认 600 秒）。

## self-upgrade

```bash
skillhub self-upgrade --check-only
skillhub self-upgrade
```

从 `~/.skillhub/config.json` 的 `self_update_url` 拉取清单并替换 CLI 本体。安装时使用 `--no-self-upgrade` 可避免启动时自动升级。

## 常见组合

```bash
# 搜索 -> 看报告 -> 安装 -> 校验
skillhub search excel --json
skillhub skill reports excel-tool --json
skillhub install excel-tool --dir "<skills>"
skillhub verify excel-tool --dir "<skills>"

# 升级前先看差异
skillhub upgrade --check-only --dir "<skills>"
skillhub upgrade --dir "<skills>"
```