/*
 * 继电器测试结构脚本
 * 用法：cat test/xxx.mt | ./bot --robot=robots/relay-test.sql
 */

/* Timer：时基矩阵，Relay 挂载其下 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

/* Relay：note 字段为透传标记（这里是联调标识 'hello-relay'） */
CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-relay');
