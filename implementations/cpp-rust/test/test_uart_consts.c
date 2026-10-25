/* hal/uart.lua 硬编码常量与系统头文件的一致性自检（F-24，test_ioctl_nums.c 同款方法）
 * 编译期断言：termios 布局/波特率常量/打开标志漂移在构建期即失败。
 * 期望值出处：波特率映射 UART_B_CONST 在 modules/lib/hal/uart.lua（26.2 按域拆分
 * 前在 HAL.lua 的 uart 段）、UART_* 常量与 cj_termios 尺寸断言在
 * modules/lib/hal_backend_glibc.lua（方案 A 下沉，955a2c3）。 */
/* O_CLOEXEC 属 POSIX 2008，C11 严格模式下 glibc 不暴露它（见 test_ioctl_nums.c 同款说明）。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stddef.h>
#include <termios.h>
#include <fcntl.h>

#include "const_lua.h"		/* A2：配置期由 gen_const_check.cmake 从 Lua 源抽取 */

/* A2：先钉住「Lua 源里的值」——此前 C 里手抄一遍、从不读 Lua，Lua 漂移不可见。 */
_Static_assert(HAL_CONST_UART_O_FLAGS == 526594,
	"hal_backend_glibc.lua UART_O_FLAGS drifted (expected 526594 = RDWR|NOCTTY|NONBLOCK|CLOEXEC)");
_Static_assert(HAL_CONST_UART_TCSANOW == 0,
	"hal_backend_glibc.lua UART_TCSANOW drifted (expected 0)");
_Static_assert(HAL_CONST_UART_TCIFLUSH == 0,
	"hal_backend_glibc.lua UART_TCIFLUSH drifted (expected 0)");
_Static_assert(HAL_CONST_UART_VMIN_IDX == 6,
	"hal_backend_glibc.lua UART_VMIN_IDX drifted (expected 6)");
_Static_assert(HAL_CONST_UART_VTIME_IDX == 5,
	"hal_backend_glibc.lua UART_VTIME_IDX drifted (expected 5)");
_Static_assert(HAL_CONST_UART_CREAD_CLOCAL == 2176,
	"hal_backend_glibc.lua UART_CREAD_CLOCAL drifted (expected 2176)");

_Static_assert(sizeof(struct termios) == 60,
	"sizeof(struct termios) != 60 (hal_backend_glibc.lua cj_termios 断言)");
_Static_assert(offsetof(struct termios, c_line) == 16,
	"offsetof(termios, c_line) != 16 (hal_backend_glibc.lua cj_termios 布局)");
_Static_assert(offsetof(struct termios, c_cc) == 17,
	"offsetof(termios, c_cc) != 17 (hal_backend_glibc.lua cj_termios 布局)");

#if VMIN != 6
#error "VMIN != 6 (HAL.UART_VMIN_IDX)"
#endif
#if VTIME != 5
#error "VTIME != 5 (HAL.UART_VTIME_IDX)"
#endif

/* UART_B_CONST：Hz → glibc speed_t 常量（hal/uart.lua 映射表）。
 * B* 宏取值随 glibc 版本分叉（glibc 2025-06 commit 5cf101a8，2.42 起生效）：
 *   < 2.42：旧 ABI 编号（B1200=9、B9600=13、B115200=0x1002…）
 *   ≥ 2.42：字面 Hz（B1200=1200、B9600=9600…）
 * hal/uart.lua 运行时探测 glibc 版本后二选一（UART_B_CONST_LEGACY / _HZ）；
 * 本文件以 #if 分支与两套表同步断言（审计 P0-3）。A2：两套表的 13 个条目
 * 现在都另有 HAL_BAUD_{LEGACY,HZ}_<hz> 抽出值直接钉住——**两个分支都校验**，
 * 与编译机实际落在哪个分支无关，故 hal/uart.lua 侧任一表的漂移都能在构建期暴露。 */

/* ---- Lua 侧旧 ABI 表（glibc < 2.42 用）---- */
_Static_assert(HAL_BAUD_LEGACY_1200 == 9, "hal/uart.lua LEGACY 表 [1200] drifted (expected 9)");
_Static_assert(HAL_BAUD_LEGACY_2400 == 11, "hal/uart.lua LEGACY 表 [2400] drifted (expected 11)");
_Static_assert(HAL_BAUD_LEGACY_4800 == 12, "hal/uart.lua LEGACY 表 [4800] drifted (expected 12)");
_Static_assert(HAL_BAUD_LEGACY_9600 == 13, "hal/uart.lua LEGACY 表 [9600] drifted (expected 13)");
_Static_assert(HAL_BAUD_LEGACY_19200 == 14, "hal/uart.lua LEGACY 表 [19200] drifted (expected 14)");
_Static_assert(HAL_BAUD_LEGACY_38400 == 15, "hal/uart.lua LEGACY 表 [38400] drifted (expected 15)");
_Static_assert(HAL_BAUD_LEGACY_57600 == 0x1001, "hal/uart.lua LEGACY 表 [57600] drifted (expected 0x1001)");
_Static_assert(HAL_BAUD_LEGACY_115200 == 0x1002, "hal/uart.lua LEGACY 表 [115200] drifted (expected 0x1002)");
_Static_assert(HAL_BAUD_LEGACY_230400 == 0x1003, "hal/uart.lua LEGACY 表 [230400] drifted (expected 0x1003)");
_Static_assert(HAL_BAUD_LEGACY_460800 == 0x1004, "hal/uart.lua LEGACY 表 [460800] drifted (expected 0x1004)");
_Static_assert(HAL_BAUD_LEGACY_500000 == 0x1005, "hal/uart.lua LEGACY 表 [500000] drifted (expected 0x1005)");
_Static_assert(HAL_BAUD_LEGACY_921600 == 0x1007, "hal/uart.lua LEGACY 表 [921600] drifted (expected 0x1007)");
_Static_assert(HAL_BAUD_LEGACY_1000000 == 0x1008, "hal/uart.lua LEGACY 表 [1000000] drifted (expected 0x1008)");

/* ---- Lua 侧字面 Hz 表（glibc >= 2.42 用）---- */
_Static_assert(HAL_BAUD_HZ_1200 == 1200, "hal/uart.lua HZ 表 [1200] drifted");
_Static_assert(HAL_BAUD_HZ_2400 == 2400, "hal/uart.lua HZ 表 [2400] drifted");
_Static_assert(HAL_BAUD_HZ_4800 == 4800, "hal/uart.lua HZ 表 [4800] drifted");
_Static_assert(HAL_BAUD_HZ_9600 == 9600, "hal/uart.lua HZ 表 [9600] drifted");
_Static_assert(HAL_BAUD_HZ_19200 == 19200, "hal/uart.lua HZ 表 [19200] drifted");
_Static_assert(HAL_BAUD_HZ_38400 == 38400, "hal/uart.lua HZ 表 [38400] drifted");
_Static_assert(HAL_BAUD_HZ_57600 == 57600, "hal/uart.lua HZ 表 [57600] drifted");
_Static_assert(HAL_BAUD_HZ_115200 == 115200, "hal/uart.lua HZ 表 [115200] drifted");
_Static_assert(HAL_BAUD_HZ_230400 == 230400, "hal/uart.lua HZ 表 [230400] drifted");
_Static_assert(HAL_BAUD_HZ_460800 == 460800, "hal/uart.lua HZ 表 [460800] drifted");
_Static_assert(HAL_BAUD_HZ_500000 == 500000, "hal/uart.lua HZ 表 [500000] drifted");
_Static_assert(HAL_BAUD_HZ_921600 == 921600, "hal/uart.lua HZ 表 [921600] drifted");
_Static_assert(HAL_BAUD_HZ_1000000 == 1000000, "hal/uart.lua HZ 表 [1000000] drifted");
#if defined(B9600) && B9600 == 13 && B1200 == 9
/* ---- 旧 ABI 编码分支（glibc < 2.42）：对应 hal/uart.lua UART_B_CONST_LEGACY ---- */
#if B2400 != 11
#error "B2400 != 11 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B4800 != 12
#error "B4800 != 12 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B19200 != 14
#error "B19200 != 14 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B38400 != 15
#error "B38400 != 15 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B57600 != 0x1001
#error "B57600 != 0x1001 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B115200 != 0x1002
#error "B115200 != 0x1002 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B230400 != 0x1003
#error "B230400 != 0x1003 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B460800 != 0x1004
#error "B460800 != 0x1004 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B500000 != 0x1005
#error "B500000 != 0x1005 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B921600 != 0x1007
#error "B921600 != 0x1007 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#if B1000000 != 0x1008
#error "B1000000 != 0x1008 (hal/uart.lua UART_B_CONST_LEGACY)"
#endif
#elif defined(B9600) && B9600 == 9600 && B1200 == 1200
/* ---- 字面 Hz 编码分支（glibc >= 2.42）：对应 hal/uart.lua UART_B_CONST_HZ ---- */
#if B2400 != 2400 || B4800 != 4800 || B19200 != 19200 || B38400 != 38400
#error "B* 低段常量不是字面 Hz (hal/uart.lua UART_B_CONST_HZ)"
#endif
#if B57600 != 57600 || B115200 != 115200 || B230400 != 230400 || B460800 != 460800
#error "B* 高段常量不是字面 Hz (hal/uart.lua UART_B_CONST_HZ)"
#endif
#if B500000 != 500000 || B921600 != 921600 || B1000000 != 1000000
#error "B* 超高速段常量不是字面 Hz (hal/uart.lua UART_B_CONST_HZ)"
#endif
#else
#error "未知的 B* 常量编码：hal/uart.lua 波特率映射表与 test_uart_consts.c 需要适配（参见 glibc 2.42 termios 编码变更）"
#endif

#if (O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC) != 526594
#error "O_RDWR|O_NOCTTY|O_NONBLOCK|O_CLOEXEC != 526594 (HAL.UART_O_FLAGS)"
#endif
#if TCSANOW != 0
#error "TCSANOW != 0 (HAL.UART_TCSANOW)"
#endif
#if TCIFLUSH != 0
#error "TCIFLUSH != 0 (HAL.UART_TCIFLUSH)"
#endif
#if (CREAD | CLOCAL) != 2176
#error "CREAD|CLOCAL != 2176 (HAL.UART_CREAD_CLOCAL)"
#endif

int main(void) {
	printf("uart 常量自检通过：termios 布局/波特率常量/打开标志均与系统头文件一致\n");
	return 0;
}
