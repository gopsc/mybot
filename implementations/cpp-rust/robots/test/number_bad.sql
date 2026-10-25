/*
 * Number 列类型回归（负值）：Number 列写入非数值字面量，解析期即清晰报错，
 * 绝不把 'abc' 当字符串静默传给驱动。
 * 用法：cat scripts/test/number_bad.mt | ./build/mybot --robot=robots/test/number_bad.sql
 * 期望退出码非 0，输出含 "declared Number"
 */
CREATE TABLE Timer (
	name  String,
	delay Number
);
INSERT INTO Timer (name, delay) VALUES ('timer-0', abc);
