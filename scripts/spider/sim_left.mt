# 仿真蜘蛛：原地左转约 1.2 秒后停（mybot-sim 从端，结构见 robots/spider_sim.sql）
# 动作码：0=stop 1=forward 2=backward 3=left 4=right

@Action
sim.M sim.S spk.delay;

3 0.6 1200;	# left 原地左转
0   -    -;	# stop
