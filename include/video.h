/* PIO video output
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

#ifndef VIDEO_H
#define VIDEO_H

#include <inttypes.h>

/* 我不知道为什么列宽、单行会是这些值，也不知道
 * 它会不会在数据改变后发生改变（很可能会变）
 *
 * 原来作者在下面有说明
 */
#define ONE_COL DISP_HEIGHT
#define ONE_LINE_BITS DISP_WIDTH
#define ONE_LINE ONE_LINE_BITS / 8
#define FB_LEN_BYTE ONE_LINE * ONE_COL
#define FB_LEN_BITS ONE_LINE_BITS * ONE_COL
#define CHAR_HEIGHT 20 /* 字模高 */
#define CHAR_WIDTH 10 /* 字模宽 */
#define CHAR_WIDTH_CN CHAR_WIDTH * 2 /* 汉字字模宽是英文的两倍 */

/* 初始化PIO和DMA */
void    video_init(uint32_t *framebuffer);
/* 绘制一个点（bpp=1） */
void p1(int x, int y);
/* 屏幕向上移动，并且填充空出来的部分白色 */
void up1(size_t h);
/* 绘制一条线 */
void line(int x0, int y0, int x1, int y1);
/* 绘制矩形 */
void rectangle(int x1, int y1, int x2, int y2, int filled);
/* 绘制文字，需要输入打印字符的长宽 */
void drawvfont(int x, int y, wchar_t z, int target_width, int target_height);

#endif
