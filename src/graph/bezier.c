/*
 * 贝塞尔曲线是通过控制点生成的光滑曲线，用于图形设计和计算机图形学中精确描述任意形状。
 * 
 * 其核心是**由控制点插值生成平滑路径**，常见于矢量绘图、字体设计和动画轨迹。
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

// 点结构定义
typedef struct {
    float x;
    float y;
} Point;

// 绘制点的函数 - 用字符表示点
void drawPoint(char canvas[][100], int width, int height, int x, int y, char c) {
    // 确保点在画布范围内
    if (x >= 0 && x < width && y >= 0 && y < height) {
        canvas[(int)y][(int)x] = c;
    }
}

// 二次贝塞尔曲线计算
Point quadraticBezier(Point p0, Point p1, Point p2, float t) {
    Point result;
    float t2 = t * t;
    float mt = 1 - t;
    float mt2 = mt * mt;
    
    result.x = mt2 * p0.x + 2 * mt * t * p1.x + t2 * p2.x;
    result.y = mt2 * p0.y + 2 * mt * t * p1.y + t2 * p2.y;
    
    return result;
}

// 三次贝塞尔曲线计算
Point cubicBezier(Point p0, Point p1, Point p2, Point p3, float t) {
    Point result;
    float t2 = t * t;
    float t3 = t2 * t;
    float mt = 1 - t;
    float mt2 = mt * mt;
    float mt3 = mt2 * mt;
    
    result.x = mt3 * p0.x + 3 * mt2 * t * p1.x + 3 * mt * t2 * p2.x + t3 * p3.x;
    result.y = mt3 * p0.y + 3 * mt2 * t * p1.y + 3 * mt * t2 * p2.y + t3 * p3.y;
    
    return result;
}

// 绘制二次贝塞尔曲线
void drawQuadraticBezier(char canvas[][100], int width, int height, 
                        Point p0, Point p1, Point p2, int segments) {
    Point current;
    
    for (int i = 0; i <= segments; i++) {
        float t = (float)i / segments;
        current = quadraticBezier(p0, p1, p2, t);
        drawPoint(canvas, width, height, current.x, current.y, '*');
    }
}

// 绘制三次贝塞尔曲线
void drawCubicBezier(char canvas[][100], int width, int height,
                    Point p0, Point p1, Point p2, Point p3, int segments) {
    Point current;
    
    for (int i = 0; i <= segments; i++) {
        float t = (float)i / segments;
        current = cubicBezier(p0, p1, p2, p3, t);
        drawPoint(canvas, width, height, current.x, current.y, '#');
    }
}

// 初始化画布
void initCanvas(char canvas[][100], int width, int height) {
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            canvas[y][x] = ' ';
        }
    }
}

// 显示画布
void displayCanvas(char canvas[][100], int width, int height) {
    // 绘制顶部边框
    for (int x = 0; x < width + 2; x++) {
        printf("-");
    }
    printf("\n");
    
    // 绘制画布内容
    for (int y = 0; y < height; y++) {
        printf("|");
        for (int x = 0; x < width; x++) {
            printf("%c", canvas[y][x]);
        }
        printf("|\n");
    }
    
    // 绘制底部边框
    for (int x = 0; x < width + 2; x++) {
        printf("-");
    }
    printf("\n");
}

int main() {
    // 画布大小
    const int WIDTH = 80;
    const int HEIGHT = 25;
    char canvas[HEIGHT][100];  // 画布
    
    // 初始化画布
    initCanvas(canvas, WIDTH, HEIGHT);
    
    // 二次贝塞尔曲线控制点
    Point qPoints[3] = {
        {10, 20},    // 起点 P0
        {20, 5},     // 控制点 P1
        {30, 20}     // 终点 P2
    };
    
    // 三次贝塞尔曲线控制点
    Point cPoints[4] = {
        {40, 20},    // 起点 P0
        {50, 5},     // 控制点 P1
        {60, 15},    // 控制点 P2
        {70, 5}      // 终点 P3
    };
    
    // 绘制控制点
    drawPoint(canvas, WIDTH, HEIGHT, qPoints[0].x, qPoints[0].y, '0');
    drawPoint(canvas, WIDTH, HEIGHT, qPoints[1].x, qPoints[1].y, '1');
    drawPoint(canvas, WIDTH, HEIGHT, qPoints[2].x, qPoints[2].y, '2');
    
    drawPoint(canvas, WIDTH, HEIGHT, cPoints[0].x, cPoints[0].y, '0');
    drawPoint(canvas, WIDTH, HEIGHT, cPoints[1].x, cPoints[1].y, '1');
    drawPoint(canvas, WIDTH, HEIGHT, cPoints[2].x, cPoints[2].y, '2');
    drawPoint(canvas, WIDTH, HEIGHT, cPoints[3].x, cPoints[3].y, '3');
    
    // 绘制贝塞尔曲线
    drawQuadraticBezier(canvas, WIDTH, HEIGHT, qPoints[0], qPoints[1], qPoints[2], 50);
    drawCubicBezier(canvas, WIDTH, HEIGHT, cPoints[0], cPoints[1], cPoints[2], cPoints[3], 50);
    
    // 显示画布
    printf("贝塞尔曲线演示 (使用字符绘制)\n");
    printf("* 表示二次贝塞尔曲线，# 表示三次贝塞尔曲线\n");
    printf("数字表示控制点\n");
    displayCanvas(canvas, WIDTH, HEIGHT);
    
    return 0;
}

