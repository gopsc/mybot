#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "bridge.h"  // SimCommand, SimEvent
#include "robot.h"
#include "world.h"

// 把「机器人 + 世界 + 场景会话 + 每帧推进 + 指令派发」收进一个 **GL 无关** 的对象。
// 此前这些逻辑是 main.cpp（GLFW 壳）里的自由函数与 lambda，无法在无 GL 的
// sim_tests 里验证；抽成 SimEngine 后，fdist 到量、pick/place、save/reload 等
// 都能 headless 单测。
//
// 职责边界：引擎只管仿真语义与物理推进，**不碰** socket、GL、蜘蛛外观步态
// （Spider 是可视化，留在壳里按 robot().v() 自己生成）。壳每帧从命令桥取出
// 持续型状态与一次性事件喂给引擎，再调 step(dt)，然后读 robot()/world() 渲染。
//
// 机器人容器：引擎持有 std::vector<RobotSlot>，每个 slot = 一只 Robot + 它自己的
// 持续型命令状态（command/speed/lastContinuous）。step() 逐只推进，各取本 slot 的
// 命令；World 无状态、按传入的 Robot 参数化，故 N 只各搬各的、互不覆盖。
//
// 寻址（C2）：每只机器人对应壳里**一套独立的命令桥/测距桥 socket**，壳按 robot-id
// 把各自桥的状态喂进 applyContinuous/applyEvent(...,idx)。所有带 idx 的接口默认
// kPrimaryRobot，单机器人调用方（旧代码、测试）无需改动。
class SimEngine {
public:
    // 主机器人下标：相机跟随、标题栏、缺省寻址的目标。
    static constexpr std::size_t kPrimaryRobot = 0;

    // scenePath 空 = 用内置默认场景（无文件）。构造后需调 reloadScene() 装载。
    explicit SimEngine(std::string scenePath = std::string());

    // 装载/重载场景（含所有机器人位姿）。文件读失败回落内置默认并告警，不开黑屏世界。
    // 与旧 main.cpp 一致：复位机器人位姿/速度/相对运动，但**保留各 slot 的持续型
    // 命令状态**（油门来自命令桥，重载后若桥仍是 forward，蜘蛛从新位姿继续走）。
    // slot 数量随场景 robot 行数调整；已有下标的命令状态沿用，新增下标从 Stop 起。
    void reloadScene();
    // 把当前世界状态（障碍 + 全部机器人位姿 + 各自搬运）原子写回场景文件；未配置路径则告警。
    void saveScene();

    // 持续型指令：每帧从对应命令桥喂入当前状态。改油门/方向；非 stop 的新持续型
    // 指令打断进行中的相对运动（stop 只松油门、不打断）。边沿触发日志。
    void applyContinuous(SimCommand cmd, float speed, std::size_t idx = kPrimaryRobot);
    // 一次性事件：fdist/turn 设相对运动剩余量、jump 起跳（弹道 + 竖直冲量）、
    // pick/place 交给 World、save 落盘。
    void applyEvent(const SimEvent& ev, std::size_t idx = kPrimaryRobot);

    // 每帧推进：逐只机器人按**本 slot 的命令**生成输入 → tickRelative（相对运动接管
    // 则覆盖输入；空中跳过）→ update（地面平面滞后 / 空中弹道）→ resolveCollisions
    // （高度感知）→ applySupport（脚下支撑面：落地吸附或走下箱沿转坠落）→ updateCarried
    // → 全部推进完后 settleUnsupported（失去支撑的静态箱落到下一支撑面；背着的跳过）。
    void step(float dt);

    // 感知：指定机器人身体前端中心沿 heading 的射线测距（米）。
    float queryRange(std::size_t idx = kPrimaryRobot) const { return world_.queryRange(slot(idx).robot); }

    // 壳渲染/HUD 用的只读访问。robot(idx) = 指定机器人（缺省主机器人）。
    std::size_t robotCount() const { return slots_.size(); }
    const Robot& robot(std::size_t idx = kPrimaryRobot) const { return slot(idx).robot; }
    const World& world() const { return world_; }
    const std::string& sceneName() const { return sceneName_; }

private:
    // 一只机器人 + 它自己的持续型命令通道（来自壳里对应的一套 socket）。
    struct RobotSlot {
        Robot robot;
        SimCommand command = SimCommand::Stop;
        float speed = 1.0f;
        SimCommand lastContinuous = SimCommand::Stop;  // 边沿检测：只在变化时打断/记日志
    };

    RobotInput commandToInput(SimCommand cmd, float speed) const;
    // 越界下标钳到主机器人：壳按 robotCount() 建桥，正常不会越界；此处兜底防崩。
    RobotSlot& slot(std::size_t idx) { return slots_[idx < slots_.size() ? idx : kPrimaryRobot]; }
    const RobotSlot& slot(std::size_t idx) const {
        return slots_[idx < slots_.size() ? idx : kPrimaryRobot];
    }

    std::string scenePath_;
    std::string sceneName_;
    World world_;
    // 缺省 1 只主机器人，保证 reloadScene() 之前 robot() 也可安全访问。
    std::vector<RobotSlot> slots_ = {RobotSlot{}};
};
