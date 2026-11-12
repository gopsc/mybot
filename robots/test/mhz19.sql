/*
 * MH-Z19B NDIR CO₂ 传感器测试（配套 mhz19.mt）
 * 直连变量（co2-0）单次读 + 万能守护（co2-d0）连续采样双路径；
 * 守护走 sensor_daemon 的 proto=uart 分支（baud 列透传 uart_open）
 */
CREATE TABLE UART (
	name String,
	path String,
	baud String
);
INSERT INTO UART (name, path, baud) VALUES ('uart-0', '/dev/serial0', '9600');

/* MH-Z19：9600 8N1 固定；预热约 3 分钟后读数稳定；量程 400~5000ppm */
CREATE TABLE MHZ19 (
	name String,
	UART String
);
INSERT INTO MHZ19 (name, UART) VALUES ('co2-0', '$uart-0');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：单字段 CO2（整数 ppm）；MH-Z19 请求-应答周期约 100ms，
 * interval 1s 足够宽裕 */
CREATE TABLE Daemon (
	name     String,
	chunk    String,
	driver   String,
	proto    String,
	path     String,
	baud     String,
	interval String,
	fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, baud, interval, fields)
  VALUES ('co2-d0', 'lib/sensor_daemon.lua', 'MHZ19', 'uart', '/dev/serial0', '9600', '1000',
          'CO2');
