# 小星星——Speaker 声乐音调示例
#
# 音调用裸音名（省八度缺省 4 = 中央C八度）：'c'=中央C、'a'=440Hz、'g'=G4。
# 数据格只认数值，音名是文本，要经 $(别名) 间接——别名用唱名指向对应音名
# 字母，数据格写 $(do) 即得文本 "c"（MIDI 号仍可直写，如 60）。
# 休止符：wave 是文本参数，同经 $(别名)——$(rest) 得 "silence"（静音占时，
# 幅值零）；静音行的 note 照给（过校验，契约统一）。
# wave 列的 '-'：首行=不投递（落到结构脚本缺省 sine），其后=继承上一行

@Alias
name   alias;
do     c;
re     d;
mi     e;
fa     f;
sol    g;
la     a;
sin    sine;
rest   silence;
@

@Action
spk0.wave  spk0.note  spk0.delay;
 -         $(do)         350;	# do
 -         $(do)         350;	# do
 -         $(sol)        350;	# sol
 -         $(sol)        350;	# sol
 -         $(la)         350;	# la
 -         $(la)         350;	# la
 -         $(sol)        700;	# sol——长音
 $(rest)   $(do)         200;	# 休止（note 照给过校验，静音幅值零）
 $(sin)    $(fa)         350;	# fa
 -         $(fa)         350;	# fa
 -         $(mi)         350;	# mi
 -         $(mi)         350;	# mi
 -         $(re)         350;	# re
 -         $(re)         350;	# re
 -         $(do)         700;	# do——长音
 $(rest)   $(do)         300;	# 尾声休止
@
