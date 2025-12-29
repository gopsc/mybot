#include <cstdint>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
#include <iostream>
#include <pthread.h>

static int i2c_fd;
static pthread_mutex_t mutex;

/* 打开I2C设备 */
void I2C_init(const char* device = "/dev/i2c-1") {
    if ((i2c_fd=  open(device, O_RDWR)) < 0) {
        std::cerr << "Failed to open I2C bus" << std::endl;
        exit(1);
    }
}

void I2C_setAddr(const uint8_t address) {
    if (ioctl(i2c_fd, I2C_SLAVE, address) < 0) {
        std::cerr << "Failed to set I2C address" << std::endl;
        exit(1);
    }
}

/* 写寄存器 */
void I2C_writeReg(uint8_t reg, uint8_t value) {
    uint8_t buf[] = {reg, value};
    if (write(i2c_fd, buf, 2) != 2) {
        std::cerr << "I2C write error" << std::endl;
    }
}

/* 读寄存器 */
uint8_t I2C_readReg(uint8_t reg) {
    uint8_t value;
    if (write(i2c_fd, &reg, 1) != 1) return 0;
    if (read(i2c_fd, &value, 1)!= 1) return 0;
    return value;
}


/* 关闭已打开的I2C设备文件 */
void I2C_close() {
    close(i2c_fd);
}

/* 获取锁 */
void I2C_lock() {
    pthread_mutex_lock(&mutex); /* 加锁 */
}

/* 释放锁 */
void I2C_unlock() {
    pthread_mutex_unlock(&mutex);   /* 解锁 */
}
