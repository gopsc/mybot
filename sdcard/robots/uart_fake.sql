/* P3-C: UART self-check on fake UART (no hardware) */
CREATE TABLE UART (name String, path String, baud String);
INSERT INTO UART (name, path, baud)
  VALUES ('uart-f', '/dev/tty-fake', '115200');

CREATE TABLE UartCheck (name String, UART String);
INSERT INTO UartCheck (name, UART) VALUES ('uc', '$uart-f');
