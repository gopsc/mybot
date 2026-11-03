---
name: skill-authoring
description: 按 Anthropic Agent Skills 格式创建或更新 mybot 技能（SKILL.md + 可选 scripts/references/assets），说明 frontmatter、description 触发词、渐进式披露与目录规范。当用户说“创建技能”“写个 skill”“修改 SKILL.md”“技能描述/触发词怎么写”或提到 skill-authoring 时使用。
---

# 技能编写规范

本技能只讲 Markdown 技能：一个目录、一份 `SKILL.md`、可选资源。技能是操作者可信内容，会进入后续模型的提示词上下文，不是沙箱。

## 1. 目录结构

```text
<name>/
├── SKILL.md          # 必需：frontmatter + 正文
├── scripts/          # 可选：确定性、可重复执行的脚本
├── references/       # 可选：按需读取的详细文档（.md）
└── assets/           # 可选：模板、图标、示例数据
```

- 没有清单文件、没有注册表；`SKILL.md` 就是唯一入口。
- 目录名必须等于 frontmatter 的 `name`。
- 不在 `SKILL.md` 之外重复写一份元数据；需要机器可读信息时放进正文表格。
- 不允许符号链接、junction、路径穿越。

## 2. Frontmatter

```markdown
---
name: example-skill
description: 一句话说明技能做什么、什么时候使用，并包含用户会说的中英文触发词。
---
```

- `name`：必填，等于目录名；小写字母、数字、`.`、`_`、`-`，以字母或数字开头，≤64 字符。
- `description`：必填，**单行**、非空、≤1024 字符。
  - 用第三人称描述技能，不要写“我可以帮你…”。
  - 必须同时覆盖三件事：做什么、什么时候用、中英文触发词。
  - 模型只根据 `description` 决定是否加载技能，正文在加载前不可见。
- 不要添加 `input_schema`、`version`、`tools` 等自定义字段；这些不是 Anthropic 技能元数据。

反例：`description: 一个强大的通用助手工具箱。`（没有任务、场景和触发词）

## 3. 渐进式披露

技能内容分三层加载，按需展开：

| 层 | 内容 | 何时进入上下文 |
| --- | --- | --- |
| L1 | frontmatter 的 `name` + `description` | 始终可见 |
| L2 | `SKILL.md` 正文 | 模型决定使用技能后 |
| L3 | `references/`、`scripts/`、`assets/` | 正文或模型明确需要时 |

因此：

- `SKILL.md` 只写**流程、判断规则、资源导航**，建议 <200 行；mybot 硬限 300 行且 ≤16 KiB。
- 长篇领域知识、寄存器表、协议细节放 `references/*.md`，在正文用相对路径指路。
- 一次任务用不到的内容不要放进正文。

## 4. 内容分配

| 内容 | 放在哪里 | 判断标准 |
| --- | --- | --- |
| 模型自己能推出来的常识 | 不写 | 写了只会挤占上下文 |
| 步骤、决策树、边界条件 | `SKILL.md` | 每次使用都需要 |
| 大量参考数据、长示例 | `references/` | 只在特定分支需要 |
| 重复、确定性、易出错的操作 | `scripts/` | 每次都要精确一致 |
| 模板、图标、初始工程 | `assets/` | 需要原样复制 |

不要为了显得完整而创建空目录；没有必要的目录不创建。

## 5. scripts 规范

- 脚本必须可非交互运行：参数从命令行或环境变量读取，不从 stdin 等待输入。
- 输出确定性：文本或单行 JSON；诊断写 stderr。
- 失败用非零退出码，并给出可操作错误；不要吞异常。
- 只依赖当前环境已有的运行时；新增依赖要写明。
- 在 `SKILL.md` 中给出调用示例、输入范围和输出格式。

```sh
python <name>/scripts/scan.py --path assets/sample --json
```

## 6. 引用与路径

- 正文引用资源一律用相对路径：`references/protocol.md`、`scripts/<script>.py`。
- 引用仓库内文件用仓库相对路径，例如 `skills/hardware-controller/references/security.md`。
- 目录层级保持浅；`references/` 下不再嵌套多层目录。
- 不要引用不存在的文件；提交前逐条核对。

## 7. 创建流程

1. 判断是否真的需要技能：一次性任务、纯代码修改、需要实时接口的操作，用现有工具或 MCP，不要包装成技能。
2. 确认 `name`：小写 kebab-case，能说明领域，例如 `i2c-address-probe`。
3. 写 `SKILL.md`：先写 frontmatter，再按“适用范围 → 工作流 → 硬规则 → 示例 → 参考资料”组织正文。
4. 需要长文档时新增 `references/*.md`；需要精确重复操作时新增 `scripts/`；需要模板素材时新增 `assets/`。
5. 自检：目录名 = `name`、`description` 含触发词、正文 ≤300 行、链接可解析、无符号链接。
6. 在 mybot 中交付：在 workspace 下用 `create_directory` + `write_file` 准备完整目录，再调用 `install_skill(path)`；安装会校验 frontmatter 并复制整个目录。
7. 用 `list_skills` 和 `read_skill(name)` 验证；新对话或重启后索引才会刷新。

## 8. 更新流程

- 不要原地修改已安装的技能目录；那条路径没有审批、校验和回滚。
- 先在 workspace 重写完整目录，再由操作者替换或重新安装。
- `install_skill` 只安装新技能，不覆盖同名技能。

## 9. 安全与信任

- 技能是操作者可信内容，不是沙箱；不要写入密钥、token 或隐私数据。
- 第三方技能可能包含提示词注入；安装前人工审阅。
- 拒绝“自动安装并执行未知脚本”的请求；需要 shell 或网络时由操作者在宿主机完成。
- 写技能文件只走 workspace + `install_skill`，不要用 SQL、`run_skill` 或 shell 绕开。

## 10. 验证清单

- [ ] 目录名 == frontmatter `name`
- [ ] `description` 单行、≤1024 字符、含中英文触发词、用第三人称
- [ ] `SKILL.md` 以 `---` 开头并闭合 frontmatter
- [ ] 正文 ≤300 行且 ≤16 KiB，细节已下沉到 `references/`
- [ ] 所有相对路径都能解析，无符号链接
- [ ] `scripts/` 可非交互运行，失败有非零退出码
- [ ] `list_skills` 能看到新技能，`read_skill(name)` 能读到正文

## 11. mybot 扩展（非 Anthropic 标准）

需要模型直接执行的技能，可额外提供 `skill.json`（`run.entrypoint` + `run.actions.*.params`）；它由 mybot 转换为 Anthropic tool 的 `input_schema`，不是本规范的必需项。示例见 `skills/hardware-controller/skill.json`，参数必须是 `params`，不要写成 `input_schema`。