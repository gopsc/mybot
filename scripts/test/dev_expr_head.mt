# $(...) 设备位拼接（正值）：$(pfx+n) → "relay-" + 2 → relay-2 播放
# （别名值 + @Vars 数值真值拼接；求值在派发期）
@Action
$(pfx+n).test;
  200;
@
