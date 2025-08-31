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
 */

/* 提示，源代码经过qing的修改，仍然遵循
 * MIT协议。
 *
 * “无论经过怎样的阻挡，最终还是回到你的身边。”
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

// Mac binary data:  disc and ROM images
//static const uint8_t umac_disc[] = {
//#include "umac-disc.h"
//};
//static const uint8_t umac_rom[] = {
//#include "umac-rom.h"
//};

/* ？？？
 * 分配一段内存，该内存被传输给
 * umac_init() 与 video_init()
 */
//static uint8_t umac_ram[RAM_SIZE];

/* 用于传输视频的内存空间 */
static uint8_t video_ram[ONE_COL * ONE_LINE];
////////////////////////////////////////////////////////////////////////////////

static void     io_init()
{
        gpio_init(GPIO_LED_PIN);
        gpio_set_dir(GPIO_LED_PIN, GPIO_OUT);
}

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

static int umac_cursor_x = 0;
static int umac_cursor_y = 0;
static int umac_cursor_button = 0;
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

static FIL discfp;
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


/* 输入框的参数 */
#define IPT_H          (4 * CHAR_HEIGHT) /* 一行分割符、
                                         * 一行输入法输出、
                                         * 一行输入法界面、
                                         * 一行直接输入 
                                         */
#define IPT_PLACE_H     (ONE_COL - IPT_H)

/* 帧缓冲区打印用游标 */
int fb_cursor_x = 0;
int fb_cursor_y = 0;


/* 判断宽字符是否为ASCII字符。用于判断
 * 字符是否需要更少缩进
 */
int is_wchar_ascii(wchar_t wc) {
  /* ASCII字符范围：0-127 */
  return (wc >= 0 && wc <= 0x7F);
}

/* 换行 */
void change_line(int h, int *px, int *py) {
  *px = 0;
  *py += h;
}

/* 屏幕向上滚动，返回滚动的幅度 */
int lines_roll(int y, int ipt_h) {
  int exh = y + ipt_h - ONE_COL; /* y轴游标超过了多少 */
  int h = exh + 1 * CHAR_HEIGHT; /* 还差多少能移够一个字符的空间 */
  up1(h, 255, ipt_h);
  return h;
}

/* 打印到vga的某个位置，你需要保证每一行的高度是相等的。
 * 需要传入打印位置的指针。这个函数必须在绘制之前就判断
 * 是否会越界
 *
 * 应当传入要打印的字符大小
 *
 * 还需要从外部输入输入框的高度，以实现输入法例外
 *
 *
 * 1.使用while确保移动到合适的范围内。
 * 
 * 2.问题在于在非终端打印下亦可造成换行，建议
 * 拆分函数
 */
void print_at_vga(wchar_t *wstr, int *px, int *py, int ipt_h) {
  size_t len = wcslen(wstr); /* 直接使用while */
  
  for (size_t i=0; i<len; ++i) {
    wchar_t wc = wstr[i];
    int target_w = CHAR_WIDTH_CN;
    int target_h  = CHAR_HEIGHT;
    int temp = (is_wchar_ascii(wc)) ? CHAR_WIDTH : target_w; /* 英文比汉字窄 */
    
    /* xx越界换行 */
    while (*px + temp >= ONE_LINE_BITS) { 
      change_line(target_h, px, py);
    }
    
    /* yy越界滚动 */
    while (*py + target_h >= (ONE_COL - ipt_h)) { 
      *px = 0;
      *py -= lines_roll(*py + target_h, ipt_h);// 屏幕上移至1个字符高;
    }
    
    //////////////////////
    if (wc == L'\n' || wc == L'\r') {
      change_line(target_h, px, py);
    }
    else {
      drawvfont(*px, *py, wstr[i], target_w, target_h);
      *px += temp;
    }
    //////////////////////
  }
}

/* 终端正常打印 */
void print_vga(wchar_t *wstr) {
    print_at_vga(wstr, &fb_cursor_x, &fb_cursor_y, IPT_H);
}


/////////////////////////////////////////////////////////////////////
/* 控制台相关的内容 */


/* 每行几个字 */
#define ONE_LINE_CHAR   (ONE_LINE_BITS / CHAR_WIDTH)
/* 每列几个字 */
#define ONE_COL_CHAR    (ONE_COL / CHAR_HEIGHT)

/* 直接输入缓冲区，刚好能容纳一行英文内容 */
static wchar_t jipt_buf[(int)ONE_LINE_CHAR * 2 + 1] = {0};

/* 记录直入缓冲的长度 */
static int jipt_len = 0;

/* 初始化控制台 */
void init_console() {

    /* 初始化缓冲区，直接把长度记为0即可 */
    //memset(jipt_buf, 0, sizeof(jipt_buf));
    jipt_len = 0;

    /* 打印分割线，可以使用line()绘制 */
    int x = 0, y = IPT_PLACE_H;
    print_at_vga(L"- - - - - -", &x, &y, 0);
        
    print_vga(L"- - - - - - - - - - - - - - - - - - -\n");
    print_vga(L"你现在看到的是我的个人终端项目，本项目基于MIT协议并且完全免费。\n");
    print_vga(L"我们的项目地址是：");
    print_vga(L"https://gitcode.com/qingss0/pico-vga\n");
    print_vga(L"有任何问题非常欢迎提交issue，我们会尽快解答。\n");
    print_vga(L"————：qing，2025年8月26日\n");
    print_vga(L"- - - - - - - - - - - - - - - - - - -\n");

}

/////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////

/* 核1主函数
 * 视频、中断处理、DMA设置
 */
static void     core1_main()
{
        // ？？？像是整数型
        // 硬盘描述符！！
        //disc_descr_t discs[DISC_NUM_DRIVES] = {0};

        printf("Core 1 started\n");
        // 硬盘初始化！
        //disc_setup(discs);

        /* 初始化umac，在umac项目里。这里可能有
         * umac的桌面
         */
        //umac_init(umac_ram, (void *)umac_rom, discs);


        /* Video runs on core 1, i.e. IRQs/DMA are unaffected by
         * core 0's USB activity.
         *
         * IRQs：中断请求
         * 视频跑在核1，中断请求和DMA不受核0的usb活动影响
         *
         * 初始化视频，应该在本项目里。这里可能
         * 有DMA和中断请求相关的配置
         *
         * 这个函数会以单缓冲区设置DMA，只需要在这里魔改
         * 即可
         */
        //video_init((uint32_t *)(umac_ram + umac_get_fb_offset()));
        video_init((uint32_t *)video_ram);
        clear(255);
        
        //printf("Enjoyable Mac times now begin:\n\n");
        printf("Bb2 now running.\n");

        init_console();
        uint16_t k;
        /* 周期性处理 */
        while (true) {
            //print_vga(L"你好！"); /* 测试*/
            if (!kbd_queue_empty() && (k = kbd_queue_pop())) {
                swprintf(jipt_buf, sizeof(jipt_buf), L"%c", k);
                print_vga(jipt_buf); /* 测试 */
                //swprintf(jipt_buf, sizeof(jipt_buf), L"%u", k);
                //print_vga(jipt_buf); /* 测试 */
            }
        }
}

// 项目主函数，入口
// 初始化io，核1主函数
// 初始化usb，维护usb与led
int     main()
{
        // 设置时钟频率，第二个实参
        // 表示当频率达不到要求时的行为，true
        // 代表失败时进行断言终止，false
        // 代表失败时保持当前状态并且返回false
        set_sys_clock_khz(250*1000, true);

        // 一次性初始化所有可用的标准输入输出接口，包括
        // 1.USB虚拟串口。2.UART硬件串口。3.其他。
	stdio_init_all();
        // (这是一个用户自定义的初始化函数)
        io_init();

        // 启动核1
        multicore_launch_core1(core1_main);

	printf("Starting, init usb\n");
        // TinyUSB 库提供的初始化函数，用于配置树莓派 Pico 的 
        // USB 功能（如 USB 串口、HID 设备、MSC 存储设备等）
        tusb_init();

        /* This happens on core 0: */
	while (true) {
                //TinyUSB 库中用于 USB 主机模式（USB Host） 的核心任务处理函数。与
                // tud_task()（用于 USB 设备模式）不同，tuh_task() 负责处理作为
                // USB 主机时的所有 USB 事件（如设备插入 / 拔出、数据传输等）。
                tuh_task();
                // 用户自定义函数，处理HID设备
                hid_app_task();
                // 用户自定义函数，周期性处理led
                poll_led_etc();
	}

	return 0;
}

