#include "video.h"
#include "kbd.h"
#include "cncc.h"
#include "console.h"
#include "robot.h"
#include "try.h"
#include <string.h>
#include <wchar.h>

/* 帧缓冲区打印点游标 */
static int fb_cursor_x = 0;
static int fb_cursor_y = 0;

static int jipt_top = 0;
/* 直入缓冲区，能容纳一行英文内容 */
static wchar_t jipt_buf[ONE_LINE_CHAR_EN];



/* 宽字符判断，建议使用标准库函数 */

/* 
 * 判断宽字符是否为ASCII字符。用于判断
 * 字符是否需要更少缩进 
 * ASCII字符范围：0-127
 */
static int is_wchar_ascii(wchar_t wc) {
  return (wc >= 0 && wc <= 0x7F);
}

/* 判断宽字符是否为字母 */
static int is_letter(wchar_t wc) {
    return (wc >= L'a' && wc <= L'z') || (wc >= L'A' && wc <= L'Z');
}

/* 判断宽字符是否为数字字符 */
static int is_digit(wchar_t wc) {
    return wc >= L'0' && wc <= L'9';
}

/*
 * x轴游标向后移动的量，英文比汉字窄
 */
static int get_dx(wchar_t wc) {
    return (is_wchar_ascii(wc)) ? CHAR_WIDTH_EN : CHAR_WIDTH_CN; 
}


/* 即时输入缓冲区是空的 */
static int jipt_is_empty() {
	return jipt_top == 0;
}

/* 即时输入缓冲区没满 */
static int jipt_is_full() {
	return jipt_top == ONE_LINE_CHAR_EN - 1;
}


static int is_ascii(char c) {
	return c < 256;
}



/* 帧缓冲区坐标换行操作 */
static void change_line(int h, int *px, int *py) {
  *px = 0;
  *py += h;
}

/*
 *
 * 屏幕向上滚动，返回滚动的幅度。这个函数
 * 我不是很搞得懂，为什么要加上一个CHAR_HEIGHT
 *
 */
static int lines_roll(int y, int ipt_h, int a) {
  int exh = y + ipt_h - ONE_COL; /* y轴游标超过了多少 */
  int h = exh + 1 * CHAR_HEIGHT; /* 还差多少能移够一个字符的空间 */
  up1(h, a, ipt_h);     /* 屏幕向上移动 */
  return h;
}






/*
 *
 * 打印到vga的某个位置，你需要保证每一行的高度是相等的。
 *
 *
 * 1. 需要传入打印位置的指针。（ 需要在调用之前判断是否越界）
 *
 * 2. 应当传入要打印的字符大小
 *
 * 3. 应当传入标准中文字符的大小
 *
 * 4. 应该传入横轴差距
 * 
 * 5. 传入颜色，颜色参数是布尔型
 *
 *
 * 20250909(qing): 应该加入对\t的解析，甚至\b等
 *
 */
static void print_vga(wchar_t wc, int *px, int *py, int target_w, int target_h, int dx, int color) {
    
    if (wc == L'\n' || wc == L'\r') {	/* TODO: 这两个字符有什么不同吗？ */
      change_line(target_h, px, py);
    }
    else {
      rectangle(*px, *py, *px + target_w - 1, *py + target_h - 1, 1, 1); /* 包含原点所以减一 */
      drawvfont(*px, *py, wc, target_w, target_h, 0);
      *px += dx;
    }
    
}


/*
 *
 * 终端打印基本函数。 需要从外部输入输入框的高度，以实现输入器额外空间
 *
 *
 * 1.使用while确保移动到合适的范围内。
 * 
 * 2.问题在于在非终端打印下亦可造成换行，建议拆分函数。可拆分之后定位打印如何实现？
 *
 */
static void _printtovga(wchar_t *wstr, int con_height) {
  while (*wstr != L'\0') {
    wchar_t wc = *(wstr++);					/* 遍历宽字符 */
    int dx = get_dx(wc);					/* 根据字符类型判断移动 */
    while (fb_cursor_x + dx >= ONE_LINE_BITS) {			/* xx越界换行 */
      change_line(CHAR_HEIGHT, &fb_cursor_x, &fb_cursor_y);
    }
    while (fb_cursor_y + CHAR_HEIGHT >= con_height) {		/* yy越界滚动 */
      fb_cursor_y -= lines_roll(fb_cursor_y, IPT_H, 255);	/* 屏幕上移至1个字符高; */
    }
    /* 打印至vga屏幕上面 */
    print_vga(wc,  &fb_cursor_x, &fb_cursor_y, CHAR_WIDTH_CN, CHAR_HEIGHT, dx, 0);
  }
}

/* 终端定位打印，暂时更换游标，线程不安全。
 *
 * 也许这游标应该用访问器封装？特别注意不要让终端换行
 */
void printvgaat(wchar_t *wstr, int start_x, int start_y) {
    int old_x = fb_cursor_x; /* 记录游标 */
    int old_y = fb_cursor_y;
    fb_cursor_x  = start_x;  /* 替换游标 */
    fb_cursor_y  = start_y;
    _printtovga(wstr, ONE_COL); /* 打印字符（整个屏幕无例外） */
    fb_cursor_x  = old_x;       /* 恢复游标 */
    fb_cursor_y  = old_y;
}

/*  打印到VGA的用户接口，默认以标准输入框高度作为输入法例外   */
void printtovga(wchar_t *wstr) {
  _printtovga(wstr, IPT_PLACE_H);
}


/* 打印光标 */
void print_cursor() {
	printvgaat(L"_", fb_cursor_x, fb_cursor_y);
}

/* 清除光标 */
void clear_cursor() {
	int jipt_px0 = fb_cursor_x;	/* position x0 */
	int jipt_py0 = fb_cursor_y;	/* position y0 */
	int jipt_px1 = fb_cursor_x + CHAR_WIDTH_EN - 1;	/* position x1 包含原点所以减一 */
	int jipt_py1 = fb_cursor_y + CHAR_HEIGHT - 1;	/* position y1 包含原点所以减一 */
	rectangle(jipt_px0, jipt_py0, jipt_px1,  jipt_py1, 1, 1);	/* 清除屏幕字符图案 */
}



/* 初始化控制台。 
 *
 * 初始化直入缓冲区、刷新屏幕，打印欢迎语和测试信息
 * 
 * 我想将其移动到一个新的文件中
 */
void init_console() {

	/* 初始化缓冲区 */
	jipt_top = 0;
	jipt_buf[0] = L'\0';

	clear(255);		/* 以深色填充屏幕 */

	/* 打印输入法分割线，其实可以使用line()绘制 */
	printvgaat(L"----------------", 0, IPT_PLACE_H);	
}


/////////////////////////////////////////////////////////////////////
/* 控制台相关的内容 */

/* 用于在VGA屏幕上打印欢迎语句 */
void welcome() {
    printtovga(L"我们的项目地址是：\n");
    printtovga(L"https://gitcode.com/qingss0/pico-vga\n");
    printtovga(L"————：qing，2025年8月26日\n\n");
}

/* 打印出键盘信息 */
void kbdinfo() {
    printtovga(L"+--------第一层---------+\n");
    printtovga(L"| 0 | 1 | 2 | 3 | 4 | 5 |\n");
    printtovga(L"| 6 | 7 | 8 | 9 | A | B |\n");
    printtovga(L"| C | D | E | F | G | H |\n");
    printtovga(L"| I | J | K | L | M | N |\n");
    printtovga(L"| O | P | Q | R | S | T |\n");
    printtovga(L"| U | V | W | X | Y |   |\n");
    printtovga(L"+-----------------------+\n");

    printtovga(L"+--------第二层-----000000----------------------+\n");
    printtovga(L"| ESC     | +       | - | * | -     | enter     |\n");
    printtovga(L"| TAB     | Z       | . | = | R     | backsapce |\n");
    printtovga(L"| CTRL    | [       | ] | D | V     | space     |\n");
    printtovga(L"| SHIFT   | Z       | X | C | V     | B         |\n");
    printtovga(L"| ALT     | Y       | P | O | return| U         |\n");
    printtovga(L"| BT_CLR 0| BT_SEL 0|   |   |       | U         |\n");
    printtovga(L"+-----------------------------------------------+\n");
}


static int flag_py = 0;                /* 已经进行了拼音映射否 */
static int flag_pg = 0;			/* 当前的输入法页数 */
static int flag_pge = 0;		/* 是否到达了最终页 */
static int flag_pg_keep = 0;		/* 是否处于输入法激活状态 */
static int flag_pg_cnt = 0;		/* 输入法页最大值计数 */
static int jipt_x = -CHAR_WIDTH_EN;    /* 即时输入缓冲区的游标 */
static wchar_t *p = jipt_buf;          /* 指向即时输入缓冲文字区的指针 */
static wchar_t *pym = NULL;            /* 当前拼音映射结果 */

static void _clear_method_box() {
	flag_py = 0;
	flag_pg = 0;
	flag_pge = 0;
	flag_pg_keep = 0;
	flag_pg_cnt = 0;
}

/* 清除整个直入区域 */
static void _clear_method_all() {
	int jipt_px0 = jipt_x;			/* position x0 */
	int jipt_py0 = JIPT_H;			/* position y0 */
	int jipt_px1 = ONE_LINE_BITS - 1;	/* position x1 包含原点所以减一 */
	int jipt_py1 = JIPT_H + CHAR_HEIGHT - 1;	/* position y1 包含原点所以减一 */
	rectangle(jipt_px0, jipt_py0, jipt_px1,  jipt_py1, 1, 1);	/* 清除屏幕字符图案 */
}

/* 清除直入区域的最后一个字符 */
static void _clear_method_last() {
	int jipt_px0 = jipt_x;			/* position x0 */
	int jipt_py0 = JIPT_H;			/* position y0 */
	int jipt_px1 = jipt_x + CHAR_WIDTH_EN - 1;	/* position x1 包含原点所以减一 */
	int jipt_py1 = JIPT_H + CHAR_HEIGHT - 1;	/* position y1 包含原点所以减一 */
	rectangle(jipt_px0, jipt_py0, jipt_px1,  jipt_py1, 1, 1);	/* 清除屏幕字符图案 */
}

/* 清除直入区的待选汉字 */
static void _clear_method_pym() {
	int jipt_px0 = 0;
	int jipt_py0 = PY_LELECT_H;
	int jipt_px1 = ONE_LINE_BITS - 1;
	int jipt_py1 = PY_LELECT_H + CHAR_HEIGHT - 1;
	rectangle(jipt_px0, jipt_py0, jipt_px1, jipt_py1, 1, 1);
}

static void _clear_jipt_buf() {

	jipt_buf[0] = '\0';
	jipt_top = 0;
	p = jipt_buf;
	jipt_x = -CHAR_WIDTH_EN;
}

static void _outputto(wchar_t wc) {

	if (wc == L'\n') {

		clear_cursor();
		printtovga(L"\n");
		eval_tryc();
		print_cursor();
	}

	else if (!enqueue_tryc(wc)) {

		wchar_t buf[] = {wc, L'\0'};
		clear_cursor();
		printtovga(buf);
		print_cursor();
	}
}


/* ---- P4-B 命令行：输入 /run p4、/stop、/status、/profile ---- */
static wchar_t cmd_buf[ROBOT_CMD_ARG];
static int cmd_top = 0;
static int cmd_x = 0;
static int cmd_mode = 0;

static void clear_cmd_line(void) {
    rectangle(0, JIPT_H, ONE_LINE_BITS - 1, JIPT_H + CHAR_HEIGHT - 1, 1, 1);
    cmd_top = 0;
    cmd_x = 0;
}

static void cmd_put(wchar_t wc) {
    if (cmd_top >= ROBOT_CMD_ARG - 1) {
        return;
    }
    cmd_buf[cmd_top++] = wc;
    cmd_buf[cmd_top] = L'\0';
    wchar_t buf[] = {wc, L'\0'};
    printvgaat(buf, cmd_x, JIPT_H);
    cmd_x += CHAR_WIDTH_EN;
}

static void cmd_backspace(void) {
    if (cmd_top <= 0) {
        return;
    }
    --cmd_top;
    cmd_buf[cmd_top] = L'\0';
    cmd_x -= CHAR_WIDTH_EN;
    rectangle(cmd_x, JIPT_H, cmd_x + CHAR_WIDTH_EN - 1,
        JIPT_H + CHAR_HEIGHT - 1, 1, 1);
}

static void cmd_dispatch(void) {
    char text[ROBOT_CMD_ARG];
    int n = 0;
    for (int i = 0; i < cmd_top && i < (int)sizeof(text) - 1; ++i) {
        text[n++] = (char)cmd_buf[i];
    }
    text[n] = '\0';
    clear_cmd_line();
    cmd_mode = 0;
    printtovga(L"\n");

    char *p = text;
    while (*p == ' ' || *p == '\t') ++p;
    char *cmd = p;
    while (*p != '\0' && *p != ' ' && *p != '\t') ++p;
    if (*p != '\0') {
        *p++ = '\0';
        while (*p == ' ' || *p == '\t') ++p;
    }
    char *arg = p;
    if (strcmp(cmd, "run") == 0) {
        /* 键盘没有下划线，提供几个 profile 简称。 */
        if (strcmp(arg, "pca") == 0) arg = "pca9685";
        else if (strcmp(arg, "pcafake") == 0) arg = "pca9685_fake";
        else if (strcmp(arg, "ads") == 0) arg = "ads1015";
        else if (strcmp(arg, "spifake") == 0) arg = "spi_fake";
        else if (strcmp(arg, "uartfake") == 0) arg = "uart_fake";
        else if (strcmp(arg, "relay") == 0) arg = "relay-test";
        robot_send_run(arg[0] != '\0' ? arg : NULL);
        printtovga(L"[run]\n");
    } else if (strcmp(cmd, "stop") == 0) {
        robot_send_stop();
        printtovga(L"[stop]\n");
    } else if (strcmp(cmd, "status") == 0) {
        robot_send_status();
        printtovga(L"[status]\n");
    } else if (strcmp(cmd, "profile") == 0) {
        robot_send_profile();
        printtovga(L"[profile]\n");
    } else if (cmd[0] != '\0') {
        printtovga(L"unknown command\n");
    }
}

/* 处理一个键盘事件。函数只做状态变更，不负责排空队列。 */
static void handle_key(uint16_t k) {
    /* P0 临时停止键：Tab（输入法缓冲区为空时）。P1 换成 :stop 命令行。 */
    if (cmd_mode) {
        if (k == L'\r') {
            cmd_dispatch();
        } else if (k == L'\b') {
            cmd_backspace();
        } else if (k >= 32 && k < 127) {
            cmd_put((wchar_t)k);
        }
        return;
    }

    if (k == L'/' && jipt_top == 0) {
        cmd_mode = 1;
        clear_cmd_line();
        cmd_put(L'/');
        cmd_top = 0;   /* 斜杠只是提示符，不进入命令文本 */
        cmd_x = CHAR_WIDTH_EN;
        return;
    }

    if (k == L'\t' && jipt_top == 0) {
        robot_request_stop();
        clear_cursor();
        printtovga(L"[robot stop]\n");
        print_cursor();
        return;
    }

    if (is_ascii(k) && is_letter(k) && !jipt_is_full()) {	/* 缓冲区有空才执行入栈 */
        _clear_method_box();

        jipt_buf[jipt_top++] = (wchar_t)k;	/* 字符进入缓冲区 */
        jipt_buf[jipt_top] = L'\0';	/* 放置终止符号 */
        jipt_x += CHAR_WIDTH_EN;	/* 横轴坐标自增 */
        printvgaat(p++, jipt_x, JIPT_H);	/* 打印新的字符 */
    }
    /* ---------------- */
    /* 匹配删减模式 */
    else if (is_ascii(k) && k == L'\b' && !jipt_is_empty()) {
        _clear_method_box();

        *(--p) = L'\0';	/* 放置终止符号 */
        jipt_top--;		/* 栈顶指针自减 */
        _clear_method_last();
        jipt_x -= CHAR_WIDTH_EN;	/* 横轴坐标自减 */
    }
    /* 直入缓冲区空的，输入回车 */
    else if (is_ascii(k) && k == L'\r' && jipt_top == 0) {
        _outputto(L'\n');
    }
    /* 直入缓冲区不为空，输出直入缓冲区 */
    else if (is_ascii(k) && k == L'\r' && jipt_top > 0) {
        for (wchar_t *p = jipt_buf; *p != L'\0'; ++p) {
            _outputto(*p);
        }
        _clear_jipt_buf();
        _clear_method_box();
        _clear_method_all();
    }
    /* ---------------- */
    else if (is_ascii(k) && k == L'=' && !flag_pge && jipt_top > 0) {	/* + */
        flag_py = 0;
        flag_pg++;
    }
    else if (k == L'=' && jipt_top == 0) {
        _outputto(k);
    }
    else if (k == L'-' && flag_pg && jipt_top > 0) {
        flag_py = 0;
        flag_pg--;
    }
    else if (k == L';' && jipt_top == 0) {
        _outputto(k);
    }
    else if (k == L' ' && jipt_top == 0) {
        _outputto(k);
    }
    else if (k == L'+' && jipt_top == 0) {
        _outputto(k);
    }
    else if (k == L'-' && jipt_top == 0) {
        _outputto(k);
    }
    else if (k == L'*' && jipt_top == 0) {
        _outputto(k);
    }
    else if (k == L'/' && jipt_top == 0) {
        _outputto(k);
    }
    /* ---------------- */
    /* 匹配选择模式 */
    else if (is_ascii(k) && is_digit(k) && jipt_top == 0) {
        _outputto(k);
    }
    else if (is_ascii(k) && is_digit(k) && jipt_top > 0 && flag_pg_keep) {
        int num = k - L'0' - 1;
        if (num < SIZE_ONE_PAGE && num < flag_pg_cnt) {	/* 等于0时选择不了字 */
            int idx = flag_pg * SIZE_ONE_PAGE + num;
            _outputto(pym[idx]);
            _clear_jipt_buf();
            _clear_method_all();
            _clear_method_box();
        }
    }
}

/* 拼音候选行刷新：原 loop_console 的“无键事件”分支。 */
static void update_ime(void) {
    if (flag_py) {
        return;
    }

    pym = py_ime(jipt_buf);	/* 进行拼音匹配 */
    flag_py = 1;		/* 已经匹配  可以利用flag进行字符串分段 */
    flag_pg_cnt = 0;

    _clear_method_pym();

    int jipt_po = 0;
    int start = flag_pg * SIZE_ONE_PAGE;
    size_t top = wcslen(pym);
    while (start + flag_pg_cnt < top && flag_pg_cnt < SIZE_ONE_PAGE) {
        wchar_t buf0[] = {L'0' + flag_pg_cnt + 1, L'\0'}; printvgaat(buf0, jipt_po, PY_LELECT_H);	jipt_po += CHAR_WIDTH_EN;
        wchar_t buf1[] = {L'.', L'\0'}; printvgaat(buf1, jipt_po, PY_LELECT_H);	jipt_po += CHAR_WIDTH_EN;
        wchar_t buf2[] = {pym[start + flag_pg_cnt], L'\0'}; printvgaat(buf2, jipt_po, PY_LELECT_H);	jipt_po += CHAR_WIDTH_CN;
        jipt_po += CHAR_WIDTH_EN;	/* 间隔 */
        flag_pg_keep = 1;
        flag_pg_cnt++;
    }
    flag_pge = (flag_pg_cnt + start < top) ? 0 : 1;
}

/* 终端轮询：从 core0 主循环调用，不再自己死循环。 */
void console_poll(void) {
    while (!kbd_queue_empty()) {
        uint16_t k = kbd_queue_pop();
        if (k != 0) {
            handle_key(k);
        }
    }
    update_ime();
}

/* 兼容旧调用点：需要独占循环的裸机路径仍可用。 */
void loop_console(void) {
    while (true) {
        console_poll();
    }
}
