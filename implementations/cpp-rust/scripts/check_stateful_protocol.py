#!/usr/bin/env python3
"""检查「有状态 LLM 协议」的判据在 Rust 产线与 Python 夹具两侧是否同一套。

模型服务端对**会话历史**（不只是单条报文）有一组状态性要求，违反即 400：工具调用
的 id 必须在 assistant 声明与 tool 回执之间一一配对，DeepSeek 思考模式下带
`tool_calls` 的历史还必须逐条带 `reasoning_content`。这套判据在仓里手写两份：

  * Rust 产线：`agent/src/session.rs` 的 `protocol_violation`——`--resume` 恢复会话
    前最后一道判据（服务端会 400 的历史宁可当场拒绝）；
  * Python 夹具：`scripts/fake_llm_server.py` 的 `protocol_error`——让假模型服务
    与真网关一样严（该函数自己的文档：夹具比真机宽松，缺陷就会溜到真机才暴露）。

两份各有一套单测（Rust 的 `protocol_violation_flags_orphans_duplicates_and_missing`、
`agent_e2e.sh` 末尾对真实请求的三类变异），但**没有任何守门比对两侧的判据集**：
夹具少一条判据时，产线拒绝的历史在离线守门里照常全绿——正是夹具文档点名的那种
「溜到真机才暴露」。本脚本零编译、零第三方依赖，接入 `test/run_all_selftest.sh`。

C++ 侧不参与比对（如实差异）：`src/` 里没有这套判据——会话历史的协议自洽由 Rust
agent 这一侧守（C++ 宿主不解析模型历史）。故本守门只钉 Rust ↔ Python 这一对。

报文一律按 DeepSeek 形态给（该模式下 `protocol_error` 的判据最全，能把配对规则与
两条夹具独有规则放在同一个 MODE 下比）；Anthropic 形态的 tool_use/tool_result 配对
规则由 `agent_e2e.sh` 末尾对真实请求的三类变异行为覆盖，此处不重做。

四组断言：
  1. **规则条数**：`protocol_violation` 里 `return Some(format!(` 的判据点个数必须等于
     本脚本登记的规则条数——产线加/删一条判据而夹具用例没跟上，在这里显形；
  2. **判据锚点**：每条登记的规则，其判据文本片段仍在该函数体内（措辞被改也显形，
     而不是「锚点抽不到 → 静默少比一条」）；
  3. **夹具行为**：用例表逐条喂给 `protocol_error`（`runpy` 加载，与 agent_e2e.sh
     同一手法，不起 HTTP 服务），违反规则的必须被拒**且理由里含该规则的特征片段**，
     合法历史必须通过——只断言「拒了」会让规则张冠李戴也算过；
  4. **用例表自检**：登记的每条 Rust 规则都至少有一条用例；标为夹具独有的规则必须
     写明理由（差异是记录在案的，不是沉默的），且用例名不重复。

用法：python3 scripts/check_stateful_protocol.py
退出码：0=一致，1=发现不一致或解析失败（原因打到 stderr）。
"""

import copy
import re
import runpy
import sys

from lib.protocol_sources import (
    FAKE_LLM_SERVER_PY,
    RUST_SESSION_RS,
    balanced_block,
    resolve,
    strip_comments,
)
from lib.protocol_sources import read as _read

PREFIX = "check_stateful_protocol"

RS_PATH = resolve(RUST_SESSION_RS)
PY_PATH = resolve(FAKE_LLM_SERVER_PY)

# Rust 产线判据登记表：规则名 → 判据文本里的稳定片段（锚点）。
# 锚点是给「判据还在不在」用的：改了措辞就必须改这里，改这里就会重新走一遍用例表。
RUST_RULES = [
    ("empty_call_id", "id 为空的工具调用"),
    ("missing_tool_call_id", "缺少 tool_call_id"),
    ("orphan_tool_id", "孤儿 tool 消息"),
    ("duplicate_answer", "被回答了不止一次"),
    ("unanswered_call", "没有得到任何 tool 回传"),
]

# 夹具独有（真网关会拒、但 Rust 侧的恢复判据不查）：逐条写明为什么不对称。
FIXTURE_ONLY_RULES = {
    "reasoning_content_required": (
        "DeepSeek 思考模式下带 tool_calls 的历史必须带 reasoning_content。"
        "Rust 侧不查——该字段由模型装饰器按请求重建，不落会话历史"
        "（repl 模块头「如实差异」第 2 条）"
    ),
    "tool_call_id_type": (
        "tool 回执的 tool_call_id 必须是字符串。Rust 侧不查——"
        "历史里的 id 经 rig 类型化（ToolCallId），构造不出非字符串"
    ),
}


def read(path):
    """本脚本的读取包装：失败文案带脚本名前缀。"""
    return _read(path, PREFIX)


# ── 1) + 2) Rust 产线判据：条数与锚点 ────────────────────────────────────


def check_rust(errors):
    body = balanced_block(strip_comments(read(RS_PATH)), "pub fn protocol_violation(")
    if body is None:
        sys.exit(
            f"{PREFIX}: 在 {RS_PATH} 里没找到 `pub fn protocol_violation(...)` 的函数体；"
            "函数改名/挪走请同步本脚本"
        )
    if "declared" not in body or "answered" not in body:
        sys.exit(
            f"{PREFIX}: {RS_PATH} 的 protocol_violation 里找不到 declared/answered "
            "两个账本——判据结构变了，本脚本的用例表（按配对规则写）不再可比"
        )

    sites = len(re.findall(r"return Some\(format!\(", body))
    if sites != len(RUST_RULES):
        errors.append(
            f"Rust protocol_violation 有 {sites} 个判据点，本脚本登记 {len(RUST_RULES)} 条规则"
            "——产线加/删了判据，请在本脚本的 RUST_RULES 与用例表里补上对应条目"
            "（夹具可能因此比产线宽松）"
        )
    for name, anchor in RUST_RULES:
        if anchor not in body:
            errors.append(
                f"Rust 判据锚点 '{anchor}'（规则 {name}）在 protocol_violation 里找不到了"
                "——判据被改写/删除？请同步 RUST_RULES 与用例表"
            )
    return sites, [a for _, a in RUST_RULES]


# ── 3) 夹具行为：用例表 ────────────────────────────────────────────────
#
# 报文一律按 DeepSeek 形态给（每条消息 content 是字符串、带 tool_calls 的 assistant
# 带 reasoning_content）——protocol_error 在 deepseek 模式下判据最全，能把配对规则与
# 两条夹具独有规则放在同一个 MODE 下比。
#
# 每条：名字 | 规则名 | 报文 | 期望 | 拒因里的特征片段（"ok" 则 None）。
# `rule` 取自 RUST_RULES 或 FIXTURE_ONLY_RULES——两侧判据集的对应关系写死在表里。


def asst(tool_calls=None, reasoning=""):
    m = {"role": "assistant", "content": ""}
    if tool_calls is not None:
        m["tool_calls"] = tool_calls
        m["reasoning_content"] = reasoning
    return m


def call(cid):
    return {"id": cid, "type": "function", "function": {"name": "t", "arguments": "{}"}}


def tool(cid, text="x"):
    return {"role": "tool", "tool_call_id": cid, "content": text}


def user(text="hi"):
    return {"role": "user", "content": text}


CASES = [
    {
        "name": "valid_pair",
        "rule": None,
        "messages": [user(), asst([call("c1")]), tool("c1", "ok")],
        "expect": "ok",
        "contains": None,
    },
    {
        "name": "empty_assistant_call_id",
        "rule": "empty_call_id",
        "messages": [user(), asst([call("")]), tool("")],
        "expect": "reject",
        "contains": "non-empty string",
    },
    {
        "name": "empty_tool_call_id",
        "rule": "missing_tool_call_id",
        "messages": [user(), asst([call("c1")]), tool("")],
        "expect": "reject",
        "contains": "empty tool_call_id",
    },
    {
        "name": "orphan_tool_id",
        "rule": "orphan_tool_id",
        "messages": [user(), asst([call("c1")]), tool("ghost")],
        "expect": "reject",
        "contains": "does not match any assistant",
    },
    {
        "name": "duplicate_answer",
        "rule": "duplicate_answer",
        "messages": [user(), asst([call("c1")]), tool("c1", "x"), tool("c1", "y")],
        "expect": "reject",
        "contains": "answered more than once",
    },
    {
        "name": "unanswered_call",
        "rule": "unanswered_call",
        "messages": [user(), asst([call("c9")])],
        "expect": "reject",
        "contains": "got no matching tool message",
    },
    {
        "name": "reasoning_content_missing",
        "rule": "reasoning_content_required",
        "messages": [
            user(),
            {"role": "assistant", "content": "", "tool_calls": [call("c1")]},
            tool("c1"),
        ],
        "expect": "reject",
        "contains": "missing",
    },
    {
        "name": "tool_call_id_not_string",
        "rule": "tool_call_id_type",
        "messages": [
            user(),
            asst([call("c1")]),
            {"role": "tool", "tool_call_id": 123, "content": "x"},
        ],
        "expect": "reject",
        "contains": "requires a string",
    },
]


def load_validator():
    """加载夹具校验器（与 agent_e2e.sh 同一手法）：runpy 只求函数，不起服务。"""
    if not PY_PATH.is_file():
        sys.exit(f"{PREFIX}: 找不到 {PY_PATH}")
    argv = sys.argv
    sys.argv = ["fake_llm_server.py", "0", "", "deepseek"]
    try:
        module = runpy.run_path(str(PY_PATH))
    finally:
        sys.argv = argv
    if "protocol_error" not in module:
        sys.exit(
            f"{PREFIX}: {PY_PATH} 里没有 protocol_error（改名/挪走了？）"
            "——本守门比的就是这个函数，请同步本脚本"
        )
    return module["protocol_error"]


def check_cases(errors, validator):
    seen = set()
    for case in CASES:
        if case["name"] in seen:
            errors.append(f"用例名重复：{case['name']}（同名会让「跑过哪些」记不清）")
        seen.add(case["name"])
        if case["rule"] is None:
            if case["expect"] != "ok":
                errors.append(f"用例 {case['name']} 没登记规则，只能是合法历史（expect=ok）")
            continue
        if case["rule"] not in dict(RUST_RULES) and case["rule"] not in FIXTURE_ONLY_RULES:
            errors.append(
                f"用例 {case['name']} 的规则 '{case['rule']}' 既不在 RUST_RULES、"
                "也不在 FIXTURE_ONLY_RULES 里——两侧的对应关系必须写明"
            )

    request = {"model": "deepseek", "messages": []}
    for case in CASES:
        request["messages"] = copy.deepcopy(case["messages"])
        got = validator(request)
        if case["expect"] == "ok":
            if got is not None:
                errors.append(
                    f"夹具拒了一条合法历史（用例 {case['name']}）：{got}\n"
                    "    ——产线（protocol_violation）放行的历史，夹具必须也放行，"
                    "否则离线守门会把好会话判死"
                )
            continue
        if got is None:
            errors.append(
                f"夹具接受了违反 '{case['rule']}' 的历史（用例 {case['name']}）——"
                "夹具比真机宽松，这类缺陷会溜到真机才 400"
            )
        elif case["contains"] and case["contains"] not in got:
            errors.append(
                f"夹具拒了 {case['name']}，但理由不是该规则（'{case['contains']}' 不在"
                f" '{got}' 里）——判据可能张冠李戴（另一条规则顺手拦下了它）"
            )

    for name, _ in RUST_RULES:
        if not any(c["rule"] == name for c in CASES):
            errors.append(
                f"Rust 规则 '{name}' 没有任何用例——产线拒的历史没在夹具上验过，"
                "等于这条规则在离线守门里没有防线"
            )
    for name, why in FIXTURE_ONLY_RULES.items():
        if not any(c["rule"] == name for c in CASES):
            errors.append(f"夹具独有规则 '{name}' 没有用例（已登记理由：{why}）")
    return len(CASES)


def main():
    errors = []
    sites, anchors = check_rust(errors)
    validator = load_validator()
    n_cases = check_cases(errors, validator)

    if errors:
        print(f"{PREFIX}: 有状态协议判据两侧不一致：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(
        f"{PREFIX}: 一致（Rust 产线 {sites} 条判据 / 锚点 {len(anchors)} 条 / "
        f"用例 {n_cases} 条：{len(RUST_RULES)} 条产线规则各有用例，"
        f"{len(FIXTURE_ONLY_RULES)} 条夹具独有已登记理由）"
    )


if __name__ == "__main__":
    main()