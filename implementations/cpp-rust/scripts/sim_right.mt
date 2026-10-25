# 仿真蜘蛛：原地右转约 1.2 秒后停（mybot-sim 从端，结构见 robots/spider_sim.sql）
# 动作码：0=stop 1=forward 2=backward 3=left 4=right

@Action
sim.M sim.S spk.delay;

4 0.6 1200;	# right 原地右转
0   -    -;	# stop
