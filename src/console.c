/* Headless console：UART0 上的一行式命令控制台。
 *
 * 没有 VGA framebuffer、键盘队列、鼠标、USB HID 或中文输入法。
 * 日志始终走同一个串口；命令行支持 /run、/stop、/status 等。
 * 终端支持 ANSI 时，上/下方向键可回看历史命令。
 */

#include "console.h"
#include "robot.h"

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "pico/stdlib.h"

#define CONSOLE_HISTORY_MAX 8

static char cmd_buf[ROBOT_CMD_ARG];
static int cmd_len;
static char history[CONSOLE_HISTORY_MAX][ROBOT_CMD_ARG];
static int history_count;
static int history_pos;

/* 解析 ESC [ A / ESC [ B；其他 CSI 序列整段丢弃。 */
static int esc_state;
static int skip_lf;
static bool console_active;

static void console_flush(void) {
    fflush(stdout);
}

static void console_prompt(void) {
    fputs("> ", stdout);
    fputs(cmd_buf, stdout);
    console_flush();
}

static void console_newline(void) {
    fputs("\r\n", stdout);
    console_flush();
}

static void console_line(const char *text) {
    fputs(text, stdout);
    console_newline();
}

static void console_clear_input(void) {
    cmd_buf[0] = '\0';
    cmd_len = 0;
}

static void console_set_input(const char *text) {
    size_t n = strlen(text);
    if (n >= sizeof(cmd_buf)) {
        n = sizeof(cmd_buf) - 1;
    }
    memcpy(cmd_buf, text, n);
    cmd_buf[n] = '\0';
    cmd_len = (int)n;
}

void console_erase_line(void) {
    if (!console_active) {
        return;
    }
    fputs("\r\x1b[2K", stdout);
    console_flush();
}

/* 日志打印后重画当前输入行。 */
void console_redraw(void) {
    if (!console_active) {
        return;
    }
    console_erase_line();
    console_prompt();
}

static void console_history_save(const char *line) {
    if (line == NULL || line[0] == '\0') {
        return;
    }
    if (history_count > 0) {
        if (strcmp(history[history_count - 1], line) == 0) {
            history_pos = history_count;
            return;
        }
    }
    if (history_count == CONSOLE_HISTORY_MAX) {
        memmove(history[0], history[1],
            sizeof(history[0]) * (CONSOLE_HISTORY_MAX - 1));
        --history_count;
    }
    snprintf(history[history_count], sizeof(history[0]), "%s", line);
    ++history_count;
    history_pos = history_count;
}

static void console_history_show(int index) {
    console_clear_input();
    if (index >= 0 && index < history_count) {
        console_set_input(history[index]);
    }
    console_redraw();
}

static void console_history_prev(void) {
    if (history_count == 0 || history_pos <= 0) {
        return;
    }
    --history_pos;
    console_history_show(history_pos);
}

static void console_history_next(void) {
    if (history_pos >= history_count) {
        return;
    }
    ++history_pos;
    if (history_pos >= history_count) {
        console_clear_input();
        console_redraw();
    } else {
        console_history_show(history_pos);
    }
}

static char *trim_left(char *s) {
    while (*s != '\0' && isspace((unsigned char)*s)) {
        ++s;
    }
    return s;
}

static void split_command(char *line, char **cmd, char **arg) {
    char *p = trim_left(line);
    *cmd = p;
    while (*p != '\0' && !isspace((unsigned char)*p)) {
        ++p;
    }
    if (*p != '\0') {
        *p++ = '\0';
        p = trim_left(p);
    }
    char *end = p + strlen(p);
    while (end > p && isspace((unsigned char)end[-1])) {
        --end;
    }
    *end = '\0';
    *arg = p;
}

static void console_dispatch(void) {
    char line[ROBOT_CMD_ARG];
    memcpy(line, cmd_buf, (size_t)cmd_len + 1);
    console_newline();
    if (cmd_len == 0) {
        console_prompt();
        return;
    }

    char *full = trim_left(line);
    if (*full == '/') {
        ++full;
        full = trim_left(full);
    }
    if (*full == '\0') {
        console_clear_input();
        console_prompt();
        return;
    }

    console_history_save(full);
    console_clear_input();
    history_pos = history_count;

    char *cmd = full;
    char *arg = NULL;
    split_command(cmd, &cmd, &arg);

    if (strcmp(cmd, "run") == 0) {
        /* 键盘没有下划线，保留几个 profile 简称。 */
        if (strcmp(arg, "pca") == 0) arg = "pca9685";
        else if (strcmp(arg, "pcafake") == 0) arg = "pca9685_fake";
        else if (strcmp(arg, "ads") == 0) arg = "ads1015";
        else if (strcmp(arg, "spifake") == 0) arg = "spi_fake";
        else if (strcmp(arg, "uartfake") == 0) arg = "uart_fake";
        else if (strcmp(arg, "relay") == 0) arg = "relay-test";
        robot_send_run(arg[0] != '\0' ? arg : NULL);
        console_line("[run]");
    } else if (strcmp(cmd, "stop") == 0) {
        robot_send_stop();
        console_line("[stop]");
    } else if (strcmp(cmd, "status") == 0) {
        robot_send_status();
        console_line("[status]");
    } else if (strcmp(cmd, "profile") == 0) {
        robot_send_profile();
        console_line("[profile]");
    } else if (strcmp(cmd, "mem") == 0) {
        robot_send_mem();
        console_line("[mem]");
    } else if (strcmp(cmd, "list") == 0) {
        robot_send_list();
        console_line("[list]");
    } else if (strcmp(cmd, "sql") == 0) {
        robot_send_sql(arg[0] != '\0' ? arg : NULL);
        console_line("[sql]");
    } else if (strcmp(cmd, "unload") == 0) {
        robot_send_unload();
        console_line("[unload]");
    } else if (strcmp(cmd, "action") == 0) {
        robot_send_action(arg[0] != '\0' ? arg : NULL);
        console_line("[action]");
    } else if (strcmp(cmd, "repeat") == 0) {
        robot_send_repeat(arg[0] != '\0' ? arg : NULL);
        console_line("[repeat]");
    } else if (strcmp(cmd, "devices") == 0) {
        robot_send_devices();
        console_line("[devices]");
    } else if (strcmp(cmd, "device") == 0) {
        robot_send_device(arg[0] != '\0' ? arg : NULL);
        console_line("[device]");
    } else if (strcmp(cmd, "i2cscan") == 0) {
        robot_send_i2cscan(arg[0] != '\0' ? arg : NULL);
        console_line("[i2cscan]");
    } else if (strcmp(cmd, "vars") == 0) {
        robot_send_vars();
        console_line("[vars]");
    } else if (strcmp(cmd, "structs") == 0) {
        robot_send_structs();
        console_line("[structs]");
    } else if (strcmp(cmd, "loop") == 0) {
        robot_send_loop(arg[0] != '\0' ? arg : NULL);
        console_line("[loop]");
    } else if (strcmp(cmd, "reload") == 0) {
        robot_send_reload();
        console_line("[reload]");
    } else if (strcmp(cmd, "use") == 0) {
        robot_send_use(arg[0] != '\0' ? arg : NULL);
        console_line("[use]");
    } else if (strcmp(cmd, "autostart") == 0) {
        robot_send_autostart(arg[0] != '\0' ? arg : NULL);
        console_line("[autostart]");
    } else if (strcmp(cmd, "help") == 0) {
        console_line("run [sql] [script] | sql <name> | action [name] | repeat <name> [count] [delay_ms]");
        console_line("loop <name> <period_ms> | loop stop | stop | status | profile | mem | list");
        console_line("reload | use <profile> | autostart <action> <period_ms> | autostart off");
        console_line("devices | device <name> | i2cscan [0|1] | vars | structs | unload | help");
        console_line("history: terminal up/down (ANSI)");
    } else {
        console_line("unknown command");
    }
    console_prompt();
}

static void console_backspace(void) {
    if (cmd_len <= 0) {
        return;
    }
    --cmd_len;
    cmd_buf[cmd_len] = '\0';
    fputs("\b \b", stdout);
    console_flush();
}

static void console_put_char(int c) {
    if (cmd_len >= (int)sizeof(cmd_buf) - 1) {
        return;
    }
    cmd_buf[cmd_len++] = (char)c;
    cmd_buf[cmd_len] = '\0';
    fputc(c, stdout);
    console_flush();
}

void console_poll(void) {
    if (!console_active) {
        return;
    }
    int budget = 32;
    while (budget-- > 0) {
        int c = getchar_timeout_us(0);
        if (c == PICO_ERROR_TIMEOUT) {
            break;
        }

        if (esc_state == 1) {
            if (c == '[') {
                esc_state = 2;
            } else if (c == 'O') {
                esc_state = 3;
            } else {
                esc_state = 0;
            }
            continue;
        }
        if (esc_state == 2) {
            if (c >= 0x40 && c <= 0x7e) {
                esc_state = 0;
                if (c == 'A') {
                    console_history_prev();
                } else if (c == 'B') {
                    console_history_next();
                }
            }
            continue;
        }
        if (esc_state == 3) {
            esc_state = 0;
            if (c == 'A') {
                console_history_prev();
            } else if (c == 'B') {
                console_history_next();
            }
            continue;
        }

        if (c == 0x1b) {
            esc_state = 1;
            continue;
        }
        if (c == 0x03) {   /* Ctrl-C：停止当前脚本 */
            robot_request_stop();
            fputs("^C", stdout);
            console_newline();
            console_clear_input();
            console_prompt();
            continue;
        }
        if (c == '\r') {
            skip_lf = 1;
            console_dispatch();
            continue;
        }
        if (c == '\n') {
            if (skip_lf) {
                skip_lf = 0;
            } else {
                console_dispatch();
            }
            continue;
        }
        skip_lf = 0;
        if (c == '\b' || c == 0x7f) {
            console_backspace();
        } else if (c >= 32 && c < 127) {
            console_put_char(c);
        }
    }
}

void console_init(void) {
    console_active = true;
    console_clear_input();
    history_count = 0;
    history_pos = 0;
    esc_state = 0;
    skip_lf = 0;

    fputs("\r\n[console] mybot-lite headless (UART0)\r\n", stdout);
    fputs("[console] type /help for commands\r\n", stdout);
    console_prompt();
}
