#pragma once

#include <glm/glm.hpp>

// 语义动作折算出的身体速度目标，由 CommandBridge 的指令填充。
// 「停」就是 throttle=0，减速快慢由 update() 的滞后常数决定。
struct RobotInput {
    float throttle = 0.0f;  // -1 (后退) .. 1 (前进)
    float steer = 0.0f;     // -1 (右) .. 1 (左)
};

// 蜘蛛身体的运动学：平面上一阶滞后逼近目标速度再积分出位姿；竖直方向仅在
// **跳跃/离地**时做最小弹道积分（重力 + 落地吸附），不做完整物理。
//
// 刻意不含刚体动力学、不含足地接触、不做 IK——mybot 只发「前进/后退/转向/停/跳」，
// 这里只负责把这些动作变成身体在场景里的位移结果；碰撞解算/射线测距/拾取放置/
// 支撑面高度（脚下踩的是地面还是箱顶）等与场景的相互作用归 World。
//
// 竖直方向是跳跃（动作码 10）引入的**受控例外**：y_ 是身体离地高度、vy_ 是竖直
// 速度。地面时 update() 不碰 y_（贴住支撑面，由 applySupport 钳制）；起跳后
// launch() 给一记竖直冲量并置 airborne_，空中 update() 让水平速度守恒做弹道、
// 重力拉 vy_，直到 applySupport() 发现 y_ 落回支撑面（地面或某箱顶）才收住。
// 因此「跳到箱子上、在箱子上走、走下箱沿坠落」都由这一套 y_/vy_ + World 支撑面
// 表达，Robot 自身仍不知道场景里有什么。
//
// 例外是**搬运状态**：每只机器人各自记「我背着第几个障碍、多重」，因为它是
// 机器人自身的属性、且必须多机器人各背各的（此前寄存在 World 里是单例，两只
// 机器人会互相覆盖）。Robot 只持有 idx+mass，「哪个 idx 在哪、怎么拾怎么放」
// 仍是 World 的事。
//
// 坐标系：机体局部 +X 为前、+Y 为上、+Z 为**右**（右手系 X×Y=Z 的必然结果）。
// 因此 theta 增大 = 向左转，与 steer>0 = 左转 一致。
class Robot {
public:
    static constexpr float kMaxSpeed = 1.6f;     // m/s（空载上限）
    static constexpr float kMaxTurnRate = 2.2f;  // rad/s
    // 松开指令后的减速速率（1/s）。update() 的滞后常数与 tickRelative() 的
    // 刹车尾程估算共用这一个值——两处不一致刹车就会失准
    static constexpr float kStopRate = 6.0f;
    // 搬运负载的减速系数（每 kg）：maxSpeed = kMaxSpeed/(1+mass*此值)，
    // 0.01 时 1kg 减速 1%、400kg 减速 80%。
    static constexpr float kLoadSlowdownPerKg = 0.01f;

    // ── 跳跃 / 竖直动力学 ─────────────────────────────────────────────
    // 重力加速度（m/s²）。跳跃 apex 与滞空时间都由它折算。
    static constexpr float kGravity = 9.8f;
    // 起跳参数上限（防滥用把蜘蛛弹上天/弹出场景）：apex 高度与前跳水平距离。
    static constexpr float kMaxJumpHeight = 1.5f;
    static constexpr float kMaxJumpDist = 4.0f;
    // 支撑吸附容差（米）：障碍顶面 ≤ 脚下 y_+此值 视为「地板」（可站、不推），
    // > 此值视为「墙」（XZ 推出）。它同时决定不跳最多能踏上多高的台阶——2cm
    // 意味着地面行驶几乎不会自动爬箱（碰撞语义与加跳跃前一致），要上箱必须跳。
    static constexpr float kGroundSnapTol = 0.02f;

    // 躯干尺寸，spider.cpp 按这些常量摆放身体与髋部；World 用车身前端作
    // 测距射线与拾取判定的原点
    static constexpr float kBodyLength = 0.40f;
    static constexpr float kBodyWidth = 0.28f;
    static constexpr float kBodyHeight = 0.14f;
    static constexpr float kBodyY = 0.26f;

    // 激光测距仪：最大探测距离（米）。超出此距离即使无障碍也返回该值。
    static constexpr float kRangeMax = 10.0f;

    // maxSpeed 由调用方给（World 按搬运负载折算后传入）；空载传 Robot::kMaxSpeed。
    // 地面（!airborne_）：原平面一阶滞后 + 积分，y_/vy_ 不动（贴住支撑面）。
    // 空中（airborne_）：忽略 input，水平速度 v_ 守恒做弹道、theta_ 冻结（无空中
    //   转向/油门），vy_ 受重力——直到 applySupport() 收住落地。
    void update(float dt, const RobotInput& input, float maxSpeed);
    void reset();

    glm::mat4 baseTransform() const;

    float x() const { return x_; }
    float z() const { return z_; }
    float theta() const { return theta_; }
    float v() const { return v_; }
    float omega() const { return omega_; }
    // 竖直：y_=身体离地高度（地面 0 / 箱顶=箱高），vy_=竖直速度，airborne_=是否离地。
    float y() const { return y_; }
    float vy() const { return vy_; }
    bool isAirborne() const { return airborne_; }
    // 里程计/IMU 桥的数据源（2026-10-16）：odo_=累计路径长度（米，绝对值口径，
    // 前进/后退都计，跳跃的水平位移也计）；accel_=机体系前向加速度（m/s²，
    // update 的帧差分实导数——空中水平速度守恒故为 0）。reset() 一并清零。
    float odo() const { return odo_; }
    float accel() const { return accel_; }

    void setX(float x) { x_ = x; }
    void setZ(float z) { z_ = z; }
    // 场景装载/重载用：整体设位姿（theta 弧度），不动速度
    void setPose(float x, float z, float theta) { x_ = x; z_ = z; theta_ = theta; }

    // 相对运动：fdist 与 turn 各记各的剩余量、**顺序执行**（先走完再转），
    // 同通道新目标覆盖旧目标。设定后每帧由主循环调用 tickRelative()，到量即
    // 自动停——到量前会提前松油门刹车，消掉一阶滞后的减速尾程。
    void setRelativeDist(float meters);
    void setRelativeTurn(float radians);
    // 每帧调用，返回本帧应覆盖的 input（有相对运动时忽略外部 input）。
    // 返回 true 表示相对运动仍在进行、false 表示已完成或没有。
    bool tickRelative(float dt, RobotInput& out);

    // 起跳（动作码 10）：朝当前 heading 前方弹道跳。dist=期望水平前跳距离（米），
    // height=期望 apex 离地高度（米）——两者都被钳到 kMaxJump*。折算：竖直冲量
    // vy0=√(2·g·height)、滞空 t=2·vy0/g、水平发射速度 vx=dist/t（空中守恒）。
    // 置 airborne_ 后由 update() 弹道推进，直到 applySupport() 落地。dist=0 即原地跳。
    // 与相对运动互斥：起跳会清掉进行中的 fdist/turn（空中不受它们控制）。
    void launch(float dist, float height);

    // 每帧由 SimEngine 在算出脚下支撑高度后调用（支撑面归 World）。y_ ≤ supportY
    // 即落地/站稳：吸附到支撑面、竖直速度清零、airborne_=false；否则仍在空中。
    void applySupport(float supportY);

    // 搬运状态（每只各自持有；idx<0 = 空载）。setCarried/clearCarried 由 World
    // 的 pick/place 调用——Robot 只存「背着哪个、多重」，不含拾放逻辑。
    bool isCarrying() const { return carriedIdx_ >= 0; }
    int carriedIndex() const { return carriedIdx_; }
    float carriedMass() const { return carriedMass_; }
    void setCarried(int idx, float mass) { carriedIdx_ = idx; carriedMass_ = mass; }
    void clearCarried() { carriedIdx_ = -1; carriedMass_ = 0.0f; }

    // 负载折算后的最大速度（m/s）：空载 = kMaxSpeed，负重越大越慢。
    float effectiveMaxSpeed() const;

private:
    float x_ = 0.0f, z_ = 0.0f, theta_ = 0.0f;
    float v_ = 0.0f, omega_ = 0.0f;

    // 竖直状态（仅跳跃/离地时演进；地面时 y_ 贴住支撑面、vy_=0）。
    float y_ = 0.0f;               // 身体离地高度（米）
    float vy_ = 0.0f;              // 竖直速度（米/秒，正=上升）
    bool airborne_ = false;        // 是否离地（update 走弹道分支）

    // 里程计/IMU 累计量（2026-10-16，见 odo()/accel() 注释）。
    float odo_ = 0.0f;             // 累计路径长度（米）
    float accel_ = 0.0f;           // 机体系前向加速度（m/s²，update 内差分）

    // 相对运动剩余量；<=0 表示无待执行的相对运动。
    float remainingDist_ = 0.0f;   // 米（正=前进，负=后退）
    float remainingTurn_ = 0.0f;   // 弧度（正=左转，负=右转）

    // 当前背负的障碍下标与质量缓存（-1 = 空载）。
    int carriedIdx_ = -1;
    float carriedMass_ = 0.0f;
};
