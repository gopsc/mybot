#include "sim_engine.h"

#include <glm/glm.hpp>

#include <cstdio>
#include <cstring>

namespace {

// place 失败原因的日志文案。不写 default：新增 PlaceFail 取值而漏了 case 会被
// -Werror=switch 挡在编译期（与 bridge.cpp 的 commandName 同款写法）。
const char* placeFailText(World::PlaceFail why) {
    switch (why) {
        case World::PlaceFail::NotCarrying:
            return "未持有物体，放置失败";
        case World::PlaceFail::PushExceeded:
            return "推出距离超限 (被墙连环顶死)，放置失败";
        case World::PlaceFail::Overlap:
            return "落点仍与障碍 3D 重叠，放置失败";
    }
    return "放置失败";
}

}  // namespace

SimEngine::SimEngine(std::string scenePath) : scenePath_(std::move(scenePath)) {
    if (!scenePath_.empty()) {
        const char* slash = std::strrchr(scenePath_.c_str(), '/');
        sceneName_ = slash ? slash + 1 : scenePath_;
    } else {
        sceneName_ = "builtin";
    }
}

void SimEngine::reloadScene() {
    if (!scenePath_.empty()) {
        SceneState st;
        if (readScene(scenePath_, st)) {
            world_.applyScene(st);
            // 场景里有几只机器人就建几个 slot；已有下标沿用其命令状态（重载不打断
            // 正在执行的 forward），新增下标默认构造即 Stop。
            slots_.resize(st.robots.size());
            for (std::size_t i = 0; i < st.robots.size(); ++i) {
                const RobotSpawn& sp = st.robots[i];
                Robot& r = slots_[i].robot;
                r = Robot();  // 复位位姿/速度/相对运动/搬运
                r.setPose(sp.x, sp.z, sp.theta);
                // 搬运状态属于 Robot，由引擎从 RobotSpawn 恢复；越界由 readScene 归一为 -1。
                if (sp.carriedIdx >= 0 && sp.carriedIdx < (int)world_.obstacles().size()) {
                    r.setCarried(sp.carriedIdx, world_.obstacles()[sp.carriedIdx].mass);
                }
            }
            std::fprintf(stderr, "scene: 已装载 %s（%zu 个障碍, %zu 只机器人）\n",
                         scenePath_.c_str(), st.obstacles.size(), st.robots.size());
            return;
        }
        std::fprintf(stderr, "scene: 回落内置默认场景\n");
    }
    world_ = World();
    slots_.resize(1);
    slots_[0].robot = Robot();
}

void SimEngine::saveScene() {
    if (scenePath_.empty()) {
        std::fprintf(stderr, "save: 未配置场景路径（argv[4] 或 MYBOT_SIM_SCENE），无处置写\n");
        return;
    }
    SceneState st;
    st.obstacles = world_.obstacles();
    st.robots.reserve(slots_.size());
    for (const RobotSlot& s : slots_) {
        RobotSpawn sp;
        sp.x = s.robot.x();
        sp.z = s.robot.z();
        sp.theta = s.robot.theta();
        sp.carriedIdx = s.robot.isCarrying() ? s.robot.carriedIndex() : -1;
        st.robots.push_back(sp);
    }
    if (writeScene(scenePath_, st)) {
        std::fprintf(stderr, "save: 场景已写入 %s（%zu 个障碍, %zu 只机器人）\n",
                     scenePath_.c_str(), st.obstacles.size(), st.robots.size());
    } else {
        std::fprintf(stderr, "save: 写入 %s 失败\n", scenePath_.c_str());
    }
}

RobotInput SimEngine::commandToInput(SimCommand cmd, float speed) const {
    RobotInput input;
    switch (cmd) {
        case SimCommand::Forward:
            input.throttle = speed;
            break;
        case SimCommand::Backward:
            input.throttle = -speed;
            break;
        case SimCommand::Left:
            input.steer = speed;
            break;
        case SimCommand::Right:
            input.steer = -speed;
            break;
        case SimCommand::Stop:
            break;
    }
    return input;
}

void SimEngine::applyContinuous(SimCommand cmd, float speed, std::size_t idx) {
    RobotSlot& s = slot(idx);
    s.command = cmd;
    s.speed = speed;
    if (cmd != s.lastContinuous) {
        std::fprintf(stderr, "cmd[%zu]: %s\n", idx, commandName(cmd));
        if (cmd != SimCommand::Stop) {
            // 新持续型指令覆盖进行中的相对运动（stop 只松油门，不打断 fdist/turn）
            s.robot.setRelativeDist(0.0f);
            s.robot.setRelativeTurn(0.0f);
        }
        s.lastContinuous = cmd;
    }
}

void SimEngine::applyEvent(const SimEvent& ev, std::size_t idx) {
    RobotSlot& s = slot(idx);
    Robot& r = s.robot;
    switch (ev.type) {
        case SimEvent::Type::FwdDist:
            std::fprintf(stderr, "cmd[%zu]: fdist %.2f\n", idx, ev.param);
            r.setRelativeDist(ev.param);
            break;
        case SimEvent::Type::Turn:
            std::fprintf(stderr, "cmd[%zu]: turn %.2f\n", idx, ev.param);
            r.setRelativeTurn(glm::radians(ev.param));
            break;
        case SimEvent::Type::Jump:
            std::fprintf(stderr, "cmd[%zu]: jump dist=%.2f height=%.2f\n", idx, ev.param, ev.param2);
            r.launch(ev.param, ev.param2);
            break;
        case SimEvent::Type::Pick:
            if (r.isCarrying()) {
                std::fprintf(stderr, "pick[%zu]: 已持有物体 (idx=%d, %.2fkg)，忽略\n", idx,
                             r.carriedIndex(), r.carriedMass());
            } else if (world_.pick(r)) {
                const auto& ob = world_.obstacles()[r.carriedIndex()];
                std::fprintf(stderr, "pick[%zu]: 成功拾取 idx=%d mass=%.2fkg pos=(%.2f,%.2f)\n",
                             idx, r.carriedIndex(), r.carriedMass(), ob.center.x, ob.center.z);
            } else {
                std::fprintf(stderr, "pick[%zu]: 前方 %.2fm 内无障碍物，拾取失败\n", idx,
                             World::kPickRange);
            }
            break;
        case SimEvent::Type::Place: {
            World::PlaceFail why = World::PlaceFail::NotCarrying;
            if (world_.place(r, &why)) {
                std::fprintf(stderr, "place[%zu]: 放置成功\n", idx);
            } else {
                std::fprintf(stderr, "place[%zu]: %s\n", idx, placeFailText(why));
            }
            break;
        }
        case SimEvent::Type::Save:
            saveScene();
            break;
    }
}

void SimEngine::step(float dt) {
    for (RobotSlot& s : slots_) {
        Robot& r = s.robot;
        RobotInput input = commandToInput(s.command, s.speed);
        // 空中不接受持续型/相对运动控制（update 走弹道分支会忽略 input），故跳过
        // tickRelative，让进行中的 fdist/turn 剩余量冻结到落地后再续——否则滞空期
        // 会按发射速度空耗掉相对运动的量。
        if (!r.isAirborne()) {
            RobotInput relInput;
            if (r.tickRelative(dt, relInput)) {
                input = relInput;
            }
        }
        r.update(dt, input, r.effectiveMaxSpeed());
        world_.resolveCollisions(r);
        // 竖直：按脚下支撑面（地面或箱顶）落地吸附；支撑突降（走下箱沿）即转坠落。
        r.applySupport(world_.supportHeight(r));
        world_.updateCarried(r);
    }
    // 离散落体：失去支撑的静态箱落到下一支撑面。各机器人背着的箱子一起跳过
    // （跟着机体走）。一层落稳后，原来压在它上面的才看得到新支撑，故重复直到
    // 不再有箱子落下；轮数以障碍数为上限，避免互相穿插时死循环。
    std::vector<int> carried;
    carried.reserve(slots_.size());
    for (const RobotSlot& s : slots_) {
        if (s.robot.isCarrying()) carried.push_back(s.robot.carriedIndex());
    }
    const int n = static_cast<int>(world_.obstacles().size());
    for (int pass = 0; pass < n; ++pass) {
        if (world_.settleUnsupported(carried) == 0) break;
    }
}
