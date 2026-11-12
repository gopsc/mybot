# BH1750 环境光守护采样消费：首行 t0 预热 400ms（守护 setup 内一帧 + 首发），
# 再经 mon0.go 每行消费：Monitor 打印 v0(LUX)/count 并回传 level/out（顶层直出 JSON）
@Action
t0.delay  mon0.go;
   400        -;
   120        -;
   120        -;
   120        -;
   120        -;
   120        -;
   120        -;
   120        -;
   120        -;
@