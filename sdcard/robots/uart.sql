/* P3-C: UART1 on real pins (TX GP8 / RX GP9) */
CREATE TABLE UART (name String, path String, baud String);
INSERT INTO UART (name, path, baud)
  VALUES ('uart-1', '/dev/ttyS1', '115200');

CREATE TABLE UartCheck (name String, UART String);
INSERT INTO UartCheck (name, UART) VALUES ('uc', '$uart-1');
