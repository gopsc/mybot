/*
 * GPIO gpiod uAPI 测试（配套 gpio.mt）
 * 输出（led-0 点闪）+ 输入（sw-0 轮询读）双路径
 * 偏移为控制器线号（Pi 上即 BCM 号）；Pi 5 主 GPIO 在 /dev/gpiochip4
 * 注意：offset 列勿写 '-'（占位符归一为 0 会误用 0 号线）
 */
CREATE TABLE GPIO (
	name      String,
	chip      String,
	offset    String,
	direction String,
	active    String,
	init      String
);
INSERT INTO GPIO (name, chip, offset, direction, active, init)
  VALUES ('led-0', '/dev/gpiochip0', '17', 'out', 'high', '0');
INSERT INTO GPIO (name, chip, offset, direction, active, init)
  VALUES ('sw-0', '/dev/gpiochip0', '27', 'in', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');
