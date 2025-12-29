#pragma once
/*
 * # 安装工具
 * apt install i2c-tools libi2c-dev
 *
 * # 扫描设备
 * i2cdetect -y 1
 */
#include <cstdint>
/* 基本I2C */
void I2C_init(const char* device = "/dev/i2c-1");
void I2C_close();
void I2C_lock();
void I2C_unlock();
void I2C_setAddr(const uint8_t address);
void I2C_writeReg(uint8_t reg, uint8_t value);
uint8_t I2C_readReg(uint8_t reg);

/* PCA9685 */
void PCA9685_init();
void PCA9685_setPWM(uint8_t channel, uint16_t on, uint16_t off);
void PCA9685_setAngle(uint8_t channel, float angle);

/*
 * MPU6050
 * 传感器数据
 */
struct MPU6050_SensorData {
    int16_t accel_x, accel_y, accel_z;
    int16_t gyro_x, gyro_y, gyro_z;
};

void MPU6050_init();
MPU6050_SensorData MPU6050_readSensorData();
void MPU6050_calAngle(const MPU6050_SensorData& data, float& pitch, float& roll);

/* Camera */
#define cimg_display 0 /* 不显示图像，只保存 */
#include "CImg.h"

void Camera_init(int w, int h);
void Camera_close();
void Camera_check();
void Camera_setVideoFormat();
void Camera_reqBuf();
void Camera_setup()
void Camera_TCPServer_init();
void Camera_TCPServer_stop();
void Camera_run();
void Camera_stop();
cimg_library::CImg<unsigned char> get_frame_from_camera(bool& flag);


/* Robot */
#include "hd/Robot.hpp"
