# TPL0501 数字电位器测试（输出型器件，直连调节）
# 结构脚本：robots/test/tpl0501.sql（SPI@模式0 + dpot-0 rtotal=100kΩ + Timer）
# 运行：cat scripts/test/tpl0501.mt | ./build/mybot --robot=robots/test/tpl0501.sql
#
# 实机测试（需 /dev/spidev0.0 + TPL0501；spi_mode 必须为 0）。
# halt-on-error 生效后无器件无法优雅跑完：SPI 的 build 一旦返回 ERR
# 即中止整个动作（exit 1）。
#
# @Action 列参数经占位符继承会常驻，而行内换算优先级为 level > percent > ohms，
# 故行序按 ohms -> percent -> level 排列，后行的高优先级参数覆盖继承值，
# 三种换算模式得以逐一验证；每行 100ms 节拍留出观察窗口。
@Action
dpot-0.ohms  dpot-0.percent  dpot-0.level  t0.delay;
        50000             -             -       100;
        50000             -             -       100;
            -            50             -       100;
            -            50             -       100;
            -             -           127       100;
            -             -           127       100;
            -             -             0       100;
@
