# 用例2：覆盖测试——结构脚本 alias_override.sql 定义 A->angle，
# 此处重定义 A->test；若覆盖生效，Servo.lua 将收不到 angle 而报 ERR
@Alias
name  alias;
   A  test;
@

@Action
s1.A;
   30;
@
