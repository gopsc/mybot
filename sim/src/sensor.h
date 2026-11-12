#pragma once

#include "request_bridge.h"

// 测距桥：mybot 侧连上来发 "range\n"，仿真器用测距逻辑算出前方障碍距离后回传
// "OK <mm>\n"。请求-应答骨架在基类 RequestResponseBridge；这里只补测距独有的
// **文本响应帧化**（整数毫米）。logTag=sensor、keyword=range（二者刻意不同名）。
class SensorBridge : public RequestResponseBridge {
public:
    explicit SensorBridge(const std::string& socketPath);

    // 回传测距结果（毫米）。
    bool sendRange(int distanceMm);
};
