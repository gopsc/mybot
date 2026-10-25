#!/usr/bin/env python3
"""检查模型配置字段白名单在 C++ 后端与 Rust agent 两侧是否同集合。

两端读**同一份** `mybot.llm.json`，各自维护一份「已承认字段」白名单，任一侧不认
就把整份配置判成「未知字段」拒读：

  * C++ 侧：`src/llmconfig.cpp` 的 `loadConfigRoot` 里的 `kKnown`
    （只登记不解析的模型侧字段也在里面——批次 2，2026-10-01：后端读不了操作者的
    配置等于把 agent 的合法字段变成了后端的启动错误）；
  * Rust 侧：`agent/src/config/file.rs` 的 `PARSED_FIELD_NAMES`（由 `parsed_fields!`
    宏表展开，每行 `(字段名, "json 键", 类型, ...)`）+ `KNOWN_UNPARSED_FIELDS`
    （C++ 后端专属的能力/摄像头/超时字段 + `thinking`）。

跨两套构建系统，刻意不做代码生成（同 `docs/sim.md`「跨构建系统不做代码生成」的取舍），
于是同一份名单手写两份。此前**没有任何守门比对它们**：两侧的单测各自只验自己那份
（Rust 的 `parsed_fields!` 一致性用例、C++ 的 `agentconfig_*` 用例），加字段时漏改
一侧要到用户改配置被拒才发现。本脚本零编译、零第三方依赖，接入
`test/run_all_selftest.sh`，让漏改一侧在 push 前就被挡下。

四组断言：
  1. 两侧集合**双向**相等（各自列出对侧没有的字段名）；
  2. Rust 的两份名单互不重叠（同一个键既解析又「只登记」是自相矛盾）；
  3. 每份名单内部无重复项（重复会让「个数」与「集合」对不上，掩盖漏改）；
  4. 抽取本身有效：每份名单抽到的名字数 == 该块里出现的字符串字面量数
     （写法变了导致抽不到时，宁可报错也不让「两边都空」变成假绿）。

用法：python3 scripts/check_llm_field_whitelist.py
退出码：0=一致，1=发现不一致或解析失败（原因打到 stderr）。
"""

import re
import sys
from collections import Counter

from lib.protocol_sources import (
    LLM_CONFIG_CPP,
    RUST_CONFIG_FILE_RS,
    balanced_block,
    rel,
    resolve,
    strip_comments,
)
from lib.protocol_sources import read as _read

PREFIX = "check_llm_field_whitelist"

CPP_PATH = resolve(LLM_CONFIG_CPP)
RS_PATH = resolve(RUST_CONFIG_FILE_RS)

STRING_RE = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"')
# 任何形状的字符串字面量：与 STRING_RE 的差集就是「白名单里有、但本脚本的标识符
# 正则表达不了」的键（如带连字符的 `"max-tokens"`）。两侧都只用 STRING_RE 比个数的话，
# 这道自检永远相等、等于没检——故字面量一律用这条更宽的式子数。
ANY_STRING_RE = re.compile(r'"([^"]*)"')
# 宏表的一行：(rust_field, "json_key", kind, ...)——json 键才是配置文件里的名字
MACRO_ROW_RE = re.compile(r'\(\s*(\w+)\s*,\s*"([A-Za-z_][A-Za-z0-9_]*)"')


def read(path):
    """本脚本的读取包装：失败文案带脚本名前缀。"""
    return _read(path, PREFIX)


def cpp_known(errors):
    body = balanced_block(strip_comments(read(CPP_PATH)), "std::set<std::string> kKnown =")
    if body is None:
        sys.exit(
            f"{PREFIX}: 在 {rel(CPP_PATH)} 里没找到 `static const std::set<std::string> "
            "kKnown = { ... }`；写法变了请同步本脚本"
        )
    names = STRING_RE.findall(body)
    check_extraction(errors, f"{rel(CPP_PATH)} 的 kKnown", names, body)
    return names


def rs_parsed(errors):
    text = read(RS_PATH)
    macro = balanced_block(text, "macro_rules! parsed_fields")
    if macro is None:
        sys.exit(f"{PREFIX}: 在 {rel(RS_PATH)} 里没找到 `macro_rules! parsed_fields`")
    rows = MACRO_ROW_RE.findall(macro)
    if not rows:
        sys.exit(
            f"{PREFIX}: {rel(RS_PATH)} 的 parsed_fields! 一行都没抽到"
            "（不再是 `(字段, \"json 键\", 类型, ...)` 的形态？请同步 MACRO_ROW_RE）"
        )
    names = [json_name for _, json_name in rows]
    # 宏表里的字符串字面量只有 json 键一种，故个数必须与行数相等（用宽正则数，
    # 这样带连字符之类「标识符正则读不出」的键也会被算进来、触发下面那条不等）
    literals = ANY_STRING_RE.findall(macro)
    if len(literals) != len(rows):
        errors.append(
            f"{rel(RS_PATH)} 的 parsed_fields! 有 {len(rows)} 行、却出现 {len(literals)} 个"
            "字符串字面量——宏表里多了本脚本不认的东西，抽取可能不完整"
        )
    rust_fields = [rust_field for rust_field, _ in rows]
    for name, n in Counter(rust_fields).items():
        if n > 1:
            errors.append(f"{rel(RS_PATH)} 的 parsed_fields! 里 Rust 字段名 `{name}` 出现 {n} 次")
    return names, set(names)


def rs_unparsed(errors):
    text = read(RS_PATH)
    m = re.search(
        r"const KNOWN_UNPARSED_FIELDS: &\[&str\] = &\[(.*?)\];", text, re.S
    )
    if m is None:
        sys.exit(
            f"{PREFIX}: 在 {rel(RS_PATH)} 里没找到 `const KNOWN_UNPARSED_FIELDS: &[&str] = "
            "&[ ... ];`；写法变了请同步本脚本"
        )
    names = STRING_RE.findall(m.group(1))
    check_extraction(errors, f"{rel(RS_PATH)} 的 KNOWN_UNPARSED_FIELDS", names, m.group(1))
    return names, set(names)


def check_extraction(errors, label, names, body):
    """抽取自检：块里**任何形状**的字符串字面量个数必须等于抽到的名字个数。

    不等即说明白名单里有一个本脚本的标识符正则表达不了的键（带连字符、带点、空串…），
    此时「两侧同集合」的结论不可信——宁可报错，也不要拿一份漏读的名单去比对。
    """
    literals = ANY_STRING_RE.findall(strip_comments(body))
    if len(literals) != len(names):
        unrepresented = [s for s in literals if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", s)]
        errors.append(
            f"{label} 抽到 {len(names)} 个名字、块里却有 {len(literals)} 个字符串字面量"
            f"——本脚本的抽取式跟写法脱节了；表达不了的键：{unrepresented or '（形状正常，是重复/多写）'}"
        )
    if not names:
        errors.append(f"{label} 一个名字都没抽到（空白名单会让两侧「相等」变成假绿）")


def main():
    errors = []
    cpp = cpp_known(errors)
    rs_parsed_names, rs_parsed_set = rs_parsed(errors)
    rs_unparsed_names, rs_unparsed_set = rs_unparsed(errors)
    rust = rs_parsed_set | rs_unparsed_set
    cpp_set = set(cpp)

    for name in sorted(cpp_set - rust):
        errors.append(
            f"`{name}` 在 C++ kKnown 里，但 Rust 的两份名单都没有——"
            f"Rust 会把带该字段的配置判成未知字段拒读（{rel(RS_PATH)}）"
        )
    for name in sorted(rust - cpp_set):
        errors.append(
            f"`{name}` 在 Rust 名单里，但 C++ kKnown 没有——"
            f"后端会把带该字段的配置判成未知字段拒读（{rel(CPP_PATH)}）"
        )
    for name in sorted(rs_parsed_set & rs_unparsed_set):
        errors.append(
            f"`{name}` 同时出现在 PARSED_FIELD_NAMES 与 KNOWN_UNPARSED_FIELDS"
            "（既解析又「只登记」，二者必有一处是多余的）"
        )
    for label, names in (("kKnown", cpp), ("KNOWN_UNPARSED_FIELDS", rs_unparsed_names)):
        for name, n in Counter(names).items():
            if n > 1:
                errors.append(f"{label} 里 `{name}` 重复登记 {n} 次")

    if errors:
        print(f"{PREFIX}: 配置字段白名单两侧不一致：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(
        f"{PREFIX}: 一致（{len(cpp_set)} 个字段：Rust 解析 {len(rs_parsed_set)} + "
        f"只登记 {len(rs_unparsed_set)}，与 C++ kKnown 同集合）"
    )


if __name__ == "__main__":
    main()
