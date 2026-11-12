# 审计 #5 负值回归：守护 interval=10ms，首行预热 200ms 等 setup 完成，
# 随后 10 拍 ×50ms 拉长时间窗，确保 daemon_tick 至少跑到一次字段校验。
# 期望日志出现 "field(s) absent or non-numeric in driver result: ACCEL_NOPE"
@Action
t0.delay;
   200;
    50;
    50;
    50;
    50;
    50;
    50;
    50;
    50;
    50;
    50;
@
