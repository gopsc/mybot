#ifndef CONSOLE_H
#define CONSOLE_H

void printvgaat(wchar_t *wstr, int start_x, int start_y);
void printtovga(wchar_t *wstr);
void init_console();
void loop_console();
void welcome();
void kbdinfo();

#endif //CONSOLE_H
