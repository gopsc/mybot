
/*
 * FIXME: 1. 传感器数据校准
        2. 可采用卡尔曼滤波
 */
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <unistd.h>
#include "../Dashun_linux.hpp"

constexpr uint8_t MPU6050_ADDR = 0x68;  /* 默认地址 */
constexpr uint8_t PWR_MGMT_1 = 0x6B;    /* 电源管理寄存器 */

/* 初始化 MPU6050 */
void MPU6050_init() {
    I2C_lock();
    I2C_setAddr(MPU6050_ADDR);
    I2C_writeReg(PWR_MGMT_1, 0x00); /* 退出睡眠模式 */
    I2C_writeReg(0x1B, 0x08);       /* 陀螺仪量程 ±500°/s */
    I2C_writeReg(0x1C, 0x10);       /* 加速度计量程 ±8g */
    I2C_unlock();
    usleep(100000);                 /* 等待稳定 */
}

/* 读取 16 位传感器数据（带符号） */
static int16_t read16BitReg(uint8_t reg_high, uint8_t reg_low) {
    return (I2C_readReg(reg_high) << 8) | I2C_readReg(reg_low);
}

/* 获取原始MPU6050传感器数据 */
MPU6050_SensorData MPU6050_readSensorData() {
    MPU6050_SensorData data;
    I2C_lock();
    I2C_setAddr(MPU6050_ADDR);
    data.accel_x = read16BitReg(0x3B, 0x3C);    /* 加速度寄存器 */
    data.accel_y = read16BitReg(0x3D, 0x3E);
    data.accel_z = read16BitReg(0x3F, 0x40);
    data.gyro_x  = read16BitReg(0x43, 0x44);    /* 陀螺仪寄存器 */
    data.gyro_y  = read16BitReg(0x45, 0x46);
    data.gyro_z  = read16BitReg(0x47, 0x48);
    I2C_unlock();
    return data;
}

/* 计算俯仰角（Pitch）和翻滚角（Roll）[单位：度] */
void MPU6050_calAngle(const MPU6050_SensorData& data, float& pitch, float& roll) {
    const float scale = 16384.0;    /* 加速度数据转重力单位（±8g 量程: 16384 LSB/g） */
    float ax = data.accel_x / scale;
    float ay = data.accel_y / scale;
    float az = data.accel_z / scale;

    /* 计算俯仰角(Pitch)和翻滚角(Roll) */
    pitch = atan2(-ax, sqrt(ay * ay + az * az)) * 180.0 / M_PI;
    roll = atan2(ay, az) * 180.0 / M_PI;
}

#ifdef __TEST
/* TEST MAIN */
int main() {
    I2C_init();
    MPU6050_init();
    while (1) {
        MPU6050_SensorData data = MPU6050_readSensorData();
        float pitch, roll;
        MPU6050_calAngle(data, pitch, roll);
        printf("pitch: %.2f\troll: %.2f\n");
    }
}
#endif
