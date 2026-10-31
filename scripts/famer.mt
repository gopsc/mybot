# 种植辅助系统
# 通过ADC获取土壤温湿度

@Alias
name        alias;
a           H(%):;
b           T(C):;
K           COVER_ME;
@

@Vars
name value;
   T     0;
   T1    0;
@

#@Action
#qs.op        qs.key;
#$("bind")    $K;
#@

@Action
adc0.read     adc1.read;
$T=voltage  $T1=voltage;
@

@Action
lcd0.text lcd0.clear lcd0.backlight;
$(a+T*100/5+",\n"+b+(T1*120/5-40))       1              1;
@


@Action
qs.op        qs.key           qs.value;
$("push")    $("湿度(%)")   $(T*100/5);
$("push")    $("温度(°C)")      $(T1*120/5-40);
$("online")  -                -;
#$("pull")    -               -;
#$("ack")     
@
