#ifndef CONSOLE_H
#define CONSOLE_H

/* Headless console：UART0 上的一行式命令控制台。
 * 不再包含 VGA/键盘/鼠标/输入法。 */
void console_init(void);
void console_poll(void);

/* 日志输出前擦掉当前输入行，输出后重画。 */
void console_erase_line(void);
void console_redraw(void);

#endif /* CONSOLE_H */
