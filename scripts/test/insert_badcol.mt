# 负路径回归用例配套动作脚本：与 robots/test/insert_badcol.sql 配对。
# insert_badcol.sql 的 INSERT 写了不存在的列名（nome ≠ name），结构脚本解析期
# 即应抛出 "INSERT INTO 'Timer': no such column 'nome'" 并以退出码 1 终止——
# 本动作脚本永远不会被执行，仅保证测试对文件齐全。
# 验证：cat scripts/test/insert_badcol.mt | ./build/mybot --robot=robots/test/insert_badcol.sql
#       期望退出码 1，错误信息含 "no such column"
@Action
timer-0.delay;
        100;
@
