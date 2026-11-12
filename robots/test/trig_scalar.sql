/* trigger 负值：@Vars 标量不能当触发目标（触发器经 play 调用、必须返回结果表） */
CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES ('v1', 10);

CREATE TABLE dummy (
	name    String,
	trigger String
);
INSERT INTO dummy (name, trigger) VALUES ('sink0', 'v1');
