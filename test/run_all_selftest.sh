#!/bin/bash
# test/run_all_selftest.sh —— 守门自身的自检（计划 M0 的 C7 起步，零行为变化）
#
# 守门脚本是「声称的防线」与「实际执行」之间唯一的仲裁者，但它自己没有任何测试：
#   - 用例不叫 test_*.lua，run_all.sh 的 glob 与 CMake 的 glob 都不会收集它；
#   - 新加的 test/cpp/*.cpp 不写进 CMakeLists.txt 就永不编译；
#   - 脚本自身的语法错误要到推送那一刻才暴露。
# 本自检只做**便宜且能机械判定**的事，且**不进入 run_all.sh 的记账**
# （守门汇总口径保持不变），由 pre-push 在守门之前调用、CI 的 gate:release 也把它
# 排在全量守门之前。两类，按段号分：
#   1–7  守门自身的可信度（脚本语法、用例是否真被 glob/编译收集、计数文案是否有出处、
#        用例表结构与两套计数互证（条数派生，tokenizer 在 test/lib/case_table.awk）、
#        TSan 名单**双向**核对、四个守门单点，以及末尾**实跑**一次拼错过滤器核对空匹配
#        防线——那是本自检唯一执行 run_all.sh 的地方，0.1s 级，见第 7 段）；
# controller-only 版本：原第 8–14 段（sim/agent/LLM 的跨源一致性）随对应能力一起移除，
# 只保留当前控制器自身可机械判定的守门检查。
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
note() { echo "[FAIL] selftest: $*" >&2; fail=$((fail + 1)); }

# 1) 守门相关脚本的语法（bash -n 不执行，纯解析）
#    test/lib/ 下用 glob 而非逐个列名：本自检存在的理由就是「新文件忘了登记 ⇒ 静默
#    不受检」，列名清单自己也会犯这个错（2026-10-06 加 agent_stale.sh 时改成 glob）。
for f in test/run_all.sh test/run_san.sh test/lib/*.sh \
		test/lib/sections/*.sh scripts/git-hooks/pre-push; do
	if [ ! -f "$f" ]; then
		note "缺文件：$f"
		continue
	fi
	bash -n "$f" || note "$f 存在语法错误"
done

# 2) 每个 test/cpp/*.cpp 都必须登记进 CMakeLists.txt（显式源清单，漏登记即永不编译）
for f in test/cpp/*.cpp; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        grep -qF "test/cpp/$base" CMakeLists.txt \
                || note "C++ 用例未登记进 CMakeLists.txt（不会参与编译）：$f"
done

# 3) test/*.lua 必须匹配 test_*.lua——run_all.sh 与 CMakeLists 两侧的 glob 同此前缀，
#    改名即被两边同时静默漏掉。
for f in test/*.lua; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in
                test_*) ;;
                *) note "Lua 用例不匹配 test_*.lua 命名（守门与 ctest 都不会收集）：$f" ;;
        esac
done

# 4) count_calls（「N 条用例」文案的唯一来源）必须真的数得到调用点。
#    它按「行首缩进 + runner 名 + 引号」匹配：引号种类、缩进或改名一变，计数静默
#    变 0，文案与真跑条数就一起漂移。这里用**独立实现**交叉核对（宽松计数不看引号）：
#    两者不等即说明 count_calls 的判据漏了某种写法。F3-4（2026-09-21）。
for r in $(grep -oE 'count_calls [a-zA-Z0-9_]+' test/run_all.sh | awk '{print $2}' | sort -u); do
        # 定义可能在 run_all.sh，也可能在 F3-1 抽出的分段文件里；调用点则必须仍在
        # run_all.sh（count_calls 数的就是它）。
        grep -qE "^[[:space:]]*${r}\(\)" test/run_all.sh test/lib/sections/*.sh \
                || note "count_calls 的参数不是已定义的 runner（run_all.sh 与分段文件里都没有）：$r"
        strict="$(grep -cE "^[[:space:]]*${r} ['\"]" test/run_all.sh)"
        loose="$(grep -cE "^[[:space:]]*${r}[[:space:]]" test/run_all.sh)"
        if [ "$strict" -eq 0 ]; then
                note "runner $r 的调用点计数为 0（写法变了？引号/缩进/改名）"
        elif [ "$strict" -ne "$loose" ]; then
                note "runner $r 计数不一致：count_calls 判据 $strict != 宽松计数 $loose（有写法没被认出来）"
        fi
done

# 5) 两张用例表的结构与条数（F3-2；2026-10-06 重写：条数改**派生**、判据改 quote-aware）
#    旧写法有两个毛病，第二个是真 bug：
#      * 条数是硬编码检查点（e2e 37 / parse 96），全仓唯一一份手维护的重复数字——文档
#        刻意不写这两个总数（口径见 docs/virtbus.md「用例条数以单一事实源为准」），于是
#        加/删用例就得人记着改它，已经漂过一次（提交 9ebcf4a「同步 parse_cases 条数
#        检查点至 96」）；
#      * 抽取用 grep "^[[:space:]]*'"，**只认单引号**。而表里 expect 字段含单引号的条目
#        按约定整条改用双引号书写（parse_cases 的 vars_bad 行；同一约定在 fixture 孤儿
#        检测那边 2026-09-20 就踩过并修好，注释见 run_all.sh「fixture 孤儿检测」段，
#        这边一直没跟上）。实测：bash 展开 parse_cases 得 97 条，旧抽取只看见 96 条，
#        而检查点写的正是 96——那条用例的字段数 / 引号收尾 / (sql,mt) 重复三项检查全部
#        落空，且检查点反过来把盲区钉成「正确值」：修好抽取器会让自检转红。
#    现改两套独立实现互证（本文件第 4 段 count_calls 的同一手法）：
#      A 行计数：quote-agnostic 地数「以引号开头的行」；
#      B 元素计数：test/lib/case_table.awk 按 bash 引号语义逐字符 tokenize，数出真实
#        元素并吐出去掉外层引号的正文（引号未收尾、双引号内含展开语法在它那里判失败）。
#      A != B ⇒ 有写法逃过了行计数（一行两条 / 非常规缩进 / 新引号形态）。
#    结构判据全部吃 B 的输出，不再对原始文本猜。parse 的段数下界是 **4 不是 3**（旧注释
#    写的「至少三段，其余字段可选」正是这个坑）：消费循环 run_parse_cases
#    （test/lib/sections/lua_e2e.sh）连做四次 ${rest#*|}，三段行走到第四次时 rest 里
#    没有 '|'，bash 原样返回，于是 expect 静默变成期望退出码本身（"0"/"1"），
#    grep -qF 几乎必然命中——用例照跑、照记通过，却一条输出断言都没有。现表里没有
#    三段行，这条是把坑封死。
tok_file=test/lib/case_table.awk
[ -f "$tok_file" ] || note "缺用例表 tokenizer：$tok_file（第 5 段的 B 侧实现）"
q="['\"]"
for t in e2e_cases parse_cases; do
	block="$(sed -n "/^${t}=(/,/^)/p" test/run_all.sh)"
	if [ -z "$block" ]; then
		note "test/run_all.sh 里抽不到用例表 ${t}=( …… )（表名改了？sed 的块抽法失效？）"
		continue
	fi
	n_a="$(printf '%s\n' "$block" | grep -cE "^[[:space:]]*${q}")"
	if ! elems="$(printf '%s\n' "$block" | awk -v SQ="'" -v DQ='"' -f "$tok_file")"; then
		note "${t} 的条目引号有问题（详见上方 case_table.awk 的输出）"
	fi
	n_b="$(printf '%s\n' "$elems" | grep -c .)"
	[ "$n_b" -gt 0 ] || note "${t} 一条都没 tokenize 出来（表被删空？）"
	[ "$n_a" -eq "$n_b" ] || note "${t} 两套计数不一致：行计数 $n_a != tokenize 元素数 $n_b（有写法逃过了行计数：一行两条？缩进或引号形态变了？）"
	# 结构判据：按消费循环（run_one_e2e / run_one_parse）的实际字段语义逐条核。
	# awk 吐 "判据\t命中条数\t首条正文"，用 here-string 喂 while（管道会开子 shell，
	# note 的计数就丢了）。
	while IFS="$(printf '\t')" read -r msg cnt sample; do
		[ -n "$msg" ] || continue
		note "${t} 有 ${cnt} 条${msg}；首条：${sample}"
	done <<< "$(printf '%s\n' "$elems" | awk -F'|' -v T="$t" '
		function bad(m) { n[m]++; if (!(m in first)) first[m] = $0 }
		NF && T == "e2e_cases" {
			if (NF != 3) bad("段数 != 3（应为 name|浮点模式|最小条数）")
			else if ($3 !~ /^[0-9]+$/) bad("第 3 段（最小条数）不是非负整数")
			if (seen[$1]++) bad("名字重复")
		}
		NF && T == "parse_cases" {
			if (NF < 4 || NF > 6) bad("段数不在 4~6（sql|mt|期望退出码|expect[|forbid[|via]]；三段行会让 expect 静默退化成退出码）")
			else if ($3 !~ /^[0-9]+$/) bad("第 3 段（期望退出码）不是非负整数")
			if (NF >= 6 && $6 != "I") bad("第 6 段（via）不是 I（--input 文件通道）也不是空")
			k = $1 "|" $2
			if (seen[k]++) bad("(sql,mt) 组合重复")
		}
		END { for (m in n) printf "%s\t%d\t%s\n", m, n[m], first[m] }
	')"
done

# 6) TSan 用例名单单点（F3-5）：名单唯一来源 test/lib/tsan_cases.txt，CI 逐条跑。
#    这里**双向**机械核对：正向——名单里每个名字在 test_daemon_concurrency.cpp 里至少
#    命中一条 TH_TEST（改过用例名而没改名单会静默少跑）；反向——文件里每条 TH_TEST 都
#    被名单某条覆盖（加了并发用例而没往名单里加前缀，同样静默少跑，见下面那段注释）。
tsan_file=test/lib/tsan_cases.txt
if [ ! -s "$tsan_file" ]; then
        note "缺 TSan 名单或为空：$tsan_file"
else
	while read -r c; do
		case "$c" in ''|\#*) continue ;; esac
		grep -qE "^TH_TEST\(${c}[A-Za-z0-9_]*\)" test/cpp/test_daemon_concurrency.cpp \
			|| note "TSan 名单里的 '$c' 在 test_daemon_concurrency.cpp 里没有对应用例（改过名？）"
	done < "$tsan_file"

	# 反向核对（2026-10-06 补）：文件里每条 TH_TEST 都必须被名单里某条覆盖。
	# 正向只保证「名单里的名字都还存在」，反过来不成立——新增一条并发用例而它的名字
	# 不含任何名单条目时，正向检查全绿，而 CI 的 gate:tsan 逐条跑的是名单，那条新用例
	# 永远不会在 TSan 下跑过：并发回归静默少一条，且少的那条恰好是新写的、最可能带
	# 数据竞争的那条。
	# 判据用**子串**而不是前缀，与真实过滤语义对齐：harness.hpp 的 runAllOutcome 是
	# `c.name.find(needle) == npos → continue`（gate:tsan 传的正是名单条目）。用前缀会
	# 把「名字中段含条目」的合法覆盖误报成漏网。
	tsan_src=test/cpp/test_daemon_concurrency.cpp
	tsan_names="$(grep -oE '^TH_TEST\([A-Za-z0-9_]+\)' "$tsan_src" | sed 's/^TH_TEST(//; s/)$//')"
	tsan_n="$(printf '%s\n' "$tsan_names" | grep -c .)"
	[ "$tsan_n" -gt 0 ] || note "$tsan_src 里一条 TH_TEST 都抽不到——用例改名换了形态，还是文件被挪了？"
	tsan_roster="$(grep -vE '^[[:space:]]*(#|$)' "$tsan_file")"
	tsan_uncovered=""
	while read -r n; do
		[ -n "$n" ] || continue
		tsan_hit=0
		while read -r c; do
			[ -n "$c" ] || continue
			case "$n" in *"$c"*) tsan_hit=1; break ;; esac
		done <<< "$tsan_roster"
		[ "$tsan_hit" -eq 1 ] || tsan_uncovered="$tsan_uncovered $n"
	done <<< "$tsan_names"
	[ -z "$tsan_uncovered" ] || note "并发用例不在 TSan 名单任何条目覆盖下（gate:tsan 不会跑它们，请往 $tsan_file 加一条前缀）：$tsan_uncovered"
fi

# 7) 守门单点与防线自证（F3-5 余部）：常量与判据取材面各自只有一份；末尾再**实跑**
#    一次拼错过滤器，核对空匹配防线（C8）真的会红。
#    TEST_TIMEOUT/SAN_DIR 默认值唯一来源
#    test/lib/params.sh（bash 直接 source、CMake 正则提取、CI 同源）。格式
#    漂移（如 CMake 侧正则依赖的 `: "${KEY:=v}"` 形态被改）会让 ctest TIMEOUT
#    在 configure 期 FATAL——这里再钉一层，让漂移在 selftest 就显形。
for k in TEST_TIMEOUT TEST_KILL_GRACE SAN_DIR; do
        grep -qE "^: \"\\\$\{${k}:=[0-9a-zA-Z._/-]+\}\"$" test/lib/params.sh \
                || note "params 单点缺 ${k} 条目或格式漂移（CMake 正则提取会失败）：test/lib/params.sh"
done
#    同族第三个单点：harness_selftest 二进制的**路径**。两个消费方——run_all.sh 顶部的
#    产物陈旧判据、tail_checks.sh 的 run_harness_selftest 段。2026-10-06 之前是两处各写
#    一遍 dirname 派生：只要有一处没跟着 BOT_TESTS 走，就成了「陈旧判据判的是 A、实际
#    跑的是 B」，判据形同不存在。顺带钉住同一轮修的守卫取材面：三个产物各配自己那份
#    编译期输入（骨架自证只吃它那两个文件；目录级的那两份还要减去属于别的目标的文件，
#    见下面第四个单点），此前共用一份最大集合，
#    后果是「只改一条用例」时 mybot 永远判陈旧而 cmake 重链不了它——门一直狼来了，
#    教会大家的正是 BOT_ALLOW_STALE=1 怎么绕。
derive_hits="$(grep -rn 'dirname "\$tests_bin")/harness_selftest' --include='*.sh' test 2>/dev/null)"
n_derive="$(printf '%s\n' "$derive_hits" | grep -c .)"
derive_file="$(printf '%s\n' "$derive_hits" | cut -d: -f1 | sort -u | tr '\n' ' ')"
[ "$n_derive" -eq 1 ] || note "harness_selftest 路径的派生式出现 $n_derive 次（应为 1 次单点）"
[ "$derive_file" = "test/run_all.sh " ] || note "harness_selftest 路径的派生式不在单点上（应只在 test/run_all.sh，实际：${derive_file:-抽不到}）"
grep -q 'binp="\$selftest_bin"' test/lib/sections/tail_checks.sh \
	|| note "run_harness_selftest 不再用单点变量 selftest_bin（自己派生路径会与陈旧判据各判各的）"
grep -q 'for _b in "\$bin" "\$tests_bin" "\$selftest_bin"' test/run_all.sh \
	|| note "产物陈旧判据的循环不再覆盖 harness_selftest（骨架自证会拿旧二进制报「8 通过」）"
#    同族第四个单点：陈旧判据的**排除名单**。目录级取材面必须减去属于别的目标的文件，
#    否则「touch src/main.cpp → cmake 只重链 mybot → mybot_tests 恒被判陈旧」这类
#    **重建也修不好**的误报会换个入口再犯一次（2026-10-06 实测两回：先是被
#    CMakeLists.txt 挡掉 run_san.sh 的整个第二跑，修掉后又暴露出 harness_selftest.cpp）。
#    归属的权威出处是 CMakeLists 的 add_executable 清单，
#    故这里从 CMakeLists **现算**、与 run_all.sh 的名单双向核对：归属变了名单就得跟着
#    变，任一侧单独漂都红（名单多一条 = 漏判真陈旧，少一条 = 门恒红教人绕过它）。
cmake_block() {	# $1=块首整行（列 0 起）；打印到该块收口的 ")" 之前
	awk -v m="$1" '$0==m{f=1;next} f&&/^\)/{exit} f{print}' CMakeLists.txt
}
_blk_core="$(cmake_block 'set(MYBOT_CORE_SOURCES')"
_blk_mybot="$(cmake_block 'add_executable(mybot')"
_blk_tests="$(cmake_block 'add_executable(mybot_tests')"
[ -n "$_blk_core" ] && [ -n "$_blk_mybot" ] && [ -n "$_blk_tests" ] \
	|| note "CMakeLists.txt 的 add_executable/set 块抽不到（块首行不再是列 0 起的整行？）——本段的归属核对已失效"
grep -q 'src/main\.cpp' <<<"$_blk_mybot" \
	|| note "src/main.cpp 不在 mybot 的 add_executable 里（陈旧判据排除它的依据没了）"
for _owned in "$_blk_core" "$_blk_tests"; do
	grep -qE 'src/main\.cpp' <<<"$_owned" \
		&& note "src/main.cpp 进了 MYBOT_CORE_SOURCES / mybot_tests 清单——它已成为这两个产物的编译期输入，陈旧判据再排除就是漏判真陈旧"
done
unset _owned
grep -q 'harness_selftest\.cpp' <<<"$_blk_tests" \
	&& note "test/cpp/harness_selftest.cpp 进了 mybot_tests 清单——它已成为 mybot_tests 的编译期输入，陈旧判据再排除就是漏判真陈旧"
_excl="$(grep -o "not -path '[^']*'" test/run_all.sh | sed "s/not -path '//; s/'\$//" | sort -u | tr '\n' ' ')"
[ "$_excl" = "src/main.cpp test/cpp/harness_selftest.cpp " ] \
	|| note "陈旧判据的排除名单变了（实际：${_excl:-抽不到}）——归属若真变了，请同步 run_all.sh 的注释与本段"
#    名单是**集合**还不够：同一条排除要在几个分支里各写一次是有讲究的
#    （src/main.cpp 对 mybot_tests 排——它对 mybot 恰恰是入口源，排了就漏判真陈旧）。
#    故再按**出现次数**钉一遍，摘掉一处副本或挪错分支都红（只用 sort -u 的话，
#    摘掉两处副本里的一处不报）。
for _e in 'src/main.cpp:1' 'test/cpp/harness_selftest.cpp:1'; do
	_p="${_e%:*}"
	_n="$(grep -o "not -path '$_p'" test/run_all.sh | grep -c .)"
	[ "$_n" -eq "${_e##*:}" ] \
		|| note "陈旧判据里 -not -path '$_p' 出现 $_n 次（应 ${_e##*:} 次）——排错了分支：多排 = 漏判真陈旧，少排 = 门恒红"
done
unset _p _n _e _excl _blk_core _blk_mybot _blk_tests
#    另一类可信度：**空匹配防线（C8）真的会红**。run_all.sh 末尾那条
#    `pass + fail == 0 → exit 1` 只在「每个分段都受过滤器管辖」时才成立。
#    2026-09-21 AG-5 后加的 harness-selftest 段无条件跑完记 1 通过，于是
#    `run_all.sh zzz_typo` 以「1 通过, 0 失败」退出 0（2026-10-06 实测）——文档里
#    写着「过滤器拼错必须失败」，实际已失效。段门补回后这里钉两件事：
#    ① 段门还在（静态）；② 拿一个不可能命中的过滤器**实跑**一次，退出码必须非 0。
#    ②是执行而非比对：将来任何分段再变成无条件 record_pass，②照样抓得到，①抓不到。
#    产物陈旧时 run_all.sh 以 2 退出，②仍成立（拼错过滤器没报绿），只是那一轮没真正
#    走到 C8 那行——故①不可省，两条互补。
grep -q 'filter_matches "harness-selftest"' test/lib/sections/tail_checks.sh \
	|| note "harness-selftest 段的过滤器段门被摘了（它记的 1 通过会让空匹配防线永不成立）"
typo_rc=0
bash test/run_all.sh zzz_selftest_typo_probe >/dev/null 2>&1 || typo_rc=$?
[ "$typo_rc" -ne 0 ] \
	|| note "拼错过滤器仍以 0 退出：空匹配防线（C8）失效，有分段在无条件记通过"
#    第三类可信度：**坏形态 lint 的抽取判据对合成坏样本正向对照**（2026-10-08 审计
#    P0 续）。run_one_inline_lint 搜的是「坏形态」，PASS 天然要求 0 命中——这意味着
#    活树里的命中数永远不能当「判据还有效」的自证（0 命中既可能是「代码干净」也可能
#    是「判据已经认不出这种坏形态」，两者在活树上无法区分）。正确做法是喂一个**已知
#    含坏形态**的合成样本，断言判据真的抓得到；之前 9c5933c 给的 min_hits 阈值企图
#    拿活树命中数当自证，但 PASS 要求 bad 为空、自检要求 hits_n≥min_hits>0，两者
#    结构上互斥——min_hits>0 时 PASS 永不可达，这正是 P0 的根因，已在 run_all.sh 里
#    删掉（见该文件 lint-driver-entry-arg_table / lint-module-path-bootstrap 附近
#    的新注释）。这里补的是「删阈值之后不留空白」：grep_cmd 原文从 run_all.sh 里
#    原样抽出（不是在这里重写一遍判据，重写会与 run_all.sh 各漂各的），只换目标路径
#    到合成坏样本目录，断言命中 > 0。
_extract_lint_cmd() {	# $1=lint 名 → stdout 吐 run_one_inline_lint 第 3 个参数的真实值
	local name="$1" block cmd_line cmd_val
	block="$(sed -n "/run_one_inline_lint \"${name}\"/,/^\$/p" test/run_all.sh)"
	cmd_line="$(printf '%s\n' "$block" | sed -n '3p' | sed -E 's/^[[:space:]]*//')"
	[ -n "$cmd_line" ] || return 1
	eval "cmd_val=$cmd_line" 2>/dev/null || return 1
	printf '%s' "$cmd_val"
}
_lint_tmp="$(mktemp -d)"
mkdir -p "$_lint_tmp/modules"
# A 的合成坏样本：真实违规驱动会写的那种内联 `type(data) ~= "table"` 守卫
# （不叫 Camera.lua，否则会被判据自己的豁免过滤器挡掉——那是在测豁免，不是测判据）。
printf 'local function build(ctx, data)\n  if type(data) ~= "table" then error("x") end\nend\n' \
	> "$_lint_tmp/modules/Fixture.lua"
# B 的合成坏样本：真实违规会写的那种裸 `:match("[^:]+")` 首段提取，且不含 __mpath
# （含了 __mpath 会被判据自己的白名单过滤器挡掉——同上，不是在测判据本身）。
printf 'local p = BOT4CJ_MODULE_PATH:match("[^:]+")\n' > "$_lint_tmp/modules/FixtureMpath.lua"
for _ln in "lint-driver-entry-arg_table" "lint-module-path-bootstrap"; do
	if ! _cmd="$(_extract_lint_cmd "$_ln")"; then
		note "抽不到 $_ln 的 grep_cmd 原文（run_one_inline_lint 的调用形态变了？正向对照失去取材面）"
		continue
	fi
	_hit="$(cd "$_lint_tmp" && eval "$_cmd" 2>/dev/null | grep -c .)"
	[ "$_hit" -gt 0 ] \
		|| note "$_ln 的判据对合成坏样本命中 0 条——抽取判据已失效（正向对照落空，见 .tmp/audit-2026-10-08.md P0）"
done
rm -rf "$_lint_tmp"
unset _lint_tmp _ln _cmd _hit


if [ "$fail" -ne 0 ]; then
        echo "run_all_selftest: $fail 项不合格" >&2
        exit 1
fi
echo "run_all_selftest: 通过（语法 / C++ 用例登记 / Lua 命名 / count_calls / 用例表结构 / TSan 名单 / 守门单点与空匹配防线）"
