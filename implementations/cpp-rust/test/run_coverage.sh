#!/bin/bash
# test/run_coverage.sh —— C++ 侧行覆盖采集（CI 的 gate:coverage 复用）。
#
# 定位：覆盖率软门禁的**数据产出**入口。它不进 run_all.sh 的记账（守门汇总
# 口径不变），也不参与任何硬门禁——工具（gcovr/lcov）全都缺失时退化为 gcov
# 原生输出并照常产出报告，不会让既有硬门禁变红。
#
# 用法：bash test/run_coverage.sh
#   COV_BUILD_DIR（缺省 build-cov）/ COV_REPORT_DIR（缺省 build-cov/coverage，
#   随构建目录一并被 .gitignore 的 build-*/ 覆盖，不污染 git status）可覆盖。
#   COV_WITH_GATE=1：采集时额外跑一遍全套守门（ALLOW_SKIP=1 bash test/run_all.sh），
#   让 e2e/TCP/Lua 链路对 **mybot** 二进制的覆盖也计入。缺省只跑单测（快）。
#
# ---- 这个数字的口径与已知盲区（2026-09-21 AG-11 实测）----
#   * 它只统计 src/ 的**行**覆盖，且**只反映本条脚本实际跑过的东西**：缺省模式
#     下就是 C++ 单测；不加 COV_WITH_GATE=1 时 e2e 用的 mybot 不计入。
#   * fork/exec 子侧代码（agent_subprocess.cpp 的 execShellChild /
#     revokeInheritedFds）**恒为 0%**，且这不是「没测」而是「测了测不到」：
#     gcov 计数在进程退出时落盘，而这两个函数永远以 execve 结束——exec 用新
#     映像的计数页覆盖当前进程，子侧执行记录不可能被写出。AG-3（close_range
#     标志写错、快速路径从未执行）正藏在这个区块里，藏了很久。
#     该区块的保证由**行为断言**承担，见 test/cpp/test_agenttools.cpp 的
#     「AG-11：子进程路径自报」用例（在子进程 exec 前把走了哪条路径写进标记
#     文件，父进程断言）——不要试图用行覆盖去覆盖它。
#   * 因此**不建议**在本数字上设 COV_MIN_LINES 硬阈值：一个既漏掉 mybot 链路、
#     又有结构性 0% 区块的指标，设阈值只会把测试压力挤到测得到的区域。
set -u
cd "$(dirname "$0")/.." || exit 1

cov_pct=""		# src/ 行覆盖率（百分数）；三个分支各自填，供末尾阈值判定

build_dir="${COV_BUILD_DIR:-build-cov}"
report_dir="${COV_REPORT_DIR:-$build_dir/coverage}"
mybot_tests="$build_dir/mybot_tests"

echo "===== 覆盖率构建（$build_dir，CMAKE_CXX_FLAGS=--coverage） ====="
# --coverage 同时作用于编译与链接（CMAKE_CXX_FLAGS 会进入 C++ 可执行文件的
# 链接行，EXE_LINKER_FLAGS 再显式兜一层），确保 libgcov 被链进来。
cmake -S . -B "$build_dir" -DCMAKE_BUILD_TYPE=Debug \
	-DCMAKE_CXX_FLAGS=--coverage -DCMAKE_EXE_LINKER_FLAGS=--coverage >/dev/null || exit 1
# 同时构建 mybot：不构建它，COV_WITH_GATE=1 那一跑就没有被插桩的二进制，
# 「叠加守门」会一点数字都不涨（实测过：79.69% → 79.69%，容易让人以为 e2e
# 没有覆盖价值，实际是它压根没被计入）。
cmake --build "$build_dir" -j"$(nproc)" --target mybot_tests mybot || exit 1

# 清掉陈旧计数文件（2026-09-21 AG-11）：重建二进制后 .gcda 的 checksum 会变，
# 不删就会看到 libgcov 报 "overwriting an existing profile data with a different
# checksum" 并**混合两套构建的数据**——数字来源不明比数字低更糟。
find "$build_dir" -name '*.gcda' -delete

echo "===== 运行 mybot_tests 采集覆盖（CWD 必须是仓库根：用例读相对路径夹具） ====="
./"$mybot_tests" >/dev/null || exit 1

if [ -n "${COV_WITH_GATE:-}" ]; then
	echo "===== COV_WITH_GATE=1：再跑全套守门，把 e2e/TCP/Lua 对 mybot 的覆盖计入 ====="
	# 两个必须显式给的环境变量（2026-09-21 AG-11 实测踩到）：
	#   BOT      —— run_all.sh 缺省跑 ./build/mybot，那是**没插桩**的二进制，
	#               于是「叠加守门」一点数字都不涨（实测 77.90% → 77.90%），
	#               极易被读成「e2e 没有覆盖价值」。必须指向插桩产物。
	#   BOT_TESTS——同理指向插桩的 mybot_tests（缺省路径其实已经是它，显式写出
	#               以免脚本被搬家后静默错位）。
	# ALLOW_SKIP=1：允许缺真机/缺可选依赖的分段跳过（覆盖率采集不是守门，
	# 不该因为本机没有摄像头而失败）；守门本身仍由 run_all.sh 正常入口把关。
	BOT="./$build_dir/mybot" BOT_TESTS="./$build_dir/mybot_tests" \
		ALLOW_SKIP=1 bash test/run_all.sh >/dev/null 2>&1 || true
	echo "（守门跑完；本轮只为累积覆盖计数，其通过与否不改变本脚本退出码）"
fi

mkdir -p "$report_dir"
if command -v gcovr >/dev/null 2>&1; then
	echo "===== gcovr 摘要（src/） ====="
	cov_summary="$(gcovr --root . --filter 'src/' --print-summary \
		--txt "$report_dir/coverage.txt" --xml "$report_dir/coverage.xml")"
	printf '%s\n' "$cov_summary"
	cov_pct="$(printf '%s\n' "$cov_summary" | sed -n 's/^lines: \([0-9.]*\)%.*/\1/p' | head -1)"
elif command -v lcov >/dev/null 2>&1; then
	echo "===== lcov 摘要（src/） ====="
	lcov --capture --directory "$build_dir" --output-file "$report_dir/lcov.info" >/dev/null
	lcov --extract "$report_dir/lcov.info" '*/src/*' --output-file "$report_dir/lcov-src.info" >/dev/null
	cov_pct="$(lcov --summary "$report_dir/lcov-src.info" 2>&1 \
		| sed -n 's/^[[:space:]]*lines[. ]*: \([0-9.]*\)%.*/\1/p' | head -1)"
else
	echo "===== 无 gcovr/lcov，退化为 gcov 原生输出（src/） ====="
	repo_root="$(pwd)"
	build_abs="$repo_root/$build_dir"
	(
		cd "$repo_root/$report_dir" || exit 1
		# 每个 src/*.cpp 会同时出现在多个 target 的对象目录里（mybot 与
		# mybot_tests），.gcno 与源码同名。两个 target 都插桩之后，同一源文件
		# 有 2 份 .gcno + 2 份 .gcda——逐个调用 gcov 时后一次会**覆盖**前一次的
		# .gcov（实测：mybot_tests 的 0% 覆盖掉 mybot 的 e2e 覆盖，mcplisten.cpp
		# 从 28% 退化成 0%）。
		#
		# gcov 不会跨 -o 目录累加（旧注释「gcov 会累加」是错的）：每次调用只读
		# 指定 -o 目录里的 .gcda，写出的 .gcov 覆盖 CWD 的同名文件。正确合并方式
		# 是每个 target 各跑 gcov 到独立临时目录，再按行累加执行计数合并成一份。
		#
		# 两个必须知道的 gcov 行为：
		#   ① 要喂**完整 .gcno 路径**。只给 -o 目录 + 源码路径时，gcov 会去找
		#      去掉扩展名的 <base>.gcno，报 "cannot open notes file"。
		#   ② 同一源文件、多个 .gcda（不同 target 各跑各的）时，必须分目录输出
		#      后手动合并——gcov 自身不做跨目录合并。
		shopt -s nullglob
		merge_tmp="$(mktemp -d)"
		# 第一步：每个 target 的 .gcda 各跑 gcov 到独立子目录
		# 目录结构：CMakeFiles/<target>.dir/src/<file>.gcda —— 取 target.dir 作子目录名
		for gcda in "$build_abs"/CMakeFiles/*.dir/src/*.gcda; do
			target_dir="$(basename "$(dirname "$(dirname "$gcda")")")"  # e.g. mybot.dir
			out_sub="$merge_tmp/$target_dir"
			mkdir -p "$out_sub"
			(cd "$out_sub" && gcov -b -o "$(dirname "$gcda")" "${gcda%.gcda}.gcno" >/dev/null 2>&1) || true
		done
		# 第二步：按源文件名合并各 target 的 .gcov（行计数累加）
		# .gcov 格式：每行 `COUNT:LINENO:TEXT`，COUNT 是 `-`（不可执行）/`#####`（未执行）/数字
		# 合并规则：`-` 保持 `-`；`#####`+`#####`=`#####`；数字+任何=求和（##### 当 0）
		for gcov_file in "$merge_tmp"/*/*.gcov; do
			[ -f "$gcov_file" ] || continue
			base="$(basename "$gcov_file")"
			# 只合并 src/ 的 .gcov（过滤掉 libstdc++ 等系统头）
			src_line="$(sed -n 's/.*:Source://p' "$gcov_file" | head -1)"
			case "$src_line" in
				*/src/*) ;;
				*) continue ;;
			esac
			# 找到所有 target 里同名 .gcov
			all_for_base=("$merge_tmp"/*/"$base")
			if [ "${#all_for_base[@]}" -le 1 ]; then
				cp "$gcov_file" "$base"
			else
				# 多文件合并：逐行读取，按 lineno 为键累加计数
				# header 行（行号 0 或缺失）取第一份的原文
				awk '
					BEGIN { FS = ":"; n = 0 }
					{
						cnt = $1; lineno = $2; src = ""
						for (i = 3; i <= NF; i++) src = src (i > 3 ? ":" : "") $i
						gsub(/^[ \t]+|[ \t]+$/, "", cnt)
						gsub(/^[ \t]+|[ \t]+$/, "", lineno)
						ln = lineno + 0
						# header 行（行号为 0）：只取第一份
						if (ln == 0) {
							if (!(0 in header_seen)) { header[++hn] = $0; header_seen[0] = 1 }
							next
						}
						if (!(ln in counts)) {
							counts[ln] = cnt
							sources[ln] = src
							order[++n] = ln
						} else {
							old = counts[ln]
							gsub(/^[ \t]+|[ \t]+$/, "", old)
							if (old == "-" || cnt == "-") counts[ln] = "-"
							else if (old == "#####" && cnt == "#####") counts[ln] = "#####"
							else {
								vo = (old ~ /^[0-9]+$/) ? old + 0 : 0
								vn = (cnt ~ /^[0-9]+$/) ? cnt + 0 : 0
								counts[ln] = (vo + vn)
							}
						}
					}
					END {
						for (i = 1; i <= hn; i++) print header[i]
						for (i = 1; i <= n; i++) {
							ln = order[i]
							printf "%8s:%5s:%s\n", counts[ln], ln, sources[ln]
						}
					}
				' "${all_for_base[@]}" > "$base"
			fi
		done
		rm -rf "$merge_tmp"
		shopt -u nullglob
	)
	# 聚合 .gcov：只统计 Source 落在 src/ 的文件（一个 .gcno 会连带生成 libstdc++
	# 等系统头的 .gcov，必须按 Source 行过滤）；字段 1 是执行计数（`-` = 非可执行行，
	# 数字 = 已执行，`#####` = 未执行）。
	awk -F: '
		FNR == 1 { src_ok = 0 }
		FNR <= 8 && $3 == "Source" { if ($4 ~ /(^|\/)src\//) src_ok = 1; next }
		!src_ok { next }
		NF < 3 { next }
		{ cnt = $1; gsub(/^[ \t]+|[ \t]+$/, "", cnt) }
		cnt == "-" { next }
		{ total++; if (cnt ~ /^[0-9]+$/) exec++ }
		END {
			if (total > 0) {
				printf "src/ 行覆盖：%.2f%%（%d/%d）\n", exec * 100 / total, exec, total
				printf "COV_LINES_PCT=%.2f\n", exec * 100 / total
			} else {
				print "src/ 行覆盖：无数据（未生成 src/ 的 .gcov）"
			}
		}
	' "$report_dir"/*.gcov > "$report_dir/gcov-summary.txt"
	# 人类可读行原样回显（保持本分支原有的 stdout 语义），机器行另取
	grep -v '^COV_LINES_PCT=' "$report_dir/gcov-summary.txt"
	cov_pct="$(sed -n 's/^COV_LINES_PCT=//p' "$report_dir/gcov-summary.txt" | head -1)"
fi
echo "报告目录：$report_dir/"

# ---- 阈值判定（F3-6，2026-09-21）----
# COV_MIN_LINES 未设 = **只报告不判定**：起步阶段用一个拍脑袋的数字卡住 CI 只会
# 逼人调低阈值，先让数据入库。CI 的 gate:coverage 2026-09-25 起已是硬门禁（判
# 采集链路失败即红，不设阈值、不判数值——数值判定只在本脚本设 COV_MIN_LINES
# 时发生，供把「覆盖率不许倒退」接进自己的流水线用）。
# 设了即硬判：低于阈值退出 1，便于把「覆盖率不许倒退」接进流水线。
if [ -z "$cov_pct" ]; then
	echo "阈值判定：未取到行覆盖率（工具输出格式变化？），跳过"
elif [ -z "${COV_MIN_LINES:-}" ]; then
	echo "阈值判定：行覆盖 ${cov_pct}%（未设 COV_MIN_LINES，只报告不判定）"
elif awk -v got="$cov_pct" -v min="$COV_MIN_LINES" 'BEGIN { exit (got + 0 >= min + 0) ? 0 : 1 }'; then
	echo "阈值判定：行覆盖 ${cov_pct}% ≥ COV_MIN_LINES=${COV_MIN_LINES}% 通过"
else
	echo "阈值判定：行覆盖 ${cov_pct}% < COV_MIN_LINES=${COV_MIN_LINES}%（覆盖率倒退）" >&2
	exit 1
fi
