"""Deterministic bilingual intent routing for the agent harness.

The classifier runs before each model request. Explicit control, authoring,
diagnosis and inspection requests get a bounded tool allowlist and budget;
messages with no intent keywords stay unrestricted so ordinary conversation
and provider-specific tool flows are not narrowed by a guess. When several
intents match, their tool sets are unioned: a request such as “write a script
and run it” still reaches both file and hardware tools.
"""
from __future__ import annotations

from dataclasses import dataclass
import re

INTENTS = ("chat", "inspect", "control", "author", "diagnose")
MODES = ("auto", "off", *INTENTS)

READ_TOOLS = frozenset({"list_hardware", "list_action_scripts", "query_sql",
                        "list_skills", "read_skill", "list_files", "read_file", "read_prompt",
                        "web_fetch", "web_search"})
TOOLS_BY_INTENT = {
    "chat": READ_TOOLS,
    "inspect": READ_TOOLS,
    "control": READ_TOOLS | {"run_action_script", "read_variables", "capture_image"},
    "author": READ_TOOLS | {"write_file", "edit_file", "update_prompt", "create_skill"},
    "diagnose": READ_TOOLS | {"shell"},
}
BUDGETS = {"chat": (3, 4), "inspect": (4, 8), "control": (8, 16),
           "author": (8, 20), "diagnose": (6, 12)}
_RULES = {
    "control": ("运行", "执行", "启动", "停止", "自检", "动作", "读取", "采样", "拍照",
                "拍一张", "拍张", "run", "execute", "start", "stop", "activate",
                "deactivate", "capture", "sample", "relay", "servo", "motor"),
    "author": ("编写", "写一个", "写个", "生成", "修改", "修复", "新建", "创建", "重构",
               "补全", "实现", "记住", "記住", "write", "edit", "create", "add", "fix", "refactor",
               "implement", "patch", "rename", "remember"),
    "diagnose": ("报错", "失败", "错误", "异常", "为什么", "无法", "诊断", "排查", "日志",
                 "堆栈", "命令", "error", "fail", "wrong", "why", "debug", "diagnose",
                 "traceback", "exception", "broken", "shell", "terminal"),
    "inspect": ("列出", "查看", "状态", "硬件", "结构", "有哪些", "查询", "显示", "清单",
                "list", "show", "status", "hardware", "structure", "query", "inspect",
                "describe"),
}
# Name the most specific matched intent; tools still come from the union.
_PRIORITY = ("author", "control", "diagnose", "inspect")
_ENGLISH = {intent: {word for word in words if word.isascii()}
            for intent, words in _RULES.items()}
_CHINESE = {intent: tuple(word for word in words if not word.isascii())
            for intent, words in _RULES.items()}


@dataclass(frozen=True)
class IntentDecision:
    name: str
    confidence: float
    reason: str
    tools: frozenset[str] = frozenset()
    restricted: bool = True
    max_requests: int = 8
    max_tool_calls: int = 16

    def allows(self, tool):
        return not self.restricted or tool in self.tools

    def as_dict(self):
        return {"name": self.name, "confidence": round(self.confidence, 2),
                "reason": self.reason, "restricted": self.restricted,
                "allowed_tools": sorted(self.tools) if self.restricted else None,
                "max_requests": self.max_requests, "max_tool_calls": self.max_tool_calls}


def _matches(text, intent):
    lowered = text.casefold()
    hits = [word for word in _CHINESE[intent] if word in lowered]
    for word in sorted(_ENGLISH[intent]):
        if re.search(rf"(?<![a-z]){re.escape(word)}(?![a-z])", lowered):
            hits.append(word)
    return hits


def classify_intent(text, mode="auto"):
    mode = str(mode or "auto").strip().lower()
    if mode == "off":
        return IntentDecision("off", 1.0, "intent routing disabled by the operator",
                              restricted=False)
    if mode in INTENTS:
        return IntentDecision(mode, 1.0, "operator-selected intent",
                              tools=TOOLS_BY_INTENT[mode],
                              max_requests=BUDGETS[mode][0],
                              max_tool_calls=BUDGETS[mode][1])
    if mode != "auto":
        mode = "auto"
    scored = {}
    for intent in _PRIORITY:
        hits = _matches(text, intent)
        if hits:
            scored[intent] = hits
    if not scored:
        return IntentDecision("chat", 0.4, "no intent keywords; tools stay unrestricted",
                              restricted=False)
    name = next(intent for intent in _PRIORITY if intent in scored)
    tools = frozenset().union(*(TOOLS_BY_INTENT[intent] for intent in scored))
    requests = max(BUDGETS[intent][0] for intent in scored)
    calls = max(BUDGETS[intent][1] for intent in scored)
    total = sum(len(hits) for hits in scored.values())
    reason = "; ".join(f"{intent}: {', '.join(hits[:4])}" for intent, hits in scored.items())
    return IntentDecision(name, min(0.95, 0.55 + 0.1 * total), reason,
                          tools=tools, max_requests=requests, max_tool_calls=calls)
