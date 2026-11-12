/*
 * SCSCL 无硬件负值：站号 0 非法（合法 1~253）——build 期即报错退出，
 * 不触总线。守门断言 rc=1 且输出含 "Invalid Argument: id"。
 * 用法：cat scripts/test/scscl_badid.mt | ./build/mybot --robot=robots/test/scscl_badid.sql
 */
CREATE TABLE UART (
	name  String,
	path  String,
	baud  String,
	proto String
);
INSERT INTO UART (name, path, baud, proto)
  VALUES ('uart-0', '/dev/serial9', '1000000', 'virt');

CREATE TABLE SCSCL (
	name   String,
	UART   String,
	id     String,
	proto  String
);
INSERT INTO SCSCL (name, UART, id, proto)
  VALUES ('s1', '$uart-0', '0', 'virt');
