#pragma once

#include <cstddef>

#include "request_bridge.h"

// 拍照桥：mybot 侧 modules/Camera.lua 连上来发一行 "capture\n"，仿真器抓当前帧、
// 编码成 JPEG 回传。请求-应答骨架（请求标志/poll/断开复位/ERR 帧）在基类
// RequestResponseBridge；这里只补拍照独有的**二进制体帧化**：
//   OK jpeg <len> <w> <h>\n  之后紧跟 <len> 字节 JPEG
//   ERR <reason>\n           （基类提供）
class CaptureBridge : public RequestResponseBridge {
public:
    explicit CaptureBridge(const std::string& socketPath);

    // 主循环渲染完、抓到帧后回传。jpeg 指向 len 字节。成功返回 true；对端已断
    // 或发送超时返回 false（并已 dropClient）。回传后清除请求标志。
    bool sendFrame(const unsigned char* jpeg, std::size_t len, int width, int height);
};
