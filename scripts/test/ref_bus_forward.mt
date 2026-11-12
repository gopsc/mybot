# 负路径回归用例配套动作脚本：与 robots/test/ref_bus_forward.sql 配对。
# 该结构脚本把 @I2C 声明在 @PCA9685 之后（接口器件前向引用），PCA9685 的
# build 拿不到 fd，active() 阶段即抛「Invalid Argument: fd or address」并以
# 退出码 1 终止——本动作脚本永远不会被执行，仅保证测试对文件齐全。
# 验证：cat scripts/test/ref_bus_forward.mt | ./build/mybot --robot=robots/test/ref_bus_forward.sql
#       期望退出码 1，错误信息含 "Invalid Argument: fd or address"
@Action
pca-0.channel  t0.delay;
            0        100;
@
