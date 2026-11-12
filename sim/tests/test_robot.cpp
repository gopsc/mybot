// Robot：平面运动学（含空中弹道）与相对运动（fdist/turn 到量刹车）。
// 拆分约定与共享工具（断言记账、socket 客户端助手）见 harness.h；套件名册见
// suites.h。本文件的用例正文自拆分前的单文件 sim/tests/main.cpp 逐字搬迁
// （2026-10-04，第三轮重构 Phase 21），未改断言、未改用例数。

#include <cmath>

#include <glm/glm.hpp>

#include "harness.h"
#include "robot.h"
#include "suites.h"

namespace SimTests {

// ---- Robot：运动学 ----

void testKinematics() {
    Robot r;
    check(r.x() == 0.0f && r.z() == 0.0f && r.theta() == 0.0f, "初始位姿在原点");

    // 满油门 4 秒：v 向 kMaxSpeed 一阶逼近，theta=0 时沿 +X 积分
    for (int i = 0; i < 240; ++i) {
        r.update(1.0f / 60.0f, {1.0f, 0.0f}, Robot::kMaxSpeed);
    }
    check(r.v() > 0.9f * Robot::kMaxSpeed, "油门=1 时 v 逼近 kMaxSpeed");
    check(r.x() > 1.0f, "theta=0 前进 x 增加");
    check(near(r.z(), 0.0f, 1e-3f), "theta=0 前进 z 不动");

    // 松油门：v 快速衰减且不为负
    const float v0 = r.v();
    for (int i = 0; i < 60; ++i) {
        r.update(1.0f / 60.0f, {0.0f, 0.0f}, Robot::kMaxSpeed);
    }
    check(r.v() < v0 * 0.5f, "油门=0 时 v 快速衰减");
    check(r.v() >= 0.0f, "v 不为负");

    // steer>0 = 左转（theta 增加）；steer<0 = 右转
    Robot left;
    for (int i = 0; i < 120; ++i) {
        left.update(1.0f / 60.0f, {0.0f, 1.0f}, Robot::kMaxSpeed);
    }
    check(left.theta() > 0.1f, "steer>0 左转 theta 增加");
    Robot right;
    for (int i = 0; i < 120; ++i) {
        right.update(1.0f / 60.0f, {0.0f, -1.0f}, Robot::kMaxSpeed);
    }
    check(right.theta() < -0.1f, "steer<0 右转 theta 减小");
}

// ---- Robot：相对运动（fdist/turn） ----

void testRelativeMotion() {
    const float dt = 1.0f / 60.0f;

    // tickRelative 到量前提前松油门刹车（尾程= v/kStopRate），实走应贴着目标。
    Robot r;
    r.setRelativeDist(1.0f);
    bool active = true;
    int guard = 0;
    while (active && guard++ < 600) {
        RobotInput in;
        active = r.tickRelative(dt, in);
        r.update(dt, in, Robot::kMaxSpeed);
    }
    check(!active, "fdist 走满后 tickRelative 返回 false");
    check(guard < 600, "fdist 1m 在时限内完成");
    check(near(r.x(), 1.0f, 0.05f), "fdist 1m 实走落在 1.0±0.05");

    // 到量后主循环仍在继续 update（现实情形）：残余动量不再拖走位姿
    // （回归：旧实现满速到量后会多滑 v/6 ≈ 0.27m）
    for (int i = 0; i < 90; ++i) {
        r.update(dt, {0.0f, 0.0f}, Robot::kMaxSpeed);
    }
    check(near(r.x(), 1.0f, 0.05f), "到量后减速尾程不再多滑");

    // 后退 0.5m
    Robot back;
    back.setRelativeDist(-0.5f);
    active = true;
    guard = 0;
    while (active && guard++ < 600) {
        RobotInput in;
        active = back.tickRelative(dt, in);
        back.update(dt, in, Robot::kMaxSpeed);
    }
    check(!active, "负 fdist 亦能完成");
    check(near(back.x(), -0.5f, 0.05f), "fdist -0.5m 实走落在 -0.5±0.05");

    // 右转 90°（回归：旧实现满速到量后角动量尾程会多转 ω/6 ≈ 21°）
    Robot t;
    t.setRelativeTurn(glm::radians(-90.0f));
    active = true;
    guard = 0;
    while (active && guard++ < 600) {
        RobotInput in;
        active = t.tickRelative(dt, in);
        t.update(dt, in, Robot::kMaxSpeed);
    }
    check(!active, "turn 完成后 tickRelative 返回 false");
    for (int i = 0; i < 90; ++i) {
        t.update(dt, {0.0f, 0.0f}, Robot::kMaxSpeed);
    }
    check(near(t.theta(), glm::radians(-90.0f), glm::radians(1.5f)),
          "turn -90° 实转落在 -90°±1.5°（含尾程）");

    // fdist 与 turn 顺序执行：先走完再转，同帧设定也不互相吞
    // （回归：旧实现 setRelativeTurn 会清掉 remainingDist，.mt 里
    //   「fdist 2 后 turn 90」两行连续下发时走路段被静默丢弃）
    Robot seq;
    seq.setRelativeDist(0.5f);
    seq.setRelativeTurn(glm::radians(90.0f));
    active = true;
    guard = 0;
    while (active && guard++ < 1200) {
        RobotInput in;
        active = seq.tickRelative(dt, in);
        seq.update(dt, in, Robot::kMaxSpeed);
    }
    check(!active, "fdist+turn 队列执行完成");
    check(near(seq.x(), 0.5f, 0.05f), "先走完 0.5m");
    check(near(seq.theta(), glm::radians(90.0f), glm::radians(1.5f)), "再转 90°");

    // 无相对运动时 tickRelative 不接管
    Robot idle;
    RobotInput in;
    check(!idle.tickRelative(dt, in), "无相对运动返回 false");
}

// ---- Robot：里程累计与前向加速度（2026-10-16，IMU/里程计桥的数据源） ----

void testOdomAccel() {
    const float dt = 1.0f / 60.0f;

    // 静止：里程与加速度都是 0
    Robot still;
    still.update(dt, {0.0f, 0.0f}, Robot::kMaxSpeed);
    check(still.odo() == 0.0f && still.accel() == 0.0f, "静止时 odo/accel 均为 0");

    // 满油门起步：加速度为正（一阶滞后折算的实导数），里程沿路径累计
    Robot go;
    for (int i = 0; i < 30; ++i) {
        go.update(dt, {1.0f, 0.0f}, Robot::kMaxSpeed);
    }
    check(go.accel() > 0.1f, "起步期前向加速度为正");
    check(go.odo() > 0.1f, "里程随位移累计");
    // 里程 = 位移路径长度：theta=0 直线时与 x 位移一致（1e-2 容差吸收离散积分）
    check(near(go.odo(), go.x(), 1e-2f), "直线行驶 odo ≈ |Δx|");

    // 稳态（v 收敛后）：加速度趋 0，里程继续线性累计
    Robot cruise;
    for (int i = 0; i < 600; ++i) {
        cruise.update(dt, {1.0f, 0.0f}, Robot::kMaxSpeed);
    }
    check(std::abs(cruise.accel()) < 0.01f, "稳态加速度趋 0");
    check(cruise.odo() > 5.0f, "长驶里程可观");

    // 松油门减速：加速度为负
    Robot brake;
    for (int i = 0; i < 120; ++i) {
        brake.update(dt, {1.0f, 0.0f}, Robot::kMaxSpeed);
    }
    brake.update(dt, {0.0f, 0.0f}, Robot::kMaxSpeed);
    check(brake.accel() < -0.1f, "松油门后前向加速度为负");

    // 后退：里程按绝对值口径照计（v<0 但 odo 递增）
    Robot back;
    for (int i = 0; i < 60; ++i) {
        back.update(dt, {-1.0f, 0.0f}, Robot::kMaxSpeed);
    }
    check(back.v() < -0.5f, "倒车 v 为负");
    check(back.odo() > 0.1f && near(back.odo(), -back.x(), 1e-2f), "后退里程按绝对值累计");

    // 空中弹道：水平速度守恒 → accel=0，但弹道位移计入里程
    Robot jump;
    jump.launch(1.0f, 0.2f);
    float odoBefore = 0.0f;
    for (int i = 0; i < 6; ++i) {  // 起跳前几帧仍在空中（apex 0.2m ≈ 0.4s 滞空）
        jump.update(dt, {0.0f, 0.0f}, Robot::kMaxSpeed);
        odoBefore = jump.odo();
    }
    check(jump.isAirborne(), "跳跃初期离地");
    check(jump.accel() == 0.0f, "空中水平速度守恒 → accel=0");
    check(odoBefore > 0.0f, "空中弹道位移计入里程");

    // reset 一并清零
    jump.reset();
    check(jump.odo() == 0.0f && jump.accel() == 0.0f, "reset 清零 odo/accel");
}

}  // namespace SimTests
