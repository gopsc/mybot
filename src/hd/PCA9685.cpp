
#include <cstdint>
#include <unistd.h>
#include "../Dashun_linux.hpp"

constexpr uint8_t PCA9685_ADDR = 0x40;  // 7位地址

/* 初始化PCA9685 */
void PCA9685_init() {
    I2C_lock();
    I2C_setAddr(PCA9685_ADDR);
    I2C_writeReg(0x00, 0x20);   /* 开启AI（地址自增）和关闭SLEEP */
    I2C_unlock();
    usleep(5000);               /* 等待振荡器启动 */

    /* 设置PWM频率为50Hz（舵机标准周期20ms） */
    const float freq = 50.0;
    float prescale_val = 25000000.0 / (4096 * freq) - 1;    /* 25MHz主频 */
    uint8_t prescale = static_cast<uint8_t>(prescale_val + 0.5);

    I2C_lock();
    I2C_writeReg(0.00, 0x10);       /* 进入SLEEP模式（允许改频率） */
    I2C_writeReg(0xFE, prescale);   /* 写入预分频值 */
    I2C_writeReg(0x00, 0x20);       /* 退出SLEEP */
    I2C_unlock();
    usleep(5000);
}

/* 设置指定通道的PWM信号（0-4095） */
void PCA9685_setPWM(uint8_t channel, uint16_t on, uint16_t off) {
    uint8_t reg = 0x06 + 4 * channel;   /* LED0 寄存器起始地址 */
    I2C_lock();
    I2C_setAddr(PCA9685_ADDR);
    I2C_writeReg(reg, on & 0xFF);
    I2C_writeReg(reg + 1, on >> 8);
    I2C_writeReg(reg + 2, off & 0xFF);
    I2C_writeReg(reg + 3, off >> 8);
    I2C_unlock();
}

/*
 * 角度转PWM值（0°~180° → 0.5ms~2.5ms脉宽）
 *
 * NOTE: 设置超过通道15的值可能造成设备损坏
 */
void PCA9685_setAngle(uint8_t channel, float angle) {
    const float min_pulse = 0.5;    /* 0°对应0.5ms */
    const float max_pulse = 2.5;    /* 180°对应2.5ms */
    float pulse_width = min_pulse + (max_pulse - min_pulse) * (angle / 180.0);
    uint16_t off_value = static_cast<uint16_t>(pulse_width * 4096 / 20);        /* 20ms 周期 */
    PCA9685_setPWM(channel, 0, off_value); /* ON=0, OFF=计算值 */
}