# 负路径回归用例配套动作脚本：与 robots/test/insert_typo.sql 配对。
# insert_typo.sql 中 INSERT 目标表名拼错（Timerr ≠ Timer），结构脚本
# 解析期即应抛出「INSERT INTO 'Timerr': table is not defined」并以退出码 1
# 终止——本动作脚本永远不会被执行，仅保证测试对文件齐全。
# 验证：cat scripts/test/insert_typo.mt | ./build/mybot --robot=robots/test/insert_typo.sql
#       期望退出码 1，错误信息含 "table is not defined"
@Action
timer-0.delay;
        100;
@