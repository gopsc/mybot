# bot4cj

bot4cj是基于仓颉和 Linux I2C 接口的机器人硬件脚本解析器。

## 依赖库
libc、libpthread、liblua-5.4

You may need this

``` bash
sudo ln -s /usr/lib/aarch64-linux-gnu/liblua5.4.so /usr/lib/aarch64-linux-gnu/liblua.so
sudo ln -s /usr/lib/x86_64-linux-gnu/liblua5.4.so /usr/lib/x86_64-linux-gnu/liblua.so
```

## 项目介绍
想要得到一个机器人软件通常比一个普通的软件更为困难，这是因为这个世界上的机器人五花八门，所以它们的软件往往都是独特的，所以我想写一种用于描述机器人硬件的通用的脚本。

`bot4cj` 基于仓颉编程语言和 Linux I2C 接口，提供了便捷的硬件控制能力，支持pca9685、mpu6050，我通常使用树莓派作为宿主机。

## 解析器

树莓派通过I2C接口连接pca9685后使用如下方法使用：

```bash
cat scripts/std.mt | cjpm run	# 蜘蛛机器人脚本
```

## 动作脚本

项目中包含的动作脚本在scripts文件夹下面，这些动作脚本的适配机器人型号如下

```textplain
# PCA9685
1号舵机(s1)		=>	左下水平关节
2号舵机(s2)		=>	左下垂直关节
3号舵机(s3)	 	=>	右下水平关节
4号舵机(s4)		=>	右下垂直关节
5号舵机(s5)		=>	右上水平关节
6号舵机(s6)		=>	右上垂直关节
7号舵机(s7)		=>	左上水平关节
8号舵机(s8)		=>	左上垂直关节
9号舵机(s9)		=>	云台1
10号舵机(s10) 	=>	云台2
扬声器(spk)		=>  仅负责延时
```

适用的机器人建模文件[仓库链接](https://github.com/gopsc/Dashun)

### 机器人脚本语法（.mt）

**.bot文件是旧版动作脚本**

机器人脚本是行列式表格，每列之间以一个或多个空格、制表符分隔，每行以分号（;）结尾。

每个矩阵对象以@name 行开头，@ 行结束。


示例：

```mt

# 在 @Action 矩阵中，硬件变量的参数可以使用别名
@Alias
name      alias;
   A      angle;
   F  frequency;
@


# 定义I2C硬件
@I2C
 name        path;
i2c-0  /dev/i2c-0;
i2c-1  /dev/i2c-1;
@


# 定义pca9685硬件
@PCA9685
     name    I2C   path;
pca9685-0  i2c-1   0x40;
@


# 定义mpu6050硬件
@MPU6050
     name    I2C   path;
mpu6050-0  i2c-1   0x69;
mpu6050-1  i2c-1   0x68;
#mpu6050-2  i2c-0   0x68;
#mpu6050-3  i2c-0   0x69;
@

# 定义扬声器硬件
@Speaker
name  channels  sample_rate  volumn  max_f  min_f;
 spk         2        48000     0.6   5000      -;
@

# 定义舵机硬件
@Servo
 name   max  min  offset  controller  channel;
  s1    90     -       -   pca9685-0        0;	# rb0
  s2   180     -       -           -        1;	# rb1 
  s3   -90     -       -           -        2;	# lb0
  s4  -180     -       -           -        3;	# lb1
  s5    90     -       -           -        4;	# lf0
  s6   180     -       -           -        5;	# lf1
  s7   -90     -       -           -        6;	# rf0
  s8  -180     -       -           -        7;	# rf1
  s9   180     -       -           -        8;	# cam0
 s10   180     -       -           -        9;	# cam1
@

# 行动矩阵为硬件变量输入参数
@Action
s1.A  s2.A  s3.A  s4.A  s5.A  s6.A  s7.A  s8.A  s9.A  s10.A  spk.F  spk.delay;	# column name
  45     -    45     -    45     -    45     -    90     90     10        200;	# stand
  90     -     -     -     -     -     -     -     -      -      -         20;	# left-behind

  45     -     -     -     -     -     -     -     -      -      0        500;	# stand
   -     -    90     -     -     -    45     -     -      -      -         20;	# right-behind

   -     -    45     -     -     -     -     -     -      -    200        500;	# stand
   -     -     -     -    90     -     -     -     -      -      0         20;	# right-front

   -     -     -     -    45     -     -     -     -      -      -        500;	# stand
   -     -     -     -     -     -    90     -     -      -      -         20;	# left-front

   -     -     -     -     -     -    45     -     -      -      -        500;	# stand
   -     -     -     -     -     -     -     -     -      -      -         20;	# stand
@

```
