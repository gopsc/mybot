/*
 * Number 列类型回归（正值）：CREATE TABLE 支持 Number 列，解析期对字面量做一次
 * 数值校验；值仍按文本驻留（运行期不做类型转换）。
 * 用法：cat scripts/test/number_type.mt | ./build/mybot --robot=robots/test/number_type.sql
 */
CREATE TABLE Timer (
	name  String,
	delay Number
);
INSERT INTO Timer (name, delay) VALUES ('timer-0', 50);

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-number');
