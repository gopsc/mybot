/*
 * 蜘蛛机器人仿真结构脚本：动作下发给 mybot-sim（sim/ 下的 3D 仿真器），
 * 全程不碰任何真实总线，无硬件依赖。
 *
 * 用法：
 *   bash scripts/build_sim.sh
 *   ./sim/build/mybot-sim &                                  # 监听动作/拍照两条 socket
 *   cat scripts/sim_forward.mt | ./build/mybot --robot=robots/spider_sim.sql
 *
 * agent 要在仿真里「拍照看画面」，给 mybot 进程补一个环境变量即可：
 *   MYBOT_SIM_CAPTURE_SOCK=/tmp/mybot-sim-capture.sock \
 *     ./build/mybot --mcp-backend --robot=robots/spider_sim.sql ...
 *
 * socket 路径刻意不在这里配：modules/Sim.lua 与 sim/src/main.cpp 同读环境
 * 变量 MYBOT_SIM_SOCK（缺省 /tmp/mybot-sim.sock）；拍照侧同读
 * MYBOT_SIM_CAPTURE_SOCK（缺省 /tmp/mybot-sim-capture.sock）。两侧单一事实源。
 *
 * 与 robots/spider1.sql 的区别：真机蜘蛛的 14 路舵机（Servo→PCA9685，I2C）
 * 换成一路 Sim 语义桥。仿真器只认「前进/后退/左转/右转/停」，腿部步态由它
 * 自己按身体速度生成，关节角不过桥。
 */

/* 别名表：动作脚本(.mt)中可用别名指代硬件参数名 */
CREATE TABLE Alias (
	name  String,
	alias String
);
INSERT INTO Alias (name, alias) VALUES (M, action);
INSERT INTO Alias (name, alias) VALUES (S, speed);
INSERT INTO Alias (name, alias) VALUES (P, param);
INSERT INTO Alias (name, alias) VALUES (Q, param2);

/* Timer：spk 仅作动作矩阵的节拍（spk.delay 单位毫秒） */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('spk');

/* Sim：语义动作桥，一行一条动作发给仿真器（modules/Sim.lua）
 * 动作码 sim.M（矩阵单元格只收 Float64，故用码不用名）：
 *   0=stop  1=forward  2=backward  3=left  4=right
 *   5=fdist(相对前进 N 米)  6=turn(相对转 N 度，正=左负=右)  7=pick  8=place  9=save
 *   10=jump(向前弹道跳：param=前跳米数、param2=apex 高度米数，两参都必填)
 * 速度 sim.S：0.00~1.00，缺省 1.0（持续型动作 1-4 用）
 * 参数 sim.P：fdist 的米数 / turn 的度数 / jump 的前跳距离（带参动作 5、6、10 需要；
 *   fdist/turn 是精确相对运动，仿真器内带刹车到量，比按时长的 left/right 可控得多）
 * 参数 sim.Q：jump 的起跳 apex 高度（仅动作 10 需要，是 jump 的第二参数） */
CREATE TABLE Sim (
	name String
);
INSERT INTO Sim (name) VALUES ('sim');

/* Camera：拍照设备（modules/Camera.lua）。注册它，宿主的 capture_image 工具
 * 才会出现（agent 靠它「看」仿真画面）。设备变量名用 cam0——与宿主缺省的
 * --camera-var 对齐，registry().find("cam0") 命中即挂上工具。
 *
 * 仿真器实时帧走环境变量而非结构脚本：给 mybot 进程设
 *   MYBOT_SIM_CAPTURE_SOCK=/tmp/mybot-sim-capture.sock
 * Camera.lua 便从这个 socket 抓 mybot-sim 的当前画面（JPEG）。不设该变量则
 * 落回真机 V4L2 路径（/dev/video0）。刻意用 env 不用列：socket 路径属部署期
 * 配置，与 Sim 侧的 MYBOT_SIM_SOCK 同源同风格，且避免把「连哪个 socket」变成
 * 模型可控的调用参数（那是条「连任意 socket」的原语）。 */
CREATE TABLE Camera (
	name String
);
INSERT INTO Camera (name) VALUES ('cam0');
