#pragma once

#include <glm/glm.hpp>

#include <string>
#include <vector>

#include "robot.h"

// 场景障碍物：盒体（center=中心, half=半尺寸, color=漫反射色, mass=质量kg,
// yaw=绕 Y 轴朝向（弧度，0=轴对齐，符号与 Robot::theta 一致））。
// mass 用于搬运时的减速计算：由场景文件给定，缺 mass 的行按体积×密度补
// （SimConfig::kDefaultDensity）。
// 带 yaw 后盒是有向盒（OBB）：碰撞/测距/拾取/支撑面都先在盒局部系里按轴对齐
// 解算、再旋回世界系（见 obb2d.h 的 Obb2D::worldToLocal/localToWorld）。
struct Obstacle {
    glm::vec3 center;
    glm::vec3 half;
    glm::vec3 color;
    float mass = 1.0f;
    float yaw = 0.0f;
};

// 场景里一只机器人的初始状态。theta 用弧度（文件里是度，读写边界换算）。
struct RobotSpawn {
    float x = 0.0f;
    float z = 0.0f;
    float theta = 0.0f;   // 弧度
    int carriedIdx = -1;  // 装载时该机器人已搬运的障碍下标（-1=无）
};

// 场景文件的内存形态：障碍集合 + N 只机器人。v1 文件读成 1 只、v2 可多只；
// readScene 保证 robots 至少 1 只（缺 robot 行补一只原点默认）。
struct SceneState {
    std::vector<Obstacle> obstacles;
    std::vector<RobotSpawn> robots;
};

// 仿真场景：障碍物集合 + 机器人与场景的相互作用（碰撞推出、射线测距、
// 拾取/放置/背负跟随、失去支撑时的离散落下）。Robot 管运动学与**自己背着哪个障碍**；「世界里有什么、
// 撞了怎么解、能不能搬」都在这里。盒-盒之间**不做逐帧碰撞解算**，只在 place() 里做
// 一次放置解算（被占则近侧水平推开 + 按脚下支撑面落地/叠放）；静态箱的另一条移动
// 是 settleUnsupported()——底面悬空时落到下一支撑面，不是刚体碰撞。
// 所有交互都按传入的 Robot 参数化、World 自身
// 不持有任何单只机器人的状态——因此同一 World 可服务 N 只机器人，各搬各的。
// GL 无关，归 simcore。
class World {
public:
    // 装载给定障碍（不改动质量，测试用自定义场景）；缺省装载 defaultScene()
    explicit World(std::vector<Obstacle> obstacles = defaultScene());

    std::vector<Obstacle>& obstacles() { return obstacles_; }
    const std::vector<Obstacle>& obstacles() const { return obstacles_; }

    // 球（XZ 平面）vs 盒截面碰撞解算：把机器人推出盒面（逐障碍解算，不迭代）。
    // **高度感知**：顶面 ≤ 机器人脚下 y_+kGroundSnapTol 的障碍视为「地板」（可站/
    // 可跳过），不产生推出；只有比脚高的「墙」才推。故跳跃 apex 高过箱顶即可越过。
    // 该机器人正搬运的物体附着在它身上，跳过不参与碰撞。
    void resolveCollisions(Robot& robot);

    // 机器人脚下的支撑面高度（米）：脚下 XZ 圆（半径 kRobotRadius）重叠、且顶面
    // 不高于脚下（y_+kGroundSnapTol）的所有障碍里最高的那个顶面；无则地面 0。
    // SimEngine 每帧用它给 Robot.applySupport()——落地吸附、走下箱沿转坠落都靠它。
    // 该机器人搬运的物体不计入（背着的箱子不能踩）。
    float supportHeight(const Robot& robot) const;

    // 机器人前方射线与障碍求交，返回最近命中距离（米）；无命中返回 maxRange。
    // 射线从身体前端、离地（身体中心高度）水平发出、沿 heading 方向。顶面不高于
    // 脚下（y_+kGroundSnapTol）的障碍是地板，射线从它上方穿过去，不当墙——站在
    // 箱顶上时读到的是前方的墙，不是脚下这块箱子的近面。该机器人搬运的物体不计入。
    float queryRange(const Robot& robot, float maxRange = Robot::kRangeMax) const;

    // 离散支撑：把「底面悬空、脚下还有更低支撑面」的静态箱落到该支撑面上（地面
    // 或另一箱顶）。不做逐帧刚体。carriedIdxs 里的下标是某只机器人正背着的，跳过
    // （跟着机体走，不能当静态箱落下）。返回本轮落下的箱子数。叠了多层时调用方应
    // 重复调用直到返回 0（一层落稳后，原来压在它上面的才有新的支撑面可落）。
    int settleUnsupported(const std::vector<int>& carriedIdxs = {});

    // place() 失败的原因（成功时不写）。与下方 place 契约里的 ①② 一一对应，另加
    // 「根本没背东西」——三者处置不同，故不让调用方只能看到一个 false。
    enum class PlaceFail {
        NotCarrying,   // 未搬运物体，或搬运下标越界
        PushExceeded,  // ① 累计推出距离超过 kMaxPlacePush
        Overlap,       // ② 兜底后仍与某障碍 3D 重叠
    };

    // 搬运设备：拾取/放置前方物体。搬运状态写回**传入的这只 Robot**（各背各的）。
    // pick: 尝试拾取前方最近的可搬运物体（距离 < kPickRange 且在前方），成功
    // 返回 true；该机器人已持有物体时直接失败；目标上方贴着另一个障碍（同一套
    // kGroundSnapTol 支撑容差 + XZ 重叠判定，与 supportHeight 的「地板」判定互为
    // 镜像）时也直接失败——上面压着箱子，抽不出来，需先搬走上面那个。
    // place: 把该机器人当前搬运的物体放到前方 kPlaceDist 处，成功返回 true。
    // 放置时做一次几何解算：与「墙」（顶面高于脚下的箱，且压在落点的竖直带上）XZ 重叠
    // 则沿机器人前方把盒子水平推开、只推近侧（不穿到阻挡箱对面）；落地高度取脚印下最高
    // 的支撑面（顶面不高于脚下的箱顶），无则地面——机器人自己站上箱顶松手即可叠放。
    // 几何不可行时返回 false、物体保留在搬运状态、场景不变（不会留下重叠的假结果）：
    // ① 累计推出距离超过 kMaxPlacePush（如被巨大/多堵墙连环顶）；
    // ② 兜底后仍与某个障碍 3D 重叠（基于释放高度的「墙/支撑」分类属启发式，写回前
    //    总会再做一次事实性的重叠校验兜底）。
    // 失败原因写进 *why（可为 nullptr＝不关心），取值见上面的 PlaceFail。
    bool pick(Robot& robot);
    bool place(Robot& robot, PlaceFail* why = nullptr);

    // 该机器人搬运中的物体跟随它移动：钉在身体正上方（抬高避免挡住摄像机）
    void updateCarried(const Robot& robot);

    // 整体替换障碍集合。搬运状态属于每只 Robot、不由场景承载——重载后由
    // SimEngine 按 SceneState.carriedIdx 恢复到主机器人身上。carriedIdx 越界
    // 由 readScene 归一为 -1。
    void applyScene(const SceneState& scene);

    static constexpr float kPickRange = 0.6f;  // 拾取半径（米）
    static constexpr float kPlaceDist = 0.5f;  // 放置距离（米）
    // 背负物体底面相对身体顶部再抬高的量（米）：避免挡住摄像机，同时是释放高度
    // releaseBottom 的组成部分（place 与 updateCarried 共用，单一事实源）。
    static constexpr float kCarryLift = 0.10f;

    // 默认障碍场景：蜘蛛从原点出发沿 +X 前进，障碍散布在前进路线两侧。
    // 与 sim/scenes/default.scene 逐字段同值（含每箱手调的质量，非统一 体积×密度），
    // 两边由 scripts/check_sim_contract.py 钉住——它是无场景文件时的内置回落，
    // 漂移就等于「跑没跑场景文件」静默变成两个世界。
    static std::vector<Obstacle> defaultScene();

private:
    std::vector<Obstacle> obstacles_;

    // 判断障碍 idx 上方是否贴着另一个障碍（顶面与别的障碍底面的距离 <=
    // kGroundSnapTol、且 XZ 有重叠）。pick() 用它拒绝"上面压着箱子、抽不出来"
    // 的目标——与 supportHeight()/wallVerticalConflict 的"地板/支撑"判定同一
    // 套容差，只是方向相反（查谁贴在它上面，而非它贴在谁上面）。
    bool isObstacleCovered(int idx) const;
};

// ---- 场景文件读写（行文本，与三桥协议同风格，可手编可 diff；实现在 scene_io.cpp） ----
//
// 首行必须是魔数 "mybot-sim scene v1"/"v2"/"v3"，之后每行一条——
//   box <cx> <cy> <cz> <hx> <hy> <hz> <r> <g> <b> [<mass> [<yaw_deg>]]
//   robot <x> <z> <theta_deg> [<carried_idx>]
// v1 与 v2 的差别只在 robot 行数：v1 恒 1 只，v2 允许**多条 robot 行**（多机器人）。
// v3 在 box 行追加可选 <yaw_deg>（绕 Y 朝向，度；0=轴对齐）——v1/v2 的盒读成 yaw=0。
// readScene 三者都收，按出现顺序读进 SceneState.robots；writeScene 一律写 v3
// （v3 是 v1/v2 的超集）。# 开头的注释与空行忽略；行内 '#' 起视为
// 注释。未知/坏行告警后跳过（与命令桥「垃圾不打断当前状态」同口径）；mass 缺省按
// 体积×800kg/m³；无 robot 行补一只原点默认。
//
// 读失败（缺文件/缺魔数/超障碍数上限）返回 false 并置 stderr。
bool readScene(const std::string& path, SceneState& out);

// 原子写：先落 <path>.tmp 再 rename，写一半崩溃不会毁掉已有场景。写 v2 魔数。
bool writeScene(const std::string& path, const SceneState& state);
