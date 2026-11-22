#ifndef ROBOT_H
#define ROBOT_H

#include <stdbool.h>
#include <stddef.h>

/* P0 机器人运行时边界：
 *
 *   core0：UART console / 日志，只通过队列与 core1 交互
 *   core1：Lua + SQL/MT 解析与 I2C/SPI/UART 驱动
 *
 * 这一阶段先把"UI 不被 core1 阻塞"这条实时性前提钉住；Lua 只加载一段
 * 内嵌脚本，验证单状态机、build/call/destroy 和内存水位。
 */

#define ROBOT_LOG_LINE 96
#define ROBOT_LOG_QUEUE_DEPTH 16
#define ROBOT_CMD_QUEUE_DEPTH 8
#define ROBOT_CMD_ARG 32

void robot_init(void);

/* core0 调用：用 robot.c 内的 16KB BSS 栈启动 core1。 */
void robot_start(void);

/* core1 入口：由 multicore_launch_core1_with_stack() 调用。 */
void robot_core1(void);

/* core0 每轮主循环调用：把 core1 日志排空并写到 UART。 */
void robot_poll_ui(void);

/* 预留的协作式停止接口。当前 P0 用它打断心跳睡眠。 */
void robot_request_stop(void);
bool robot_is_running(void);

/* core0 控制台 -> core1 命令队列。profile 为 NULL 表示使用 /profile.txt。 */
void robot_send_run(const char *profile);
void robot_send_stop(void);
void robot_send_status(void);
void robot_send_profile(void);
void robot_send_mem(void);
void robot_send_list(void);
void robot_send_sql(const char *name);
void robot_send_unload(void);
void robot_send_action(const char *name);
void robot_send_repeat(const char *arg);

/* 供 core1 内部/后续驱动使用：非阻塞写入日志队列。 */
void robot_log(const char *fmt, ...);

#endif /* ROBOT_H */
