/* controller 多列负值：同一行两个转发列指向同一目标——同 payload 双转发 */
CREATE TABLE dummy (
	name        String,
	controller  String,
	controller2 String
);
INSERT INTO dummy (name, controller, controller2) VALUES ('c-0', '-', '-');
INSERT INTO dummy (name, controller, controller2) VALUES ('x0', 'c-0', 'c-0');
