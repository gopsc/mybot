/* pico-umac
 *
 * Main loop to initialise umac, and run main event loop (piping
 * keyboard/mouse events in).
 *
 * Copyright 2024 Matt Evans
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation files
 * (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge,
 * publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 * BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
 * ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 *
 *
 *
 * 提示，源代码经过qing的修改，仍然遵循
 * MIT协议。
 *
 *
 * “无论经过怎样的阻挡，最终还是回到你的身边。”
 *
 * 现在该代码不再引导umac，而是启动一个宽字符中文终端。
 * 2025
 */
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <wchar.h>
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pio.h"
#include "hardware/sync.h"
#include "pico/multicore.h"
#include "pico/stdlib.h"
#include "pico/time.h"
#include "hw.h"
#include "video.h"
#include "kbd.h"
#include "graph.h"
#include "cncc.h"

#include "bsp/rp2040/board.h"
#include "tusb.h"

//#include "umac.h"

#if USE_SD
#include "f_util.h"
#include "ff.h"
#include "rtc.h"
#include "hw_config.h"
#endif

////////////////////////////////////////////////////////////////////////////////
// Imports and data

extern void     hid_app_task(void);
extern int cursor_x;
extern int cursor_y;
extern int cursor_button;


/*
 *
 * 分配一段内存，该内存被传输给 video_init()
 *
 * 用于传输视频的内存空间，单位是8位，即每个变量8个像素
 *
 */
static uint8_t video_ram[ONE_COL * ONE_LINE];
////////////////////////////////////////////////////////////////////////////////

/* 初始化gpio */
static void     io_init()
{
        gpio_init(GPIO_LED_PIN);
        gpio_set_dir(GPIO_LED_PIN, GPIO_OUT);   /* 设置 GPIO 引脚的方向（输入或输出）*/
}

/* 周期性执行的led灯事件，每隔
 * 一段时间切换一次状态 */
static void     poll_led_etc()
{
        static int led_on = 0;
        static absolute_time_t last = 0;
        absolute_time_t now = get_absolute_time();

        if (absolute_time_diff_us(last, now) > 500*1000) {
                last = now;

                led_on ^= 1;
                gpio_put(GPIO_LED_PIN, led_on);
        }
}

/* 这些是鼠标游标，我们暂时用不上 */
//static int umac_cursor_x = 0;
//static int umac_cursor_y = 0;
//static int umac_cursor_button = 0;
/*
 * umac的事件循环
 */
//static void     poll_umac()
//{
//        static absolute_time_t last_1hz = 0;
//        static absolute_time_t last_vsync = 0;
//        absolute_time_t now = get_absolute_time();

//        umac_loop();

//        int64_t p_1hz = absolute_time_diff_us(last_1hz, now);
//        int64_t p_vsync = absolute_time_diff_us(last_vsync, now);
//        if (p_vsync >= 16667) {
                /* FIXME: Trigger this off actual vsync */
 //               umac_vsync_event();
 //               last_vsync = now;
 //       }
//        if (p_1hz >= 1000000) {
//                umac_1hz_event();
//                last_1hz = now;
//        }

//        int update = 0;
//        int dx = 0;
//        int dy = 0;
//        int b = umac_cursor_button;
//        if (cursor_x != umac_cursor_x) {
//                dx = cursor_x - umac_cursor_x;
//                umac_cursor_x = cursor_x;
//                update = 1;
//        }
//        if (cursor_y != umac_cursor_y) {
//                dy = cursor_y - umac_cursor_y;
//                umac_cursor_y = cursor_y;
//                update = 1;
//        }
//        if (cursor_button != umac_cursor_button) {
//                b = cursor_button;
//                umac_cursor_button = cursor_button;
//                update = 1;
//        }
//        if (update) {
                // 这里应该有图像绘制的方法
//                umac_mouse(dx, -dy, b);
//        }

//        if (!kbd_queue_empty()) {
//                uint16_t k = kbd_queue_pop();
//                umac_kbd_event(k & 0xff, !!(k & 0x8000));
//        }
//}

#if USE_SD

/* 硬盘读取 */
static int      disc_do_read(void *ctx, uint8_t *data, unsigned int offset, unsigned int len)
{
        FIL *fp = (FIL *)ctx;
        f_lseek(fp, offset);
        unsigned int did_read = 0;
        FRESULT fr = f_read(fp, data, len, &did_read);
        if (fr != FR_OK || len != did_read) {
                printf("disc: f_read returned %d, read %u (of %u)\n", fr, did_read, len);
                return -1;
        }
        return 0;
}

/* 硬盘写入 */
static int      disc_do_write(void *ctx, uint8_t *data, unsigned int offset, unsigned int len)
{
        FIL *fp = (FIL *)ctx;
        f_lseek(fp, offset);
        unsigned int did_write = 0;
        FRESULT fr = f_write(fp, data, len, &did_write);
        if (fr != FR_OK || len != did_write) {
                printf("disc: f_write returned %d, read %u (of %u)\n", fr, did_write, len);
                return -1;
        }
        return 0;
}

/* 硬盘文件描述符指针 */
//static FIL discfp;
#endif

// 设置硬盘（TF卡）
//static void     disc_setup(disc_descr_t discs[DISC_NUM_DRIVES])
//{
//#if USE_SD
//        char *disc0_name;
//        const char *disc0_ro_name = "umac0ro.img";
//        const char *disc0_pattern = "umac0*.img";

        /* Mount SD filesystem */
//        printf("Starting SPI/FatFS:\n");
//        set_spi_dma_irq_channel(true, false);   // （这是个自定义函数）
//        sd_card_t *pSD = sd_get_by_num(0);      // 这个函数在本项目的sd_hw_config.c里面
//        FRESULT fr = f_mount(&pSD->fatfs, pSD->pcName, 1);      // 将文件系统挂载到指定的逻辑驱动器（通常对应物理存储设备，如 SD 卡），是进行
//        printf("  mount: %d\n", fr);                            // 所有文件操作（如读写文件、遍历目录）的前置步骤。
//        if (fr != FR_OK) {
//                printf("  error mounting disc: %s (%d)\n", FRESULT_str(fr), fr);
//                goto no_sd;
//        }

        /* Look for a disc image 寻找一个硬盘镜像*/
//        DIR di = {0};
//        FILINFO fi = {0};
//        fr = f_findfirst(&di, &fi, "/", disc0_pattern); //在指定目录中查找第一个符合条件的文件或
//        if (fr != FR_OK) {
//                printf("  Can't find images %s: %s (%d)\n", disc0_pattern, FRESULT_str(fr), fr);
//                goto no_sd;
//        }
//        disc0_name = fi.fname;
//        f_closedir(&di);

//        int read_only = !strcmp(disc0_name, disc0_ro_name);
//        printf("  Opening %s (R%c)\n", disc0_name, read_only ? 'O' : 'W');

        /* Open image, set up disc info:  打开镜像，设置硬盘信息 */
//        fr = f_open(&discfp, disc0_name, FA_OPEN_EXISTING | FA_READ | FA_WRITE);
//        if (fr != FR_OK && fr != FR_EXIST) {
//                printf("  *** Can't open %s: %s (%d)!\n", disc0_name, FRESULT_str(fr), fr);
//                goto no_sd;
//        } else {
//                printf("  Opened, size 0x%x\n", f_size(&discfp));
//                if (read_only)
//                        printf("  (disc is read-only)\n");
//                discs[0].base = 0; // Means use R/W ops  意思是使用读取、写入的方法
//                discs[0].read_only = read_only;
//                discs[0].size = f_size(&discfp);
//                discs[0].op_ctx = &discfp;
//                discs[0].op_read = disc_do_read;
//                discs[0].op_write = disc_do_write;
//        }

        /* FIXME: Other files can be stored on SD too, such as logging
         * and NVRAM storage.
         *
         * We could also implement a menu here to select an image,
         * writing text to the framebuffer and checking kbd_queue_*()
         * for user input.
         *
         * 设计意见：其他文件也可以存储在SD卡，像日志、NVRAM
         
         * 我们可以在这里部署一个菜单去选择镜像。
         * 向帧缓冲区写内容并检查用户输入的键盘队列
         */
//        return;

//no_sd:
//#endif
        /* If we don't find (or look for) an SD-based image, attempt
         * to use in-flash disc image:
         */
        //discs[0].base = (void *)umac_disc;
//        discs[0].base = NULL;
//        discs[0].read_only = 1;
        //discs[0].size = sizeof(umac_disc);
//        discs[0].size = 0;
//}

/////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////
/* 打印文字相关的内容 */


/* 帧缓冲区打印用游标 */
static int fb_cursor_x = 0;
static int fb_cursor_y = 0;

/* 直接输入缓冲区，刚好能容纳一行英文内容 */
static wchar_t jipt_buf[ONE_LINE_CHAR_EN] = {0};
/* 记录直入缓冲的栈顶 */
static int jipt_top = 0;


////////////////////////////////
////////////////////////////////
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
int lines_roll(int y, int ipt_h, int a) {
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
void print_vga(wchar_t wc, int *px, int *py, int target_w, int target_h, int dx, int color) {
    
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
 * x轴游标向后移动的量，英文比汉字窄
 */
static int get_dx(wchar_t wc) {
    return (is_wchar_ascii(wc)) ? CHAR_WIDTH_EN : CHAR_WIDTH_CN; 
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
void _printtovga(wchar_t *wstr, int con_height) {
  while (*wstr != L'\0') {

    /* 遍历宽字符 */
    wchar_t wc = *(wstr++);

    /* 根据字符类型判断移动 */
    int dx = get_dx(wc);
    
    /* xx越界换行 */
    while (fb_cursor_x + dx >= ONE_LINE_BITS) { 
      change_line(CHAR_HEIGHT, &fb_cursor_x, &fb_cursor_y);
    }
    
    /* yy越界滚动 */
    while (fb_cursor_y + CHAR_HEIGHT >= con_height) {
      fb_cursor_y -= lines_roll(fb_cursor_y, IPT_H, 255);// 屏幕上移至1个字符高;
    }
  
    /* 打印至vga屏幕上面 */
    print_vga(wc, 
        &fb_cursor_x, &fb_cursor_y,
        CHAR_WIDTH_CN, CHAR_HEIGHT,
        dx, 0
    );

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


/* 初始化控制台。 
 *
 * 初始化直入缓冲区、刷新屏幕，打印欢迎语和测试信息
 * 
 * 我想将其移动到一个新的文件中
 */
static void init_console() {

    /* 初始化缓冲区，直接把长度记为0，然后在该位置赋值终止符即可 */
    jipt_top = 0;
    jipt_buf[jipt_top] = L'\0';

    /* 以深色填充屏幕 */
    clear(255);
        
    /* 打印输入法分割线，其实可以使用line()绘制 */
    printvgaat(L"- - - - - -", 0, IPT_PLACE_H);

}


/////////////////////////////////////////////////////////////////////
/* 控制台相关的内容 */

/* 用于在VGA屏幕上打印欢迎语句 */
static void welcome() {
    printtovga(L"你现在看到的是我的个人终端项目，本项目基于MIT协议并且完全免费。\n");
    printtovga(L"我们的项目地址是：");
    printtovga(L"https://gitcode.com/qingss0/pico-vga\n");
    printtovga(L"有任何问题非常欢迎提交issue，我们会尽快解答。\n");
    printtovga(L"————：qing，2025年8月26日\n");
    printtovga(L"- - - - - - - - - - - - - - - - - - -\n");
}

/*
 * 打印测试信息的函数，我觉得可以把其中的格式化打印独立出来
 */
static void testinfo() {
    wchar_t buf[128];
    swprintf(
        buf, sizeof(buf), 
        L"一行的比特数：%d\n英文字符的宽度：%d\n即时输入缓冲区的长度：%d\n", 
        ONE_LINE_BITS,  CHAR_WIDTH_EN,  ONE_LINE_CHAR_EN
    );
    printtovga(buf);
    printtovga(L"- - - - - - - - - - - - - - - - - - -\n");
}

/////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////

/*
 *
 * 核1主函数
 *
 * 视频、中断处理、DMA设置
 *
 * TF卡读取
 *
 */
static void core1_main()
{
        /* 硬盘描述符！  */
        //disc_descr_t discs[DISC_NUM_DRIVES] = {0};

        /* 硬盘初始化！ */
        //disc_setup(discs);

        /* Video runs on core 1, i.e. IRQs/DMA are unaffected by
         * core 0's USB activity.
         *
         * IRQs：中断请求
         * 视频跑在核1，中断请求和DMA不受核0的usb活动影响
         *
         * 初始化视频，应该在本项目里。这里可能
         * 有DMA和中断请求相关的配置
         *
         * 这个函数会以单缓冲区设置DMA，只需要在这里魔改即可
         */
        video_init((uint32_t *)video_ram);
        
        init_console();


        /* 打印欢迎语 */
        welcome();
        
        /* 打印测试信息 */
        testinfo();

        
        uint16_t k;			/* 存储每一次读到的键位本体 */
        wchar_t *p = jipt_buf;          /* 指向即时输入缓冲文字区的指针 */
        int jipt_x = -CHAR_WIDTH_EN;    /* 即时输入缓冲区的游标 */
        int flag = 0;                   /* 已经进行了拼音映射否 */
        wchar_t *pym;                   /*  拼音映射结果 */

        /* 周期性处理 */
        while (true) {

	    /* 有输入事件就读取 */
            if (!kbd_queue_empty() && (k = kbd_queue_pop())) {	
              
              /* 匹配按下 */
              if (k < 256 ) {
                /* ---------------- */
                if (is_letter(k)) {
                  if (jipt_top < ONE_LINE_CHAR_EN - 1) {	/* 缓冲区有空才执行入栈 */

                    /* FLAG：是否已经进行了拼音匹配
                     * 一旦有新的键盘事件就赋值为0。 */
                    flag = 0;
                    *(p++) = (wchar_t)k;	/* 字符进入缓冲区 */
                    *p = L'\0';	/* 放置终止符号 */
                    jipt_top++;	/* 栈顶指针自增 */
                    jipt_x += CHAR_WIDTH_EN;	/* 横轴坐标自增 */
                    printvgaat(p - 1, jipt_x, JIPT_H);	/* 打印新的字符 */
                 }
              }
              /* ---------------- */
              /* 匹配删减模式 */
              else if (k == L'\b') {
		if (jipt_top > 0) {
                  flag = 0;		/* 重新进行拼音匹配 */
                  *(--p) = L'\0';	/* 放置终止符号 */
                  jipt_top--;		/* 栈顶指针自减 */
                						
		  int jipt_px0 = jipt_x;			/* position x0 */
		  int jipt_py0 = JIPT_H;			/* position y0 */
		  int jipt_px1 = jipt_x + CHAR_WIDTH_EN - 1;	/* position x1 包含原点所以减一 */
		  int jipt_py1 = JIPT_H + CHAR_HEIGHT - 1;	/* position y1 包含原点所以减一 */
                  rectangle(jipt_px0, jipt_py0, jipt_px1,  jipt_py1, 1, 1);	/* 清除屏幕字符图案 */
                  jipt_x -= CHAR_WIDTH_EN;			/* 横轴坐标自减 */
		}
              }

              /* ---------------- */
              /* 匹配选择模式 */
              // else if (is_digit(k) && wcscmp(L"", pym)) {
              // ... 
              //   jipt_top = 0;
              //   jipt_buf[jipt_top] = L'\0';
              //   flag =0;
              //}

              /* 匹配直接输入模式 */
              // else if (is_digit(k)) {}
              }
            }
            
	    if (!flag) {

              pym = py_ime(jipt_buf);	/* 进行拼音匹配 */
              flag = 1;			/* 已经匹配  可以利用flag进行字符串分段 */
              
	      int jipt_px0 = 0;
	      int jipt_py0 = PY_LELECT_H;
	      int jipt_px1 = ONE_LINE_BITS - 1;
	      int jipt_py1 = PY_LELECT_H; + CHAR_HEIGHT - 1;
              rectangle(jipt_px0, jipt_py0, jipt_px1, jipt_py1, 1, 1);	/* 清除屏幕拼音结果字符 */
              printvgaat(pym, 0, PY_LELECT_H);

            }
        }
}

/* 项目主函数入口， 初始化io、核1主函数  */
int     main()
{
        /* 设置时钟频率，第二个实参
         * 表示当频率达不到要求时的行为，true
         * 代表失败时进行断言终止，false
         * 代表失败时保持当前状态并且返回false  */
        set_sys_clock_khz(250*1000, true);

        /* 一次性初始化所有可用的标准输入输出接口，包括
         * 1.USB虚拟串口。2.UART硬件串口。3.其他。  */
	stdio_init_all();

        /* (这是一个用户自定义的初始化函数) */
        io_init();

        /*  启动核1  */
        multicore_launch_core1(core1_main);

        /* TinyUSB 库提供的初始化函数，用于配置树莓派 Pico 的 
         * USB 功能（如 USB 串口、HID 设备、MSC 存储设备等） */
        tusb_init();

        /* This happens on core 0:
	 * 这些发生在核0： 维护usb与led  */
	while (true) {

                /* TinyUSB 库中用于 USB 主机模式（USB Host） 的核心任务处理函数。与
                 * tud_task()（用于 USB 设备模式）不同，tuh_task() 负责处理作为
                 * USB 主机时的所有 USB 事件（如设备插入 / 拔出、数据传输等）。  */
                tuh_task();

                /*  用户自定义函数，处理HID设备  */
                hid_app_task();

                /*  用户自定义函数，周期性处理led  */
                poll_led_etc();

	}

	return 0;
}

