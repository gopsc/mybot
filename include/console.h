#ifndef CONSOLE_H
#define CONSOLE_H

#define SIZE_ONE_PAGE 6
#define SIZE_OUTPUT_BUFFER 2048
void printvgaat(wchar_t *wstr, int start_x, int start_y);
void printtovga(wchar_t *wstr);
void print_cursor();
void clear_cursor();
void init_console();
void loop_console();
void welcome();
void kbdinfo();

#endif //CONSOLE_H
