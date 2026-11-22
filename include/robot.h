#ifndef ROBOT_H
#define ROBOT_H

#include <stdbool.h>
#include <stddef.h>

/* P0 机器人运行时边界：
 *
 *   core0：VGA / console / USB HID，只通过队列与 core1 交互
 *   core1：Lua + 后续的 SQL/MT 解析与 I2C/SPI/UART 驱动
 *
 * 这一阶段先把"UI 不被 core1 阻塞"这条实时性前提钉住；Lua 只加载一段
 * 内嵌脚本，验证单状态机、build/call/destroy 和内存水位。
 */

#define ROBOT_LOG_LINE 96
#define ROBOT_LOG_QUEUE_DEPTH 16

void robot_init(void);

/* core0 调用：用 robot.c 内的 16KB BSS 栈启动 core1。 */
void robot_start(void);

/* core1 入口：由 multicore_launch_core1_with_stack() 调用。 */
void robot_core1(void);

/* core0 每轮主循环调用：把 core1 日志排空并显示到 VGA。 */
void robot_poll_ui(void);

/* 预留的协作式停止接口。当前 P0 用它打断心跳睡眠。 */
void robot_request_stop(void);
bool robot_is_running(void);

/* 供 core1 内部/后续驱动使用：非阻塞写入日志队列。 */
void robot_log(const char *fmt, ...);

#endif /* ROBOT_H */
