/* trigger 负值：框架保留键不能当触发器名（结果子表会和框架键易主/被吞） */
CREATE TABLE dummy (
	name    String,
	trigger String
);
INSERT INTO dummy (name, trigger) VALUES ('sink0', 'mode');
