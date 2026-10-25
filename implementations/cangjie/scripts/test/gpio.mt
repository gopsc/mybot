# GPIO gpiod uAPI 测试（输出点闪 + 输入轮询）
# 结构脚本：robots/test/gpio.sql（led-0@BCM17 输出 + sw-0@BCM27 输入 + Timer）
# 运行：cat scripts/test/gpio.mt | ./target/release/bin/main --robot=robots/test/gpio.sql
#
# 实机测试（需 /dev/gpiochipN + gpio 组权限；Pi 5 用 /dev/gpiochip4 改 .sql）。
# halt-on-error 生效后无 GPIO 控制器无法优雅跑完：GPIO 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无硬件机器上快速验证错误通道是否打通。
#
# led-0.value 参数经占位符继承常驻（1 -> 1 -> 0 -> 0 -> 1 -> 1 -> 0）；
# sw-0 为输入模式，call 忽略 value 参数、返回实时读值（行 5 读一次）。
@Action
led-0.value  sw-0.value  t0.delay;
          1           -       100;
          -           -       100;
          0           -       100;
          -           -       100;
          1           0       200;
          -           -       100;
          0           -       100;
          -           -       100;
@
