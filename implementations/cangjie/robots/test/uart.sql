/*
 * UART 串口总线测试（配套 uart.mt）
 * 生命周期验证：build 打开串口（raw 8N1 + 波特率）-> call 回读 fd -> destroy 关闭
 * 无设备也可跑：打开空置串口或 USB 转串口即验证 open/termios/close 链路
 */
CREATE TABLE UART (
	name String,
	path String,
	baud String
);
INSERT INTO UART (name, path, baud) VALUES ('uart-0', '/dev/serial0', '9600');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');
