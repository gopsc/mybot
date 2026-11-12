# 多守护聚合消费：首行预热 500ms 等三路守护首发（imu0/baro0 采样 + agg0 聚合，
# 聚合拍要等两个 peer 都有首帧），随后经 mon0.go 每行消费 $agg0 快照——
# 期望 10 个拼接值（imu0 七字段在前、baro0 三字段在后，即 sources 声明序）。
@Action
t0.delay  mon0.go;
   500        -;
    50        -;
    50        -;
    50        -;
    50        -;
    50        -;
@
