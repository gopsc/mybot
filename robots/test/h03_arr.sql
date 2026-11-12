/*
 * H-03 修复验证：数组参数跨语言双向传输
 * arr_src 守护发布 {1.5,2.5,3.5,sin(t)}，h03 经 src 引用列拿到其 values(JsonArray) 快照；
 * 配合 h03_arr.mt 只调用一次 h03，验证：
 *   入参：metadata.values(JsonArray) → Lua 表（# 可测长、下标可取元素）
 *   出参：Lua 返回表 list → JsonArray（不再被 LUA_TTABLE 跳过）
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name  String,
	chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('arr_src', 'lib/daemon_probe.lua');

CREATE TABLE H03ARR (
	name String,
	src  String
);
INSERT INTO H03ARR (name, src) VALUES ('h03', '$arr_src');