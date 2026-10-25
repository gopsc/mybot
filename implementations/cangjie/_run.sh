#!/bin/bash
cd "$(dirname "$0")" || exit
export cjStackSize=64MB
# 堆不可压到 64MB：controller 转发（嵌套 play）路径在小堆高频 GC 下会触发
# 悬空引用段错误（0.3.2 真机回归：walk-fl.mt 必崩于 22~30 行，现场为
# managed 对象字段读取野指针；64MB 堆 5~6/6 崩，默认堆/512MB 0/12 崩，
# 无转发路径同体积分配不崩——判别实验见 CHANGELOG 0.3.2）。
# 默认取 128MB：CHANGELOG 建议的 512MB 在 512MB 内存的板子（如 CM0）上会 OOM，
# 128MB 为折中值（该中间值尚未经 A/B 验证；仍崩可用 cjHeapSize=256MB 覆盖）
export cjHeapSize="${cjHeapSize:-128MB}"

# 长脚本模式（BOT4CJ_NO_GC=1）：关闭 GC。
# 根因（0.3.3 复盘，gdb 实证）：仓颉 1.1.3 并发复制 GC（WCollector）在高分配
# 速率 mutator 下存在运行时缺陷——GC 线程 ForwardFromSpace 搬移对象时，用户线程
# 可卡死在 PreforwardBarrier::ReadReference/TryForwardObject 读屏障内（活锁，
# CPU 100%），或读到未转发旧引用（SIGSEGV/managed 野指针）、或容器内部状态被
# 并发搬移破坏（ConcurrentModificationException / IndexOutOfBounds size:-1）。
# controller 转发路径因 payload 双重浅拷贝使分配速率翻倍而优先暴露；
# 实测 >800 行长脚本默认堆下失败率 50%+，且与堆大小（64/128/512MB）无关。
# cjEnableGC=0 下同脚本 6/6 全过（验证实验见 CHANGELOG 0.3.3）。
# 适用：一次性执行的动作脚本（进程退出由 OS 回收内存，分配量 ~行数×20KB，
# 千行级脚本 RSS <100MB，安全）。不适用：--tcp 长驻模式（会无限增长直至 OOM）。
if [ "${BOT4CJ_NO_GC:-0}" = "1" ]; then
	export cjEnableGC=0
fi

# M3: cjpm run 恒返回 0，会吞掉程序 abort 的退出码，故直跑产物并把退出码原样透传。
# 运行时库路径按当前架构选择（x86_64 / aarch64），与 cjpm.toml 的 target 声明一致
base=$(cd "$(dirname "$0")" && pwd)
# POSIX 可移植写法（find -printf 为 GNU 扩展）：取 .so 所在目录去重后以 : 连接
ldp=$(find "$base/target/release" -maxdepth 2 -name "*.so" 2>/dev/null | while IFS= read -r so; do dirname "$so"; done | sort -u | paste -sd: -)
crjarch="x86_64"
case "$(uname -m)" in
	aarch64|arm64) crjarch="aarch64" ;;
esac
if [ -n "$CANGJIE_HOME" ]; then
	rt="$CANGJIE_HOME/runtime/lib/linux_${crjarch}_cjnative"
else
	cjc_path="$(command -v cjc 2>/dev/null)"
	if [ -z "$cjc_path" ]; then
		echo "未找到 cjc 编译器，请设置 CANGJIE_HOME 环境变量或将 cjc 加入 PATH" >&2
		exit 1
	fi
	rt="$(dirname "$(dirname "$cjc_path")")/runtime/lib/linux_${crjarch}_cjnative"
fi
# 拼接 LD_LIBRARY_PATH：ldp 或 rt 为空时跳过，避免空项等价于把当前目录纳入库搜索路径
ldpath=""
[ -n "$ldp" ] && ldpath="$ldp"
[ -n "$rt" ]  && ldpath="${ldpath:+$ldpath:}$rt"
export LD_LIBRARY_PATH="$ldpath"

bin="$base/target/release/bin/main"
if [ ! -x "$bin" ]; then
	echo "未找到编译产物 target/release/bin/main，请先执行 bash _set.sh 构建" >&2
	exit 1
fi
# 源码新于产物：提醒可能跑的是过期二进制（行为与文档/最新修复不一致的常见原因）
stale=$(find "$base/src" -name "*.cj" -newer "$bin" -print -quit 2>/dev/null)
if [ -n "$stale" ]; then
	echo "警告: src/ 源码比编译产物新（${stale#$base/}），当前运行的可能是过期二进制；建议先执行 bash _set.sh" >&2
fi
exec "$bin" "$@"
