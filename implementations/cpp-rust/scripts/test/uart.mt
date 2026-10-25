# UART 串口总线测试
# 结构脚本：robots/test/uart.sql（UART uart-0@/dev/serial0@9600 + Timer）
# 运行：cat scripts/test/uart.mt | ./build/mybot --robot=robots/test/uart.sql
#
# 实机测试（需存在 /dev/serial0 或 /dev/ttyUSB0 等串口设备）。
# uart-0.go 列无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# build 打开串口、20 行内保持打开、退出时 destroy 关闭，验证生命周期。
# 若接了另一个对端串口（USB 转串口互连），可手工观察字符收发。
@Action
uart-0.go  t0.delay;
        1        100;
        1        100;
        -        100;
        -        100;
        -        100;
        -        100;
        -        100;
        -        100;
        -        100;
        -        100;
@
