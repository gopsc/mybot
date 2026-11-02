# 注册 Qsont 设备使用的 iot 账号（iot-server 准备工作的第 1 步）
# 只注册账号，不创建设备；设备由 scripts/qsont-create-device.mt 创建。
#
# 注意：合并后的 robots/qsont.sql 会在激活时先用 user/pass 登录，
# 因此本脚本只适用于“账号已存在”的情况（幂等验证）；首次注册请按
# robots/qsont.sql 顶部的手工 curl 调用 /users/register。
#
# 条件反射结构：
#   1. @Action 先探测登录 —— 已存在且密码正确时直接跳过注册（幂等，可反复运行）
#   2. @if(state.status==401) 才发注册请求 —— 账号不存在或密码不对时才尝试创建
#   3. @Action 调用 verify 收尾验证登录，在调用者捕获 state.login
#
# 凭据放在 @Alias，推荐用 --var-env 从环境变量注入，避免出现在 argv 里；
# @Struct 只保存每次运行的状态（Struct 不能被 --var 覆盖）。
# 密码只支持字母数字（会被拼进 JSON 文本）。
# 登录成功会在 outputs 里带出 access_token，不需要留存时用 --no-session-log。
#
# 用法（qsont.me 是非回环地址，run 需要 --allow-hardware）：
#   export QS_USER=iot_01
#   export QS_PASS='pass123'
#   pymybot run --robot robots/qsont.sql --input scripts/qsont-iot-register.mt \
#     --timeout 30 --allow-hardware --var-env user=QS_USER --var-env pass=QS_PASS
#
# 也可用 --var（值会出现在进程列表和 shell 历史里，真实密码请自行评估）：
#   pymybot run --robot robots/qsont.sql --input scripts/qsont-iot-register.mt \
#     --timeout 30 --allow-hardware --var user=iot_01 --var pass=pass123

@Alias
name  alias;
user  COVER_ME;
pass  COVER_ME;
@

@Struct(state)
{
  "status": 0,
  "login": 0
}
@

# 1) 登录探测：200 = 账号可用；401 = 不存在或密码不符
@Action
cloud.method  cloud.path          cloud.headers                       cloud.body                                                        cloud.status;
$("POST")     $("/users/login")   $("Content-Type=application/json")  $("{\"username\":\""+user+"\",\"password\":\""+pass+"\"}")        $state.status=status;
@

# 2) 只有探测失败才注册；device_type 必须是 iot，否则后续 push/pull 会被 403
@if(state.status==401)
@Action
cloud.method  cloud.path              cloud.headers                       cloud.body                                                                                            cloud.status;
$("POST")     $("/users/register")    $("Content-Type=application/json")  $("{\"username\":\""+user+"\",\"password\":\""+pass+"\",\"device_type\":\"iot\"}")                    $state.status=status;
@
@

# 3) 收尾验证：无论走哪条分支，最后再用同一凭据登录一次
@Reflex(verify)
cloud.method  cloud.path          cloud.headers                       cloud.body;
$("POST")     $("/users/login")   $("Content-Type=application/json")  $("{\"username\":\""+user+"\",\"password\":\""+pass+"\"}");
@

@Action
verify.user verify.pass verify.capture;
$(user)     $(pass)     $state.login=status;
@
