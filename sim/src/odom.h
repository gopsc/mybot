#pragma once

#include "request_bridge.h"

// 里程计桥（2026-10-16）：mybot 侧连上发 "odom\n"，仿真器回一帧地面真值位姿。
// 请求-应答骨架在基类 RequestResponseBridge；这里只补里程计独有的**文本响应
// 帧化**（五个浮点域，%.4f）。
//
// 响应域与口径（逐字对应 Robot 的访问器，docs/sim.md「里程计桥」）：
//   x z      世界坐标位置（米，+x 前、+z 右；theta=0 时朝 +x）
//   theta_deg 航向角（度，+左）
//   v        机体前向速度（m/s，带符号：负=后退）
//   odo      累计路径长度（米，绝对值口径：前进/后退/跳跃水平位移都计）
// 注意这是**地面真值**（仿真器的权威状态），不是轮速积分的估计值——仿真里
// 没有轮子打滑模型，两者的差为零，如实标注口径即可。
class OdomBridge : public RequestResponseBridge {
public:
    explicit OdomBridge(const std::string& socketPath);

    // 回传一帧里程计快照（位置/航向/速度/累计里程）。
    bool sendOdom(float x, float z, float thetaDeg, float v, float odo);
};
