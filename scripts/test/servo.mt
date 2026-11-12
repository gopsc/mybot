# s1: angle=200 + offset(-5) = 195 -> 限幅到 max=90
# s2: angle=30, max=-180 -> 反向 180-30 = 150；controller 用 - 继承 dummy-0
@Action
s1.A  s2.A;
  200    30;
@
