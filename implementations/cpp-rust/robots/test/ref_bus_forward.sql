-- 负路径回归用例：接口器件（总线）声明在器件之后（F-04′ 配套）
--
-- 器件行的总线句柄 fd 与从机 address 不是字面列，而是经 $i2c-b 从 @I2C 的
-- call 快照来的（modules/I2C.lua 只在 build 里 i2c_open 出 fd 并下发）。
-- 而 build 按声明序执行，所以「总线必须先于器件声明」是 build 期强制的：
-- 本文件的 @I2C 声明在 @PCA9685 之后，PCA9685 build 时 I2C 还没 build，
-- 快照里没有 fd → modules/lib/drv_common.lua 的 i2c_pair 返回
-- 「Invalid Argument: fd or address」→ 退出码 1。
--
-- 这条约束同时是销毁期 fd 有效性的来源：fd 只由接口器件自己的 destroy 关闭，
-- 声明顺序 + 倒序销毁 ⇒ 总线最后关闭 fd，器件 destroy 期间句柄始终有效
-- （见 docs/dsl.md「接口器件（总线）必须声明在器件之前」）。
--
-- 真机安全：全程不触总线——PCA9685 build 在 i2c_pair 处即返回，@I2C 的
-- build 根本没被执行，故插着真舵机的机器上跑本用例也不会写总线。
--
-- 验证：cat scripts/test/ref_bus_forward.mt | ./build/mybot --robot=robots/test/ref_bus_forward.sql
--       期望退出码 1，错误信息含 "Invalid Argument: fd or address"

/* 器件在前：$i2c-b 是合法前向引用（存在性校验在全部表注册之后才执行），
 * 但 build 期已经用不上它了——这正是本用例要钉住的失败面。 */
CREATE TABLE PCA9685 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO PCA9685 (name, I2C, address) VALUES ('pca-0', '$i2c-b', '0x40');

/* 总线在后：必须声明在挂载其上的器件之前 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-b', '/dev/i2c-1');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');
