/*
 * $ 引用列成环回归（负值契约，修复 C1）：
 * mon0.src=$mon1 且 mon1.src=$mon0（互相引用，等价于自引用 $mon0）。
 * 修复前 collect() → read() → getMetadata_() → collect() 无限互递归，
 * 主线程栈溢出 SIGSEGV 裸崩；修复后达到引用深度上限即清晰报错退出非 0。
 *
 * 用法：cat scripts/test/ref_cycle.mt | ./build/mybot --robot=robots/test/ref_cycle.sql
 * 期望退出码非 0，输出含 "circular '$' reference"
 */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$mon1');
INSERT INTO Monitor (name, src) VALUES ('mon1', '$mon0');
