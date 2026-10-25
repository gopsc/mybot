# 控制蜘蛛从标准站立动作逐渐躺下
#
@Vars
name   value;
POS_S0     45;	# THE POSITION OF START
POS_S1      0;
INT_S1     10;
BEAT_T0    80;
@
@Merge
phase path;
    - scripts/map_spider.mt;
    - scripts/move-fl.mt;
    - scripts/move-fr.mt;
    - scripts/move-bl.mt;
    - scripts/move-br.mt;
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
