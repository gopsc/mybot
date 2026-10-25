# AD9833 DDS 波形发生器测试（频率扫描式变更 + 静音）
# 结构脚本：robots/test/ad9833.sql（SPI mode=2 + sig0 1kHz sine + Timer）
# 运行：cat scripts/test/ad9833.mt | ./target/release/bin/main --robot=robots/test/ad9833.sql
#
# 实机测试（需 /dev/spidev0.0 + AD9833 模块；示波器/频率计看 VOUT）。
# @Action 数值参数映射：freq 列改频率（Hz）、mute 列 1/0 静音/放行；
# wave 为字符串参数不经 @Action（由结构脚本列配置）。
# 前 5 行扫频（500 -> 1k -> 2k -> 5k -> 1k），后 2 行静音 -> 放行，20ms 间隔。
@Action
sig0.freq  sig0.mute  t0.delay;
      500         -        20;
     1000         -        20;
     2000         -        20;
     5000         -        20;
     1000         -        20;
        -         1        20;
        -         0        20;
@
