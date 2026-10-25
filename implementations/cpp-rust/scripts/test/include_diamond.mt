# 菱形正值：主脚本 → fa、fb 两臂，两臂都包含 shared.once.mt。
# 断言：rc=0 且 test=300 恰好出现一次（观察面专段计数）。
@Merge
path;
  scripts/test/fa.once.mt;
  scripts/test/fb.once.mt;
@
