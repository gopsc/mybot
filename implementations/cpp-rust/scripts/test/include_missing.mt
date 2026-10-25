# 负值契约：引用不存在的文件 → 清晰报错（路径不回显内容）
@Action
timer-0.delay;
  100;
@

@Merge
path;
  scripts/test/include_nonexistent.mt;
@
