# test/lib/case_table.awk —— 用例表 tokenizer（run_all_selftest.sh 第 5 段的 B 侧实现）
#
# 输入：run_all.sh 里一张用例表的整块文本（含 `name=(` 首行与 `)` 末行），从 stdin 读。
# 输出：每个数组元素一行，**去掉外层引号**，元素内部的引号原样保留。
# 退出码：0 正常；1 = 有引号未收尾，或某条双引号元素里含展开语法（见下）。
#
# 为什么逐字符走而不是按行 grep：表里的条目有两种引号形态——expect 字段本身含单引号
# 时整条改用双引号书写（run_all.sh 的 vars_bad 行，约定见「fixture 孤儿检测」段注释）。
# 只认单引号的抽取会漏掉这一条，而条数检查点一旦是手写的，就会把这个盲区钉成「正确值」：
# 2026-10-06 实测 bash 展开 parse_cases 得 97 条、旧抽取只看见 96 条，而检查点写的正是
# 96——那条用例的字段数 / 引号收尾 / (sql,mt) 重复三项检查全部落空，且「修好抽取器」
# 反而会让自检转红。
#
# 引号语义按 bash 复刻：单引号内不认任何转义；双引号内认反斜杠转义；元素之外的 '#'
# 起注释直到行尾。调用方须传 SQ / DQ 两个变量（本文件刻意不写引号字面量，免得 awk
# 程序里出现引号地狱）。
#
# 双引号元素若含 '$' 或反引号，bash 会展开而本 tokenizer 只会按字面输出，两侧的「元素
# 正文」就不再是同一个东西（字段判据会失真）——这种条目直接判失败，不猜展开结果。
# 单引号元素无此问题，含单引号的 expect 请写成双引号条目并保持无展开语法。
#
# 元素正文若含换行（bash 允许跨行引号），本文件会把它打成多行，于是 A 侧行计数与
# B 侧元素数不等而判失败——字段判据是按行做的，这是刻意的不容忍。

BEGIN { st = 0; buf = ""; has_exp = 0; bad = 0 }
{
	L = length($0)
	i = 1
	while (i <= L) {
		c = substr($0, i, 1)
		if (st == 0) {
			if (c == "#") { i = L + 1; continue }
			if (c == SQ) { st = 1; buf = "" }
			else if (c == DQ) { st = 2; buf = ""; has_exp = 0 }
		} else if (st == 1) {
			if (c == SQ) { st = 0; print buf }
			else buf = buf c
		} else {
			if (c == "\\") { buf = buf substr($0, i + 1, 1); i += 2; continue }
			if (c == DQ) {
				st = 0
				if (has_exp) {
					printf "case_table.awk: 第 %d 行的双引号条目含 $ 或反引号，bash 会展开而本 tokenizer 按字面解析（判据会失真）：%s\n", NR, buf > "/dev/stderr"
					bad = 1
				}
				print buf
			} else {
				if (c == "$" || c == "`") has_exp = 1
				buf = buf c
			}
		}
		i++
	}
	if (st != 0) {
		printf "case_table.awk: 第 %d 行有引号未收尾（bash 会从这里一路吞到文件尾，后续条目全部消失）\n", NR > "/dev/stderr"
		bad = 1
		st = 0
		buf = ""
	}
}
END { exit bad }
