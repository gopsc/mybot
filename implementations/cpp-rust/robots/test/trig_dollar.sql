/* trigger 负值：trigger 是调用编排边，不接受 $ 数据引用写法 */
CREATE TABLE dummy (
	name    String,
	trigger String
);
INSERT INTO dummy (name, trigger) VALUES ('trig0', '-');
INSERT INTO dummy (name, trigger) VALUES ('sink0', '$trig0');
