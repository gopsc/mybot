#!/usr/bin/env python3
"""检查 sim/ 与宿主侧（C++ / Lua）之间四组手写双份的契约是否一致。

两套构建系统（sim/ 的独立 CMake 与 mybot 的 Lua 驱动）之间刻意不做代码生成
（见 docs/sim.md「跨构建系统不做代码生成」），于是同一份契约在两侧各手写一份。
既有的交叉校验在 sim/tests/test_contract.cpp（testActionTable / testSharedConstants），
但它只在开发者手动跑 `bash scripts/build_sim.sh` 时才会执行——sim/ 不在任何
CI job 的构建范围内（见 sim/CMakeLists.txt 顶部注释），所以那道安全网实际上
从未被强制执行过。

本脚本把这些校验用纯文本解析重做一遍（零编译依赖），并补上 sim/tests 里也没有
的两组（3 请求关键字、4 默认场景），接入 test/run_all_selftest.sh，让「漏改一侧」
在主干守门（push 前）就被挡下，而不必依赖人记得去构建 sim/。四组契约：

  1. 动作码表（testActionTable）
     * C++ 侧单一事实源：sim/src/action_table.cpp 的 kActions[]
     * Lua 侧：modules/Sim.lua 的 CODES / PARAM_CODES / PARAM2_CODES / CODE_MAX
  2. 五条 AF_UNIX 缺省 socket 路径（testSharedConstants）
     * C++ 侧：sim/src/sim_config.h 的 kDefault*SocketPath
     * Lua 侧：modules/Sim.lua 的 kDefaultSock / kSensorDefaultSock
       （Camera.lua 的拍照路径只取自 env、无硬编码缺省，故不参与比对）
  3. 一问一答桥的请求关键字
     * sim 侧：sim/src/{sensor,capture,imu,odom}.cpp 传给 RequestResponseBridge 的 keyword
     * 宿主侧：modules/Sim.lua 的 range()、src/agentimage.cpp、
       modules/Camera.lua 的 capture_live() 里发出的 "<word>\\n"
  4. 默认场景（内置回落 vs 播种模板）
     * C++ 侧：sim/src/world.cpp 的 World::defaultScene()
     * 数据侧：sim/scenes/default.scene 的 box 行
     （这组两侧同属 sim/，但一份是代码、一份是数据，同样是手写双份）

用法：python3 scripts/check_sim_contract.py
退出码：0=一致，1=发现不一致或解析失败（原因打到 stderr）。
"""

import math
import re
import sys

from lib.protocol_sources import (
    AGENT_IMAGE_CPP,
    LUA_CAMERA,
    LUA_SIM,
    SIM_ACTION_TABLE_CPP,
    SIM_CAPTURE_CPP,
    SIM_CONFIG_H,
    SIM_IMU_CPP,
    SIM_ODOM_CPP,
    SIM_SCENE,
    SIM_SENSOR_CPP,
    SIM_WORLD_CPP,
    balanced_block,
    rel,
    resolve,
)
from lib.protocol_sources import read as _read

PREFIX = "check_sim_contract"

CPP_PATH = resolve(SIM_ACTION_TABLE_CPP)
LUA_PATH = resolve(LUA_SIM)
SIM_CONFIG_PATH = resolve(SIM_CONFIG_H)
WORLD_CPP_PATH = resolve(SIM_WORLD_CPP)
SCENE_PATH = resolve(SIM_SCENE)


def read(path):
    """本脚本的读取包装：失败文案带脚本名前缀。"""
    return _read(path, PREFIX)


# ── 1) 动作码表 ────────────────────────────────────────────────────────


def parse_cpp_actions():
    text = read(CPP_PATH)

    body = balanced_block(text, "kActions[] = {")
    if body is None:
        sys.exit(f"{PREFIX}: 在 {rel(CPP_PATH)} 里没找到 kActions[] = {{ ... }}")

    # 每行形如：
    #   {0, "stop", nullptr, ActionKind::Continuous, false, false, SimCommand::Stop, SimEvent::Type::Pick},
    #   {2, "backward", "back", ActionKind::Continuous, false, false, ...},
    row_re = re.compile(
        r"\{\s*(\d+)\s*,\s*\"([^\"]+)\"\s*,\s*(?:nullptr|\"[^\"]*\")\s*,"
        r"\s*ActionKind::(Continuous|OneShot)\s*,\s*(true|false)\s*,\s*(true|false)\s*,"
    )
    actions = []
    for rm in row_re.finditer(body):
        actions.append(
            {
                "code": int(rm.group(1)),
                "wire": rm.group(2),
                "kind": rm.group(3),
                "needsParam": rm.group(4) == "true",
                "needsParam2": rm.group(5) == "true",
            }
        )
    if not actions:
        sys.exit(
            f"{PREFIX}: {rel(CPP_PATH)} 的 kActions[] 一条记录都没解析到，"
            "正则是不是跟表的格式脱节了？"
        )
    codes_seen = [a["code"] for a in actions]
    if len(codes_seen) != len(set(codes_seen)):
        sys.exit(f"{PREFIX}: {rel(CPP_PATH)} 的 kActions[] 里码重复：{codes_seen}")
    return sorted(actions, key=lambda a: a["code"])


def parse_lua_table():
    text = read(LUA_PATH)

    codes_block = balanced_block(text, "local CODES =")
    if codes_block is None:
        sys.exit(f"{PREFIX}: 在 {rel(LUA_PATH)} 里没找到 local CODES = {{ ... }}")
    codes = {}
    for m in re.finditer(r"\[(\d+)\]\s*=\s*\"([^\"]+)\"", codes_block):
        codes[int(m.group(1))] = m.group(2)

    params_block = balanced_block(text, "local PARAM_CODES =") or ""
    params = {int(m.group(1)) for m in re.finditer(r"\[(\d+)\]\s*=\s*true", params_block)}

    params2_block = balanced_block(text, "local PARAM2_CODES =") or ""
    params2 = {int(m.group(1)) for m in re.finditer(r"\[(\d+)\]\s*=\s*true", params2_block)}

    cm = re.search(r"CODE_MAX\s*=\s*(\d+)", text)
    code_max = int(cm.group(1)) if cm else None

    return codes, params, params2, code_max


def check_action_table(errors):
    actions = parse_cpp_actions()
    codes, params, params2, code_max = parse_lua_table()

    cpp_max = max(a["code"] for a in actions)
    if code_max != cpp_max:
        errors.append(f"CODE_MAX 不一致：Lua CODE_MAX={code_max}，C++ 表最大码={cpp_max}")
    if len(codes) != len(actions):
        errors.append(
            f"CODES 条目数不一致：Lua CODES 有 {len(codes)} 条，C++ 表有 {len(actions)} 条"
        )

    for a in actions:
        code, wire = a["code"], a["wire"]
        lua_name = codes.get(code)
        if lua_name is None:
            errors.append(f"code={code}：Lua CODES 缺这一项（C++ wireName='{wire}'）")
        elif lua_name != wire:
            errors.append(f"code={code}：wireName 不一致（C++='{wire}'，Lua='{lua_name}'）")

        lua_needs_param = code in params
        if lua_needs_param != a["needsParam"]:
            errors.append(
                f"code={code}（{wire}）：needsParam 不一致"
                f"（C++={a['needsParam']}，Lua PARAM_CODES={lua_needs_param}）"
            )

        lua_needs_param2 = code in params2
        if lua_needs_param2 != a["needsParam2"]:
            errors.append(
                f"code={code}（{wire}）：needsParam2 不一致"
                f"（C++={a['needsParam2']}，Lua PARAM2_CODES={lua_needs_param2}）"
            )

    extra = sorted(set(codes) - {a["code"] for a in actions})
    if extra:
        errors.append(f"Lua CODES 里有 C++ 表里不存在的码：{extra}")

    return len(actions)


# ── 2) 五条缺省 socket 路径 ────────────────────────────────────────────

# C++ 侧常量名 → (Lua 侧变量名或 None)。拍照路径在 Lua 侧无硬编码缺省
# （Camera.lua 只从 MYBOT_SIM_CAPTURE_SOCK 取），故只参与「互不相同 / 均为
# /tmp 绝对路径」两条自检，不做跨语言比对。
SOCKET_PATHS = [
    ("kDefaultSocketPath", "kDefaultSock"),
    ("kDefaultSensorSocketPath", "kSensorDefaultSock"),
    ("kDefaultCaptureSocketPath", None),
    # IMU/里程计桥（2026-10-16）：同一比对口径
    ("kDefaultImuSocketPath", "kImuDefaultSock"),
    ("kDefaultOdomSocketPath", "kOdomDefaultSock"),
]


def check_socket_paths(errors):
    cpp_text = read(SIM_CONFIG_PATH)
    lua_text = read(LUA_PATH)

    paths = {}
    for cpp_name, lua_name in SOCKET_PATHS:
        m = re.search(
            r"inline constexpr const char\*\s+%s\s*=\s*\"([^\"]+)\";" % cpp_name, cpp_text
        )
        if not m:
            sys.exit(f"{PREFIX}: {rel(SIM_CONFIG_PATH)} 里找不到 {cpp_name} 的定义")
        cpp_val = m.group(1)
        paths[cpp_name] = cpp_val

        if lua_name is None:
            continue
        lm = re.search(r"local\s+%s\s*=\s*\"([^\"]+)\"" % lua_name, lua_text)
        if not lm:
            sys.exit(f"{PREFIX}: {rel(LUA_PATH)} 里找不到 local {lua_name} 的定义")
        if lm.group(1) != cpp_val:
            errors.append(
                f"缺省 socket 路径不一致（{cpp_name} vs {lua_name}）："
                f"C++='{cpp_val}'，Lua='{lm.group(1)}'"
            )

    vals = list(paths.values())
    if len(set(vals)) != len(vals):
        errors.append(f"缺省 socket 路径有重复（复制粘贴串台）：{paths}")
    for name, v in paths.items():
        if not v.startswith("/tmp/"):
            errors.append(f"{name} 不是 /tmp 下的绝对路径：'{v}'")

    return len(vals)


# ── 3) 一问一答桥的请求关键字 ──────────────────────────────────────────

# 每座桥：sim 侧的 Bridge 构造函数把 keyword 传给 RequestResponseBridge
# （第三个实参）；宿主侧的发送点各写一份 "<word>\n" 字面量。发送点用
# (文件, 定位锚) 描述——锚是所在函数头，避免同文件里多个 req 字面量串台；
# 锚为 None 表示全文件只允许出现一处。
REQUEST_BRIDGES = [
    {
        "bridge": SIM_SENSOR_CPP,
        "senders": [
            (LUA_SIM, "function range("),
            (AGENT_IMAGE_CPP, None),
        ],
    },
    {
        "bridge": SIM_CAPTURE_CPP,
        "senders": [(LUA_CAMERA, "local function capture_live(")],
    },
    # IMU/里程计桥（2026-10-16）：发送点在 Sim.lua 的 imu()/odom() 里
    # （`local req = "imu\n"` 形态，锚定各自函数头）
    {
        "bridge": SIM_IMU_CPP,
        "senders": [(LUA_SIM, "function imu(")],
    },
    {
        "bridge": SIM_ODOM_CPP,
        "senders": [(LUA_SIM, "function odom(")],
    },
]

# 发送点形态：Lua 的 `local req = "range\n"` 与 C++ 的 `const char* req = "range\n";`
# 共用这个模式（源码里是真反斜杠 + n 两个字符）。
SEND_RE = re.compile(r"req\s*=\s*\"([A-Za-z]+)\\n\"")
KEYWORD_RE = re.compile(r"RequestResponseBridge\(\s*socketPath\s*,\s*\"[^\"]*\"\s*,\s*\"([^\"]+)\"")


def check_request_words(errors):
    checked = 0
    for spec in REQUEST_BRIDGES:
        bridge_text = read(spec["bridge"])
        km = KEYWORD_RE.search(bridge_text)
        if not km:
            sys.exit(
                f"{PREFIX}: {spec['bridge']} 里找不到 RequestResponseBridge 的 keyword 实参"
                "（构造函数形态变了？请同步本脚本的 KEYWORD_RE）"
            )
        keyword = km.group(1)

        for sender, anchor in spec["senders"]:
            text = read(sender)
            start = 0
            if anchor is not None:
                start = text.find(anchor)
                if start == -1:
                    sys.exit(f"{PREFIX}: {sender} 里找不到定位锚 '{anchor}'")
            m = SEND_RE.search(text, start)
            if not m:
                sys.exit(
                    f"{PREFIX}: {sender}（锚 '{anchor}'）之后找不到 "
                    'req = "<word>\\n" 发送点——形态变了请同步本脚本的 SEND_RE'
                )
            if m.group(1) != keyword:
                errors.append(
                    f"请求关键字不一致：{spec['bridge']} 的 keyword='{keyword}'，"
                    f"{sender} 发的是 '{m.group(1)}'"
                )
            checked += 1
    return checked


# ── 4) 默认场景（内置回落 vs 播种模板文件）──────────────────────────────

# World::defaultScene() 是**无场景文件时**的内置回落；sim/scenes/default.scene
# 是有文件时用户实际拿到的世界（首次运行从模板拷一份到家目录地图目录）。两者必须
# 逐字段同值，否则「跑没跑场景文件」会静默变成一次行为分叉。质量尤其要紧：
# Robot::kLoadSlowdownPerKg 直接吃 mass，最轻的红箱若按 体积×kDefaultDensity(800)
# 算是 409.6kg 而非模板的 61.44kg，搬起来慢 6.7 倍。
# 只比 box 行：内置回落不含机器人出生点，而 readScene 对缺 robot 行的文件本来就补
# 一只原点默认，与模板里的 `robot 0 0 0` 同值，没有第二份可漂移的手写数据。
SCENE_BOX_FIELDS = ("cx", "cy", "cz", "hx", "hy", "hz", "r", "g", "b", "mass")

# C++ 侧一行：{{cx, cy, cz}, {hx, hy, hz}, {r, g, b}, mass}，浮点都带 f 后缀。
# 质量写成必选（不是 `(?:...)?`）：某行漏掉 mass 就整行不匹配，由下面的条数自检
# 响亮报出，而不是拿 Obstacle 的默认 mass=1.0 悄悄比过去。
_VEC3 = r"\{\s*(-?[0-9.]+)f\s*,\s*(-?[0-9.]+)f\s*,\s*(-?[0-9.]+)f\s*\}"
CPP_BOX_RE = re.compile(
    r"\{\s*" + _VEC3 + r"\s*,\s*" + _VEC3 + r"\s*,\s*" + _VEC3 + r"\s*,\s*(-?[0-9.]+)f\s*\}"
)

# 数据侧一行：`box` + 10 个数 + 可选尾注释。
_NUM = r"(-?[0-9]+(?:\.[0-9]+)?)"
SCENE_BOX_RE = re.compile(r"^box\s+" + r"\s+".join([_NUM] * 10) + r"\s*(?:#.*)?$", re.M)


def check_default_scene(errors):
    cpp_text = read(WORLD_CPP_PATH)
    fn_body = balanced_block(cpp_text, "World::defaultScene()")
    if fn_body is None:
        sys.exit(f"{PREFIX}: 在 {rel(WORLD_CPP_PATH)} 里没找到 World::defaultScene()")
    decl = balanced_block(fn_body, "std::vector<Obstacle> obs = {")
    if decl is None:
        sys.exit(
            f"{PREFIX}: World::defaultScene() 里没找到 std::vector<Obstacle> obs = {{ ... }}；"
            "写法变了请同步本脚本的 CPP_BOX_RE"
        )
    cpp_rows = [[float(g) for g in m.groups()] for m in CPP_BOX_RE.finditer(decl)]
    if not cpp_rows:
        sys.exit(
            f"{PREFIX}: World::defaultScene() 一个箱都没解析到，正则是不是跟表的格式脱节了？"
        )

    scene_text = read(SCENE_PATH)
    scene_rows = [[float(g) for g in m.groups()] for m in SCENE_BOX_RE.finditer(scene_text)]
    n_box_lines = len(re.findall(r"^box\b", scene_text, re.M))
    if n_box_lines != len(scene_rows):
        sys.exit(
            f"{PREFIX}: {rel(SCENE_PATH)} 有 {n_box_lines} 行 box，只解析出 {len(scene_rows)} 行"
            "（box 行不再是 10 个数？请同步本脚本的 SCENE_BOX_RE）"
        )

    if len(cpp_rows) != len(scene_rows):
        errors.append(
            f"默认场景箱数不一致：World::defaultScene() 有 {len(cpp_rows)} 个，"
            f"{rel(SCENE_PATH)} 有 {len(scene_rows)} 个"
        )
        return len(scene_rows)  # 条数都对不上时逐箱配对没有意义，别刷屏假差异
    for i, (cpp_row, scene_row) in enumerate(zip(cpp_rows, scene_rows)):
        for name, cv, sv in zip(SCENE_BOX_FIELDS, cpp_row, scene_row):
            if not math.isclose(cv, sv, rel_tol=1e-6, abs_tol=1e-6):
                errors.append(
                    f"默认场景第 {i} 个箱的 {name} 不一致："
                    f"World::defaultScene()={cv}，{rel(SCENE_PATH)}={sv}"
                )
    return len(scene_rows)


def main():
    errors = []
    n_actions = check_action_table(errors)
    n_paths = check_socket_paths(errors)
    n_senders = check_request_words(errors)
    n_boxes = check_default_scene(errors)

    if errors:
        print(f"{PREFIX}: 跨构建系统契约不一致：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(
        f"{PREFIX}: 一致（{n_actions} 个动作码 / {n_paths} 条缺省 socket 路径"
        f" / {n_senders} 个请求关键字发送点 / {n_boxes} 个默认场景箱）"
    )


if __name__ == "__main__":
    main()
