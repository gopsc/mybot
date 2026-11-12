// SimEngine：headless 验证仿真逻辑（原本困在 GL 壳里无法单测）——场景装卸、
// fdist 到量、多机器人实体化与寻址、跳跃/竖直动力学/支撑面。
// 拆分约定与共享工具（断言记账、socket 客户端助手）见 harness.h；套件名册见
// suites.h。本文件的用例正文自拆分前的单文件 sim/tests/main.cpp 逐字搬迁
// （2026-10-04，第三轮重构 Phase 21），未改断言、未改用例数。

#include <unistd.h>

#include <cmath>
#include <string>
#include <vector>

#include <glm/glm.hpp>

#include "bridge.h"
#include "harness.h"
#include "robot.h"
#include "sim_engine.h"
#include "suites.h"
#include "world.h"

namespace SimTests {

// ---- SimEngine：headless 验证仿真逻辑（原本困在 GL 壳里，无法单测） ----

std::string engineScenePath(const char* tag) {
    return "/tmp/mybot-sim-tests-" + std::to_string(::getpid()) + "-engine-" + tag + ".scene";
}

SimEvent mkEvent(SimEvent::Type type, float param = 0.0f) {
    SimEvent ev;
    ev.type = type;
    ev.param = param;
    return ev;
}

void testSimEngine() {
    const float dt = 1.0f / 60.0f;

    // 无障碍场景：持续型推进与相对运动都不受碰撞干扰
    const std::string emptyPath = engineScenePath("empty");
    writeTextFile(emptyPath, "mybot-sim scene v1\nrobot 0 0 0\n");
    // 拾取场景：正前方 0.3m 处一个可搬盒（近面在拾取半径内）
    const std::string pickPath = engineScenePath("pick");
    writeTextFile(pickPath,
                  "mybot-sim scene v1\n"
                  "robot 0 0 0\n"
                  "box 0.5 0.2 0 0.2 0.2 0.2 1 1 1 5\n");

    // ① 持续型前进：油门=1 沿 +X 积分；stop 后减速
    {
        SimEngine eng(emptyPath);
        eng.reloadScene();
        check(!eng.sceneName().empty() && eng.sceneName().find('/') == std::string::npos,
              "sceneName 取自路径 basename（无斜杠、非空）");
        eng.applyContinuous(SimCommand::Forward, 1.0f);
        for (int i = 0; i < 120; ++i) {
            eng.step(dt);
        }
        check(eng.robot().x() > 1.0f, "持续型 forward 推进 +X");
        check(near(eng.robot().z(), 0.0f, 1e-3f), "theta=0 前进不偏 z");
        eng.applyContinuous(SimCommand::Stop, 1.0f);
        const float v0 = eng.robot().v();
        for (int i = 0; i < 60; ++i) {
            eng.step(dt);
        }
        check(eng.robot().v() < v0 * 0.5f, "stop 后速度衰减");
    }

    // ② 一次性 fdist/turn：引擎 step 内 tickRelative 到量自动停
    {
        SimEngine eng(emptyPath);
        eng.reloadScene();
        eng.applyEvent(mkEvent(SimEvent::Type::FwdDist, 1.0f));
        for (int i = 0; i < 300; ++i) {
            eng.step(dt);
        }
        check(near(eng.robot().x(), 1.0f, 0.05f), "fdist 1m 实走落在 1.0±0.05");

        eng.applyEvent(mkEvent(SimEvent::Type::Turn, 90.0f));
        for (int i = 0; i < 300; ++i) {
            eng.step(dt);
        }
        check(near(eng.robot().theta(), glm::radians(90.0f), glm::radians(1.5f)),
              "turn 90° 实转落在 90°±1.5°");
    }

    // ③ 新持续型指令打断进行中的相对运动（stop 不打断）
    {
        SimEngine eng(emptyPath);
        eng.reloadScene();
        eng.applyEvent(mkEvent(SimEvent::Type::FwdDist, 1.0f));
        for (int i = 0; i < 20; ++i) {
            eng.step(dt);  // 走一段，未到量
        }
        eng.applyContinuous(SimCommand::Forward, 1.0f);  // 打断 fdist
        for (int i = 0; i < 300; ++i) {
            eng.step(dt);
        }
        check(eng.robot().x() > 2.0f, "持续型 forward 打断 fdist 后继续前进（不止于 1m）");
    }

    // ④ pick/place 经引擎事件派发
    {
        SimEngine eng(pickPath);
        eng.reloadScene();
        check(!eng.robot().isCarrying(), "初始未搬运");
        eng.applyEvent(mkEvent(SimEvent::Type::Pick));
        check(eng.robot().isCarrying(), "pick 事件后 isCarrying");
        check(eng.robot().effectiveMaxSpeed() < Robot::kMaxSpeed, "搬运后最大速度被压低");
        // 搬运中前进，物体跟随
        eng.applyContinuous(SimCommand::Forward, 1.0f);
        for (int i = 0; i < 60; ++i) {
            eng.step(dt);
        }
        check(near(eng.world().obstacles()[0].center.x, eng.robot().x(), 1e-4f),
              "搬运中物体跟随机体");
        eng.applyContinuous(SimCommand::Stop, 1.0f);
        const float px = eng.robot().x();
        eng.applyEvent(mkEvent(SimEvent::Type::Place));
        check(!eng.robot().isCarrying(), "place 事件后未搬运");
        check(eng.world().obstacles()[0].center.x > px, "物体放到机体前方");
        check(near(eng.world().obstacles()[0].center.y, eng.world().obstacles()[0].half.y, 1e-3f),
              "place 事件后物体落回地面（不悬空）");
    }

    // ⑤ save/reload round-trip：save 落盘当前位姿，reload 从文件恢复
    {
        const std::string savePath = engineScenePath("save");
        writeTextFile(savePath, "mybot-sim scene v1\nrobot 0 0 0\n");
        SimEngine eng(savePath);
        eng.reloadScene();
        eng.applyEvent(mkEvent(SimEvent::Type::FwdDist, 1.0f));
        for (int i = 0; i < 300; ++i) {
            eng.step(dt);
        }
        const float savedX = eng.robot().x();
        check(near(savedX, 1.0f, 0.05f), "save 前走到 ~1m");
        eng.applyEvent(mkEvent(SimEvent::Type::Save));  // 写回文件
        // 再走一段，位姿前移
        eng.applyEvent(mkEvent(SimEvent::Type::FwdDist, 1.0f));
        for (int i = 0; i < 300; ++i) {
            eng.step(dt);
        }
        check(eng.robot().x() > savedX + 0.5f, "reload 前位姿已前移");
        eng.reloadScene();  // 从刚保存的文件重载
        check(near(eng.robot().x(), savedX, 1e-3f), "reload 恢复到 save 时的位姿");
        ::unlink(savePath.c_str());
    }

    // ⑥ 搬运态 round-trip：搬运属于 Robot，save/reload 经 SceneState.carriedIdx
    //    由引擎恢复到主机器人身上（applyScene 只管障碍）
    {
        const std::string carryPath = engineScenePath("carry");
        writeTextFile(carryPath,
                      "mybot-sim scene v1\n"
                      "robot 0 0 0\n"
                      "box 0.5 0.2 0 0.2 0.2 0.2 1 1 1 5\n");
        SimEngine eng(carryPath);
        eng.reloadScene();
        eng.applyEvent(mkEvent(SimEvent::Type::Pick));
        check(eng.robot().isCarrying(), "pick 后主机器人背负");
        eng.applyEvent(mkEvent(SimEvent::Type::Save));  // 写回（含 carried_idx）
        eng.reloadScene();                              // 从文件重载
        check(eng.robot().isCarrying(), "reload 恢复搬运态");
        check(eng.robot().carriedIndex() == 0, "恢复的是同一障碍 idx=0");
        check(near(eng.robot().carriedMass(), 5.0f, 1e-4f), "恢复搬运质量一致");
        ::unlink(carryPath.c_str());
    }

    ::unlink(emptyPath.c_str());
    ::unlink(pickPath.c_str());
}

// ---- 多机器人实体化（C1 核心守门）：搬运属于每只 Robot，World 服务 N 只 ----
//
// 此前搬运状态是 World 级单例，两只机器人会互相覆盖。C1 把它下沉到 Robot、
// World 改为按传入 Robot 参数化的无状态交互。这条测试用两只机器人在同一 World
// 里各自拾取/背负/减速/放置，证明「N 只各搬各的」在核心层已成立——上线多机器人
// （C2）只剩填容器 + 给指令加寻址，物理无需再改。
void testMultiRobot() {
    std::vector<Obstacle> obs = {
        {{0.5f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1.0f, 1.0f, 1.0f}, 5.0f},   // idx0：A 正前方
        {{0.5f, 0.2f, 3.0f}, {0.2f, 0.2f, 0.2f}, {1.0f, 1.0f, 1.0f}, 20.0f},  // idx1：B 正前方
    };
    World w(obs);
    Robot a, b;
    a.setPose(0.0f, 0.0f, 0.0f);  // 朝 +X，前方 0.3m 是 idx0
    b.setPose(0.0f, 3.0f, 0.0f);  // 朝 +X，前方 0.3m 是 idx1

    check(!a.isCarrying() && !b.isCarrying(), "两只初始均空载");
    check(w.pick(a), "A 拾取前方 idx0");
    check(a.isCarrying() && a.carriedIndex() == 0, "A 背负 idx0");
    check(!b.isCarrying(), "A 拾取不影响 B（搬运是每只各自的状态，非 World 单例）");
    check(w.pick(b), "B 仍可独立拾取前方 idx1");
    check(b.isCarrying() && b.carriedIndex() == 1, "B 背负 idx1");
    check(near(a.carriedMass(), 5.0f, 1e-6f) && near(b.carriedMass(), 20.0f, 1e-6f),
          "两只背负质量各自独立");

    // 负载减速按各自 mass：B 更重更慢
    check(a.effectiveMaxSpeed() > b.effectiveMaxSpeed(), "负重更大的 B 最大速度更低");
    check(near(b.effectiveMaxSpeed(), Robot::kMaxSpeed / (1.0f + 20.0f * 0.01f), 1e-4f),
          "B 减速公式按其自身质量");

    // 各自的搬运物跟随各自机体，互不干扰
    w.updateCarried(a);
    w.updateCarried(b);
    check(near(w.obstacles()[0].center.z, a.z(), 1e-6f) &&
              near(w.obstacles()[1].center.z, b.z(), 1e-6f),
          "两只搬运物分别钉在各自机体上方");

    // 各自放置互不干扰
    check(w.place(a), "A 放置成功");
    check(!a.isCarrying() && b.isCarrying(), "A 放下后 B 仍背负（状态隔离）");
    check(w.place(b), "B 放置成功");
    check(!b.isCarrying(), "B 放下后空载");

    // 测距/碰撞也按各自搬运物跳过：A 放下后 idx0 重新参与 A 的测距
    check(w.queryRange(a) < Robot::kRangeMax, "A 空载后前方障碍重新计入测距");
}

// ---- 引擎多机器人寻址（C2 核心守门）：每只 slot 各接各的命令通道 ----
//
// 壳里每只机器人一套命令桥/测距桥，按 idx 把各自桥的状态喂进 applyContinuous /
// applyEvent(...,idx)。这条测试用一个 v2 双机器人场景，让两只各自拾取、再朝相反
// 方向各走各的，证明「N 只独立受控、互不串台」在引擎层成立——寻址只加了个默认
// 参数（kPrimaryRobot），单机器人旧调用方无感。
void testEngineMultiRobot() {
    const float dt = 1.0f / 60.0f;
    const std::string path = engineScenePath("multi");
    // robot0 在原点朝 +X、robot1 在 (0,5) 朝 +X；各正前方 0.3m 一个可搬盒
    writeTextFile(path,
                  "mybot-sim scene v2\n"
                  "robot 0 0 0\n"
                  "robot 0 5 0\n"
                  "box 0.5 0.2 0 0.2 0.2 0.2 1 1 1 5\n"
                  "box 0.5 0.2 5 0.2 0.2 0.2 1 1 1 8\n");
    SimEngine eng(path);
    eng.reloadScene();
    check(eng.robotCount() == 2, "v2 场景装载 2 只机器人");
    check(near(eng.robot(0).z(), 0.0f, 1e-3f) && near(eng.robot(1).z(), 5.0f, 1e-3f),
          "两只位姿分别来自两条 robot 行");
    check(near(eng.robot().z(), eng.robot(0).z(), 1e-6f), "robot() 缺省即主机器人 idx0");

    // 各自独立拾取：idx 寻址到对应机器人，一只拾取不动另一只
    eng.applyEvent(mkEvent(SimEvent::Type::Pick), 0);
    check(eng.robot(0).isCarrying() && eng.robot(0).carriedIndex() == 0, "robot0 拾取 idx0");
    check(!eng.robot(1).isCarrying(), "robot0 拾取不影响 robot1");
    eng.applyEvent(mkEvent(SimEvent::Type::Pick), 1);
    check(eng.robot(1).isCarrying() && eng.robot(1).carriedIndex() == 1, "robot1 独立拾取 idx1");
    check(near(eng.robot(0).carriedMass(), 5.0f, 1e-4f) &&
              near(eng.robot(1).carriedMass(), 8.0f, 1e-4f),
          "两只背负质量各自独立");

    // 两只朝相反方向各走各的：持续型命令通道按 idx 隔离
    eng.applyContinuous(SimCommand::Forward, 1.0f, 0);
    eng.applyContinuous(SimCommand::Backward, 1.0f, 1);
    for (int i = 0; i < 120; ++i) {
        eng.step(dt);
    }
    check(eng.robot(0).x() > 0.5f, "robot0 forward 沿 +X 前进");
    check(eng.robot(1).x() < -0.5f, "robot1 backward 沿 -X 后退（各自命令独立）");

    ::unlink(path.c_str());
}

// ---- 跳跃 / 竖直动力学 / 支撑面（动作码 10）headless 守门 ----
//
// 覆盖：起跳弹道 apex 与落回、跳到箱顶站稳、箱顶行走、走下箱沿坠落、apex 不够高
// 被当墙挡（高度感知碰撞）、jump 经引擎事件派发。GL 无关，全在 SimEngine+World+Robot 上跑。
SimEvent mkJump(float dist, float height) {
    SimEvent ev;
    ev.type = SimEvent::Type::Jump;
    ev.param = dist;
    ev.param2 = height;
    return ev;
}

void testJump() {
    const float dt = 1.0f / 60.0f;

    // ① 空场景原地跳（dist=0）：升到设定 apex 再落回地面，无水平位移
    {
        const std::string p = engineScenePath("jump-empty");
        writeTextFile(p, "mybot-sim scene v1\nrobot 0 0 0\n");
        SimEngine eng(p);
        eng.reloadScene();
        eng.applyEvent(mkJump(0.0f, 0.5f));
        float maxY = 0.0f;
        int guard = 0;
        while (eng.robot().isAirborne() && guard++ < 600) {
            eng.step(dt);
            if (eng.robot().y() > maxY) {
                maxY = eng.robot().y();
            }
        }
        check(!eng.robot().isAirborne(), "原地跳落地后 airborne 清除");
        check(maxY > 0.40f && maxY < 0.55f, "跳跃 apex 接近设定高度 0.5m");
        check(near(eng.robot().y(), 0.0f, 0.02f), "落回地面 y≈0");
        check(near(eng.robot().x(), 0.0f, 1e-3f), "dist=0 原地跳无水平位移");
        ::unlink(p.c_str());
    }

    // ② 跳到箱顶站稳（apex 高过箱顶）③ 箱顶行走 y 保持箱高
    {
        const std::string p = engineScenePath("jump-box");
        // 宽箱 center(1.4,0.15,0) half(1.0,0.15,1.0) → x 0.4..2.4、顶面 0.3
        writeTextFile(p, "mybot-sim scene v1\nrobot 0 0 0\nbox 1.4 0.15 0 1.0 0.15 1.0 1 0 0\n");
        SimEngine eng(p);
        eng.reloadScene();
        eng.applyEvent(mkJump(0.8f, 0.6f));  // apex 0.6 > 箱顶 0.3
        int guard = 0;
        while (eng.robot().isAirborne() && guard++ < 600) {
            eng.step(dt);
        }
        check(!eng.robot().isAirborne(), "跳上箱后落地");
        check(near(eng.robot().y(), 0.3f, 0.05f), "落在箱顶 y≈箱高 0.3");
        check(eng.robot().x() > 0.4f && eng.robot().x() < 2.4f, "落点在箱面 x 范围内");

        const float landX = eng.robot().x();
        eng.applyContinuous(SimCommand::Forward, 1.0f);
        for (int i = 0; i < 30; ++i) {
            eng.step(dt);
        }
        eng.applyContinuous(SimCommand::Stop, 1.0f);
        check(near(eng.robot().y(), 0.3f, 0.05f), "箱顶行走 y 保持箱高（不掉下去）");
        check(eng.robot().x() > landX + 0.1f, "箱顶行走 x 前进");
        check(eng.robot().x() < 2.4f, "箱顶行走仍在箱面内");
        ::unlink(p.c_str());
    }

    // ④ 走下箱沿 → 支撑突降 → 自动坠回地面
    {
        const std::string p = engineScenePath("jump-fall");
        // 窄箱 x 0.4..1.2、顶面 0.3；跳上后一直前进会走出远端
        writeTextFile(p, "mybot-sim scene v1\nrobot 0 0 0\nbox 0.8 0.15 0 0.4 0.15 0.4 1 0 0\n");
        SimEngine eng(p);
        eng.reloadScene();
        eng.applyEvent(mkJump(0.6f, 0.6f));
        int guard = 0;
        while (eng.robot().isAirborne() && guard++ < 600) {
            eng.step(dt);
        }
        check(near(eng.robot().y(), 0.3f, 0.05f), "先落在窄箱顶 y≈0.3");
        eng.applyContinuous(SimCommand::Forward, 1.0f);
        // 先前进到走出箱沿（airborne 再次为真 = 支撑突降开始坠落），再到重新落地。
        // 不能用 y 阈值判落地：y 降到 0.05 时仍高于地面支撑 0，airborne 还没清。
        guard = 0;
        bool leftBox = false;
        while (guard++ < 600) {
            eng.step(dt);
            if (eng.robot().isAirborne()) {
                leftBox = true;
            } else if (leftBox) {
                break;  // 走过箱沿坠落、又落回地面
            }
        }
        eng.applyContinuous(SimCommand::Stop, 1.0f);
        check(leftBox, "前进后走出箱沿转为坠落（airborne 一度为真）");
        check(near(eng.robot().y(), 0.0f, 0.02f), "走下箱沿后坠回地面 y≈0");
        check(!eng.robot().isAirborne(), "坠地后 airborne 清除");
        check(eng.robot().x() > 1.0f, "已走过箱子远端（x>1.0）");
        ::unlink(p.c_str());
    }

    // ⑤ apex 不够高：箱子当墙挡回（高度感知碰撞），跳不上去、落回地面
    {
        const std::string p = engineScenePath("jump-wall");
        // 高箱 center(0.8,0.25,0) half(0.4,0.25,0.4) → x 0.4..1.2、顶面 0.5
        writeTextFile(p, "mybot-sim scene v1\nrobot 0 0 0\nbox 0.8 0.25 0 0.4 0.25 0.4 1 0 0\n");
        SimEngine eng(p);
        eng.reloadScene();
        eng.applyEvent(mkJump(1.5f, 0.2f));  // apex 0.2 < 箱顶 0.5 → 挡回
        int guard = 0;
        while (eng.robot().isAirborne() && guard++ < 600) {
            eng.step(dt);
        }
        check(near(eng.robot().y(), 0.0f, 0.05f), "跳不够高：落回地面 y≈0（没上箱）");
        check(eng.robot().x() < 0.6f, "跳不够高：被箱当墙挡在近面外");
        ::unlink(p.c_str());
    }
}

}  // namespace SimTests
