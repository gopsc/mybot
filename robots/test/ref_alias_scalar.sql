/*
 * 引用列 $ 指向标量（Alias）回归（负值契约）：
 * Alias 的读取结果是标量 JsonString（如 "42"），而 $ 引用列的语义是合并
 * 字段快照对象（v0..、status、count）。修复前 monitor 引用 $tv 会在 play 期
 * 抛 Json 类型崩溃（asObject called on the wrong Json kind=4）。
 * 修复后应给出清晰报错并退出非 0，绝不裸崩。
 *
 * 用法：cat scripts/test/ref_alias_scalar.mt | ./build/mybot --robot=robots/test/ref_alias_scalar.sql
 * 期望退出码非 0，输出含 "referenced variable returned a non-object"
 */
CREATE TABLE Alias (
	name  String,
	alias String
);
INSERT INTO Alias (name, alias) VALUES ('tv', '42');

CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$tv');