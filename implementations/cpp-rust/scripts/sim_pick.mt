# 仿真蜘蛛：拾取前方方块（mybot-sim 从端）
# 动作码：0=stop 1=forward 2=backward 3=left 4=right 5=fdist 6=turn 7=pick 8=place
#
# 用法：cat scripts/sim_pick.mt | ./build/mybot --robot=robots/spider_sim.sql

@Action
sim.M;

7;	# pick 拾取前方最近的方块
