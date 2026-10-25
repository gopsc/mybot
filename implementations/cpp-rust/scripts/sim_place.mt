# 仿真蜘蛛：放置背负的方块到前方（mybot-sim 从端）
# 动作码：0=stop 1=forward 2=backward 3=left 4=right 5=fdist 6=turn 7=pick 8=place
#
# 用法：cat scripts/sim_place.mt | ./build/mybot --robot=robots/spider_sim.sql

@Action
sim.M;

8;	# place 把背负的方块放到前方
