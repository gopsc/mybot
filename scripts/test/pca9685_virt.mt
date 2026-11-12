# PCA9685 无硬件端到端配套动作：通道 0 扫三个角度
# 运行：cat scripts/test/pca9685_virt.mt | ./build/mybot --robot=robots/test/pca9685_virt.sql
# angle 是 PCA9685.call 的动作参数，channel 已在结构脚本里定为 0
@Action
pca-0.angle  t0.delay;
        90        50;
        45        50;
       135        50;
        90        50;
@
