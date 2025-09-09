#include <stddef.h>
#include "video.h"

/*
 * 字库相关的内容
 * 以下变量在 chsf.c 中声明
 */
extern const uint8_t ttu[];
extern int ttunumber;
extern const uint8_t zzhi[];
extern const uint8_t zzhi32[];
extern int zzhinumber;
extern int zzhinumber32;

/* 这些变量似乎用于以某种格式访问字库内存 */
uint16_t *chss;
uint32_t *chss32;
uint8_t const *vec;
int zn;
int zn32;
int vennum;



/* 20250403
 * Bresenham 画直线算法
 *
 * Deepseek of qing
 *
 * color是个布尔型
 */
void line(int x0, int y0, int x1, int y1, int color) {
    int dx = x1 > x0 ? x1 - x0 : x0 - x1;
    int dy = y1 > y0 ? y1 - y0 : y0 - y1;
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = (dx > dy ? dx : -dy) / 2;
    int e2;
    
    while (1) {
        p1(x0, y0, color);
        if (x0 == x1 && y0 == y1) break;

        e2 = err;

        if (e2 > -dx) {
            err -= dy;
            x0 += sx;
        }

        if (e2 < dy) {
            err += dx;
            y0 += sy;
        }
    }
}


/**
 * 绘制矩形（支持填充）
 * @param x1, y1    矩形的一个顶点坐标
 * @param x2, y2    矩形的对角顶点坐标
 * @param filled    是否填充（1填充 / 0不填充）
 *
 * Deepseek of qing
 *
 * 颜色参数是布尔型
 */
void rectangle(int x1, int y1, int x2, int y2, int color, int filled) {
    // 确保 x_start <= x_end, y_start <= y_end
    int x_start = (x1 < x2) ? x1 : x2;
    int x_end = (x1 < x2) ? x2 : x1;
    int y_start = (y1 < y2) ? y1 : y2;
    int y_end = (y1 < y2) ? y2 : y1;

    // 绘制填充（逐行画水平线）
    if (filled) {
        for (int y = y_start; y <= y_end; y++) {
            line(x_start, y, x_end, y, color);
        }
    }
    // 绘制边框（4条边）
    else {
        line(x_start, y_start, x_end, y_start, color); // 上边
        line(x_end, y_start, x_end, y_end, color);     // 右边
        line(x_start, y_end, x_end, y_end, color);     // 下边
        line(x_start, y_start, x_start, y_end, color); // 左边
    }
}

/////////////////////////////

/* 20250404
 * 在找到字体位置的情况下进行绘制
 * x, y是左上角坐标，vect指向矢量字库数据，width和high分别代表要绘制的图的宽和高
 *
 * 此函数的开发者为陈必红老师
 *
 * 颜色参数是布尔型
 */
unsigned char const *drawvect(int x, int y, unsigned char const *vect, int width, int high, int color) {
    if (!vect) return 0;

    int i = 0, j = 1; // 指向第一对数字
    unsigned char ix, iy; // 从数组取出的第一对坐标放在这
    double x1, y1;//, x2, y2; // 绘制直线的实数的坐标

    if (high == 0) high = width; // 调节高宽

    int ii1, jj1, ii2, jj2; // 最后算出的绘制直线的坐标
    int isend = 0; //是否到达曲线尾
    int isallend = 0; // 是否结束整个图像

    do {
        ix = vect[i];
        iy = vect[j];
        isend = ix & 1; // 奇数代表曲线尾
        isallend = iy & 1; // 奇数代表整个图像结束

        if (isallend) {
            i += 2;
            break; // 整个图像结束返回
        }

        if (isend) { // 如果这里曲线结束什么也不画进到下一条曲线
            i += 2;
            j += 2;
            continue;
        }

        ix /= 2;
        iy /= 2;
        x1 = ix;
        y1 = iy;
        x1 = width * x1 / 128.0;
        y1 = high * y1 / 128.0;
        ii1 = (int)(x1 + x);
        jj1 = (int)(y1 + y);

        int k;
        for (k = 0; k < 100000; k++) {
            //x2 = x1;
            //y2 = y1;
            ii2 = ii1;
            jj2 = jj1;
            i += 2;
            j += 2;
            ix = vect[i];
            iy = vect[j];
            isend = ix & 1; //奇数代表曲线尾
            isallend = iy & 1; //奇数代表整个图像结束
            ix /= 2;
            iy /= 2;
            x1 = ix;
            y1 = iy;
            x1 = width * x1 / 128.0;
            y1 = high * y1 / 128.0;
            ii1 = (int)(x1 + x);
            jj1 = (int)(y1 + y);
            line(ii1, jj1, ii2, jj2, color);

            if (isend || isallend) {
                break;
			}
        }

        i += 2; //指向下一条曲线
        j += 2;

    } while (!isallend);

    return vect + i;
}

/* 20250404
 * 该函数用于以一个点为左上角绘制矢量字体
 * 此函数的作者为陈必红老师
 *
 * 20250826(qing): 经过修改，该函数可以输入打印字符的长宽了
 * 20250901(qing): color参数是bool
 */
void drawvfont(int x, int y, wchar_t z, int target_width, int target_height, int color) {
    //chss = (uint16_t *)zzhi;
    chss32 = (uint32_t *) zzhi32;
    vec = ttu;
    //zn = zzhinumber;
    zn32 = zzhinumber32;
    vennum = ttunumber;

    int i, j, k, ii;

    j = -1;
    for (i = 0; i < zn32; i++) {
        if (chss32[i] == z) {
            j = i;
            break;
        }
    }

    if (j < 0) return;

    k = 0;
    for (i = 0; i < vennum; i++) {
        if (k == j)
            break;
        for (ii =i; ii <vennum; ii++) {
            if (vec[2*ii + 1] & 1) {
                k++;
                i = ii;
                break;
            }
        }
    }

    drawvect(x, y, ttu + 2 * i, target_width, target_height, color);
}
