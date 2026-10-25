#!/usr/bin/env python3
"""检查文档里的仓内路径引用与计数是否还与仓库实况一致。

文档是唯一一处「写下一个路径/数字，然后没人再回头看」的地方：文件改名、拆分、
删除之后，引用它的文档不会报错，只会静静地指向不存在的东西。同一条计数（模块数、
共享库数）还常在手写多份（README、docs/README.md、docs/drivers.md 的口径行），
于是三处各漂一点、彼此不一致，读者无从判断哪个是真的。

本脚本零编译、零第三方依赖，做七组检查（接入 test/run_all_selftest.sh）：

  1. 路径存在性：README.md 与 docs/*.md 里的仓内路径引用逐个实测存在。
     * markdown 链接 `[文字](目标)` 的目标按**文档所在目录**解析（docs/x.md 里
       `](sim.md)` 指 docs/sim.md）；
     * 反引号代码跨度按**仓库根**解析（正文里写 `sim/src/main.cpp` 从来都是根相对）；
     * 只认「以已知顶层目录开头 / 带已知扩展名 / 不含通配与占位符」的跨度，
       否则 `set_word/get_sword` 这类函数名清单会被当成路径，全是假差异。
     * 历史与占位引用在 KNOWN_ABSENT 里逐条登记并写明理由（见该表）。
     * 环境态路径（build/ 生成物、用户本地的 mybot.llm.json）跳过不断言：
       它们的存在与否看机器，登记豁免也不行——文件存在时豁免表反而判过期
       （见 ENV_STATE_* 的注释）。
  2. 驱动清单双向对齐：docs/drivers.md 各节表格里点名的模块集合，与
     `ls modules/*.lua` **双向**相等——漏登记一个新驱动、或留着一个已删驱动都判失败。
  3. 计数口径自洽：drivers.md 开头「计数口径」那行的分项（器件 / 总线 / 框架工具、
     共享库数）与本页各节的实际条目数、与磁盘上的实际文件数三者一致。
  4. 文档索引覆盖：每个 docs/*.md 都被 README.md 或 docs/README.md 链到——
     新增一篇文档而忘了挂索引，等于它对读者不存在。
  5. 已删文件的引用：DELETED_FILES 里登记的名字（按基名匹配，故 `docs/x.md` 与
     链接形态 `x.md` 都算）在全仓任何文本文件里再出现即判失败。取材面比检查 1 宽
     （源码注释 / 脚本 / CI / 冻结 html 都算），因为死引用的成因恰恰是「引用它的
     地方不在任何守门的取材面里」；名单里的文件若又存在了同样判失败（名单过期）。
  6. 套件计数口径：docs/testing.md「四处套件的计数口径」那张表（mybot_tests /
     harness_selftest / sim_tests / Rust agent）与表下两条式子里的每个数字，都从仓库
     实况派生后比对——加/删用例而忘了改表，这里判红，不再依赖人回头更新快照。
     唯一派生不出来的是 sim_tests 的通过数（sim 侧记账单位是**断言**不是用例，
     check() 调用点 328 处而实跑 406 条，差额来自循环与条件分支），故只钉它的
     「N 个 TU」（sim/CMakeLists.txt 的 add_executable 源清单），并要求表里明写
     「运行时数」以免被误当成受检数字。
  7. README 计数：README「项目结构」与「测试规模」两节里的每个计数都按第 6 组同款
     判据从仓库实况派生后比对。此前这些数字自称「快照，改完用这几条命令复核，
     别手改数字」——纯人工、无门，于是六处一起漂（2026-10-08 审计 P2）。
     派生不出来的两个运行时数（run_all.sh 汇总行的守门用例数、sim_tests 的断言数）
     **不许写死**，命中即判红并提示改成指针，理由见 README_UNPINNED 的注释。

用法：python3 scripts/check_doc_paths.py
退出码：0=一致，1=发现不一致或解析失败（原因打到 stderr）。
"""

import os
import re
import sys
from pathlib import Path

from lib.protocol_sources import ROOT, rel
from lib.protocol_sources import read as _read

PREFIX = "check_doc_paths"

DOCS_DIR = ROOT / "docs"
MODULES_DIR = ROOT / "modules"
README = ROOT / "README.md"
DRIVERS_MD = DOCS_DIR / "drivers.md"

# 检查 1 的取材面：仓库根的 README + docs 下全部 md
DOC_GLOB = "docs/*.md"

# 只把这些开头/结尾的跨度当路径候选（见文件头「否则全是假差异」）
TOP_PREFIXES = (
    "src/", "sim/", "agent/", "modules/", "test/", "scripts/",
    "robots/", "docs/", "prompts/", "build/", "./",
)
KNOWN_EXTENSIONS = (
    ".md", ".lua", ".sql", ".mt", ".cpp", ".hpp", ".h", ".c", ".rs", ".py",
    ".sh", ".json", ".svg", ".html", ".txt", ".cmake", ".yml", ".yaml",
    ".scene", ".example", ".toml", ".supp",
)
# 通配符、占位符、shell 展开、空白：出现即不是「一个具体路径」
PLACEHOLDER_RE = re.compile(r"[*<>{}$\s]|\.\.\.")

# 环境态路径：存在与否取决于本机构建/用户配置，不是仓库事实——对它们做存在性
# 断言只会产出「看机器脸色」的门（新检出没有；构建过、或按 README 快速开始
# cp 过模板就有）。登记进 KNOWN_ABSENT 也救不了：文件存在时该表「过期即删」
# 判据反而判红——CI 的 gate:release 恰带着 build:release 的 build/ 产物跑本
# 脚本（needs + artifacts: [build]）。build/、build-*/ 与 DELETED_SCAN_PRUNE
# 的剪枝约定同源（生成目录）；mybot.llm.json 被 .gitignore 挡住、由用户从
# mybot.llm.json.example 复制（裸名与 ./ 前缀两种写法都认，example 不受影响）。
ENV_STATE_EXACT = frozenset(("mybot.llm.json", "./mybot.llm.json"))
ENV_STATE_PREFIXES = ("build/", "build-")


def env_state(ref):
    """ref 是否环境态路径（生成物/用户本地配置）：是则不做存在性断言。"""
    return ref in ENV_STATE_EXACT or ref.startswith(ENV_STATE_PREFIXES)

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
CODE_RE = re.compile(r"`([^`\n]+)`")
URL_PREFIXES = ("http://", "https://", "mailto:", "#")

# 已知不存在、且**故意**不存在的引用。键是引用串，值是理由。
# 分两类：
#   * 历史记录：正文明写「历史上」提到后来被删/改名的文件——把它们改成现名等于
#     篡改历史；
#   * 占位/示例：教程与查找顺序里写的假名（`modules/X.lua`），本来就不该存在。
# 登记在这里的条目若**又存在了**（比如文件被加回来），本脚本也判失败：那时它不再是
# 豁免，而说明这份名单过期了。
# 2026-10-04：docs/changelog.md（冻结变更账本）整篇删除后，本表原「历史记录」类
# 下七条——仅由该账本提及、仓内再无第二处引用的条目——随之失去唯一引用来源，按本
# 脚本自身的「过期即删」判据一并清掉。2026-10-12 合并 main 时 changelog 以精简版
# （changelog.md + changelog-detail.md，main 侧 cf860ff 起持续维护）复活，账本正文
# 重新提到其中三条历史名，按「历史记录」语义登记回来。
KNOWN_ABSENT = {
    # —— 历史记录（正文明写「历史上」）——
    "src/luaend.cpp": "历史：development.md 明写「历史上」，N-17 拆成 luasandbox.cpp 等",
    # —— 历史记录（仅 changelog-detail.md 的历史条目提到）——
    "modules/LlmOpenAI.lua": "历史：changelog-detail.md 记录的已删 Lua 协议驱动（2026-09-25 #8）",
    "test/cpp/test_sessionfile.cpp": "历史：changelog-detail.md 记录的已删参考实现（Rust 侧承接）",
    "test/test_llm_wire_contract.lua": "历史：changelog-detail.md 记录的已删用例（随 Lua 协议轨道退场）",
    # —— 占位 / 示例 ——
    "./mybot.llm.conf.json": "占位：agent.md 列的是配置文件**查找顺序**候选名，不是仓内文件",
    "modules/X.lua": "占位：development.md「新增驱动」教程里的假名",
    "robots/xxx.sql": "占位：同上，结构脚本示例名",
    "scripts/xxx.mt": "占位：同上，动作脚本示例名",
    "test/test_xxx.lua": "占位：同上，回归用例示例名",
}

# 已删除且**刻意不重建**的文件：任何取材面里再出现指向它的引用即判失败（检查 5）。
# 与 KNOWN_ABSENT 方向相反——那张表登记「文档提到的历史名，允许不存在」，这张表登记
# 「这个名字不许再被当成现存出处引用」。为什么需要它，是一次真实的漏网：9480de3 删掉
# docs/changelog.md 后，d7ca619 只清掉了 docs/*.md 里**路径形态**的死引用。
# 2026-10-12 合并 main：main 侧以「精简版 changelog（52 行）+ changelog-detail.md 归档」
# 的决策（cf860ff）取代本分支 9480de3 的整篇删除，docs/changelog.md 随合并复活、
# 条目从名单移除；「出处写提交号」的口径保留给 changelog 之外的正文。
# 匹配用**基名**：`docs/x.md` 与 markdown 链接里的相对形态 `x.md` 一并覆盖。
DELETED_FILES = {
}
# 自排除：本脚本的表与头注必须能写出这个名字（与 KNOWN_ABSENT 的注释同理）。
DELETED_SCAN_SKIP = ("scripts/check_doc_paths.py",)
DELETED_SCAN_SUFFIXES = frozenset((
    ".md", ".html", ".sh", ".py", ".cpp", ".hpp", ".h", ".c", ".rs", ".lua",
    ".yml", ".yaml", ".txt", ".cmake", ".awk", ".mt", ".sql", ".scene",
))
DELETED_SCAN_PRUNE = frozenset((
    ".git", ".zcode", ".trae", ".tmp", "build", "target", "node_modules",
))


# drivers.md 里不参与「模块清单」的两节：前者讲入口函数契约、后者讲刻意保留的重复，
# 表格首列不是模块名。
NON_ROSTER_SECTIONS = ("驱动契约", "收敛豁免清单（刻意保留的重复实现）")

# 「计数口径」那行的抽取式。它是一整行长文本，各分项都用 **粗体** 标出，故按粗体锚定。
COUNT_LINE_RE = re.compile(
    r"`ls modules/\*\.lua` = (?P<total>\d+) = "
    r"\*\*(?P<device>\d+) 款器件/执行器/系统接口驱动\*\*.*?"
    r"\+ \*\*(?P<bus>\d+) 条总线\*\*.*?"
    r"\+ \*\*(?P<tool>\d+) 个框架/工具驱动\*\*.*?"
    r"另有 (?P<lib>\d+) 个共享库",
    re.S,
)
SECTION_RE = re.compile(r"^## (.+)$", re.M)
ROW_FIRST_CELL_RE = re.compile(r"^\|\s*(.+?)\s*\|", re.M)
NAME_RE = re.compile(r"`([A-Za-z_][A-Za-z0-9_]*)`")


def read(path):
    """本脚本的读取包装：失败文案带脚本名前缀。"""
    return _read(path, PREFIX)


def doc_files():
    files = [README] + sorted(DOCS_DIR.glob("*.md"))
    if len(files) < 2:
        sys.exit(f"{PREFIX}: {DOC_GLOB} 一个都没找到，取材面是不是变了？")
    return files


# ── 1) 路径存在性 ──────────────────────────────────────────────────────


def path_candidates(doc):
    """返回 [(kind, ref)]：kind ∈ {link, code}，决定按哪个基准目录解析。"""
    text = read(doc)
    out = set()
    for m in LINK_RE.finditer(text):
        target = m.group(1)
        if not target.startswith(URL_PREFIXES) and not env_state(target):
            out.add(("link", target))
    for m in CODE_RE.finditer(text):
        ref = m.group(1)
        if not ref.startswith(TOP_PREFIXES):
            continue
        if env_state(ref):
            continue
        if PLACEHOLDER_RE.search(ref):
            continue
        if not ref.endswith(KNOWN_EXTENSIONS):
            continue
        out.add(("code", ref))
    return sorted(out)


def resolve(doc, kind, ref):
    ref = ref.split("#", 1)[0]
    if not ref:
        return None
    if ref.startswith("/"):
        return ROOT / ref.lstrip("/")
    base = doc.parent if kind == "link" else ROOT
    return base / ref


def check_paths(errors):
    n = 0
    seen_absent = set()
    for doc in doc_files():
        for kind, ref in path_candidates(doc):
            target = resolve(doc, kind, ref)
            if target is None:
                continue
            n += 1
            if target.exists():
                continue
            # 只按仓库根相对形态登记豁免（链接形态在 docs/ 下，同一文件两种写法都认）
            try:
                key = str(target.relative_to(ROOT))
            except ValueError:
                key = ref
            if key in KNOWN_ABSENT or ref in KNOWN_ABSENT:
                seen_absent.add(key if key in KNOWN_ABSENT else ref)
                continue
            errors.append(
                f"{rel(doc)} 引用的路径不存在：{ref}"
                f"（{'链接' if kind == 'link' else '代码跨度'}，解析为 {key}）"
            )
    stale = sorted(set(KNOWN_ABSENT) - seen_absent)
    for name in stale:
        errors.append(
            f"豁免名单里的 '{name}' 这次没被任何文档引用（或已存在）——"
            f"该条目过期了，请从 {rel(Path(__file__))} 的 KNOWN_ABSENT 删掉"
        )
    return n


# ── 2) drivers.md 的模块清单 ↔ modules/*.lua ──────────────────────────


def drivers_roster():
    """按节抽取 drivers.md 表格首列点名的模块名：{节标题: {名字, ...}}。"""
    text = read(DRIVERS_MD)
    roster = {}
    section = None
    for line in text.splitlines():
        m = SECTION_RE.match(line)
        if m:
            section = m.group(1).strip()
            if section not in NON_ROSTER_SECTIONS:
                roster.setdefault(section, set())
            continue
        if section is None or section in NON_ROSTER_SECTIONS:
            continue
        row = ROW_FIRST_CELL_RE.match(line)
        if not row:
            continue
        cell = row.group(1)
        if cell.startswith("---") or cell in ("驱动", "模块"):
            continue
        for name in NAME_RE.findall(cell):
            roster[section].add(name)
    if not roster:
        sys.exit(f"{PREFIX}: {rel(DRIVERS_MD)} 一个模块名都没抽到，表格格式变了？")
    return roster


def modules_on_disk():
    names = {p.stem for p in MODULES_DIR.glob("*.lua")}
    if not names:
        sys.exit(f"{PREFIX}: {rel(MODULES_DIR)}/*.lua 一个都没有，取材面是不是变了？")
    return names


def check_roster(errors, roster, on_disk):
    documented = set().union(*roster.values()) if roster else set()
    for name in sorted(documented - on_disk):
        errors.append(
            f"{rel(DRIVERS_MD)} 点名了 modules/{name}.lua，但磁盘上没有这个文件"
            "（改名或删除后漏改文档）"
        )
    for name in sorted(on_disk - documented):
        errors.append(
            f"modules/{name}.lua 存在，但 {rel(DRIVERS_MD)} 没有登记它"
            "（新增驱动漏进清单：读者按文档找不到它）"
        )
    return len(on_disk)


# ── 3) 计数口径自洽 ───────────────────────────────────────────────────


def check_counts(errors, roster, on_disk):
    text = read(DRIVERS_MD)
    m = COUNT_LINE_RE.search(text)
    if m is None:
        sys.exit(
            f"{PREFIX}: {rel(DRIVERS_MD)} 开头找不到「计数口径」那行，或它的措辞变了"
            "（本脚本按 **粗体分项** 锚定；改措辞请同步 COUNT_LINE_RE）"
        )
    stated = {k: int(v) for k, v in m.groupdict().items()}

    if stated["total"] != len(on_disk):
        errors.append(
            f"drivers.md 计数口径写 `ls modules/*.lua` = {stated['total']}，"
            f"实际 {len(on_disk)} 个"
        )

    sections = list(roster)
    device_sections = [s for s in sections if s != "框架 / 总线 / 工具"]
    tool_section = "框架 / 总线 / 工具"
    if tool_section not in roster:
        sys.exit(f"{PREFIX}: {rel(DRIVERS_MD)} 找不到「{tool_section}」一节，节名变了？")

    device_total = sum(len(roster[s]) for s in device_sections)
    if device_total != stated["device"]:
        errors.append(
            f"drivers.md 计数口径写 {stated['device']} 款器件/执行器/系统接口驱动，"
            f"前 {len(device_sections)} 节实际点名 {device_total} 个"
        )
    framework_total = len(roster[tool_section])
    if framework_total != stated["bus"] + stated["tool"]:
        errors.append(
            f"drivers.md 计数口径写 {stated['bus']} 条总线 + {stated['tool']} 个框架/工具驱动"
            f"（合计 {stated['bus'] + stated['tool']}），「{tool_section}」一节实际点名 "
            f"{framework_total} 个"
        )
    if stated["device"] + stated["bus"] + stated["tool"] != stated["total"]:
        errors.append(
            f"drivers.md 计数口径的分项加起来 {stated['device']}+{stated['bus']}"
            f"+{stated['tool']} = {stated['device'] + stated['bus'] + stated['tool']}，"
            f"与它自己写的总数 {stated['total']} 不符"
        )

    lib_on_disk = len(list((MODULES_DIR / "lib").rglob("*.lua")))
    if stated["lib"] != lib_on_disk:
        errors.append(
            f"drivers.md 计数口径写 modules/lib/ 有 {stated['lib']} 个共享库，"
            f"实际 {lib_on_disk} 个（find modules/lib -name '*.lua'）"
        )
    return stated


# ── 4) 文档索引覆盖 ───────────────────────────────────────────────────


def check_index(errors):
    indexed = set()
    for doc in (README, DOCS_DIR / "README.md"):
        for m in LINK_RE.finditer(read(doc)):
            target = resolve(doc, "link", m.group(1))
            if target is None or target.suffix != ".md":
                continue  # 网页与两张 SVG 的存在性由检查 1 管，索引只对齐 md 全集
            if target.parent == DOCS_DIR:
                indexed.add(target.name)
    on_disk = {p.name for p in DOCS_DIR.glob("*.md")}
    if not on_disk:
        sys.exit(f"{PREFIX}: {rel(DOCS_DIR)} 下没有 md 文件，取材面是不是变了？")
    for name in sorted(on_disk - indexed):
        errors.append(
            f"docs/{name} 没有被 README.md 或 docs/README.md 链到（读者从索引进不去）"
        )
    for name in sorted(indexed - on_disk):
        errors.append(f"索引链到 docs/{name}，但该文件不存在")
    return len(on_disk)


# ── 5) 已删文件的引用（全仓取材面）────────────────────────────────────


def check_deleted(errors):
    """扫全仓，找出仍把 DELETED_FILES 里的名字当现存出处引用的地方。

    取材面比检查 1 宽得多（源码注释、脚本、CI、冻结 html 都算）：死引用的成因正是
    「引用它的地方不在任何守门的取材面里」。反过来，名单里的文件若又存在了，说明名单
    过期——与 KNOWN_ABSENT 的「过期即失败」同一取向。
    """
    for name in DELETED_FILES:
        if (ROOT / name).exists():
            errors.append(f"DELETED_FILES 名单过期：{name} 又存在了（该条目不再是豁免）")
    pats = {n: re.compile(re.escape(Path(n).name)) for n in DELETED_FILES}
    skip = {ROOT / s for s in DELETED_SCAN_SKIP}
    n_files = 0
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [
            d for d in dirnames
            if d not in DELETED_SCAN_PRUNE and not d.startswith("build-")
        ]
        for fn in sorted(filenames):
            p = Path(dirpath) / fn
            if p in skip:
                continue
            if p.suffix not in DELETED_SCAN_SUFFIXES:
                continue
            try:
                lines = p.read_text(encoding="utf-8").splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            n_files += 1
            for name, pat in pats.items():
                for i, line in enumerate(lines, 1):
                    if pat.search(line):
                        errors.append(
                            f"{rel(p)}:{i} 仍引用已删除的 {name}"
                            f"——{DELETED_FILES[name]}"
                        )
    if not n_files:
        sys.exit(f"{PREFIX}: 已删文件扫描一个文件都没读到，取材面是不是变了？")
    return n_files


# ── 6) 四处套件的计数口径（docs/testing.md 的快照表 vs 仓库实况派生）──

TESTING_MD = DOCS_DIR / "testing.md"
TEST_CPP_DIR = ROOT / "test" / "cpp"
SIM_CMAKE = ROOT / "sim" / "CMakeLists.txt"
AGENT_SRC = ROOT / "agent" / "src"

TH_TEST_RE = re.compile(r"\bTH_TEST\(")
TH_META_RE = re.compile(r"\bTH_TEST\(meta_")
RUST_TEST_RE = re.compile(r"(?m)^[ \t]*#\[(tokio::)?test\]")
SIM_TESTS_TU_RE = re.compile(r"add_executable\(sim_tests\b(.*?)\)", re.S)


def _count_in(pat, paths):
    n = 0
    for p in paths:
        n += len(pat.findall(p.read_text(encoding="utf-8")))
    return n


def _stated(text, pat, what):
    """从 testing.md 里按锚点正则抠出一个整数；抠不到就 exit（不是「跳过」）。

    与 check_counts 对 drivers.md「计数口径」那行同一取向：锚点消失说明措辞被改过，
    那时静默少比一个数比报错危险得多——这张表本来就是「没人会回头看」的那类数字。
    """
    m = re.search(pat, text)
    if m is None:
        sys.exit(
            f"{PREFIX}: {rel(TESTING_MD)}「四处套件的计数口径」里找不到{what}，"
            "措辞变了？（改措辞请同步本脚本的锚点正则）"
        )
    return int(m.group(1))


def check_suite_counts(errors):
    """把 testing.md 那张套件计数表与仓库实况派生值逐个比对。

    这张表原本只是「某天的快照」，没有任何守门看着它：加一条用例、拆一个 TU，表里的
    数字就悄悄过期，而读者拿它当基线核对守门输出（「271 通过对不对？」）。三个数能
    从源码静态派生（见下），第四个不能——sim 侧记账单位是**断言**不是用例，
    check() 调用点 328 处而实跑 406 条，差额来自循环与条件分支，跑一遍才知道；
    加上 sim/ 不在任何 CI job 的构建范围，那个数只能人工回填，故这里只钉它的
    「N 个 TU」部分，并要求表里明写「运行时数」以免被误当成受检数字。
    """
    text = read(TESTING_MD)

    cpp_sources = sorted(TEST_CPP_DIR.glob("*.cpp")) + sorted(TEST_CPP_DIR.glob("*.hpp"))
    if not cpp_sources:
        sys.exit(f"{PREFIX}: {rel(TEST_CPP_DIR)} 下一个 .cpp/.hpp 都没有，取材面变了？")
    harness_hpp = TEST_CPP_DIR / "harness.hpp"
    selftest_cpp = TEST_CPP_DIR / "harness_selftest.cpp"
    for p in (harness_hpp, selftest_cpp):
        if not p.is_file():
            sys.exit(f"{PREFIX}: 派生口径依赖的 {rel(p)} 不在了")

    th_total = _count_in(TH_TEST_RE, cpp_sources)
    th_define = _count_in(TH_TEST_RE, [harness_hpp])
    th_selftest = _count_in(TH_TEST_RE, [selftest_cpp])
    th_meta = _count_in(TH_META_RE, [selftest_cpp])
    if th_define != 1:
        errors.append(
            f"{rel(harness_hpp)} 里 `TH_TEST(` 出现 {th_define} 次，不是 1 次"
            "——testing.md 那条式子写的是「− 1 处宏定义」，多出来的会被算成用例"
        )
    mybot_derived = th_total - th_define - th_selftest
    harness_derived = th_selftest - th_meta

    rs_sources = sorted(AGENT_SRC.rglob("*.rs"))
    rust_derived = _count_in(RUST_TEST_RE, rs_sources)

    sim_cmake = read(SIM_CMAKE)
    m = SIM_TESTS_TU_RE.search(sim_cmake)
    if m is None:
        sys.exit(f"{PREFIX}: {rel(SIM_CMAKE)} 里找不到 add_executable(sim_tests …)")
    sim_tu_derived = len(
        [ln for ln in m.group(1).splitlines() if ln.strip().endswith(".cpp")]
    )

    # 表格四行
    row_mybot = _stated(
        text, r"\|\s*`mybot_tests`\s*\|[^\n|]*\|\s*(\d+)\s*通过", "`mybot_tests` 那行的通过数"
    )
    row_harness = _stated(
        text,
        r"\|\s*`harness_selftest`\s*\|[^\n|]*\|\s*(\d+)\s*通过",
        "`harness_selftest` 那行的通过数",
    )
    m_sim = re.search(
        r"\|\s*`sim_tests`\s*\|[^\n|]*\|\s*(\d+)\s*通过[^\n|]*（(\d+)\s*个\s*TU）", text
    )
    if m_sim is None:
        sys.exit(f"{PREFIX}: {rel(TESTING_MD)} 里找不到 `sim_tests` 那行（通过数 + N 个 TU）")
    row_sim_tu = int(m_sim.group(2))
    row_rust = _stated(
        text, r"\|\s*Rust agent\s*\|[^\n|]*\|\s*(\d+)\s*passed", "Rust agent 那行的 passed 数"
    )

    if row_mybot != mybot_derived:
        errors.append(
            f"testing.md 写 `mybot_tests` {row_mybot} 通过，按仓库实况派生是 {mybot_derived}"
            f"（`test/cpp/` 里 `TH_TEST(` {th_total} 次 − 宏定义 {th_define}"
            f" − harness_selftest {th_selftest}）"
        )
    if row_harness != harness_derived:
        errors.append(
            f"testing.md 写 `harness_selftest` {row_harness} 通过，按仓库实况派生是 "
            f"{harness_derived}（该文件 {th_selftest} 个 TH_TEST − {th_meta} 个 meta_ 例句）"
        )
    if row_sim_tu != sim_tu_derived:
        errors.append(
            f"testing.md 写 `sim_tests` {row_sim_tu} 个 TU，"
            f"{rel(SIM_CMAKE)} 的 add_executable(sim_tests …) 实际列了 {sim_tu_derived} 个"
        )
    if row_rust != rust_derived:
        errors.append(
            f"testing.md 写 Rust agent {row_rust} passed，按仓库实况派生是 {rust_derived}"
            f"（{rel(AGENT_SRC)} 下 #[test] + #[tokio::test]）"
        )

    # 表下两条式子里的数：与表格、与派生值三方自洽
    bullet_total = _stated(
        text, r"`TH_TEST\(`\s*的出现次数（(\d+)）", "第一条式子里 `TH_TEST(` 的出现次数"
    )
    if bullet_total != th_total:
        errors.append(
            f"testing.md 的式子写 `TH_TEST(` 出现 {bullet_total} 次，实际 {th_total} 次"
        )
    bullet_selftest = _stated(
        text, r"−\s*(\d+)\s*个属于\s*`harness_selftest`", "第一条式子里减掉的 harness_selftest 数"
    )
    if bullet_selftest != th_selftest:
        errors.append(
            f"testing.md 的式子减掉 {bullet_selftest} 个 harness_selftest 用例，"
            f"{rel(selftest_cpp)} 实际有 {th_selftest} 个"
        )
    bullet_result = _stated(text, r"=\s*(\d+)。拿这个式子复核", "第一条式子的结果")
    if bullet_result != mybot_derived:
        errors.append(
            f"testing.md 第一条式子的结果写 {bullet_result}，派生值是 {mybot_derived}"
        )
    if bullet_result != row_mybot:
        errors.append(
            f"testing.md 第一条式子的结果 {bullet_result} 与表格里 `mybot_tests` 的 "
            f"{row_mybot} 不一致（同一页两个数）"
        )
    bullet_meta_file = _stated(
        text, r"有\s*(\d+)\s*个\s*`TH_TEST`", "第二条式子里 harness_selftest 的 TH_TEST 数"
    )
    if bullet_meta_file != th_selftest:
        errors.append(
            f"testing.md 第二条式子写 harness_selftest 有 {bullet_meta_file} 个 TH_TEST，"
            f"实际 {th_selftest} 个"
        )
    bullet_meta_run = _stated(text, r"只报\s*(\d+)\s*通过", "第二条式子里二进制报的通过数")
    if bullet_meta_run != harness_derived:
        errors.append(
            f"testing.md 第二条式子写二进制只报 {bullet_meta_run} 通过，派生值是 "
            f"{harness_derived}"
        )
    bullet_meta_n = _stated(text, r"另外\s*(\d+)\s*个\s*`meta_\*`", "第二条式子里的 meta_ 例句数")
    if bullet_meta_n != th_meta:
        errors.append(
            f"testing.md 第二条式子写 {bullet_meta_n} 个 meta_ 例句，"
            f"{rel(selftest_cpp)} 实际有 {th_meta} 个"
        )

    # 406 那一格必须自带「不可派生」的标记，否则读者会以为它也受检
    if "运行时数" not in m_sim.group(0):
        errors.append(
            "testing.md 的 `sim_tests` 行没写「运行时数」标记：那个通过数是断言计数，"
            "本脚本派生不出来（只能钉 TU 数），不标注会被误当成受检数字"
        )

    return {
        "mybot": mybot_derived,
        "harness": harness_derived,
        "sim_tu": sim_tu_derived,
        "rust": rust_derived,
        "meta": th_meta,
    }


# ── 7) README 的计数（与第 6 组同判据：从仓库实况派生后比对）──────────

ROBOTS_DIR = ROOT / "robots"
SCRIPTS_DIR = ROOT / "scripts"
TEST_DIR = ROOT / "test"

# README 里每个计数 → (锚点正则, 人话说明)。锚点消失即 exit，与 _stated 同取向：
# 这些数字属于「没人会回头看」那一类，静默少比一个比报错危险得多。
# 同一个数在 README 里出现两次的（Lua/C++ 测试文件数在「项目结构」与「测试规模」
# 两节各写一遍），两条锚点都要登记——只钉一处会让另一处继续漂。
README_COUNT_ANCHORS = [
    ("modules", r"Lua驱动生态（(\d+)个模块", "项目结构里 modules/ 那行的模块数"),
    ("lib", r"个模块 \+ (\d+)个共享库）", "项目结构里 modules/ 那行的共享库数"),
    ("robots", r"结构脚本（(\d+)个机器人定义）", "项目结构里 robots/ 那行的机器人定义数"),
    ("scripts", r"动作脚本库（(\d+)个动作脚本）", "项目结构里 scripts/ 那行的动作脚本数"),
    ("sim_tu", r"sim_tests（(\d+) 个 TU", "项目结构里 sim/tests/ 那行的 TU 数"),
    ("lua_tests", r"三层测试（(\d+) Lua", "项目结构里 test/ 那行的 Lua 测试文件数"),
    ("cpp_test_files", r"三层测试（\d+ Lua \+ (\d+) C\+\+", "项目结构里 test/ 那行的 C++ 单测文件数"),
    ("docs_md", r"深入文档（(\d+)篇Markdown", "项目结构里 docs/ 那行的 Markdown 篇数"),
    ("mybot", r"\n- (\d+) 个 C\+\+ 单测（", "测试规模里的 C++ 单测条数"),
    ("lua_tests", r"\n- (\d+) 个 Lua 测试文件", "测试规模里的 Lua 测试文件数"),
    ("cpp_test_files", r"个 Lua 测试文件 \+ (\d+) 个 C\+\+ 单测文件",
     "测试规模里的 C++ 单测文件数"),
    ("harness", r"harness_selftest` (\d+) 条", "测试规模里的 harness_selftest 条数"),
    ("meta", r"另有 (\d+) 个 `meta_\*` 例句", "测试规模里的 meta_ 例句数"),
    ("rust", r"`cargo test --release` (\d+) 条", "测试规模里的 Rust 用例数"),
]

# 派生不出来的运行时数**不许在 README 里写死**。命中即判红，并说明该改成指针。
# 由来：README 曾写「271 道守门用例」「406 条断言」，两者都要跑一遍才知道，
# 静态门钉不住，于是烂成了 274 / 实况不符——与第 6 组对 sim 406 只钉「N 个 TU」
# 并要求标「运行时数」是同一个取舍，只是 README 这侧直接不写数字（门面要的是量级感，
# 而量级感由那 14 个受检数字已经给足，多两个必漂的数字不值）。
README_UNPINNED = [
    (re.compile(r"\d+\s*道守门用例"), "`bash test/run_all.sh` 汇总行的守门用例数"),
    (re.compile(r"\d+\s*条断言"), "`sim_tests` 的断言数"),
    (re.compile(r"sim_tests`\s*\d+\s*条"), "`sim_tests` 的通过数"),
]


def _readme_int(text, pat, what):
    m = re.search(pat, text)
    if m is None:
        sys.exit(
            f"{PREFIX}: {rel(README)} 里找不到{what}，措辞变了？"
            "（改措辞请同步 README_COUNT_ANCHORS 的锚点正则）"
        )
    return int(m.group(1))


def check_readme_counts(errors, suites):
    """把 README 的每个计数与仓库实况派生值比对（第 6 组的同款判据，换个文档）。

    此前 README 的数字自称「快照，改完文件用这几条命令复核，别手改数字」——纯人工、
    无门，于是六处一起漂（2026-10-08 审计 P2：87/38 实为 88/42、650 实为 689、
    148 实为 153、23 个共享库实为 28、工具表 9 行实为 12）。第 6 组已经证明
    「从源码派生」这条路对 testing.md 有效，这里照搬同一套。
    """
    text = read(README)

    derived = dict(suites)
    derived.update({
        "modules": len(list(MODULES_DIR.glob("*.lua"))),
        "lib": len(list((MODULES_DIR / "lib").rglob("*.lua"))),
        "robots": len(list(ROBOTS_DIR.glob("*.sql"))),
        "scripts": len(list(SCRIPTS_DIR.glob("*.mt"))),
        "lua_tests": len(list(TEST_DIR.glob("*.lua"))),
        "cpp_test_files": len(list((TEST_DIR / "cpp").glob("test_*.cpp"))),
        "docs_md": len(list(DOCS_DIR.glob("*.md"))),
    })

    for key, pat, what in README_COUNT_ANCHORS:
        stated = _readme_int(text, pat, what)
        if stated != derived[key]:
            errors.append(
                f"README 写{what}为 {stated}，按仓库实况派生是 {derived[key]}"
                "（派生命令见 README「项目结构」节末与第 6 组同源的口径）"
            )

    for pat, what in README_UNPINNED:
        m = pat.search(text)
        if m is not None:
            errors.append(
                f"README 写死了{what}（`{m.group(0)}`）：这是运行时数，本脚本静态派生"
                "不出来，写死必漂移——改成指向实时输出（`bash test/run_all.sh` 汇总行 / "
                f"{rel(TESTING_MD)}），别抄数字"
            )

    return derived


def main():
    errors = []
    n_paths = check_paths(errors)
    roster = drivers_roster()
    on_disk = modules_on_disk()
    n_modules = check_roster(errors, roster, on_disk)
    stated = check_counts(errors, roster, on_disk)
    n_docs = check_index(errors)
    n_scanned = check_deleted(errors)
    suites = check_suite_counts(errors)
    readme = check_readme_counts(errors, suites)

    if errors:
        print(f"{PREFIX}: 文档与仓库实况不一致：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(
        f"{PREFIX}: 一致（{n_paths} 条路径引用 / {n_modules} 个模块双向对齐"
        f" / 计数口径 {stated['total']}={stated['device']}+{stated['bus']}+{stated['tool']}"
        f"、lib {stated['lib']} / {n_docs} 篇文档全部挂上索引"
        f" / {n_scanned} 个文件里零处引用 {len(DELETED_FILES)} 个已删文件"
        f" / 套件计数派生 mybot_tests {suites['mybot']}、harness_selftest "
        f"{suites['harness']}、sim_tests {suites['sim_tu']} 个 TU、Rust {suites['rust']}"
        f" / README {len(README_COUNT_ANCHORS)} 处计数派生比对"
        f"（模块 {readme['modules']}、lib {readme['lib']}、Lua 测试 {readme['lua_tests']}"
        f"、C++ 测试文件 {readme['cpp_test_files']}、docs {readme['docs_md']} 篇）"
        f" / {len(KNOWN_ABSENT)} 条历史与占位豁免仍生效）"
    )


if __name__ == "__main__":
    main()
