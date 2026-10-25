# 审计 #1 负值回归：relay0.note 与结构脚本的 note 列同名，必须被拒绝
# （note 在结构脚本里是 'hello-relay'，若被这里的 999 覆盖则说明防线失效）
@Action
relay0.test  relay0.note;
     200          999;
@
