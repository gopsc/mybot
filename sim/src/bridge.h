#pragma once

#include <string>
#include <vector>

#include "unix_line_server.h"

// mybot 下发的语义动作分两类，刻意分开表达：
//   持续型（SimCommand）：保持到下一条持续型指令为止，像油门位；
//   一次性（SimEvent）：到达即触发、不保持状态，像按一下按钮。
// 迁入早期两者共用一个枚举、靠主循环「枚举变化」边沿触发，导致同枚举重复
// 下发（连续两次不同距离的 fdist、两次 pick）第二条被静默吞掉——事件队列
// 从结构上保证每条一次性指令都触发一次。
enum class SimCommand {
    Stop,
    Forward,
    Backward,
    Left,
    Right,
};

const char* commandName(SimCommand cmd);

struct SimEvent {
    enum class Type {
        FwdDist,  // forward N meters: param = meters (positive)
        Turn,     // turn N degrees: param = degrees (positive=left, negative=right)
        Jump,     // forward jump: param = distance (meters), param2 = apex height (meters)
        Pick,     // pick up obstacle in front
        Place,    // place carried obstacle in front
        Save,     // save scene to the configured scene file (path comes from argv/env, never from the wire)
    };
    Type type;
    float param = 0.0f;
    // 第二数值参数：目前仅 Jump 用（起跳 apex 高度）。其余事件恒 0，线上不多带字段。
    float param2 = 0.0f;
};

// AF_UNIX 行文本服务端。mybot 侧 modules/Sim.lua 每发一条动作写一行：
//   forward | backward | left | right | stop   [速度 0.0~1.0]
//   fdist <meters>
//   turn <degrees>
//   jump <meters> <height>
//   pick / place / save
// 例如 "forward 0.8"、"fdist 2.0"、"turn 90"、"jump 0.8 0.35"。
// 选行文本是为了能用 socat 直接手测：
//   socat - UNIX-CONNECT:/tmp/mybot-sim.sock
//
// 非阻塞、无独立线程：主渲染循环每帧 poll() 一次。同一帧内到达多条持续型
// 指令时以最后一条为准（中间态没有渲染意义）；一次性指令按序入队，主循环
// drain 到空。
class CommandBridge : public UnixLineServer {
public:
    explicit CommandBridge(const std::string& socketPath);

    // 持续型指令的当前状态
    SimCommand command() const { return command_; }
    float speed() const { return speed_; }

    // 取走一条一次性事件（FIFO）；无事件返回 false。主循环每帧 drain 到空。
    bool pollEvent(SimEvent& out);

    // 最近一条解析过的原始行，仅用于窗口标题上给人看
    const std::string& lastLine() const { return lastLine_; }

private:
    void handleLine(const std::string& line) override;
    // 控制器走了蜘蛛就该停：mybot 跑完动作脚本退出、或中途崩掉，都表现为连接
    // 断开。让一只没人管的蜘蛛继续走比让它站住危险得多。队列里未执行的一次性
    // 指令一并作废——没有控制器了，继续执行没有意义。
    void onClientGone() override;

    SimCommand command_ = SimCommand::Stop;
    float speed_ = 1.0f;
    std::vector<SimEvent> events_;
    std::string lastLine_;
};
