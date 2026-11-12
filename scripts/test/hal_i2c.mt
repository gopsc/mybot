# HAL 集成测试：Alias(.mt内联) → Servo → controller(pca9685-0) → I2C 全链路经纯 Lua HAL
# 本机 /dev/i2c-1 存在但 0x40 无设备：写操作静默失败（i2cset 报错到 stderr），
# 与 cfunc 时代 writeI2cReg 忽略错误的行为一致，程序应正常走完并退出 0
@Action
s1.A;
   45;
@
