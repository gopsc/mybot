# C-4 守门：数据行比表头多一个单元格（最常见的动作脚本笔误）。
# 参差行是本文件的第 6 行。修复前 catch-all 把 DoesNotSync 降级成
# "I don't understand what happened"，且 @Name 行末换行未计数使行号少 1（报第 5 行）。
@Action
relay0.test;
  200  300;
@
