# 左前脚平行移动 需要提前定义好 $POS_S0 、 $POS_S1  和  $INT_S1
#
@Action
    BL0.A                BL1.A;	# column name
$(POS_S0)   $(POS_S1+0*INT_S1);	# stand
        -   $(POS_S1+1*INT_S1);
        -   $(POS_S1+2*INT_S1);
        -   $(POS_S1+3*INT_S1);
        -   $(POS_S1+4*INT_S1);
        -   &(POS_S1+5*INT_S1);
@
