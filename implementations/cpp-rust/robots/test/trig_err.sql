/* trigger 负值：触发器返回 ERR 即整帧中断（Timer 缺 delay 参数必报 ERR） */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-bad');

CREATE TABLE Relay (
	name    String,
	trigger String,
	note    String
);
INSERT INTO Relay (name, trigger, note) VALUES ('relay-err', 'timer-bad', 'halt');
