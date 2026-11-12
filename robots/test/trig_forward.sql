/* trigger 负值：被引用方必须先声明（与 controller 同规则） */
CREATE TABLE dummy (
	name    String,
	trigger String
);
INSERT INTO dummy (name, trigger) VALUES ('sink0', 'trig-later');
INSERT INTO dummy (name, trigger) VALUES ('trig-later', '-');
