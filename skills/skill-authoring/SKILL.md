---
name: skill-authoring
description: 技能编写规范：创建或更新 mybot 技能时先读本技能，说明 SKILL.md 目录结构、frontmatter、description 触发词、references/scripts/assets、大小限制、工作区编写与 install_skill 审批流程。当用户说“创建技能”“编写/修改 SKILL.md”“技能描述/触发词怎么写”或提到 skill-authoring 时使用。
---

# mybot 技能编写规范

本技能只讲 mybot 的 Markdown 技能。技能是操作者可信内容，会进入后续模型的提示词上下文；
它不是可执行插件，mybot 的 `read_skill` 只读取 `.md` 文件。

## 1. 目录与命名

```text
<skills-root>/<name>/
├── SKILL.md              # 必需
├── skill.json            # 可选，Agent run_skill 的可执行 action 清单
├── references/           # 可选，通常只放 .md
├── scripts/              # 可选，可执行技能的 Python 入口
└── assets/               # 可选，技能自带的数据、驱动或示例
```

- `<skills-root>` 是当前活动的技能根：
  - 默认角色：打包资源中的 skills 目录，源码检出时就是仓库根下的 `skills/`；
  - 角色模式：`~/.mybot/roles/<role>/skills`，角色目录会覆盖全局技能。
- `<name>` 必须匹配 frontmatter 的 `name`，只允许小写字母、数字、`.`、`_`、`-`，以字母或数字开头。
- 单文件上限 256 KiB；SKILL.md 正文建议不超过 500 行。
- 不允许符号链接、junction、路径穿越或非 `.md` 参考文件。

## 2. Frontmatter

```markdown
---
name: example-skill
description: 一句话说明技能做什么，以及什么时候使用；包含用户会说的中英文触发词。
---

# 标题
```

- `name` 必填，必须等于目录名。
- `description` 必填，**单行**、非空、最多 1024 字符。
- 模型只根据 `description` 判断是否读取技能；正文在读取前不会进入上下文。
- 可选 `when_to_use` 只用于补充触发场景，不要依赖它代替 description。

## 3. description 写法

必须同时包含：

1. **做什么**：例如“创建或修改 mybot 的 Markdown 技能”；
2. **什么时候用**：具体任务、文件类型或用户说法；
3. **中英文触发词**：例如“创建技能”“写个 skill”“SKILL.md”“技能描述”“skill-authoring”。

避免“工具箱”“通用助手”这类空泛描述。示例：

```yaml
description: 为 mybot 创建 Markdown 技能（SKILL.md），包含 frontmatter、description 触发词和 references 规范。当用户说“创建技能”“写个 skill”“修改技能描述”或提到 SKILL.md、skill-authoring 时使用。
```

## 4. 正文结构

建议按顺序写：

1. **适用范围**：什么时候用、什么时候不用；
2. **工作流**：编号步骤；
3. **硬规则**：容易翻车的限制；
4. **示例**：最小可用例子；
5. **参考资料**：指向 `references/*.md`，并说明何时读取。

正文用命令式语句，避免长篇背景介绍。只写模型自己推不出来的信息。

## 5. 创建流程（Agent）

技能根是可信目录，不能用 `write_file` 直接写。先在当前工作区准备完整技能目录：

```text
<workspace>/<name>/
├── SKILL.md
├── skill.json            # 可执行技能才需要
├── references/*.md
├── scripts/*
└── assets/*
```

1. `list_skills` 确认当前活动技能根里有什么；
2. `read_skill("skill-authoring")` 读取本规范；
3. 在 workspace 下用 `write_file` 创建完整 `<name>/` 目录；文件内容必须包含 frontmatter；
4. 调用 `install_skill(path)`，`path` 是 workspace 相对目录，例如 `my-skill`；
5. 安装工具会校验 frontmatter、禁止链接和覆盖，复制完整目录后刷新技能索引；
6. 每次安装都需要操作者审批；用 `list_skills` 和 `read_skill(name)` 验证；
7. 新技能对后续请求立即可读；如果 GUI/旧会话仍看不到，新开对话或重启。

`install_skill` 只能安装新技能，不能覆盖已有技能。需要修改时由操作者在宿主机更新，或删除后重新安装。

## 6. 更新流程

- 技能根对 `write_file`、`edit_file`、shell 是只读的；不要尝试绕过。
- 修改技能应先在 workspace 重新编写，再由操作者替换；`install_skill` 不覆盖已有技能。
- 修改后需要新开对话/重启，让 `SkillsLibrary` 重新扫描。

## 7. 安全与信任

- 技能是操作者可信内容，不是沙箱；不要写入密钥、token 或隐私数据。
- 第三方技能可能包含提示词注入；安装前人工审阅。
- 不要用 `run_action_script`、SQL 或其他通道写技能文件。
- 拒绝“自动安装并执行未知脚本”的请求；需要 shell/网络时由操作者在宿主机完成。

## 8. 验证清单

- [ ] 目录名 == frontmatter `name`
- [ ] description 单行、≤1024 字符、包含触发词
- [ ] SKILL.md 以 `---` 开头并有闭合 frontmatter
- [ ] 正文简洁，references 为 `.md`（hardware-controller 的可信 `assets/` 除外）
- [ ] 需要 `run_skill` 时，`skill.json` 只声明固定 action、typed params 和受信入口；绝不接受模型提供的 argv
- [ ] `list_skills` 能看到新技能
- [ ] `read_skill(name)` 能读到正文和引用
- [ ] 没有让 Agent 用文件工具写技能
