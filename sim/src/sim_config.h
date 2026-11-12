#pragma once

#include <cstddef>

// 仿真器全局配置参数：影响整体行为的可调常量集中管理。
// 类内部的常量（如 Robot::kMaxSpeed、Spider::kLegCount）仍留在各自类里——
// 那是类的实现细节，不是全局配置。这里只放跨模块共享或影响协议行为的参数。
//
// 命名空间 SimConfig 避免与类内部的 kXxx 常量冲突。调用方用 SimConfig::kXxx。
namespace SimConfig {

// ── 命令桥（CommandBridge）────────────────────────────────────────────
// 一次性事件队列上限。FIFO，超限丢弃最旧的。防止控制器崩掉前连发几百条 fdist
// 把内存撑爆。32 条对正常动作脚本绰绰有余（一帧最多 drain 几条）。
constexpr std::size_t kMaxQueuedEvents = 32;

// ── 三桥公共（UnixLineServer）──────────────────────────────────────────
// sendAll 的绝对截止时间（毫秒）。超时即断开对端，不无限等。3 秒覆盖正常响应
// 绰绰有余（拍照的 JPEG 编码也就几十毫秒），又不会因为对端卡死而阻塞渲染循环。
constexpr int kSendDeadlineMs = 3000;

// ── 拍照桥（CaptureBridge）────────────────────────────────────────────
// JPEG 压缩质量（0-100）。90 是画质与体积的平衡点：再高体积翻倍但画质提升肉眼
// 难辨，再低会出现块状伪影影响模型看图判断。
constexpr int kJpegQuality = 90;

// ── 世界（World）───────────────────────────────────────────────────────
// 机器人碰撞半径（米）。用于球体 vs AABB 的碰撞解算。0.2m 约等于蜘蛛车身宽度
// 的一半，留一点余量避免贴太近。
constexpr float kRobotRadius = 0.20f;

// 障碍物默认密度（kg/m³）。800 接近木材密度，给障碍物一个合理的质量默认值。
// 场景文件里没指定质量时用这个 × 体积。
constexpr float kDefaultDensity = 800.0f;

// 场景文件的最大障碍数。512 个足够覆盖复杂场景，再多就是滥用（渲染也吃不消）。
constexpr std::size_t kMaxSceneObstacles = 512;

// 场景文件单行最大长度。512 字节对 box 行绰绰有余（一行的格式是固定的），
// 超限视为格式错误，防止恶意构造的超长行撑爆内存。
constexpr std::size_t kMaxSceneLine = 512;

// ── 默认 socket 路径（与 Lua 侧共享的对外契约）─────────────────────────
// 各 AF_UNIX 桥的缺省路径。运行期实际路径的优先级是 argv > 环境变量 > 这里的
// 缺省（见 main.cpp resolveSocketPath）。这是 C++ 侧的单一事实源：main.cpp
// 不再各写一份字面量。
//
// Lua 侧（modules/Sim.lua 的 kDefaultSock / kSensorDefaultSock）也硬编码了同样
// 的缺省路径——两套构建系统之间不做代码生成（跨 build 生成脆弱，同阶段1 的取舍），
// 改由 sim_tests 的 testSharedConstants 运行期读 Sim.lua 交叉校验字面量一致，
// 任一侧漏改即红；同一套比对另有零编译依赖的 scripts/check_sim_contract.py
// 挂在主干守门上（sim/ 不在 CI 构建范围内，光靠 sim_tests 那份挡不住）。
// Camera.lua 的拍照路径只取自 env、无硬编码缺省，故不参与跨语言比对。
inline constexpr const char* kDefaultSocketPath = "/tmp/mybot-sim.sock";
inline constexpr const char* kDefaultCaptureSocketPath = "/tmp/mybot-sim-capture.sock";
inline constexpr const char* kDefaultSensorSocketPath = "/tmp/mybot-sim-sensor.sock";
inline constexpr const char* kDefaultImuSocketPath = "/tmp/mybot-sim-imu.sock";
inline constexpr const char* kDefaultOdomSocketPath = "/tmp/mybot-sim-odom.sock";

}  // namespace SimConfig
