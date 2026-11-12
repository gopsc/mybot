/* trigger 多列负值：trigger2 同样拒绝标量目标 */
CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES ('v1', 10);

CREATE TABLE dummy (
	name     String,
	trigger  String,
	trigger2 String
);
INSERT INTO dummy (name, trigger, trigger2) VALUES ('x0', '-', 'v1');
