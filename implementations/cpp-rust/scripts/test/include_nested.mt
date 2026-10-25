# 嵌套包含正值：主脚本 → 组合片段（include_scene.once.mt）→ 两个叶子片段。
# 组合片段没有自有 @Action（纯组合合法），其有效动作 = 两叶按相位归并。
@Action
timer-0.delay;
  100;
@

@Merge
path;
  scripts/test/include_scene.once.mt;
@
