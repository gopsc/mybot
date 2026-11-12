# 复用场景（正值）：主脚本改绑片段的设备别名——主从覆盖 + 设备列解析组合。
# 片段缺省 leg→relay-a，这里改绑 relay-b：模板一个字不动，播放必须落在
# relay-b（note=from-b），且不得再碰 relay-a（note=from-a 禁止出现）。
@Alias
name  alias;
   leg  relay-b;
@

@Merge
path;
  dev_alias_leg.once.mt;
@
