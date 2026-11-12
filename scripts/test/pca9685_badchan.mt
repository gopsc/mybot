# PCA9685 通道越界配套动作：结构脚本已把 channel 定为 17（非法）
# 运行：cat scripts/test/pca9685_badchan.mt | ./build/mybot --robot=robots/test/pca9685_badchan.sql
# 预期：驱动在写总线前守卫住，清晰报错并以非 0 退出
@Action
pca-0.angle;
        90;
@
