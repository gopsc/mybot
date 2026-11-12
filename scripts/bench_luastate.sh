#!/bin/bash
# bench_luastate.sh —— 「每硬件变量一个 lua_State」模型的成本基准（C1，2026-09-25）
#
# 背景：MtVars_Lua 给每个 Lua 驱动变量开一个独立 LuaJIT 态（luavar.cpp），
# spider1 这类结构是 PCA9685 + 14 Servo + 守护 ≈ 15+ 个态。本基准量化它的
# 固定成本，供「懒建态 / 只读 chunk 缓存 / env 共享」的档位决策用数据说话。
#
# 方法：生成一个无硬件基准驱动 BenchDrv.lua，其前奏**逐字复刻**真实驱动的
# 标准加载（SHT3X.lua 同款四行：HAL + print_table + drv_common + bitcompat，
# 全走 mpath 解析），build/call/destroy 空操作——每个变量量到的就是固定成本：
# 沙箱态建立 + 四份 lib 的编译与装载（JIT 预热不计入：空操作不产生热轨迹）。
# 扫 N ∈ 0/1/2/5/10/20/40，N=0 是 Alias 纯标量基线（零 lua_State），相邻差值
# 即每变量边际成本。测量取 getrusage(RUSAGE_CHILDREN).ru_maxrss（峰值 RSS，
# KiB）与全链墙钟（解析 + 装配 + build + @Action + destroy）。
#
# 用法: bash scripts/bench_luastate.sh [BOT 路径]（缺省 ./build/mybot）
#   BOT=./build/mybot bash scripts/bench_luastate.sh
# 输出仅打印，不做守门判据（基准数字进守门会抖）。
#
# 实测结论（2026-09-25，本机 i7/NVMe，.median of 3）：
#   墙钟 ≈ 1.45 ms/变量（N=100 → 146ms、N=200 → 287ms，线性极佳）；
#   峰值 RSS ≈ 170~200 KiB/变量（N=100 → +16.3 MiB、N=200 → +39.6 MiB；
#   N≤20 的行差被基线抖动/页量化淹没，读小 N 时看趋势别看单行）。
#   即 spider1 量级（15+ 变量）≈ +3 MiB / +22ms——现行模型便宜且线性，
#   结论：**维持每变量一态**；只有当结构脚本规模到数百变量（RSS 数十 MiB、
#   装配数百 ms）时才值得回来做 chunk 缓存/懒建态（本基准即复测工具）。
set -u

BOT="${1:-${BOT:-./build/mybot}}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
if [ ! -x "$BOT" ]; then
	echo "找不到可执行文件: $BOT（先 cmake --build build）" >&2
	exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/BenchDrv.lua" <<'LUA'
-- BenchDrv.lua —— lua_State 每变量模型的成本基准驱动（无硬件，C1 基准专用）
-- 前奏逐字复刻真实驱动的标准加载（SHT3X.lua 同款），build/call/destroy 全
-- 空操作——量的是「每变量一个 lua_State」的固定成本：沙箱态建立 + 四份
-- lib 的编译与装载。 BOT4CJ_MODULE_PATH 由基准脚本注入（modules:$tmp）。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))
local DEBUG = false

function build(data) return { result = "OK" } end
function call(data) return { result = "OK" } end
function destroy(data) return { result = "OK" } end
LUA

printf '@Action\nd0.call;\n     -;\n@\n' > "$tmp/one.mt"
printf '@Action\n@\n' > "$tmp/none.mt"

# 单次测量：打印 "<墙钟ms> <峰值RSS KiB>"；RUSAGE_CHILDREN 在每次独立
# python 进程里只含本孩子，ru_maxrss 不跨运行累积。
measure() { # $1=sql路径 $2=mt路径
	python3 - "$BOT" "$1" "$2" <<'PY'
import resource, subprocess, sys, time
bot, sql, mt = sys.argv[1], sys.argv[2], sys.argv[3]
mtb = open(mt, "rb").read()
t0 = time.monotonic()
p = subprocess.run([bot, "--robot=" + sql], input=mtb, capture_output=True)
dt = (time.monotonic() - t0) * 1000
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
if p.returncode != 0:
    sys.stderr.write(p.stderr.decode(errors="replace")[-1500:])
    sys.exit(1)
print(f"{dt:.0f} {rss}")
PY
}

# 中位数稳定化（RSS 受 ASLR/分配器抖动 ±200 KiB）：每个 N 跑 3 遍取中位数
median3() { # $1=sql $2=mt → "<中位ms> <中位rss>"
	python3 - "$@" <<'PY'
import sys
rows = sorted(float(x) for x in sys.argv[1:])
print(f"{rows[1]:.0f}")
PY
}

echo "N   墙钟ms  峰值RSS_KiB   (3 遍取中位；基线=N=0；行差≈每变量边际成本)"
fail=0
for n in 0 1 2 5 10 20 40 100; do
	sql="$tmp/bench_$n.sql"
	{
		echo "CREATE TABLE Alias (name String, alias String);"
		echo "INSERT INTO Alias (name, alias) VALUES (A, angle);"
		if [ "$n" -gt 0 ]; then
			echo "CREATE TABLE BenchDrv (name String, note String);"
			i=0
			while [ "$i" -lt "$n" ]; do
				printf "INSERT INTO BenchDrv (name, note) VALUES ('d%d', '-');\n" "$i"
				i=$((i + 1))
			done
		fi
	} > "$sql"
	mt="$tmp/none.mt"
	[ "$n" -gt 0 ] && mt="$tmp/one.mt"
	samples_ms=()
	samples_rss=()
	for rep in 1 2 3; do
		if out="$(BOT4CJ_MODULE_PATH="modules:$tmp" measure "$sql" "$mt")"; then
			samples_ms+=("$(printf '%s' "$out" | cut -d' ' -f1)")
			samples_rss+=("$(printf '%s' "$out" | cut -d' ' -f2)")
		else
			echo "  [FAIL] N=$n（mybot 退出非 0，stderr 已在上方）"
			fail=1
			break
		fi
	done
	[ "$fail" -ne 0 ] && break
	printf '%-3s %-8s %s\n' "$n" "$(median3 "${samples_ms[@]}")" "$(median3 "${samples_rss[@]}")"
done
exit "$fail"
