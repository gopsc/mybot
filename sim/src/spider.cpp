#include "spider.h"

#include <glm/gtc/matrix_transform.hpp>

#include <algorithm>
#include <cmath>

#include "mesh.h"
#include "robot.h"
#include "shader.h"

using glm::mat4;
using glm::vec3;

namespace {

constexpr float kPi = 3.14159265358979323846f;

// 腿节尺寸（米）：髋侧展段 / 大腿 / 小腿
constexpr float kCoxaLen = 0.09f;
constexpr float kFemurLen = 0.16f;
constexpr float kTibiaLen = 0.18f;
constexpr float kCoxaThick = 0.050f;
constexpr float kFemurThick = 0.032f;
constexpr float kTibiaThick = 0.022f;

// 髋部安装点：前后偏移取自机体长度，左右贴机身侧面
constexpr float kHipX = 0.13f;
constexpr float kHipY = Robot::kBodyY - 0.02f;
constexpr float kHipZ = Robot::kBodyWidth * 0.5f;

// 静态站姿角（自水平向下）：大腿 0.45，膝部再折 0.55，足端恰好落在地面附近
constexpr float kFemurBase = 0.45f;
constexpr float kTibiaBase = 0.55f;

// 步态摆幅
constexpr float kYawSwing = 0.45f;  // 髋部前后摆（rad）
constexpr float kLift = 0.30f;      // 摆动相抬腿幅度（rad）

const vec3 kBodyColor(0.15f, 0.16f, 0.20f);
const vec3 kHeadColor(0.21f, 0.23f, 0.28f);
const vec3 kLegColor(0.09f, 0.09f, 0.12f);
const vec3 kEyeColor(1.00f, 0.90f, 0.30f);
const vec3 kCamColor(0.95f, 0.55f, 0.10f);
const vec3 kLensColor(0.08f, 0.08f, 0.10f);

void drawPart(const Shader& shader, const Mesh& mesh, const mat4& model, const vec3& color) {
    shader.setMat4("model", model);
    shader.setVec3("objectColor", color);
    mesh.draw();
}

// 在给定坐标系里沿局部 ±Z 摆一根方段（腿节）。side=+1 朝右侧、-1 朝左侧。
mat4 segmentAlongZ(const mat4& frame, float side, float len, float thick) {
    return frame * glm::translate(mat4(1.0f), vec3(0.0f, 0.0f, side * len * 0.5f)) *
           glm::scale(mat4(1.0f), vec3(thick, thick, len));
}

void drawLeg(const Shader& shader, const SceneMeshes& meshes, const mat4& base, int legIndex,
             float phase, float stride) {
    // 0=右前 1=左前 2=右后 3=左后
    const float side = (legIndex == 0 || legIndex == 2) ? 1.0f : -1.0f;
    const float fore = (legIndex == 0 || legIndex == 1) ? 1.0f : -1.0f;

    const mat4 hip =
        base * glm::translate(mat4(1.0f), vec3(fore * kHipX, kHipY, side * kHipZ));

    // 髋部前后摆（绕 Y）。机体局部 +Z 是右侧，R_y(θ) 把 +Z 转向 +X（前），
    // 所以右侧腿正角即前摆；左侧腿外展方向是 -Z，要取反才左右对称。
    const float yaw = side * kYawSwing * std::sin(phase);
    const mat4 legFrame = hip * glm::rotate(mat4(1.0f), yaw, vec3(0.0f, 1.0f, 0.0f));
    drawPart(shader, meshes.cube, segmentAlongZ(legFrame, side, kCoxaLen, kCoxaThick), kLegColor);

    // 摆动相抬腿：sin 的导数是 cos，cos>0 正是髋部向前回摆的半程，此时腿该离地
    const float lift = kLift * stride * std::max(0.0f, std::cos(phase));

    // 大腿下压。R_x(φ) 把 +Z 转向 -Y（下），故右侧用 +φ、左侧用 -φ
    const mat4 femurFrame =
        legFrame * glm::translate(mat4(1.0f), vec3(0.0f, 0.0f, side * kCoxaLen)) *
        glm::rotate(mat4(1.0f), side * (kFemurBase - lift), vec3(1.0f, 0.0f, 0.0f));
    drawPart(shader, meshes.cube, segmentAlongZ(femurFrame, side, kFemurLen, kFemurThick),
             kLegColor);

    // 小腿：膝部在同轴上再折一段，抬腿时收得更拢
    const mat4 tibiaFrame =
        femurFrame * glm::translate(mat4(1.0f), vec3(0.0f, 0.0f, side * kFemurLen)) *
        glm::rotate(mat4(1.0f), side * (kTibiaBase + lift * 0.6f), vec3(1.0f, 0.0f, 0.0f));
    drawPart(shader, meshes.cube, segmentAlongZ(tibiaFrame, side, kTibiaLen, kTibiaThick),
             kLegColor);

    const mat4 foot = tibiaFrame * glm::translate(mat4(1.0f), vec3(0.0f, 0.0f, side * kTibiaLen));
    drawPart(shader, meshes.sphere, foot * glm::scale(mat4(1.0f), vec3(kTibiaThick * 1.7f)),
             kLegColor);
}

void drawBody(const Shader& shader, const SceneMeshes& meshes, const mat4& base) {
    const float bodyTop = Robot::kBodyY + Robot::kBodyHeight * 0.5f;

    drawPart(shader, meshes.cube,
             base * glm::translate(mat4(1.0f), vec3(0.0f, Robot::kBodyY, 0.0f)) *
                 glm::scale(mat4(1.0f),
                            vec3(Robot::kBodyLength, Robot::kBodyHeight, Robot::kBodyWidth)),
             kBodyColor);

    // 后段腹部（圆鼓）
    drawPart(shader, meshes.sphere,
             base * glm::translate(mat4(1.0f),
                                   vec3(-Robot::kBodyLength * 0.44f, Robot::kBodyY + 0.02f, 0.0f)) *
                 glm::scale(mat4(1.0f), vec3(0.26f, 0.20f, 0.23f)),
             kBodyColor);

    // 前段头胸
    drawPart(shader, meshes.cube,
             base * glm::translate(mat4(1.0f),
                                   vec3(Robot::kBodyLength * 0.42f, Robot::kBodyY - 0.01f, 0.0f)) *
                 glm::scale(mat4(1.0f), vec3(0.17f, 0.11f, 0.19f)),
             kHeadColor);

    // 眼
    const float eyeX = Robot::kBodyLength * 0.50f;
    const float eyeY = Robot::kBodyY + 0.02f;
    drawPart(shader, meshes.sphere,
             base * glm::translate(mat4(1.0f), vec3(eyeX, eyeY, 0.05f)) *
                 glm::scale(mat4(1.0f), vec3(0.036f)),
             kEyeColor);
    drawPart(shader, meshes.sphere,
             base * glm::translate(mat4(1.0f), vec3(eyeX, eyeY, -0.05f)) *
                 glm::scale(mat4(1.0f), vec3(0.036f)),
             kEyeColor);

    // 云台相机：真机上是 cam0/cam1 两路舵机，这里只做外观，不参与指令
    const float camY = bodyTop + 0.035f;
    drawPart(shader, meshes.cube,
             base * glm::translate(mat4(1.0f), vec3(0.02f, camY, 0.0f)) *
                 glm::scale(mat4(1.0f), vec3(0.10f, 0.07f, 0.10f)),
             kCamColor);
    drawPart(shader, meshes.cylinder,
             base * glm::translate(mat4(1.0f), vec3(0.075f, camY, 0.0f)) *
                 glm::rotate(mat4(1.0f), glm::half_pi<float>(), vec3(0.0f, 0.0f, 1.0f)) *
                 glm::scale(mat4(1.0f), vec3(0.05f, 0.04f, 0.05f)),
             kLensColor);
}

}  // namespace

void Spider::update(float dt, float bodySpeed) {
    // 相位直接由位移积分：速度为 0 腿就停摆，负速度（后退）自然反转步态
    phase_ += dt * bodySpeed * kPhaseRadPerMeter;
    if (phase_ > kPi) {
        phase_ -= 2.0f * kPi;
    } else if (phase_ < -kPi) {
        phase_ += 2.0f * kPi;
    }

    // 抬腿幅度随速度渐入：走起来才迈腿，停住就四腿站直
    const float target = std::min(1.0f, std::fabs(bodySpeed) / 0.25f);
    stride_ += (target - stride_) * std::min(1.0f, 6.0f * dt);
}

void Spider::reset() {
    phase_ = 0.0f;
    stride_ = 0.0f;
}

float Spider::legPhase(int legIndex, float gaitPhase) {
    // 对角步态：右前(0) 与 左后(3) 同相，左前(1) 与 右后(2) 反相
    const bool alternate = (legIndex == 1 || legIndex == 2);
    return gaitPhase + (alternate ? kPi : 0.0f);
}

void drawSpider(const Robot& robot, const Spider& spider, const Shader& shader,
                const SceneMeshes& meshes) {
    const mat4 base = robot.baseTransform();

    drawBody(shader, meshes, base);
    const float stride = spider.stride();
    for (int leg = 0; leg < Spider::kLegCount; ++leg) {
        drawLeg(shader, meshes, base, leg, Spider::legPhase(leg, spider.gaitPhase()), stride);
    }
}
