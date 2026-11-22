/*
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
/* mybot-lite headless firmware for RP2040.
 *
 * core0：UART 控制台、日志输出、LED。
 * core1：Lua / SQL / MT / I2C / SPI / UART 机器人运行时。
 *
 * 本版本已移除 VGA framebuffer、PIO 视频、USB HID 键鼠和中文输入法。
 * 所有诊断与控制都走 UART0（默认 GP0 TX / GP1 RX，115200）。
 */

#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "pico/stdlib.h"
#include "pico/time.h"

#include "console.h"
#include "hw.h"
#include "robot.h"

static void board_io_init(void) {
    gpio_init(GPIO_LED_PIN);
    gpio_set_dir(GPIO_LED_PIN, GPIO_OUT);
}

static void poll_led(void) {
    static int led_on = 0;
    static absolute_time_t last = 0;
    absolute_time_t now = get_absolute_time();

    if (absolute_time_diff_us(last, now) > 500 * 1000) {
        last = now;
        led_on ^= 1;
        gpio_put(GPIO_LED_PIN, led_on);
    }
}

int main(void) {
    set_sys_clock_khz(250 * 1000, true);
    stdio_init_all();

    board_io_init();
    console_init();

    robot_init();
    robot_start();

    while (true) {
        poll_led();
        console_poll();
        robot_poll_ui();
    }

    return 0;
}
