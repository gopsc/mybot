# LCD1206 字符液晶显示示例（HD44780 + PCF8574 I2C 背包）
# 演示：清屏 → 两行文本 → 延时 → 更新一行 → 清屏循环
#
# 用法：cat scripts/test/lcd1206.mt | ./build/mybot --robot=robots/test/lcd1206.sql
# 仿真（无硬件）：proto=virt 设备行加在 SQL 的 INSERT 里（address 列前加 proto 列填 virt）

# 文本别名：.mt 数据格只认数值，文本须经 @Alias + $(name) 间接
@Alias
name      alias;
hello     Hello;
world     World;
temp_line Temperature;
status    System OK;
@

@Action
lcd0.text  lcd0.line  lcd0.clear  lcd0.backlight  timer-0.delay;
$(hello)        0           1             1              -   ;	# 清屏，第 0 行显示 Hello
$(world)        1           -             -             1000 ;	# 第 1 行显示 World，等 1s
$(temp_line)    0           -             -              -   ;	# 更新第 0 行
$(status)       1           -             -             2000 ;	# 更新第 1 行，等 2s
   -            -           1             -              -   ;	# 清屏
   -            -           -             0             500  ;	# 关背光，等 0.5s
   -            -           -             1              -   ;	# 开背光
$(hello)        0           -             -              -   ;	# 重新显示
$(world)        1           -             -             1000 ;	# 等 1s
@
