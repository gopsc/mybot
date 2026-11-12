/* trigger 负值（N-6）：被 trigger 引用的名字，动作脚本 @Alias 不得覆盖 */
CREATE TABLE dummy (
	name    String,
	trigger String
);
INSERT INTO dummy (name, trigger) VALUES ('trig0', '-');
INSERT INTO dummy (name, trigger) VALUES ('sink0', 'trig0');
