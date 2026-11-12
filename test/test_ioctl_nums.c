/* hal_backend_glibc.lua 硬编码 ioctl 编号与内核头文件的一致性自检（F-24）
 * 全部为编译期断言：常量漂移（改 Lua / 换内核 / 换架构）在构建期即失败。
 *
 * A2（2026-09-20 审计）修复：本文件此前把 Lua 里的数字**在 C 里又手抄一遍**，
 * 只与内核头比对，从不读 Lua 源——Lua 侧漂移完全不被发现（实测把
 * HAL.SPI_IOC_WR_MODE 改成 0xDEADBEEF 本目标照绿）。现在期望值来自
 * test/gen_const_check.cmake 在配置期从 modules/lib/hal_backend_glibc.lua **抽取**生成的
 * const_lua.h，每项做**双边断言**：
 *   HAL_CONST_X == <手抄预期值>   —— 抽取生效 + Lua 值未漂移（人写错会红）
 *   <预期值>     == <内核符号>     —— 内核/架构未漂移（原判据，保留）
 * 两侧都钉死，「声称比对 Lua」不再是一句空话。
 *
 * 用 _Static_assert 而非 #if：_IOW/_IOWR 宏展开含 sizeof，#if 表达式不支持。 */
/* O_CLOEXEC 属 POSIX 2008：本文件按 C11 严格模式编译（CMAKE_C_STANDARD 11），
 * glibc 默认特性宏下不暴露它，故在任何头文件之前显式开 _GNU_SOURCE
 * （与 src/agent_subprocess.cpp 同款兜底，重复定义会触发 -Wpedantic 告警）。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <linux/gpio.h>

#include "const_lua.h"		/* 配置期由 gen_const_check.cmake 生成 */

/* ---- open 标志（HAL 全部器件句柄都带 O_CLOEXEC，见 hal_backend_glibc.lua 常量区注释）---- */
_Static_assert(HAL_CONST_O_CLOEXEC == 0x80000,
	"hal_backend_glibc.lua O_CLOEXEC drifted (expected 0x80000)");
_Static_assert(O_CLOEXEC == 0x80000,
	"O_CLOEXEC != 0x80000 (hal_backend_glibc.lua O_CLOEXEC)");

/* ---- SPI ---- */
_Static_assert(HAL_CONST_SPI_IOC_WR_MODE == 0x40016b01,
	"hal_backend_glibc.lua SPI_IOC_WR_MODE drifted (expected 0x40016b01)");
_Static_assert(SPI_IOC_WR_MODE == 0x40016b01,
	"SPI_IOC_WR_MODE != 0x40016b01 (hal_backend_glibc.lua)");
_Static_assert(HAL_CONST_SPI_IOC_WR_BITS_PER_WORD == 0x40016b03,
	"hal_backend_glibc.lua SPI_IOC_WR_BITS_PER_WORD drifted (expected 0x40016b03)");
_Static_assert(SPI_IOC_WR_BITS_PER_WORD == 0x40016b03,
	"SPI_IOC_WR_BITS_PER_WORD != 0x40016b03 (hal_backend_glibc.lua)");
_Static_assert(HAL_CONST_SPI_IOC_WR_MAX_SPEED_HZ == 0x40046b04,
	"hal_backend_glibc.lua SPI_IOC_WR_MAX_SPEED_HZ drifted (expected 0x40046b04)");
_Static_assert(SPI_IOC_WR_MAX_SPEED_HZ == 0x40046b04,
	"SPI_IOC_WR_MAX_SPEED_HZ != 0x40046b04 (hal_backend_glibc.lua)");
_Static_assert(HAL_CONST_SPI_IOC_MESSAGE_1 == 0x40206b00,
	"hal_backend_glibc.lua SPI_IOC_MESSAGE_1 drifted (expected 0x40206b00)");
_Static_assert(SPI_IOC_MESSAGE(1) == 0x40206b00,
	"SPI_IOC_MESSAGE(1) != 0x40206b00 (hal_backend_glibc.lua)");

/* ---- GPIO ---- */
_Static_assert(HAL_CONST_GPIO_GET_LINEHANDLE == 0xC16CB403,
	"hal_backend_glibc.lua GPIO_GET_LINEHANDLE drifted (expected 0xC16CB403)");
_Static_assert(GPIO_GET_LINEHANDLE_IOCTL == 0xC16CB403,
	"GPIO_GET_LINEHANDLE_IOCTL != 0xC16CB403 (hal_backend_glibc.lua)");
_Static_assert(HAL_CONST_GPIOHANDLE_GET_LINE_VALUES == 0xC040B408,
	"hal_backend_glibc.lua GPIOHANDLE_GET_LINE_VALUES drifted (expected 0xC040B408)");
_Static_assert(GPIOHANDLE_GET_LINE_VALUES_IOCTL == 0xC040B408,
	"GPIOHANDLE_GET_LINE_VALUES_IOCTL != 0xC040B408 (hal_backend_glibc.lua)");
_Static_assert(HAL_CONST_GPIOHANDLE_SET_LINE_VALUES == 0xC040B409,
	"hal_backend_glibc.lua GPIOHANDLE_SET_LINE_VALUES drifted (expected 0xC040B409)");
_Static_assert(GPIOHANDLE_SET_LINE_VALUES_IOCTL == 0xC040B409,
	"GPIOHANDLE_SET_LINE_VALUES_IOCTL != 0xC040B409 (hal_backend_glibc.lua)");

/* ---- I2C（hal_backend_glibc.lua 字段，此前漏检）---- */
_Static_assert(HAL_CONST_I2C_RDWR == 0x0707, "hal_backend_glibc.lua I2C_RDWR drifted (expected 0x0707)");
_Static_assert(HAL_CONST_I2C_M_RD == 0x0001, "hal_backend_glibc.lua I2C_M_RD drifted (expected 0x0001)");

/* ---- 结构尺寸：Lua ffi 断言值与内核头一致 ---- */
_Static_assert(sizeof(struct spi_ioc_transfer) == 32,
	"sizeof(spi_ioc_transfer) != 32 (hal_backend_glibc.lua ffi 断言)");
_Static_assert(sizeof(struct gpiohandle_request) == 364,
	"sizeof(gpiohandle_request) != 364 (hal_backend_glibc.lua ffi 断言)");
_Static_assert(sizeof(struct gpiohandle_data) == 64,
	"sizeof(gpiohandle_data) != 64 (hal_backend_glibc.lua ffi 断言)");

int main(void) {
	printf("ioctl 常量自检通过：Lua 抽取值 == 预期值 == 内核头（SPI/GPIO/I2C + 结构尺寸）\n");
	return 0;
}
