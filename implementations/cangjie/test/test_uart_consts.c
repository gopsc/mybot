/* 实证 HAL.lua uart 段硬编码常量与系统头文件一致（test_ioctl_nums.c 同款方法） */
#include <stdio.h>
#include <stddef.h>
#include <termios.h>
#include <string.h>
#include <fcntl.h>

int main(void) {
	struct termios t;
	memset(&t, 0, sizeof t);
	printf("sizeof(struct termios) = %zu\n", sizeof(struct termios));
	printf("offsetof(c_line)   = %zu\n", offsetof(struct termios, c_line));
	printf("offsetof(c_cc)     = %zu\n", offsetof(struct termios, c_cc));
	printf("offsetof(c_ispeed) = %zu\n", offsetof(struct termios, c_ispeed));
	printf("VMIN=%d VTIME=%d NCCS=%d\n", VMIN, VTIME, NCCS);
	printf("B1200=%d B2400=%d B4800=%d B9600=%d B19200=%d B38400=%d\n",
		B1200, B2400, B4800, B9600, B19200, B38400);
	printf("B57600=%d B115200=%d B230400=%d B460800=%d B921600=%d\n",
		B57600, B115200, B230400, B460800, B921600);
	printf("O_RDWR=%d O_NOCTTY=%d O_NONBLOCK=%d\n", O_RDWR, O_NOCTTY, O_NONBLOCK);
	printf("TCSANOW=%d TCIFLUSH=%d\n", TCSANOW, TCIFLUSH);
	printf("CREAD=%d CLOCAL=%d CS8=%d\n", CREAD, CLOCAL, CS8);
	return 0;
}
