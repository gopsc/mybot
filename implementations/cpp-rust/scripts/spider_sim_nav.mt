# 仿真器导航感知示例动作（配 robots/spider_sim_nav.sql，需先起 mybot-sim）：
# 首行预热 600ms 等两路守护首发 + 聚合首拍（imu0/odom0 各要一次桥往返，聚合
# 要等两个 peer 都有首帧），随后逐拍经 mon0.go 消费 $nav0 快照（10 个拼接值：
# v0..v4 imu、v5..v9 odom），并间隙发 sim 动作（fdist 前进、turn 转向）。
@Action
t0.delay  mon0.go  sim.M  sim.P;
   600        -       0      -;
    50        -       1    0.8;
   300        -       0      -;
    50        -       6     90;
   300        -       0      -;
    50        -       5    0.5;
   300        -       0      -;
@
