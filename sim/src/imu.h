#pragma once

#include "request_bridge.h"

// IMU 桥（2026-10-16）：mybot 侧连上发 "imu\n"，仿真器回一帧机体姿态/角速度/
// 前向加速度/竖直速度/离地标志。请求-应答骨架在基类 RequestResponseBridge；
// 这里只补 IMU 独有的**文本响应帧化**（五个浮点/整数域，%.4f）。与测距桥
// （整数毫米）不同，IMU 是连续物理量，保留小数才有意义。
//
// 响应域与口径（逐字对应 Robot 的访问器，docs/sim.md「IMU 桥」）：
//   yaw_deg  航向角（度，+左）；gyro_z 角速度（rad/s，即 d(yaw)/dt，+左转）
//   acc_fwd  机体系前向加速度（m/s²，update 帧差分）
//   vy       竖直速度（m/s，+上升）；airborne 0/1 是否离地
// 仿真器是运动学模型（非刚体动力学）：没有横摆加速度计/磁力计，域集合如实
// 反映「这台虚拟 IMU 真的测得到什么」，不编造物理量。
class ImuBridge : public RequestResponseBridge {
public:
    explicit ImuBridge(const std::string& socketPath);

    // 回传一帧 IMU 数据（角度制航向、rad/s 角速度、m/s² 前向加速度、m/s 竖直速度）。
    bool sendImu(float yawDeg, float gyroZ, float accFwd, float vy, bool airborne);
};
