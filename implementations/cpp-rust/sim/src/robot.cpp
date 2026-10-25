#include "robot.h"

#include <glm/gtc/matrix_transform.hpp>

#include <algorithm>
#include <cmath>

using glm::mat4;
using glm::vec3;

void Robot::update(float dt, const RobotInput& input, float maxSpeed) {
    const float vPrev = v_;
    if (airborne_) {
        // 空中弹道：忽略 input（无油门/舵），水平速度守恒，竖直受重力。theta_ 冻结。
        // 落地由 SimEngine 调 applySupport() 收住——这里只管把抛物线积分下去。
        vy_ -= kGravity * dt;
        y_ += vy_ * dt;
        x_ += v_ * std::cos(theta_) * dt;
        z_ += v_ * -std::sin(theta_) * dt;
        // 里程与加速度照常累计：空中水平速度守恒（加速度≈0），但弹道位移计入里程。
        odo_ += std::abs(v_) * dt;
        accel_ = 0.0f;
        return;
    }

    const float targetV = input.throttle * maxSpeed;
    const float targetOmega = input.steer * kMaxTurnRate;
    // 松开指令（throttle=0）时减速明显快于加速，否则「停」之后还溜一大段
    const float vRate = std::min(1.0f, (input.throttle == 0.0f ? kStopRate : 3.0f) * dt);
    const float oRate = std::min(1.0f, kStopRate * dt);
    v_ += (targetV - v_) * vRate;
    omega_ += (targetOmega - omega_) * oRate;

    theta_ += omega_ * dt;
    x_ += v_ * std::cos(theta_) * dt;
    z_ += v_ * -std::sin(theta_) * dt;
    // 地面：y_ 贴住支撑面（由 applySupport 钳制），此处不积分重力——走下箱沿时
    // 支撑面高度会突降，applySupport 发现 y_>support 即转 airborne，下一帧起弹道。

    // 里程计累计（绝对路径长度，前进/后退都计）与机体系前向加速度（帧差分）。
    // 这两个是 IMU/里程计桥的数据源：加速度是一阶滞后折算的实导数，不是编造。
    odo_ += std::abs(v_) * dt;
    accel_ = dt > 0.0f ? (v_ - vPrev) / dt : 0.0f;
}

void Robot::reset() {
    *this = Robot();
}

float Robot::effectiveMaxSpeed() const {
    return kMaxSpeed / (1.0f + carriedMass_ * kLoadSlowdownPerKg);
}

mat4 Robot::baseTransform() const {
    // y_ 让整个机体（含腿，spider.cpp 全相对 base 画）随跳跃离地/落箱一起升降。
    return glm::translate(mat4(1.0f), vec3(x_, y_, z_)) *
           glm::rotate(mat4(1.0f), theta_, vec3(0.0f, 1.0f, 0.0f));
}

void Robot::setRelativeDist(float meters) {
    remainingDist_ = meters;
}

void Robot::setRelativeTurn(float radians) {
    remainingTurn_ = radians;
}

bool Robot::tickRelative(float dt, RobotInput& out) {
    if (std::abs(remainingDist_) > 1e-4f) {
        const float dir = remainingDist_ > 0.0f ? 1.0f : -1.0f;
        // 提前刹车：一阶滞后下松开油门后的滑行尾程 ≈ v/kStopRate。剩余量
        // 小于尾程就收油门，让滑行恰好落在目标上；每帧重估，自收敛——
        // 否则满速到量再松开，尾程会多滑 v/kStopRate（60fps 下 ~0.27m/21°）
        out.throttle = (std::abs(remainingDist_) > std::abs(v_) / kStopRate) ? dir : 0.0f;
        out.steer = 0.0f;
        const float traveled = std::abs(v_) * dt;
        remainingDist_ -= dir * traveled;
        if (std::abs(remainingDist_) <= 1e-4f ||
            (dir > 0 && remainingDist_ < 0) || (dir < 0 && remainingDist_ > 0)) {
            remainingDist_ = 0.0f;
        }
        return true;
    }
    if (std::abs(remainingTurn_) > 1e-4f) {
        const float dir = remainingTurn_ > 0.0f ? 1.0f : -1.0f;
        // 转向同理：剩余角量小于滑行尾程 ω/kStopRate 就回正方向舵
        out.throttle = 0.0f;
        out.steer = (std::abs(remainingTurn_) > std::abs(omega_) / kStopRate) ? dir : 0.0f;
        const float turned = std::abs(omega_) * dt;
        remainingTurn_ -= dir * turned;
        if (std::abs(remainingTurn_) <= 1e-4f ||
            (dir > 0 && remainingTurn_ < 0) || (dir < 0 && remainingTurn_ > 0)) {
            remainingTurn_ = 0.0f;
        }
        return true;
    }
    return false;
}

void Robot::launch(float dist, float height) {
    // 钳到安全范围：负值/超限都归一，避免把蜘蛛弹上天或弹出场景。
    height = std::max(0.0f, std::min(height, kMaxJumpHeight));
    dist = std::max(0.0f, std::min(dist, kMaxJumpDist));
    // 给一个极小下限，保证 dist=0（原地跳）也有非零滞空时间，避免除零。
    const float vy0 = std::sqrt(2.0f * kGravity * std::max(height, 0.01f));
    const float airtime = 2.0f * vy0 / kGravity;   // 上升+回落到同高度
    v_ = dist / airtime;                            // 水平发射速度（空中守恒）
    vy_ = vy0;
    omega_ = 0.0f;                                  // 空中不转
    // 起跳打断进行中的相对运动：空中不受 fdist/turn 控制，落地后重新接受指令。
    remainingDist_ = 0.0f;
    remainingTurn_ = 0.0f;
    airborne_ = true;
}

void Robot::applySupport(float supportY) {
    if (y_ <= supportY) {
        // 落到支撑面（地面或箱顶）：吸附、竖直速度清零、转为地面态。
        y_ = supportY;
        vy_ = 0.0f;
        airborne_ = false;
    } else {
        // 仍高于支撑面：在空中（跳跃途中，或走下箱沿后支撑突降）。
        airborne_ = true;
    }
}

