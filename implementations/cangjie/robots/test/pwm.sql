/*
 * PWM 硬件脉宽调制测试（配套 pwm.mt）
 * 用法：cat scripts/test/pwm.mt | bash _run.sh --robot=robots/test/pwm.sql
 *
 * 实机前提：
 *   1) 启用硬件 PWM：/boot/firmware/config.txt 加 dtoverlay=pwm（或 pwm-2chan），
 *      具体引脚与功能编号查 /boot/overlays/README
 *   2) 出现 /sys/class/pwm/pwmchip0，且当前用户有写权限（root 或 pwm 组）
 *   3) 目标引脚未被 gpiod 占用——同一脚的 gpiod 与 PWM 功能复用互斥
 * 无 PWM 控制器时 build 返回 ERR，halt-on-error 会中止动作并 exit 1，
 * 可借这条负路径快速确认错误通道是否打通。
 *
 * 纯 Lua 离线测试（mock sysfs，不触硬件）见 test/test_pwm.lua。
 */
CREATE TABLE PWM (
	name      String,
	chip      String,
	channel   String,
	frequency String,
	duty      String,
	invert    String
);
INSERT INTO PWM (name, chip, channel, frequency, duty, invert)
  VALUES ('pwm0', '0', '1', '20000', '0', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');
