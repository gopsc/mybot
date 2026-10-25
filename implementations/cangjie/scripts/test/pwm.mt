# PWM 硬件脉宽调制测试（占空比渐增再渐减）
# 结构脚本：robots/test/pwm.sql（pwmchip0 pwm1 @ 20kHz）
# 运行：cat scripts/test/pwm.mt | bash _run.sh --robot=robots/test/pwm.sql
#
# 20kHz 超出人耳范围：接 L298N 的 EN 脚听不到啸叫；接 LED 则为调光。
# duty 为百分比 0~100，每行用 t0.delay 保持 300ms。
# 列序决定执行顺序：先改占空比，再延时。
@Action
pwm0.duty  t0.delay;
         0       300;
        25       300;
        50       300;
        75       300;
       100       300;
        50       300;
         0       300;
@
