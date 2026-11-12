#!/usr/bin/env python3
"""检查后端工具注册表（makeAgentTools 装配的工具集）与**两张**文档工具表是否同集合。

`docs/agent.md` 的「给智能体的工具」一节是**手工维护**的权威总表（无自动生成，同
`docs/sim.md`「跨构建系统不做代码生成」的取舍一致）；`README.md` 的「Agent 工具系统」
一节是同一份名单的门面摘要（少一列门控细节）。工具本身的权威定义是四个
`make*Tool` 所在 TU 里 `return AgentTool{"<name>", ...}` 的第一个字段
（`src/agenttools.cpp` / `src/agenttools_wait.cpp` / `src/agenttools_fs.cpp` /
`src/agentimage.cpp`，见 `src/agenttools.cpp:560 makeAgentTools` 的装配序），外加 Rust 侧
**本地工具** `agent/src/httpfetch.rs` 的 `pub const TOOL_NAME: &str = "http_fetch"`
（Phase 6；不经后端注册表，但同样列在两张文档表里）。此前没有任何守门比对
这些名单：加一个工具（或改名/删除）只要忘了同步文档表，就只能靠人工评审
发现——而 ICA 侧的姊妹风险已经有 `agent/src/ica/specs.rs` 的 `all.len() == 8`
自钉（见该文件测试注释），后端工具这一半一直是空的。

**为什么两张表都要比**：只钉 `docs/agent.md` 时，README 的工具表可以静默少几行
（2026-10-08 审计实测少了 `list_dir`/`read_file`/`write_file` 三个），而 README 是
新人第一入口——误导面比深入文档更大。

本脚本零编译、零第三方依赖，接入 `test/run_all_selftest.sh`，让「代码加了工具、
文档没跟上」（或反过来，文档写了代码里不存在的工具）在 push 前就被挡下。

两组断言：
  1. 代码侧抽到的工具名集合 == 每张文档表第一列的工具名集合（双向，各自列出对侧没有的）；
  2. 抽取本身有效：代码侧与每张文档侧都至少抽到 1 个、且各自无重复项
     （抽到 0 个或有重复都说明写法变了、本脚本的抽取式脱节，宁可报错也不让
     「两边都空」或「两边都重复同一个」悄悄变成假绿）。

注意：工具是否**实际注册**取决于运行期能力门控（`--agent-shell` 等，见
`src/agenttools.cpp:560-576`）——本脚本比对的是「代码里一共定义了哪些工具」，
不是「某次运行实际暴露了哪些」，这与两张文档表「列出全部工具、门控写在说明里」
的既有体例一致。

用法：python3 scripts/check_agent_tool_table.py
退出码：0=一致，1=发现不一致或解析失败（原因打到 stderr）。
"""

import re
import sys
from collections import Counter

from lib.protocol_sources import (
    AGENT_IMAGE_CPP,
    AGENTTOOLS_CPP,
    AGENTTOOLS_FS_CPP,
    AGENTTOOLS_WAIT_CPP,
    DOCS_AGENT_MD,
    README_MD,
    RUST_HTTPFETCH_RS,
    rel,
    resolve,
    strip_comments,
)
from lib.protocol_sources import read as _read

PREFIX = "check_agent_tool_table"

CODE_PATHS = [
    resolve(AGENTTOOLS_CPP),
    resolve(AGENTTOOLS_WAIT_CPP),
    resolve(AGENTTOOLS_FS_CPP),
    resolve(AGENT_IMAGE_CPP),
]
# Rust 本地工具：(路径, 名字常量正则)。ICA 的 ica_* 工具不在文档工具表里（另有专节，
# 且 agent/src/ica/specs.rs 自钉数量），故不列。
RUST_LOCAL_SOURCES = [
    (resolve(RUST_HTTPFETCH_RS),
     re.compile(r'pub const TOOL_NAME: &str = "([a-zA-Z_][a-zA-Z0-9_]*)";')),
]
# 文档侧：(路径, 小节标题, 人话标签)。小节标题用于把抽取范围限定在工具表那一节，
# 否则页面别处的 `| \`name\` |` 形态表格（如配置字段表）会被误抽成工具名。
DOC_SOURCES = [
    (resolve(DOCS_AGENT_MD), "## 给智能体的工具", "docs/agent.md 工具表"),
    (resolve(README_MD), "## Agent 工具系统", "README 工具表"),
]

# 工具名的第一个字段：`AgentTool{` 之后第一个字符串字面量就是 name
# （三个 TU 里全部如此，见头注；不用 balanced_block 是因为一个文件里有多个
# `AgentTool{` 块，而我们只要每块的**第一个**字符串，正则 findall 更直接）。
TOOL_NAME_RE = re.compile(r'AgentTool\{\s*"([a-zA-Z_][a-zA-Z0-9_]*)"')

# 文档表第一列：`| \`name\` |`（表头/分隔行不匹配——它们不是反引号包着的标识符）
DOC_ROW_RE = re.compile(r'^\|\s*`([a-zA-Z_][a-zA-Z0-9_]*)`\s*\|', re.M)


def read(path):
    return _read(path, PREFIX)


def code_tool_names(errors):
    names = []
    for path in CODE_PATHS:
        text = strip_comments(read(path))
        found = TOOL_NAME_RE.findall(text)
        if not found:
            errors.append(f"{rel(path)} 里一个 `AgentTool{{\"...\"}}` 都没抽到——"
                "本脚本的抽取式跟写法脱节了，还是该文件确实不再定义工具？")
        names.extend(found)
    for path, pattern in RUST_LOCAL_SOURCES:
        found = pattern.findall(strip_comments(read(path)))
        if len(found) != 1:
            errors.append(f"{rel(path)} 里应恰好抽到 1 个 `pub const TOOL_NAME`，实际 {len(found)} 个"
                "——本脚本的抽取式跟写法脱节了？")
        names.extend(found)
    for name, n in Counter(names).items():
        if n > 1:
            errors.append(f"代码侧工具名 `{name}` 出现 {n} 次（同名工具重复定义？）")
    return names


def doc_tool_names(errors, path, marker, label):
    text = read(path)
    start = text.find(marker)
    if start == -1:
        sys.exit(f"{PREFIX}: 在 {rel(path)} 里没找到 `{marker}` 小节标题")
    end = text.find("\n## ", start + len(marker))
    if end == -1:
        end = len(text)
    section = text[start:end]
    names = DOC_ROW_RE.findall(section)
    if not names:
        errors.append(f"{rel(path)} 的「{marker}」小节一行 `| \\`name\\` |` 都没抽到"
            "——表格写法变了，还是表空了？")
    for name, n in Counter(names).items():
        if n > 1:
            errors.append(f"{label}里工具名 `{name}` 出现 {n} 次")
    return names


def main():
    errors = []
    code_names = code_tool_names(errors)
    code_set = set(code_names)

    doc_sets = {}
    for path, marker, label in DOC_SOURCES:
        names = doc_tool_names(errors, path, marker, label)
        doc_sets[label] = set(names)
        for name in sorted(code_set - set(names)):
            errors.append(
                f"工具 `{name}` 在代码里定义了"
                f"（{', '.join(str(rel(p)) for p in CODE_PATHS + [q for q, _ in RUST_LOCAL_SOURCES])}），"
                f"但{label}没有这一行——用户看文档会漏掉这个工具"
            )
        for name in sorted(set(names) - code_set):
            errors.append(
                f"{label}里有 `{name}` 这一行，但代码里找不到同名 "
                f"`AgentTool{{\"...\"}}` 或 Rust 本地工具 `TOOL_NAME`——文档在说一个不存在"
                f"（或已改名/已删除）的工具"
            )

    if errors:
        print(f"{PREFIX}: 工具注册表（后端 + Rust 本地）与文档工具表不一致：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(
        f"{PREFIX}: 一致（{len(code_set)} 个工具：代码定义 == "
        + " == ".join(label for _, _, label in DOC_SOURCES)
        + "）"
    )


if __name__ == "__main__":
    main()
