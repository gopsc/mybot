/* 实证 HAL.lua 硬编码的 ioctl 编号与内核头文件一致 */
#include <stdio.h>
#include <linux/spi/spidev.h>
#include <linux/i2c-dev.h>
#include <linux/gpio.h>

int main(void) {
	printf("I2C_SLAVE          = 0x%04lx\n", (unsigned long)I2C_SLAVE);
	printf("SPI_IOC_WR_MODE    = 0x%08x\n", SPI_IOC_WR_MODE);
	printf("SPI_IOC_WR_BITS    = 0x%08x\n", SPI_IOC_WR_BITS_PER_WORD);
	printf("SPI_IOC_WR_SPEED   = 0x%08x\n", SPI_IOC_WR_MAX_SPEED_HZ);
	printf("SPI_IOC_MESSAGE(1) = 0x%08x\n", SPI_IOC_MESSAGE(1));
	printf("sizeof(spi_ioc_transfer) = %zu\n", sizeof(struct spi_ioc_transfer));
	printf("GPIO_GET_LINEHANDLE  = 0x%08lx\n", (unsigned long)GPIO_GET_LINEHANDLE_IOCTL);
	printf("GPIO_GET_LINE_VALUES = 0x%08lx\n", (unsigned long)GPIOHANDLE_GET_LINE_VALUES_IOCTL);
	printf("GPIO_SET_LINE_VALUES = 0x%08lx\n", (unsigned long)GPIOHANDLE_SET_LINE_VALUES_IOCTL);
	printf("sizeof(gpiohandle_request) = %zu\n", sizeof(struct gpiohandle_request));
	printf("sizeof(gpiohandle_data)    = %zu\n", sizeof(struct gpiohandle_data));
	printf("sizeof(gpiochip_info)      = %zu\n", sizeof(struct gpiochip_info));
	return 0;
}
