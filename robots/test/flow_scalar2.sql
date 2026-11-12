/* controller 多列负值：@Vars 标量不能当 controller 目标（装配期拒绝） */
CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES ('v1', 10);

CREATE TABLE dummy (
	name        String,
	controller  String,
	controller2 String
);
INSERT INTO dummy (name, controller, controller2) VALUES ('x0', '-', 'v1');
