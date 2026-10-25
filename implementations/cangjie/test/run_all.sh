#!/bin/bash
# bot4cj Lua 离线测试统一入口
# 用法: bash test/run_all.sh [测试名过滤]
#   例: bash test/run_all.sh                # 跑全部
#       bash test/run_all.sh pca9685       # 只跑文件名含 pca9685 的
# 说明：
#   - 统一用 luajit 运行（HAL 依赖 ffi）；可用环境变量 LUACMD 覆盖解释器
#   - 单测超时 TEST_TIMEOUT 秒（默认 60，需 coreutils timeout；缺失则不限时）——
#     防单个用例死循环挂死整个入口
#   - test_jit_warmup.lua 是真机 ABI 回归测试（需 /dev/i2c-*），无总线环境自动跳过
#   - test_ioctl_nums.c 为 C 编译期常量自检，不在本入口范围
cd "$(dirname "$0")/.." || exit 1

LUACMD="${LUACMD:-luajit}"
if ! command -v "$LUACMD" >/dev/null 2>&1; then
	echo "未找到解释器：$LUACMD"
	echo "HAL 依赖 ffi，请安装 LuaJIT：sudo apt install luajit"
	echo "（或 LUACMD=lua5.4 只跑纯 Lua 用例，HAL 相关用例会失败）"
	exit 1
fi

TEST_TIMEOUT="${TEST_TIMEOUT:-60}"
timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
	timeout_cmd="timeout $TEST_TIMEOUT"
fi

filter="${1:-}"
pass=0
fail=0
failed=""

for t in test/test_*.lua; do
	name="$(basename "$t")"
	if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
		continue
	fi
	# 真机测试：文件内声明 "-- requires: i2c" 且本机无 /dev/i2c-* 时跳过
	if grep -q '^\-\- requires: i2c' "$t" && ! ls /dev/i2c-* >/dev/null 2>&1; then
		echo "----- $name -----"
		echo "[SKIP] 需要 /dev/i2c-* 真机总线（文件标记 -- requires: i2c），本机无 i2c，跳过"
		continue
	fi
	echo "----- $name -----"
	out="$($timeout_cmd "$LUACMD" "$t" 2>&1)"
	rc=$?
	echo "$out"
	# 兼容两种失败约定：退出码非零，或打印 [FAIL] 行（124 = timeout 超时）
	if [ $rc -eq 124 ] && [ -n "$timeout_cmd" ]; then
		echo "[FAIL] 用例超时（>${TEST_TIMEOUT}s，疑似死循环）"
		fail=$((fail + 1))
		failed="$failed $name"
	elif [ $rc -ne 0 ] || echo "$out" | grep -qF "[FAIL]"; then
		fail=$((fail + 1))
		failed="$failed $name"
	else
		pass=$((pass + 1))
	fi
done

echo "==============================================="

# ======================================================================
# 仓颉级无硬件端到端：编译产物 + 仓颉 runtime 齐备才跑，缺失则跳过
# （纯 Lua 环境/CI 无 cjc 时不阻断回归）。用例走真实 bot4cj 二进制：
# 守护线程→共享槽→Ema→Monitor 全链路，I2C/SPI 器件均为内存仿真模型。
#
# 用例表：用例名|raw 快照浮点断言 ERE（证明 :f 字段未被取整）|count 下限。
# EMA 混合断言对所有用例通用：某拍 monf 行内 out ≠ raw（滤波确实推进）。
# ======================================================================
bin="target/release/bin/main"
e2e_cases=(
	'mpu_virt|"v6":41\.[0-9]+|10'
	'bme280_virt|"v0":2[0-9]\.[0-9]+|10'
	'ads1256_virt|"v1":[0-2]\.[0-9]+|10'
	'vl53l0x_virt|"v0":[0-9]+\.[0-9]+|10'
	'vl53l4cd_virt|"v0":[0-9]+\.[0-9]+|10'
	'sht3x_virt|"v0":2[0-9]\.[0-9]+|10'
	'mcp3421_virt|"v0":-?[0-9]+\.[0-9]+|10'
	'ms5611_virt|"v0":10[01][0-9]\.[0-9]+|10'
	'sgp30_virt|"v0":[4-7][0-9][0-9]\.[0-9]+|10'
	'ina219_virt|"v0":1[12]\.[0-9]+|10'
	'ads1115_virt|"v0":1\.[0-9]+|10'
	# AS7262 raw 六通道是无符号整数计数（:f 透传无小数），浮点断言锚定 monf
	# 行 Ema 对 V 计数的 α 混合输出 out（必为带小数浮点）
	'as7262_virt|"out":[0-9]+\.[0-9]+|10'
	# MAX30102 raw IR/RED 同为无符号 18 位整数计数，浮点断言锚定 monf 行
	# Ema 对 IR 计数的 α 混合输出 out（必为带小数浮点）
	'max30102_virt|"out":[0-9]+\.[0-9]+|10'
	# AMG8833 raw MAXR/MAXC 是整数行列，浮点断言锚定 monf 行 Ema 对
	# AVGT 平均温度的 α 混合输出 out（必为带小数浮点）
	'amg8833_virt|"out":[0-9]+\.[0-9]+|10'
	# PCF8574 raw PINS/OUT 是无符号 8 位整数引脚码（:f 透传无小数），
	# 浮点断言锚定 monf 行 Ema 对 PINS walking 位码的 α 混合输出 out
	'pcf8574_virt|"out":[0-9]+\.[0-9]+|10'
	# LTC2944 raw 四字段均 :f 浮点；v0=CHARGE/v1=V/v2=I/v3=T，锚定 v1
	# 母线电压正弦（11.6~12.4V，带小数即证明未被 sign=16 取整）
	'ltc2944_virt|"v1":1[12]\.[0-9]+|10'
	# CHT8305 raw 两字段均 :f 浮点；v0=T（20~30°C 正弦）/v1=H（40~60%RH
	# 反相），锚定 v0 温度（带小数即证明未被 sign=16 取整）
	'cht8305_virt|"v0":2[0-9]\.[0-9]+|10'
	# ADS1015 raw 单字段 voltage:f（12 位左对齐孪生，V=raw12*FS/2048），
	# AIN0 正弦 1.40~1.90V，锚定 v0（带小数即证明未被 sign=16 取整）
	'ads1015_virt|"v0":1\.[0-9]+|10'
	# INA226 raw 三字段均 :f 浮点；v0=V/v1=I/v2=P（总线 16 位无移位
	# 1.25mV、分流 2.5µV 全软件换算），锚定 v0 母线电压正弦（11.6~12.4V）
	'ina226_virt|"v0":1[12]\.[0-9]+|10'
	# INA3221 raw 六字段均 :f 浮点；v0=V1/v1=I1/v2=V2/v3=I2/v4=V3/v5=I3
	# （三通道 13 位 <<3：总线 8mV、分流 40µV 全软件换算），锚定 v0 的
	# ch1 母线电压正弦（11.6~12.4V）
	'ina3221_virt|"v0":1[12]\.[0-9]+|10'
	# MAX17043 raw 两字段均 :f 浮点；v0=VCELL（12 位 <<4、1.25mV 全软件
	# 换算，3.60~4.10V 锂电正弦）/v1=SOC（1/256% 定点），锚定 v0
	'max17043_virt|"v0":[34]\.[0-9]+|10'
	# ADXL345 raw 三轴均 sign='16' 展开的有符号整数码（无 :f 字段），
	# 浮点断言锚定 monf 行 Ema 对 ACCEL_X 正弦码（±77，含负值）的 α 混合 out
	'adxl345_virt|"out":-?[0-9]+\.[0-9]+|10'
	# LPS22HB raw 两字段均 :f 浮点；v0=P（24 位小端/4096，1008.25~1018.25hPa
	# 海平面正弦）/v1=T（16 位小端/100，20~24°C），锚定 v0 气压（带小数即
	# 证明未被 sign=16 取整）
	'lps22hb_virt|"v0":10[01][0-9]\.[0-9]+|10'
)

run_one_e2e() {
	local name="$1" float_ere="$2" count_min="$3"
	echo "----- $name (仓颉 E2E) -----"
	if [ ! -x "$bin" ]; then
		echo "[SKIP] 无编译产物 $bin（执行 bash _set.sh 后可跑无硬件端到端）"
		return 2
	fi
	# 动作时长约 1s，给 30s 上限防挂死；_run.sh 退出码原样透传
	if [ -n "$timeout_cmd" ]; then
		out="$(cat "scripts/test/$name.mt" | timeout 30 bash _run.sh --robot="robots/test/$name.sql" 2>&1)"
	else
		out="$(cat "scripts/test/$name.mt" | bash _run.sh --robot="robots/test/$name.sql" 2>&1)"
	fi
	local rc=$?
	echo "$out"
	local e2e_ok=true
	[ $rc -ne 0 ] && e2e_ok=false
	echo "$out" | grep -qF "VIRTUAL HARDWARE" || e2e_ok=false
	echo "$out" | grep -qE "chunk setup error|chunk load error|setup failed|tick error|cleanup error|解析失败" \
		&& e2e_ok=false
	echo "$out" | grep -qF "joined, total publishes=" || e2e_ok=false
	# 守护持续发布：出现 ≥2 个不同 count 且最大值达标
	local count_max count_uniq
	count_max="$(echo "$out" | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)"
	count_uniq="$(echo "$out" | grep -oE '"count":[0-9]+' | sort -u | wc -l)"
	{ [ -z "$count_max" ] || [ "$count_max" -lt "$count_min" ] || [ "$count_uniq" -lt 2 ]; } && e2e_ok=false
	# raw 快照里 :f 浮点字段保持小数（未被 sign=16 取整补码）
	echo "$out" | grep -qE "$float_ere" || e2e_ok=false
	# EMA 已推进：至少一行 monf 快照 out ≠ raw（首拍种子相同，后续 α 混合必不同）。
	# JSON 键序不固定，逐行各自提取 out/raw 数值做比对。
	local mixed_n=0 o r
	while IFS= read -r line; do
		o="$(printf '%s' "$line" | grep -oE '"out":-?[0-9]+(\.[0-9]+)?' | head -1 | cut -d: -f2)"
		r="$(printf '%s' "$line" | grep -oE '"raw":-?[0-9]+(\.[0-9]+)?' | head -1 | cut -d: -f2)"
		if [ -n "$o" ] && [ -n "$r" ] && [ "$o" != "$r" ]; then
			mixed_n=$((mixed_n + 1))
		fi
	done < <(printf '%s' "$out" | grep -F '"raw"')
	[ "$mixed_n" -ge 1 ] || e2e_ok=false
	if $e2e_ok; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		failed="$failed $name(E2E)"
	fi
}

if ! command -v cjc >/dev/null 2>&1 && [ -z "$CANGJIE_HOME" ] && [ ! -d "$HOME/cangjie" ]; then
	for spec in "${e2e_cases[@]}"; do
		name="${spec%%|*}"
		if [ -z "$filter" ] || [[ "$name" == *"$filter"* ]]; then
			echo "----- $name (仓颉 E2E) -----"
			echo "[SKIP] 无仓颉 runtime（需 cjc 在 PATH、设置 CANGJIE_HOME，或存在 ~/cangjie）"
		fi
	done
else
	[ -z "$CANGJIE_HOME" ] && [ -d "$HOME/cangjie" ] && export CANGJIE_HOME="$HOME/cangjie"
	for spec in "${e2e_cases[@]}"; do
		name="${spec%%|*}"
		rest="${spec#*|}"
		float_ere="${rest%%|*}"
		count_min="${rest##*|}"
		if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
			continue
		fi
		run_one_e2e "$name" "$float_ere" "$count_min"
	done
fi


# 空匹配防线：过滤器拼错时 0 通过 0 失败不得假绿
if [ $((pass + fail)) -eq 0 ]; then
	echo "汇总: 无匹配用例（过滤器 '${filter}' 未命中任何 test/test_*.lua 或仓颉 E2E，请检查拼写）"
	exit 1
fi
echo "汇总: $pass 通过, $fail 失败"
if [ $fail -ne 0 ]; then
	echo "失败用例:$failed"
	exit 1
fi
