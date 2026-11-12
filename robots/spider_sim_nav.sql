/*
 * 仿真器导航感知示例（2026-10-16，第一档「仿真多路观测接上聚合器」）：
 * Sim 语义动作桥（动）+ 两路守护采样（imu0/odom0，lib/sim_sensor_daemon.lua）
 * + sources 聚合（nav0，lib/sensor_aggregate.lua）+ Monitor 消费（mon0 以
 * $nav0 引用拿到 10 个拼接值：imu 5 + odom 5，序 = sources 声明序）。
 *
 * 运行方式（先起仿真器再起后端）：
 *   ./sim/build/mybot-sim                     # IMU/里程计桥缺省路径即被监听
 *   ./build/mybot --robot=robots/spider_sim_nav.sql --mcp-backend --mcp-socket /tmp/mybot.sock
 * 动作脚本：cat scripts/spider_sim_nav.mt | ./build/mybot --robot=robots/spider_sim_nav.sql
 *
 * socket 路径刻意不写结构脚本：与 modules/Sim.lua、sim/src/main.cpp 同读环境
 * 变量（MYBOT_SIM_SOCK / MYBOT_SIM_IMU_SOCK / MYBOT_SIM_ODOM_SOCK），缺省
 * /tmp/mybot-sim*.sock。两侧不各自配置是既有口径（见 spider_sim.sql）。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 别名表：动作脚本(.mt)中可用别名指代硬件参数名（M/S/P/Q → 驱动参数字段） */
CREATE TABLE Alias (
	name  String,
	alias String
);
INSERT INTO Alias (name, alias) VALUES (M, action);
INSERT INTO Alias (name, alias) VALUES (S, speed);
INSERT INTO Alias (name, alias) VALUES (P, param);
INSERT INTO Alias (name, alias) VALUES (Q, param2);

/* Sim：语义动作桥，一行一条动作发给仿真器（modules/Sim.lua）
 * 动作码同 spider_sim.sql：0=stop 1=forward 2=backward 3=left 4=right
 * 5=fdist 6=turn 7=pick 8=place 9=save 10=jump */
CREATE TABLE Sim (
	name String
);
INSERT INTO Sim (name) VALUES ('sim');

/* 守护三行一张表（同名表只许一张）：两路采样（sim_sensor_daemon）+ 一路聚合
 * （sensor_aggregate），不用的列一律 '-'（矩阵空占位符 = 未提供）。
 * kind 列在加载期校验（imu|odom）；interval=20ms 即采样拍频。
 * 仿真器缺席按逐拍错误处理（count 停滞 + 限频日志），后起即自动重连。
 * 聚合：nav0 把 imu0(5 字段) + odom0(5 字段) 按声明序拼进同一槽。
 * 拼接 10 值 ≤ maxvals=16；peer 须先行声明（先声明后引用，环不可能）。 */
CREATE TABLE Daemon (
	name     String,
	chunk    String,
	kind     String,
	sources  String,
	interval String,
	maxvals  String
);
INSERT INTO Daemon (name, chunk, kind, sources, interval, maxvals)
  VALUES ('imu0', 'lib/sim_sensor_daemon.lua', 'imu', '-', '20', '-');
INSERT INTO Daemon (name, chunk, kind, sources, interval, maxvals)
  VALUES ('odom0', 'lib/sim_sensor_daemon.lua', 'odom', '-', '20', '-');
INSERT INTO Daemon (name, chunk, kind, sources, interval, maxvals)
  VALUES ('nav0', 'lib/sensor_aggregate.lua', '-', 'imu0|odom0', '50', '16');

/* 消费：mon0 以 $nav0 引用读聚合快照。字段序：
 *   v0..v4  imu：  yaw_deg / gyro_z / acc_fwd / vy / airborne
 *   v5..v9  odom： x / z / theta_deg / v / odo */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$nav0');
