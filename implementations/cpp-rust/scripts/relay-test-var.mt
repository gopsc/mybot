# controller 转发测试动作（参数化）：延时格写 $(ms)，由 run_action_script 的 vars
# 注入——用来在工具层锚定「调用时传的实参真的流到了派发值」。Timer 回显 slept=<ms>，
# 故回执里出现注入的数即证明 vars → run(injectVars) → $(ms) → 器件 一路打通。
# 用法：run_action_script(script="relay-test-var.mt", vars={"ms":137})
@Action
relay0.test;
      $(ms);
@
