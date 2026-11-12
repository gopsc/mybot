# 浮点 + sign=16 拒绝发布回归：守护 count 停滞（不发布被截断的假值）。
# 期望锚点在守护日志："would be truncated to integer"
@Action
t0.delay  mon0.go;
   2000        -;
    50        -;
    50        -;
    50        -;
    50        -;
    50        -;
@
