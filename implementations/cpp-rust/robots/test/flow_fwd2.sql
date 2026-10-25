/* controller 多列负值：controller2 同样受「先声明」约束 */
CREATE TABLE dummy (
	name        String,
	controller  String,
	controller2 String
);
INSERT INTO dummy (name, controller, controller2) VALUES ('x0', '-', 'later0');
INSERT INTO dummy (name, controller, controller2) VALUES ('later0', '-', '-');
