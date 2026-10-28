# 用已有 iot 账号创建设备：登录（build 时完成）→ op=create → 返回 id 和机器码
#
# 账号来自结构 SQL 的 Alias 行（user/pass），device 来自 Vars 行（缺省 0），
# 均可在激活前用 --var/--var-env 覆盖。设备名默认 flowerpot-01，用 --var 覆盖。
# op=create 成功后以服务端返回的新 device id 为准。
# 注意 op=create 每次都新建一台设备，不要放进启动流程反复执行。
#
# 用法：
#   export QS_USER=iot_01 QS_PASS=pass123
#   pymybot run --robot robots/qsont.sql --input scripts/qsont-create-device.mt \
#     --timeout 30 --allow-hardware --var-env user=QS_USER --var-env pass=QS_PASS \
#     --var device=13 --var devname=flowerpot-01

@Alias
name     alias;
devname  flowerpot-01;
@

@Struct(state)
{
  "device": 0,
  "key": "",
  "name": ""
}
@

@Action
qs.op        qs.device_name    qs.device            qs.key        qs.name;
$("create")  $(devname)        $state.device=device $state.key=key $state.name=name;
@
