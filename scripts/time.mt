# 系统时间示例：结构用 robots/time.sql。
# 默认快照：epoch / epoch_ms / utc / local / 拆分字段。
@Action
clock.now;
        1;
@

# 动作参数 format / utc：第一行本地格式，第二行 UTC 格式。
@Action
clock.format clock.utc;
$("%H:%M:%S") 0;
$("%H:%M:%S") 1;
@

# 捕获格式化文本；stamp 未声明时按文本自动创建 Alias。
@Action
clock.format clock.stamp;
$("%m-%dT%H:%M:%S") $stamp=formatted;
@
