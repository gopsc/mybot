#!/usr/bin/env python3
"""检查「LLM wire 契约」里本仓自己手写的那部分，在 Rust 产线与各调用点是否一致。

模型调用自 2026-09-25 起是 **Rust 直连**：C++ 宿主与 Lua 驱动沙箱都不参与网络
（见 `docs/agent.md`「模型调用（Rust 直连；Lua 协议驱动轨道已删）」），
`modules/Llm*.lua` 已不存在，`--llm-driver` 只是 C++ 转发给 Rust 的**协议族名**。
故本守门只钉 **Rust provider ↔ Python 夹具 ↔ E2E 脚本**这条链，不涉及 C++。

报文字段本身大多**不在本仓**：请求体（`top_p`/`reasoning_effort`/`temperature`/
`max_tokens`/`stream`）、SSE 帧名（`chat.completion.chunk`/`[DONE]`/`message_start`/
`content_block_*`/`message_delta`/`message_stop`）、响应字段（`choices`/`tool_calls`/
`usage.prompt_tokens`…）、鉴权头名（`Authorization`/`x-api-key`/`anthropic-version`）
都由 vendored 的 **rig** crate 拥有——`agent/src` 里搜不到这些字面量，对它们做
「从本仓源码文本互钉」在本仓不可能。唯一本仓手写的响应字段是 `reasoning_content`
（已由第 12 段 `check_stateful_protocol.py` 钉住）。

于是本脚本只钉本仓**确实手写了两份以上**的两件事：

  1. **协议族 → 请求路径**：`agent/src/provider.rs` 的 `Driver::request_path()`
     （OpenAI 族 `/chat/completions`、Anthropic `/v1/messages`）必须能解释夹具
     `scripts/fake_llm_server.py` 里两条 `self.path != "..."` 断言（Anthropic 那条
     全等、OpenAI 族那条取后缀），且各 E2E 脚本的 `--llm-endpoint` 路径都以某个
     已知 `request_path` 结尾；
  2. **协议族表名**：`Driver::from_table`（`LlmOpenAI`/`LlmDeepSeek`/`LlmAnthropic`）
     必须与 `Driver::as_str` 同集合，且 E2E 脚本里出现的每个 `--llm-driver` 都是
     其中的表名——脚本写错族名（如 `LlmDeepseek`）在 Rust 侧要等第一次调用才报错，
     这里在 push 前挡下。

另有一条成对断言：同一命令里 `--llm-driver X --llm-endpoint Y` 同时出现时，Y 的路径
必须以 X 的 `request_path` 结尾（族名与路径不许错配，如 `LlmAnthropic` 配
`/v1/chat/completions`）。

如实差异（不参与比对，登记在此以免读者以为漏检）：
  * **C++ / Lua 不参与**：不再实现 LLM 网络（无 `modules/Llm*.lua`）。
  * **rig 独占字段**：请求体、SSE 帧名、响应字段、鉴权头名，见上——本仓无字面量可钉。

用法：python3 scripts/check_llm_wire.py
退出码：0=一致，1=发现不一致或解析失败（原因打到 stderr）。
"""

import re
import sys

from lib.protocol_sources import (
    E2E_AGENT_SH,
    E2E_ICA_SH,
    FAKE_LLM_SERVER_PY,
    RUST_PROVIDER_RS,
    balanced_block,
    rel,
    resolve,
    strip_comments,
)
from lib.protocol_sources import read as _read

PREFIX = "check_llm_wire"

PROVIDER_RS = resolve(RUST_PROVIDER_RS)
FAKE_PY = resolve(FAKE_LLM_SERVER_PY)
E2E_SCRIPTS = (resolve(E2E_AGENT_SH), resolve(E2E_ICA_SH))

# provider.rs 的三个 match 表：表名→变体、变体→表名、变体（或 `A | B`）→路径。
TABLE_ROW_RE = re.compile(
    r'"([A-Za-z_][A-Za-z0-9_]*)"\s*=>\s*Ok\(Driver::([A-Za-z][A-Za-z0-9_]*)\)'
)
AS_STR_ROW_RE = re.compile(
    r'Driver::([A-Za-z][A-Za-z0-9_]*)\s*=>\s*"([A-Za-z_][A-Za-z0-9_]*)"'
)
# 夹具里两条鉴权/路径分支断言（每条形如 `self.path != "/v1/..."`）。
FIXTURE_PATH_RE = re.compile(r'self\.path\s*!=\s*"([^"]+)"')
# E2E 脚本里的实参（值可能带引号，URL 到引号/空白/续行反斜杠为止）。
DRIVER_ARG_RE = re.compile(r"--llm-driver\s+[\"']?([A-Za-z_][A-Za-z0-9_]*)")
ENDPOINT_ARG_RE = re.compile(r"--llm-endpoint\s+[\"']?(https?://[^\"'\s\\]+)")
# 同一行上成对出现的 `--llm-driver X … --llm-endpoint Y`（脚本里族名在路径之前）。
PAIRED_RE = re.compile(
    r"--llm-driver\s+[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?[^\n]*?"
    r"--llm-endpoint\s+[\"']?(https?://[^\"'\s\\]+)"
)
# 整行 shell 注释（行首可选空白后 `#`）：脚本头注释里举例的族名/路径不算实参。
SHELL_COMMENT_RE = re.compile(r"(?m)^[ \t]*#[^\n]*")


def read(path):
    """本脚本的读取包装：失败文案带脚本名前缀。"""
    return _read(path, PREFIX)


def strip_shell_comments(text):
    """去掉整行 shell 注释，避免把注释里举例的族名/接入点当成真实参。"""
    return SHELL_COMMENT_RE.sub("", text)


# ── 1) Rust provider：协议族表名与请求路径 ─────────────────────────────


def provider_facts(errors):
    """返回 (表名→变体, 变体→请求路径)。"""
    text = strip_comments(read(PROVIDER_RS))

    table_block = balanced_block(text, "pub fn from_table(")
    if table_block is None:
        sys.exit(
            f"{PREFIX}: {rel(PROVIDER_RS)} 里没找到 `pub fn from_table(...)`；"
            "函数改名/挪走请同步本脚本"
        )
    rows = TABLE_ROW_RE.findall(table_block)
    if not rows:
        sys.exit(
            f"{PREFIX}: from_table 里一条 `\"表名\" => Ok(Driver::X)` 都没抽到，"
            "写法变了请同步 TABLE_ROW_RE"
        )
    name_to_variant = dict(rows)

    as_str_block = balanced_block(text, "pub fn as_str(")
    if as_str_block is None:
        sys.exit(f"{PREFIX}: {rel(PROVIDER_RS)} 里没找到 `pub fn as_str(...)`")
    as_str = AS_STR_ROW_RE.findall(as_str_block)
    if {n for _, n in as_str} != set(name_to_variant):
        errors.append(
            f"{rel(PROVIDER_RS)}: from_table 的表名集合 {sorted(name_to_variant)} 与 as_str 的 "
            f"{sorted(n for _, n in as_str)} 不一致（同一族在两张表里名字不同）"
        )

    path_block = balanced_block(text, "pub fn request_path(")
    if path_block is None:
        sys.exit(f"{PREFIX}: {rel(PROVIDER_RS)} 里没找到 `pub fn request_path(...)`")
    variant_to_path = {}
    for line in path_block.splitlines():
        if "=>" not in line:
            continue
        lhs, rhs = line.split("=>", 1)
        m = re.search(r'"([^"]+)"', rhs)
        if m is None:
            continue
        for variant in re.findall(r"Driver::([A-Za-z][A-Za-z0-9_]*)", lhs):
            variant_to_path[variant] = m.group(1)

    if set(variant_to_path) != set(name_to_variant.values()):
        errors.append(
            f"{rel(PROVIDER_RS)}: request_path 只覆盖了 {sorted(variant_to_path)}，"
            f"而 from_table 提到 {sorted(name_to_variant.values())}——某个族没有请求路径"
        )
    if variant_to_path.get("OpenAi") != variant_to_path.get("DeepSeek"):
        errors.append(
            f"{rel(PROVIDER_RS)}: OpenAI 与 DeepSeek 走同一个 rig 路径，现在却分别是 "
            f"{variant_to_path.get('OpenAi')!r} / {variant_to_path.get('DeepSeek')!r}"
        )
    return name_to_variant, variant_to_path


# ── 2) Python 夹具：path 断言必须能被产线 request_path 解释 ────────────


def check_fixture(errors, variant_to_path):
    found = FIXTURE_PATH_RE.findall(read(FAKE_PY))
    if len(found) != 2:
        sys.exit(
            f"{PREFIX}: {rel(FAKE_PY)} 里 `self.path != \"...\"` 断言有 {len(found)} 条"
            "（预期 2：Anthropic 与 OpenAI 族各一）；协议分支改写请同步本脚本"
        )
    anthropic_path = variant_to_path.get("Anthropic")
    openai_path = variant_to_path.get("OpenAi")
    if anthropic_path is None or found.count(anthropic_path) != 1:
        errors.append(
            f"{rel(FAKE_PY)} 的 path 断言 {found} 里，没有一条全等于 Anthropic 的 "
            f"request_path {anthropic_path!r}（夹具要求的路径与产线拼出的不一致）"
        )
    openai_hits = [p for p in found if p != anthropic_path and p.endswith(openai_path or "")]
    if openai_path is None or len(openai_hits) != 1:
        errors.append(
            f"{rel(FAKE_PY)} 的 path 断言 {found} 里，没有一条以 OpenAI 族 request_path "
            f"{openai_path!r} 结尾（夹具要求的路径与产线拼出的不一致）"
        )
    return len(found)


# ── 3) E2E 脚本：族名与接入点路径 ──────────────────────────────────────


def check_scripts(errors, name_to_variant, variant_to_path):
    known_paths = set(variant_to_path.values())
    n_driver = n_endpoint = n_paired = 0
    for script in E2E_SCRIPTS:
        text = strip_shell_comments(read(script))
        for name in DRIVER_ARG_RE.findall(text):
            n_driver += 1
            if name not in name_to_variant:
                errors.append(
                    f"{rel(script)}: --llm-driver {name} 不是 {rel(PROVIDER_RS)} from_table "
                    f"里的表名（{sorted(name_to_variant)}）——Rust 侧要等第一次调用才报错"
                )
        for url in ENDPOINT_ARG_RE.findall(text):
            n_endpoint += 1
            if not any(url.endswith(p) for p in known_paths):
                errors.append(
                    f"{rel(script)}: --llm-endpoint {url} 的路径不以任何已知 request_path "
                    f"{sorted(known_paths)} 结尾"
                )
        for name, url in PAIRED_RE.findall(text):
            n_paired += 1
            want = variant_to_path.get(name_to_variant.get(name))
            if want is None or not url.endswith(want):
                errors.append(
                    f"{rel(script)}: --llm-driver {name} 配的接入点 {url} 与它的 request_path "
                    f"{want!r} 不符（族名与路径错配）"
                )
    if n_driver == 0:
        errors.append(
            f"{rel(E2E_AGENT_SH)}/{rel(E2E_ICA_SH)} 里一处 --llm-driver 都没抽到——"
            "脚本形态变了，本守门的族名断言会变成假绿"
        )
    if n_endpoint == 0:
        errors.append(
            f"{rel(E2E_AGENT_SH)}/{rel(E2E_ICA_SH)} 里一处 --llm-endpoint 都没抽到——"
            "脚本形态变了，本守门的路径断言会变成假绿"
        )
    return n_driver, n_endpoint, n_paired


def main():
    errors = []
    name_to_variant, variant_to_path = provider_facts(errors)
    n_fixture = check_fixture(errors, variant_to_path)
    n_driver, n_endpoint, n_paired = check_scripts(
        errors, name_to_variant, variant_to_path
    )

    if errors:
        print(f"{PREFIX}: LLM wire 契约不一致：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(
        f"{PREFIX}: 一致（协议族表名 {len(name_to_variant)} 个 / request_path "
        f"{len(variant_to_path)} 条 / 夹具 path 断言 {n_fixture} 条 / E2E 脚本 "
        f"--llm-driver {n_driver} 处、--llm-endpoint {n_endpoint} 处（成对校验 {n_paired} 处））"
    )


if __name__ == "__main__":
    main()