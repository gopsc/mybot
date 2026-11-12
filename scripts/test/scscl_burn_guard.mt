# SCSCL 烧号授权防线（审计 H-3）负值配套动作：结构脚本未声明 allow_burn，
# 本行的 set_id 烧号请求必须被拒绝（call() 返回 ERR，框架打印并退出非 0）。
@Action
s1.set_id  t0.delay;
         7        50;
@
