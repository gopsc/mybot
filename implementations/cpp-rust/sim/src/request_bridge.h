#pragma once

#include <cstddef>
#include <string>

#include "unix_line_server.h"

// 请求-应答桥的公共骨架：一问一答语义——对端连上发一个关键字，本端置请求标志，
// 主循环渲染/算完后回一条 OK 响应，出错回 ERR。拍照桥与测距桥只差两点：**认哪个
// 关键字**、**OK 响应怎么帧化**；其余（请求标志、poll 口径、EOF/断开复位、ERR 帧）
// 全在这里。新增一个同步传感器 = 派生本类、给个关键字、写一个 sendXxx，无需碰
// capture/sensor。
//
// 与 CommandBridge 刻意分开：命令是持续型即发即忘（无回执），这里是一问一答。
// 各桥 socket 各自独立的理由见 docs/sim.md。
class RequestResponseBridge : public UnixLineServer {
public:
    // logTag：stderr 前缀（如 "capture"/"sensor"）；keyword：唯一被接受的请求行
    // （如 "capture"/"range"）。二者可不同（测距桥 tag=sensor、keyword=range）。
    RequestResponseBridge(const std::string& socketPath, const char* logTag,
                          const char* keyword, std::size_t maxBufferBytes = 1024);

    // 遮蔽基类 poll：先走公共骨架（收行/断开管理），再报告本帧是否有待处理请求。
    bool poll();

    // 回一条 "ERR <reason>\n" 并清除请求标志。对端已断/发送失败返回 false。
    bool sendError(const char* reason);

protected:
    // 子类发 OK 响应前调用：清除请求标志，返回是否仍有对端可写。返回 false 时
    // 子类应直接短路返回 false（与旧实现「先清标志再判 hasClient」逐字一致）。
    bool beginResponse();

private:
    void handleLine(const std::string& line) override;
    void onClientGone() override;

    const char* keyword_;
    bool requestPending_ = false;
};
