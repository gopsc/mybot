# 种植辅助系统
# 通过ADC获取土壤温湿度



# 字段、qsont-key、继电器Res
@Alias
name        alias;
a           H(%):;
b           T(C):;
K           COVER_ME;
R01         COVER_ME; 
@


# 目标传感器值
@Vars
name value;
   T     0;
   T1    0;
 time_h  -1;
 time_m  -1;
@


# 关灯
@Struct(S0)
{
	"A01": 100000,
	"res": "ok"
}
@


# 开灯
@Struct(S1)
{
	"A01": 110000,
	"res": "ok"
}
@

# 获取当前时间
@Action
clock.get clock.capture;
        1  $time_h=hour; 
        1  $time_m=minute;
@

# 阅读传感器
@Action
adc0.read     adc1.read;
$T=voltage  $T1=voltage;
@


# 通过网络继电器开关灯
@Action
tcp0.timeout tcp0.num_recv;
        2000           512;
@

@Action
tcp0.connect;
1;
@

@Action
tcp0.recv_hex;
            1;
@


# 控制灯
@if(time_h>=6&&time_h<=22)
@Action
tcp0.send_str;
   $(S1);
@
@
@if(time_h<5||time_h>22)
@Action
tcp0.send_str;
   $(S0);
@
@

@Action
tcp0.recv_str tcp0.reply;
            1   $R01=recv_str;
@

@Action
tcp0.close;
1;
@


# 上传到QSONT

#@Action
#qs.op        qs.key;
#$("bind")    $K;
#@

@Action
qs.op        qs.key           qs.value;
$("push")    $("湿度(%)")   $(T*100/5);
$("push")    $("温度(°C)")      $(T1*120/5-40);
$("online")  -                -;
#$("pull")    -               -;
#$("ack")     
@


# 屏幕回显
@Action
lcd0.text lcd0.clear lcd0.backlight;
$(a+T*100/5+",\n"+b+(T1*120/5-40))       1              1;
@


