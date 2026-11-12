# 仿真蜘蛛：前进 2 秒后停（mybot-sim 从端，结构见 robots/spider_sim.sql）
# 动作码：0=stop 1=forward 2=backward 3=left 4=right
#
# 用法：cat scripts/sim_forward.mt | ./build/mybot --robot=robots/spider_sim.sql

@Action
sim.M sim.S spk.delay;

1 0.8 2000;	# forward 八成才力前进 2 秒
0   -    -;	# stop 收工（mybot 退出时仿真器也会自行停）
