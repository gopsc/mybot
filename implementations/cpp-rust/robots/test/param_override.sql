/*
 * 负值契约（审计 #1）：@Action 的列名 <设备>.<参数> 中，参数名不得与结构脚本
 * 的元数据列同名。
 *
 * 动作参数与结构元数据最终被合并成同一张 Lua 表交给驱动 call()，若不设限，
 * .mt 里写一列 relay0.note（乃至 fd / address / max / min / offset）就能覆盖
 * 结构脚本的定义——在 --tcp 模式下等价于远程改写总线句柄与舵机限幅。
 * 收口语义：结构元数据由 .sql 独占，.mt 只能引入新的参数键。
 *
 * 期望：清晰报错、退出码非 0（而非静默按覆盖后的值执行）。
 * 用法：cat scripts/test/param_override.mt | ./build/mybot --robot=robots/test/param_override.sql
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-relay');
