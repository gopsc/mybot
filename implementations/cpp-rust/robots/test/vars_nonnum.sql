/*
 * @Vars 仅支持 Number 回归（负值）：value 列为 String 时解析器不管，但 @Vars
 * 自身在注册期强制数值校验 → 非数值清晰报错、退出非 0。
 * 用法：cat scripts/test/vars_nonnum.mt | ./build/mybot --robot=robots/test/vars_nonnum.sql
 * 期望退出码非 0，输出含 "neither a Number"
 */
CREATE TABLE Vars (
	name  String,
	value String
);
INSERT INTO Vars (name, value) VALUES ('spd', fast);
