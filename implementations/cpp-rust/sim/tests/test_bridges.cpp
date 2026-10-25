// 五座 AF_UNIX 桥的线上协议（命令桥的持续型状态 + 一次性事件，拍照桥的二进制
// 体帧化，测距桥的文本响应），以及请求-应答基类的扩展成本。
// 拆分约定与共享工具（断言记账、socket 客户端助手）见 harness.h；套件名册见
// suites.h。本文件的用例正文自拆分前的单文件 sim/tests/main.cpp 逐字搬迁
// （2026-10-04，第三轮重构 Phase 21），未改断言、未改用例数。

#include <sys/socket.h>
#include <unistd.h>

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>

#include "bridge.h"
#include "capture.h"
#include "harness.h"
#include "request_bridge.h"
#include "imu.h"
#include "odom.h"
#include "sensor.h"
#include "suites.h"

namespace SimTests {

// ---- CommandBridge：线上协议（持续型状态 + 一次性事件） ----

void testCommandBridge() {
    const std::string path = testSockPath("cmd");
    CommandBridge bridge(path);
    check(bridge.listening(), "命令桥监听成功");

    int fd = connectTo(path);
    check(fd >= 0, "客户端连上命令桥");

    // 一次性事件：不改变持续型状态
    say(fd, "fdist 2.50\n");
    bridge.poll();
    check(bridge.command() == SimCommand::Stop, "fdist 不改持续型状态");
    SimEvent ev;
    check(bridge.pollEvent(ev) && ev.type == SimEvent::Type::FwdDist && near(ev.param, 2.5f, 1e-4f),
          "fdist 作为事件出队，参数 2.5");
    check(!bridge.pollEvent(ev), "队列为空时 pollEvent 返回 false");

    // 持续型指令
    say(fd, "forward 0.5\n");
    bridge.poll();
    check(bridge.command() == SimCommand::Forward && near(bridge.speed(), 0.5f, 1e-4f),
          "forward 0.5 解析成功");
    check(!bridge.pollEvent(ev), "持续型指令不产生事件");

    // 连续两次 fdist：两条都要触发（回归守门：按枚举边沿触发的旧实现会吞掉第二条）
    say(fd, "fdist 2.0\nfdist 3.5\n");
    bridge.poll();
    check(bridge.pollEvent(ev) && near(ev.param, 2.0f, 1e-4f), "第一条 fdist 入队");
    check(bridge.pollEvent(ev) && near(ev.param, 3.5f, 1e-4f), "第二条 fdist 也入队（不被吞）");
    check(!bridge.pollEvent(ev), "两条 drain 后为空");

    // 垃圾行/坏参数/缺参数：不改状态、不产生事件
    say(fd, "xyzzy\nfdist abc\nturn\n");
    bridge.poll();
    check(bridge.command() == SimCommand::Forward && !bridge.pollEvent(ev),
          "未知指令与坏参数整行忽略");

    // 同帧持续型多行以最后一条为准；一次性按 FIFO 入队
    say(fd, "turn -90\nleft 0.3\n");
    bridge.poll();
    check(bridge.command() == SimCommand::Left && near(bridge.speed(), 0.3f, 1e-4f),
          "同帧多行以最后一条持续型为准");
    check(bridge.pollEvent(ev) && ev.type == SimEvent::Type::Turn && near(ev.param, -90.0f, 1e-4f),
          "turn -90 按序入队");
    check(!bridge.pollEvent(ev), "队列 drain 完");

    // pick/place 也是事件
    say(fd, "pick\nplace\n");
    bridge.poll();
    check(bridge.pollEvent(ev) && ev.type == SimEvent::Type::Pick, "pick 入队");
    check(bridge.pollEvent(ev) && ev.type == SimEvent::Type::Place, "place 入队");

    // save 同为事件（线上不带路径——路径只来自本进程的 argv/env）
    say(fd, "save\n");
    bridge.poll();
    check(bridge.pollEvent(ev) && ev.type == SimEvent::Type::Save, "save 入队");

    // jump 带两个数值参数：param=前跳距离、param2=apex 高度
    say(fd, "jump 0.8 0.35\n");
    bridge.poll();
    check(bridge.pollEvent(ev) && ev.type == SimEvent::Type::Jump &&
              near(ev.param, 0.8f, 1e-4f) && near(ev.param2, 0.35f, 1e-4f),
          "jump 双参入队（param=距离, param2=高度）");
    // 缺第二参数：整行忽略，不产生半截跳跃事件
    say(fd, "jump 0.8\n");
    bridge.poll();
    check(!bridge.pollEvent(ev), "jump 缺高度参数被整行忽略");
    // 第二参数非数字：同样整行忽略
    say(fd, "jump 0.8 abc\n");
    bridge.poll();
    check(!bridge.pollEvent(ev), "jump 坏高度参数被整行忽略");

    // 半关写端（socat 手测模式）：事件不能被 EOF 连带清掉
    say(fd, "fdist 3\n");
    ::shutdown(fd, SHUT_WR);
    bridge.poll();
    check(bridge.pollEvent(ev) && ev.type == SimEvent::Type::FwdDist && near(ev.param, 3.0f, 1e-4f),
          "半关写端后事件仍被处理（延迟断开）");
    bridge.poll();
    check(bridge.command() == SimCommand::Stop, "EOF 处理完后回落 Stop");

    // 新连接顶掉旧连接
    ::close(fd);
    const int fd2 = connectTo(path);
    check(fd2 >= 0, "重连成功");
    say(fd2, "stop\n");
    bridge.poll();
    check(bridge.command() == SimCommand::Stop, "新连接顶掉旧连接并接受指令");

    // 事件队列有界：灌超过上限的事件，多的被丢并告警
    const int fd3 = connectTo(path);
    for (int i = 0; i < 40; ++i) {
        say(fd3, "pick\n");
    }
    bridge.poll();
    int drained = 0;
    while (bridge.pollEvent(ev)) {
        ++drained;
    }
    check(drained == 32, "事件队列上限 32，超出的被丢");

    // 灌垃圾超限：断开并回落 Stop
    const std::string junk(5000, 'x');
    (void)::send(fd3, junk.data(), junk.size(), MSG_NOSIGNAL);
    bridge.poll();
    check(bridge.command() == SimCommand::Stop, "超限垃圾被断开并回落 Stop");
    ::close(fd3);
}

// ---- SensorBridge：请求-响应 ----

void testSensorBridge() {
    const std::string path = testSockPath("sensor");
    SensorBridge sensor(path);
    check(sensor.listening(), "测距桥监听成功");

    const int fd = connectTo(path);
    check(fd >= 0, "客户端连上测距桥");

    say(fd, "range\n");
    check(sensor.poll(), "range 请求被检出");
    check(sensor.sendRange(237), "sendRange 成功");
    check(recvLine(fd) == "OK 237", "响应行 = 'OK 237'");

    say(fd, "bogus\n");
    check(!sensor.poll(), "未知请求不置位");
    say(fd, "range\n");
    check(sensor.poll(), "再次 range 仍可检出");
    check(sensor.sendError("boom"), "sendError 成功");
    check(recvLine(fd) == "ERR boom", "错误响应行 = 'ERR boom'");

    // 半关写端（socat 手测模式）：请求不能再被 EOF 连带清掉，答复要发得出去
    say(fd, "range\n");
    ::shutdown(fd, SHUT_WR);
    check(sensor.poll(), "半关写端后 range 请求仍被检出（延迟断开）");
    check(sensor.sendRange(4321), "半关连接上答复仍可发送");
    check(recvLine(fd) == "OK 4321", "半关连接答复 = 'OK 4321'");

    ::close(fd);
}

// ---- ImuBridge：请求-响应（2026-10-16，帧 = 5 域浮点/整数） ----

void testImuBridge() {
    const std::string path = testSockPath("imu");
    ImuBridge imu(path);
    check(imu.listening(), "IMU 桥监听成功");

    const int fd = connectTo(path);
    check(fd >= 0, "客户端连上 IMU 桥");

    say(fd, "imu\n");
    check(imu.poll(), "imu 请求被检出");
    check(imu.sendImu(-12.5f, 0.75f, 1.25f, -0.5f, false), "sendImu 成功");
    check(recvLine(fd) == "OK -12.5000 0.7500 1.2500 -0.5000 0", "IMU 帧逐域一致");

    say(fd, "bogus\n");
    check(!imu.poll(), "未知请求不置位");
    say(fd, "imu\n");
    check(imu.poll(), "再次 imu 仍可检出");
    check(imu.sendError("boom"), "sendError 成功");
    check(recvLine(fd) == "ERR boom", "错误响应行 = 'ERR boom'");

    // 半关写端（socat 手测模式）：请求不能被 EOF 连带清掉
    say(fd, "imu\n");
    ::shutdown(fd, SHUT_WR);
    check(imu.poll(), "半关写端后 imu 请求仍被检出（延迟断开）");
    check(imu.sendImu(0.0f, 0.0f, 0.0f, 2.5f, true), "半关连接上答复仍可发送");
    check(recvLine(fd) == "OK 0.0000 0.0000 0.0000 2.5000 1", "半关连接答复一致");

    ::close(fd);
}

// ---- OdomBridge：请求-响应（2026-10-16，帧 = 5 域浮点） ----

void testOdomBridge() {
    const std::string path = testSockPath("odom");
    OdomBridge odom(path);
    check(odom.listening(), "里程计桥监听成功");

    const int fd = connectTo(path);
    check(fd >= 0, "客户端连上里程计桥");

    say(fd, "odom\n");
    check(odom.poll(), "odom 请求被检出");
    check(odom.sendOdom(1.5f, -2.25f, 90.0f, -0.8f, 12.75f), "sendOdom 成功");
    check(recvLine(fd) == "OK 1.5000 -2.2500 90.0000 -0.8000 12.7500", "里程计帧逐域一致");

    say(fd, "imu\n");  // 认错关键字的请求不置位（imu 是邻居桥的词）
    check(!odom.poll(), "邻居关键字（imu）不置位 odom 请求");

    say(fd, "odom\n");
    check(odom.poll(), "再次 odom 仍可检出");
    check(odom.sendError("boom"), "sendError 成功");
    check(recvLine(fd) == "ERR boom", "错误响应行 = 'ERR boom'");

    ::close(fd);
}

// ---- CaptureBridge：请求-响应 + 二进制体 ----

void testCaptureBridge() {
    const std::string path = testSockPath("cap");
    CaptureBridge capture(path);
    check(capture.listening(), "拍照桥监听成功");

    const int fd = connectTo(path);
    check(fd >= 0, "客户端连上拍照桥");

    say(fd, "capture\n");
    check(capture.poll(), "capture 请求被检出");

    const unsigned char fake[4] = {0xFF, 0xD8, 0xFF, 0xE0};
    check(capture.sendFrame(fake, sizeof(fake), 2, 2), "sendFrame 成功");
    check(recvLine(fd) == "OK jpeg 4 2 2", "帧头 = 'OK jpeg 4 2 2'");
    unsigned char body[4] = {};
    check(recvExact(fd, body, sizeof(body)), "帧体收满");
    check(std::memcmp(body, fake, sizeof(fake)) == 0, "帧体逐字节一致");

    say(fd, "bogus\n");
    check(!capture.poll(), "未知请求不置位");

    // 半关写端（socat 手测模式）：请求不能再被 EOF 连带清掉，答复要发得出去
    say(fd, "capture\n");
    ::shutdown(fd, SHUT_WR);
    check(capture.poll(), "半关写端后 capture 请求仍被检出（延迟断开）");
    check(capture.sendFrame(fake, sizeof(fake), 2, 2), "半关连接上答复仍可发送");
    check(recvLine(fd) == "OK jpeg 4 2 2", "半关连接帧头一致");
    check(recvExact(fd, body, sizeof(body)), "半关连接帧体收满");

    ::close(fd);
}

// ---- 请求-应答基类：证明「新增一个同步传感器」的扩展成本 ----
// 派生 RequestResponseBridge、给个关键字、写一个 sendXxx 即可，无需碰 capture/sensor。
class PingBridge : public RequestResponseBridge {
public:
    explicit PingBridge(const std::string& socketPath)
        : RequestResponseBridge(socketPath, "ping", "ping") {}

    bool sendPong(int n) {
        if (!beginResponse()) {
            return false;
        }
        char msg[32];
        const int k = std::snprintf(msg, sizeof(msg), "OK pong %d\n", n);
        return sendAll(msg, static_cast<std::size_t>(k));
    }
};

void testRequestResponseBase() {
    const std::string path = testSockPath("ping");
    PingBridge ping(path);
    check(ping.listening(), "派生桥监听成功");
    const int fd = connectTo(path);
    check(fd >= 0, "客户端连上派生桥");

    say(fd, "bogus\n");
    check(!ping.poll(), "未知关键字不置位");
    say(fd, "ping\n");
    check(ping.poll(), "配置的关键字命中置位");
    check(ping.sendPong(7), "子类 sendXxx 成功");
    check(recvLine(fd) == "OK pong 7", "子类 OK 帧正确");
    check(ping.sendError("nope"), "基类 sendError 可用");
    check(recvLine(fd) == "ERR nope", "基类 ERR 帧正确");

    // 半关写端（socat 手测模式）：请求不被 EOF 连带清掉，答复仍发得出去
    say(fd, "ping\n");
    ::shutdown(fd, SHUT_WR);
    check(ping.poll(), "半关写端后请求仍被检出（延迟断开）");
    check(ping.sendPong(9), "半关连接上答复仍可发送");
    check(recvLine(fd) == "OK pong 9", "半关连接答复正确");

    ::close(fd);
}

}  // namespace SimTests
