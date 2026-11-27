# 控制蜘蛛从标准站立动作逐渐躺下

# 脚本位置
#@Alias
#name  alias;
#PATH  ./;
#@

@Vars
name   value;
POS_S0     45;	# THE POSITION OF START
POS_S1      0;
INT_S1     10;
BEAT_T0    80;
@

@Merge
phase path;
    - map_spider.mt;
    - move-fl.mt;
    - move-fr.mt;
    - move-bl.mt;
    - move-br.mt;
@

@Action
spk.F   spk.delay;
   10  $(BEAT_T0);	# stand
    -           -;
    -           -;
    -           -;
    -           -;
    -           -;
@
