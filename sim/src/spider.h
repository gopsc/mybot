#pragma once

class Robot;
class Shader;
struct SceneMeshes;

// 4 腿 × 3 段（髋/大腿/小腿）的程序化蜘蛛外观。
//
// 腿部摆动周期由本类自己按身体速度积分生成，**不来自 mybot**：上游只下发
// 语义动作（前进/后退/转向/停），关节角不过桥。速度为 0 时腿停摆。
class Spider {
public:
    static constexpr int kLegCount = 4;

    void update(float dt, float bodySpeed);
    void reset();

    float gaitPhase() const { return phase_; }

    // 0=完全站定（腿不抬）.. 1=满幅步态。停住时相位会冻在某个值上，若抬腿
    // 不随速度渐入，静止的蜘蛛就会僵在「两条腿平举」的半程姿态。
    float stride() const { return stride_; }

    // legIndex: 0=右前 1=左前 2=右后 3=左后。对角步态（trot）：0/3 同相，1/2 反相。
    static float legPhase(int legIndex, float gaitPhase);

private:
    // 身体每前进 1 米腿部相位推进的弧度数，决定步频观感（≈2.2 个完整步周期/米）
    static constexpr float kPhaseRadPerMeter = 14.0f;

    float phase_ = 0.0f;
    float stride_ = 0.0f;
};

void drawSpider(const Robot& robot, const Spider& spider, const Shader& shader,
                const SceneMeshes& meshes);
