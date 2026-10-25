/* trigger 负值：触发器名与本表元数据列同名——结果子表按触发器名并入调用
 * 参数，同名列会被易主，装配期拒绝 */
CREATE TABLE dummy (
	name    String,
	trigger String,
	note    String
);
INSERT INTO dummy (name, trigger, note) VALUES ('note', '-', '-');
INSERT INTO dummy (name, trigger, note) VALUES ('sink0', 'note', 'x');
