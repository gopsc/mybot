# 守护配置 schema 负值用例（daemon_badproto / daemon_fieldmode / daemon_fieldempty）
# 的共同占位动作脚本：三个用例都在**结构脚本加载期**（守护线程尚未 spawn）即失败，
# 本动作脚本永远不会被执行，仅为输入占位与配对关系可见。
# 验证：cat scripts/test/daemon_schema.mt | ./build/mybot --robot=robots/test/daemon_badproto.sql
@Action
t0.delay;
   100;
@
