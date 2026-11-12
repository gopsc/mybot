/*
 * 最小结构脚本：仅一个 dummy 设备，用于驱动层联调
 * 用法：cat test/xxx.mt | ./bot --robot=robots/test.sql
 */

/* dummy：空驱动矩阵，pp1 为透传参数（"-" 表示未设置） */
CREATE TABLE dummy (
	name String,
	pp1  String
);
INSERT INTO dummy (name, pp1) VALUES (d1, -);
