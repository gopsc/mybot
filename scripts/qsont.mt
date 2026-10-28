# Qsont 推/拉示例：结构用 robots/qsont.sql；device 必须用 --var/--var-env 指定。
# 用法：
#   export QS_USER=iot_01 QS_PASS=pass123
#   pymybot run --robot robots/qsont.sql --input scripts/qsont.mt \
#     --timeout 30 --allow-hardware --var-env user=QS_USER --var-env pass=QS_PASS --var device=13

@Action
qs.op        qs.key           qs.value;
$("push")    $("temperature") 23.5;
$("online")  -                -;
$("pull")    -                -;
@
