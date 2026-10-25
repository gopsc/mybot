#!/usr/bin/env python3
"""零编译守门脚本的共用底座：源码文本抽取原语 + 协议出处路径清单。

本模块只放**机械部分**——把一份手写契约从源码里抠出来所需要的通用原语
（去注释、取平衡括号块、按仓内相对路径读数），以及「协议出处」的路径常量表。
各守门脚本自己的**判据与比对逻辑一律留在各自文件里**：什么算不一致、两侧该
同集合还是该有差集、报错文案怎么写，都是每个守门脚本自己的判断，不下沉到这里。
这样底座改动只可能影响「怎么读源码」，不可能悄悄改变「怎么判」。

## 与「独立实现」原则的关系（重要）

docs/testing.md 明写主干这几道零编译校验与 sim/tests/ 里的 C++ 同款校验
**不得共享代码**——理由是「共享实现等于共享同一个错误，两侧一起改错就一起绿」。
本模块不违反该原则：

  * 它只共享**Python 侧**的文本管道（去注释、括号配平）；C++ 侧
    （sim/tests/test_contract.cpp 的 braceBlock 等）仍是另一套独立实现，
    两边照旧交叉印证「脚本本身没写错」；
  * 判据与比对逻辑不在本模块内，各脚本仍各写各的。

因此本模块的存在**不构成**那条原则要防的「两侧一起改错」。

## read 为什么要带 prefix

各脚本的「找不到文件」文案都以脚本名开头（`check_xxx: 找不到 <path>`），
故读数原语接收 prefix 由调用方传入，而不是在本模块里写死一个名字。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# ── 协议出处清单 ────────────────────────────────────────────────────────
# 只登记「当前有守门脚本消费」的路径：登记一条是为了让某个守门脚本少写一处
# 硬编码字符串；没有消费方的路径不预先登记（空登记会变成又一份要维护的事实源）。
# 值一律是**仓内相对路径**，用 resolve() 解析成绝对 Path。

# run_all_selftest.sh 第 8 段：仿真器跨构建系统契约（check_sim_contract.py）
SIM_ACTION_TABLE_CPP = "sim/src/action_table.cpp"
LUA_SIM = "modules/Sim.lua"
SIM_CONFIG_H = "sim/src/sim_config.h"
SIM_SENSOR_CPP = "sim/src/sensor.cpp"
SIM_IMU_CPP = "sim/src/imu.cpp"
SIM_ODOM_CPP = "sim/src/odom.cpp"
SIM_CAPTURE_CPP = "sim/src/capture.cpp"
LUA_CAMERA = "modules/Camera.lua"
AGENT_IMAGE_CPP = "src/agentimage.cpp"
SIM_WORLD_CPP = "sim/src/world.cpp"
SIM_SCENE = "sim/scenes/default.scene"

# 第 11 段：模型配置字段白名单的双端同集合（check_llm_field_whitelist.py）
LLM_CONFIG_CPP = "src/llmconfig.cpp"
RUST_CONFIG_FILE_RS = "agent/src/config/file.rs"

# 第 12 段：有状态 LLM 协议判据的双端同集合（check_stateful_protocol.py）
RUST_SESSION_RS = "agent/src/session.rs"
FAKE_LLM_SERVER_PY = "scripts/fake_llm_server.py"

# 第 13 段：LLM wire 可钉部分（check_llm_wire.py）——协议族表名与请求路径
# 在 Rust provider / Python 夹具 / E2E 脚本三处的同集合（报文其余字段归 rig，见该脚本头）
RUST_PROVIDER_RS = "agent/src/provider.rs"
E2E_AGENT_SH = "scripts/agent_e2e.sh"
E2E_ICA_SH = "scripts/ica_e2e.sh"

# 第 14 段：后端工具注册表 ↔ 文档工具表同集合（check_agent_tool_table.py）
# 文档侧是**两张**表：docs/agent.md「给智能体的工具」（权威总表，第三列写门控）与
# README.md「Agent 工具系统」（门面摘要）。两张都要比对——只钉前者时 README 少了
# 三个工具（list_dir/read_file/write_file）也不会变红，而 README 是新人第一入口。
AGENTTOOLS_CPP = "src/agenttools.cpp"
AGENTTOOLS_WAIT_CPP = "src/agenttools_wait.cpp"
AGENTTOOLS_FS_CPP = "src/agenttools_fs.cpp"
DOCS_AGENT_MD = "docs/agent.md"
README_MD = "README.md"
# Rust 侧本地工具（不经后端注册表）：http_fetch 的名字常量 `pub const TOOL_NAME`
RUST_HTTPFETCH_RS = "agent/src/httpfetch.rs"


def resolve(ref):
    """把协议出处（仓内相对路径字符串或 Path）解析成仓库根下的绝对 Path。

    绝对路径原样返回，相对路径拼到 ROOT 下——这样调用点既能传常量，也能直接传
    源码里现写的相对字符串（如请求桥表里的 "sim/src/sensor.cpp"），无需先转换。
    """
    p = ref if isinstance(ref, Path) else Path(ref)
    return p if p.is_absolute() else ROOT / p


def read(path, prefix):
    """读一个源文件，找不到即以 '<prefix>: 找不到 <绝对路径>' 退出。

    prefix 由各调用脚本传入自己的名字，好让失败文案仍以脚本名开头。
    """
    p = resolve(path)
    if not p.is_file():
        sys.exit(f"{prefix}: 找不到 {p}")
    return p.read_text(encoding="utf-8")


def rel(path):
    """转成仓库根相对路径；已是相对路径则原样返回（容错版）。

    各脚本把 rel() 用于报错文案里的文件名，调用点既有绝对 Path 也有相对字符串，
    故这里两条都认，省得每个调用点自己判。
    """
    p = path if isinstance(path, Path) else Path(path)
    return p.relative_to(ROOT) if p.is_absolute() else p


def strip_comments(text):
    """去掉 C 系源码里的块注释 /* ... */ 与行注释 // ...（各替换为一个空格）。

    `//[^\\n]*` 已连 /// 文档注释一并吃掉，无需再单独一遍 ///（见 strip 的两遍）。
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def balanced_block(text, marker, open_ch="{", close_ch="}"):
    """取 marker 之后第一个平衡的 open_ch...close_ch 内部内容；找不到返回 None。

    与 sim/tests/test_contract.cpp 的 braceBlock() 是同一个算法，但**两侧各自独立
    实现**（见模块头「与独立实现原则的关系」），用于交叉印证「脚本本身没写错」。
    """
    m = text.find(marker)
    if m == -1:
        return None
    start = text.find(open_ch, m)
    if start == -1:
        return None
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
    return None