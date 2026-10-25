/*
 * SCSCL 真机烧号脚本：先只接目标舵机（广播 0xFE 会命中总线上所有舵机）。
 * allow_burn=1 是审计 H-3 防线的结构期授权列：set_id 烧号为不可逆持久化
 * 硬件写，必须由结构脚本显式授权，动作脚本（--tcp 下可远程提交）无法旁路。
 */
CREATE TABLE UART (name String, path String, baud String);
INSERT INTO UART (name, path, baud) VALUES ('uart-0', '/dev/ttyS0', '1000000');
CREATE TABLE SCSCL (
  name String, UART String, id String, max String, min String, offset String,
  allow_burn String
);
INSERT INTO SCSCL (name, UART, id, max, min, offset, allow_burn)
  VALUES ('scs1', '$uart-0', '1', '1023', '0', '0', '1');
