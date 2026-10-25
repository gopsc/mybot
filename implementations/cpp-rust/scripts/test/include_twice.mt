# 负值契约：普通 .mt 重复包含 → 报错（抓笔误；共享片段请用 *.once.mt 后缀）
@Merge
path;
  scripts/test/include_a.mt;
  scripts/test/include_a.mt;
@
