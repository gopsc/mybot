# SCSCL 总线舵机无硬件端到端配套动作：位置控制四帧 + 末行站号烧写
# 运行：cat scripts/test/scscl_virt.mt | ./build/mybot --robot=robots/test/scscl_virt.sql
# position 经 offset/限幅管线后按大端写入 0x2A；speed 步/s（0 且 time 非 0
# 时按 time 走）；"-" 继承上一行（矩阵占位符语义）。
# 末行列 set_id=7：解锁 EPROM → 广播写 0x05（独占本行，同行参数忽略；
# 真机广播会命中总线上所有舵机，烧号请只接目标舵机、掉电重启生效）。
@Action
s1.position  s1.speed  s1.time  s1.set_id  t0.delay;
        512       300         0         -        50;
        256         0       400         -        50;
       1023      1000         0         -        50;
          0         -         -         -        50;
          -         -         -         7        50;
@
