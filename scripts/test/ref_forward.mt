# 前向引用正向回归（F-05）+ destroy 静态元数据（F-04），配套 ref_forward.sql：
# 列名与 ema_chain.mt 相同（t0.delay / ema0.out / mon0.read）；
# 末尾守护 join 行证明清理链完整，且不得出现 "Deactive warning"。
@Action
# 预热 200ms：等待 sim0 守护完成 setup 首发（暖机竞态规避），再开始滤波链
t0.delay  ema0.out  mon0.read;
  200        -        -     ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
   -         -        20    ;
@
