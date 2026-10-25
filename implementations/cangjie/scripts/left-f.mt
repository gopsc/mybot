# ONE STEP
#
#               legs                 | neck |    free    |  speaker | delay
#~s1   s2  s3   s4  s5   s6  s7   s8   s9 s10   - - - - - -  spk       delay;	# column name
#!90  180 -90 -180  90  180 -90 -180  180 180   - - - - - -  5000       1000;	# 4-legs spider robot
#!-     -   -    -   -    -   -    -    -  90   - - - - - -     -          -;	# 4-legs spider robot
#!-     -   -    -   -    -   -    -    -   -   - - - - - -     -          -;	# offset
@Action
s7.A  s8.A  s5.A  s6.A  s3.A  s4.A  s1.A  s2.A  s9.A  s10.A  spk.F  spk.delay;	# column name
45    -     45    -     45    -     45    -     90    90      1000        100;	# stand
-     -     -     -     -     -     -     -     -     -       1000          -;	# stand

-     -     -     30    -     -     -     30    -     -       0            40;	# right behind up       & left  front  up
-     -     40    -     -     -     90    -     -     -       -             -;	# right behind forward  & left  front  forward
-     -     -     0     -     -     -     0     -     -       -             -;	# right behind down     & left  front  down
-     30    -     -     -     30    -     -     -     -       -             -;	# right front  up       & left  behind up
0     -     90    -     90    -     0     -     -     -       -             -;	# right front  forward  & left  behind forward
-     0     -     -     -     0     -     -     -     -       -             -;	# right front  down     & left  behind down

90    -     -     30    40    -     -     30    -     -       -             -;	# right behind up       & left  front  up
-     -     40    -     -     -     90    -     -     -       -             -;	# right behind forward  & left  front  forward
-     -     -     0     -     -     -     0     -     -       -             -;	# right behind down     & left  front  down
-     30    -     -     -     30    -     -     -     -       -             -;	# right front  up       & left  behind up
0     -     90    -     90    -     0     -     -     -       -             -;	# 
-     0     -     -     -     0     -     -     -     -       -             -;	# 

90    -     -     30    40    -     -     30    -     -       -             -;	# right behind up       & left  front  up
-     -     40    -     -     -     90    -     -     -       -             -;	# right behind forward  & left  front  forward
-     -     -     0     -     -     -     0     -     -       -             -;	# right behind down     & left  front  down
-     30    -     -     -     30    -     -     -     -       -             -;	# right front  up       & left  behind up
0     -     90    -     90    -     0     -     -     -       -             -;	# 
-     0     -     -     -     0     -     -     -     -       -             -;	# 

90    -     -     30    40    -     -     30    -     -       -             -;	# right behind up       & left  front  up
-     -     40    -     -     -     90    -     -     -       -             -;	# right behind forward  & left  front  forward
-     -     -     0     -     -     -     0     -     -       -             -;	# right behind down     & left  front  down
-     30    -     -     -     30    -     -     -     -       -             -;	# right front  up       & left  behind up
0     -     90    -     90    -     0     -     -     -       -             -;	# 
-     0     -     -     -     0     -     -     -     -       -             -;	# 

90    -     -     30    40    -     -     30    -     -       -             -;	# right behind up       & left  front  up
-     -     40    -     -     -     90    -     -     -       -             -;	# right behind forward  & left  front  forward
-     -     -     0     -     -     -     0     -     -       -             -;	# right behind down     & left  front  down
-     30    -     -     -     30    -     -     -     -       -             -;	# right front  up       & left  behind up
0     -     90    -     90    -     0     -     -     -       -             -;	# 
-     0     -     -     -     0     -     -     -     -       -             -;	# 

90    -     -     30    40    -     -     30    -     -       -             -;	# right behind up       & left  front  up
-     -     40    -     -     -     90    -     -     -       -             -;	# right behind forward  & left  front  forward
-     -     -     0     -     -     -     0     -     -       -             -;	# right behind down     & left  front  down
-     30    -     -     -     30    -     -     -     -       -             -;	# right front  up       & left  behind up
45    -     45    -     45    -     45    -     -     -       -             -;	# right front  forward  & left  behind forward
-     0     -     -     -     0     -     -     -     -       -             -;	# right front  down     & left  behind down
@

