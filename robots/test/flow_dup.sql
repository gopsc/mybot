/* trigger 多列负值：同一行两个触发列指向同一目标——扇出语义下只会双调用 */
CREATE TABLE dummy (
	name     String,
	trigger  String,
	trigger2 String
);
INSERT INTO dummy (name, trigger, trigger2) VALUES ('trig0', '-', '-');
INSERT INTO dummy (name, trigger, trigger2) VALUES ('sink0', 'trig0', 'trig0');
