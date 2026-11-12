/*
 * MCP4725 12 位 I2C DAC · 无硬件端到端（proto=virt，@Action 直写路径）
 *
 * 第二条【非守护】型 virt 用例（首条见 pca9685_virt.sql）：DAC 是被 @Action
 * 直接驱动的写路径器件，与 PCA9685 共用 drv_common 入口前置注入——总线行
 * （I2C）注入后自己的 i2c_open 即虚拟 open 并下发 fd，器件行采纳该 fd 并挂上
 * 内嵌模型 MCP4725_VIRT（modules/MCP4725.lua 尾部）。
 *
 * 本用例同时是「驱动入口走 arg_table」的回归：build/call 必须经 arg_table
 * （它代调 virt_prepare），否则直驱 virt 注入不触发、i2c_open 打到真实
 * /dev/i2c-99 响亮失败——2026-09-19 审计发现 27 个旧风格驱动绕过该钩子，
 * MCP4725/TPL0501 已迁移，本用例钉住 MCP4725 的直驱 virt 能力不再回退。
 *
 * 跑的是【真实】MCP4725.lua：build 在位读回（5 字节）、快速写 2 字节帧
 * （命令位嵌首字节高 3 位）、percent -> 码换算（50% -> 2048），
 * 全部由模型逐事务校验。
 *
 * 用法：cat scripts/test/mcp4725_virt.mt | ./build/mybot --robot=robots/test/mcp4725_virt.sql
 */
CREATE TABLE I2C (
	name  String,
	path  String,
	proto String
);
/* 故意用不存在但格式合法的总线号（pca9685_virt.sql 同款防线）：virt 前置
 * 一旦回归，真实 i2c_open 会失败并响亮报错，绝不在插了 DAC 的树莓派上真写。 */
INSERT INTO I2C (name, path, proto) VALUES ('i2c-v', '/dev/i2c-99', 'virt');

/* address 必须显式给：virt 挂载按它定位（'-' 会让 virt_prepare 拿不到 addr） */
CREATE TABLE MCP4725 (
	name    String,
	I2C     String,
	address String,
	vref    String,
	proto   String
);
INSERT INTO MCP4725 (name, I2C, address, vref, proto)
  VALUES ('dac0', '$i2c-v', '0x62', '-', 'virt');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');
