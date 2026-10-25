/*
 * N-5 会话覆盖 × $ 引用列交叉回归：
 * 结构 @Vars 定义 tv=200，Relay 的 note 列引用 $tv；
 * 动作脚本用 @Alias 覆盖 tv（会话期覆盖仅改名字索引，结构变量仍在销毁序）。
 * $ 引用在 seed 期（build 前）锁定目标指针——collect/destroy 都取结构期
 * Vars 快照，note=200。修复前 collect 按名重查会解析到别名（标量），
 * play 期抛 "referenced variable returned a non-object"、退出 1。
 *
 * 用法：cat scripts/test/ref_override.mt | ./build/mybot --robot=robots/test/ref_override.sql
 * 期望退出码 0，输出含 "note=200"
 */
CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES ('tv', 200);

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', '$tv');
