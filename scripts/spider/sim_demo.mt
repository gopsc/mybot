# 仿真蜘蛛：串一段动作做演示（前进→左转→前进→后退→停）
# mybot-sim 从端，结构见 robots/spider_sim.sql
# 动作码：0=stop 1=forward 2=backward 3=left 4=right

@Action
sim.M sim.S spk.delay;

1 0.8 2500;	# forward 直走一段
3 0.6 1200;	# left 原地左转
1 0.8 2500;	# forward 再直走
2 0.5 1500;	# backward 倒回来一点
0   -    -;	# stop
