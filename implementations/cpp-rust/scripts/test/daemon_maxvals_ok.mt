# maxvals 放行夹具（daemon_fieldcount_maxvals_ok.sql）：65 字段 + maxvals=128
# 通过加载期数量判据；本动作脚本拉 300ms 时间窗让守护 spawn/发布/收尾完整走完，
# 期望日志出现 "spawned, config:"（含 maxvals=128）与 "joined, total publishes="。
@Action
t0.delay;
   300;
@
