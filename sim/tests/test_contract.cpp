// 动作表：内部不变量、与 modules/Sim.lua 的跨语言一致性守门、逐个数字码经真桥
// 派发一遍。数字码是对外契约（只增不改），这里是它唯一的运行期钉子。
// 拆分约定与共享工具（断言记账、socket 客户端助手）见 harness.h；套件名册见
// suites.h。本文件的用例正文自拆分前的单文件 sim/tests/main.cpp 逐字搬迁
// （2026-10-04，第三轮重构 Phase 21），未改断言、未改用例数。

#include <unistd.h>

#include <cstddef>
#include <cstdio>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>

#include "action_table.h"
#include "bridge.h"
#include "harness.h"
#include "sim_config.h"
#include "suites.h"

namespace SimTests {

// ---- 动作表：内部不变量 + 与 modules/Sim.lua 的一致性守门 ----

#ifndef MYBOT_MODULES_DIR
#define MYBOT_MODULES_DIR ""
#endif

std::string slurp(const std::string& path) {
    std::ifstream f(path);
    if (!f) {
        return {};
    }
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// 取 marker 之后第一个平衡的 { ... } 块内部内容；找不到返回空串。
std::string braceBlock(const std::string& src, const std::string& marker) {
    const std::size_t m = src.find(marker);
    if (m == std::string::npos) {
        return {};
    }
    const std::size_t open = src.find('{', m);
    if (open == std::string::npos) {
        return {};
    }
    int depth = 0;
    for (std::size_t i = open; i < src.size(); ++i) {
        if (src[i] == '{') {
            ++depth;
        } else if (src[i] == '}' && --depth == 0) {
            return src.substr(open + 1, i - open - 1);
        }
    }
    return {};
}

// 解析形如 [0] = "stop" 的条目 → {code: name}
std::map<int, std::string> parseCodeNames(const std::string& block) {
    std::map<int, std::string> out;
    for (std::size_t i = 0; (i = block.find('[', i)) != std::string::npos;) {
        int code = 0;
        char name[64] = {};
        int consumed = 0;
        if (std::sscanf(block.c_str() + i, "[%d] = \"%63[^\"]\"%n", &code, name, &consumed) == 2) {
            out[code] = name;
            i += static_cast<std::size_t>(consumed);
        } else {
            ++i;
        }
    }
    return out;
}

// 解析形如 [5] = true 的条目 → {code}
std::set<int> parseCodeSet(const std::string& block) {
    std::set<int> out;
    for (std::size_t i = 0; (i = block.find('[', i)) != std::string::npos;) {
        int code = 0;
        int consumed = 0;
        if (std::sscanf(block.c_str() + i, "[%d] = true%n", &code, &consumed) == 1) {
            out.insert(code);
            i += static_cast<std::size_t>(consumed);
        } else {
            ++i;
        }
    }
    return out;
}

// 取 marker 之后第一个双引号字符串字面量的内容；找不到返回空串。
std::string quotedAfter(const std::string& src, const std::string& marker) {
    const std::size_t m = src.find(marker);
    if (m == std::string::npos) {
        return {};
    }
    const std::size_t q1 = src.find('"', m);
    if (q1 == std::string::npos) {
        return {};
    }
    const std::size_t q2 = src.find('"', q1 + 1);
    if (q2 == std::string::npos) {
        return {};
    }
    return src.substr(q1 + 1, q2 - q1 - 1);
}

void testActionTable() {
    // 内部不变量：码连续覆盖 0..kMaxActionCode、每码唯一、规范名可反查
    check(kActionCount == kMaxActionCode + 1, "动作表条目数 = 最大码 + 1");
    for (int code = 0; code <= kMaxActionCode; ++code) {
        const ActionDef* a = findActionByCode(code);
        check(a != nullptr, "每个数字码都有定义");
        if (a != nullptr) {
            check(a->code == code, "码与下标一致");
            check(findActionByWireName(a->wireName) == a, "规范名可反查到同一行");
        }
    }
    check(findActionByCode(kMaxActionCode + 1) == nullptr, "越界码返回 nullptr");
    check(findActionByWireName("nosuchaction") == nullptr, "未知动作名返回 nullptr");
    // backward 的别名 back 命中同一行
    check(findActionByWireName("back") == findActionByWireName("backward"), "别名 back 命中 backward");

    // 与 modules/Sim.lua 的一致性：CODES / PARAM_CODES / CODE_MAX 必须与表相符。
    // 加动作时若只改一侧，这里会红——把「漏改」从运行期提前到测试期。
    const std::string lua = slurp(std::string(MYBOT_MODULES_DIR) + "/Sim.lua");
    if (lua.empty()) {
        check(false, "读到 modules/Sim.lua（MYBOT_MODULES_DIR 是否正确）");
        return;
    }
    const std::map<int, std::string> codes = parseCodeNames(braceBlock(lua, "local CODES ="));
    const std::set<int> params = parseCodeSet(braceBlock(lua, "local PARAM_CODES ="));
    const std::set<int> params2 = parseCodeSet(braceBlock(lua, "local PARAM2_CODES ="));

    int codeMax = -1;
    const std::size_t cmPos = lua.find("CODE_MAX");
    if (cmPos != std::string::npos) {
        std::sscanf(lua.c_str() + cmPos, "CODE_MAX = %d", &codeMax);
    }
    check(codeMax == kMaxActionCode, "Lua CODE_MAX 与表最大码一致");
    check(static_cast<int>(codes.size()) == kActionCount, "Lua CODES 条目数与表一致（无多余/缺失）");

    for (int i = 0; i < kActionCount; ++i) {
        const ActionDef& a = kActions[i];
        const auto it = codes.find(a.code);
        check(it != codes.end() && it->second == a.wireName, "Lua CODES 动作名与表一致");
        const bool luaNeedsParam = params.count(a.code) != 0;
        check(luaNeedsParam == a.needsParam, "Lua PARAM_CODES 与表 needsParam 一致");
        const bool luaNeedsParam2 = params2.count(a.code) != 0;
        check(luaNeedsParam2 == a.needsParam2, "Lua PARAM2_CODES 与表 needsParam2 一致");
    }
}

// 缺省 socket 路径是 C++/Lua 两侧的对外契约。两套构建系统之间不做代码生成
// （跨 build 生成脆弱，同阶段1 动作码守门的取舍），改由这里运行期读
// modules/Sim.lua 交叉校验字面量一致——任一侧改了缺省路径而漏改另一侧即红。
// 拍照路径 Camera.lua 只取自 env、无硬编码缺省，故不参与校验。
void testSharedConstants() {
    const std::string lua = slurp(std::string(MYBOT_MODULES_DIR) + "/Sim.lua");
    if (lua.empty()) {
        check(false, "读到 modules/Sim.lua（MYBOT_MODULES_DIR 是否正确）");
        return;
    }
    check(quotedAfter(lua, "local kDefaultSock =") == SimConfig::kDefaultSocketPath,
          "Lua 命令 socket 缺省路径与 SimConfig 一致");
    check(quotedAfter(lua, "local kSensorDefaultSock =") == SimConfig::kDefaultSensorSocketPath,
          "Lua sensor socket 缺省路径与 SimConfig 一致");
    // IMU/里程计桥（2026-10-16）：同一比对口径
    check(quotedAfter(lua, "local kImuDefaultSock =") == SimConfig::kDefaultImuSocketPath,
          "Lua imu socket 缺省路径与 SimConfig 一致");
    check(quotedAfter(lua, "local kOdomDefaultSock =") == SimConfig::kDefaultOdomSocketPath,
          "Lua odom socket 缺省路径与 SimConfig 一致");

    // 五条缺省路径互不相同（防复制粘贴串台），且都是 /tmp 下绝对路径
    const std::string cmd = SimConfig::kDefaultSocketPath;
    const std::string cap = SimConfig::kDefaultCaptureSocketPath;
    const std::string sen = SimConfig::kDefaultSensorSocketPath;
    const std::string imu = SimConfig::kDefaultImuSocketPath;
    const std::string odo = SimConfig::kDefaultOdomSocketPath;
    check(cmd != cap && cmd != sen && cmd != imu && cmd != odo && cap != sen && cap != imu &&
              cap != odo && sen != imu && sen != odo && imu != odo,
          "五条缺省 socket 路径互不相同");
    check(cmd.rfind("/tmp/", 0) == 0 && cap.rfind("/tmp/", 0) == 0 && sen.rfind("/tmp/", 0) == 0 &&
              imu.rfind("/tmp/", 0) == 0 && odo.rfind("/tmp/", 0) == 0,
          "缺省路径均为 /tmp 下绝对路径");
}

// 遍历动作表逐条过命令桥：证明 handleLine 对每个动作都按表分派（持续型改状态、
// 一次性入队），新增动作只要表里加一行就被这条守门覆盖。
void testActionTableDispatch() {
    const std::string path = testSockPath("dispatch");
    CommandBridge bridge(path);
    check(bridge.listening(), "命令桥监听成功（表驱动派发）");
    const int fd = connectTo(path);
    check(fd >= 0, "客户端连上命令桥");

    for (int i = 0; i < kActionCount; ++i) {
        const ActionDef& a = kActions[i];
        SimEvent ev;
        while (bridge.pollEvent(ev)) {
        }  // 清空上一条残留

        char line[64];
        if (a.kind == ActionKind::OneShot) {
            if (a.needsParam2) {
                std::snprintf(line, sizeof(line), "%s 2.5 1.5\n", a.wireName);
            } else if (a.needsParam) {
                std::snprintf(line, sizeof(line), "%s 2.5\n", a.wireName);
            } else {
                std::snprintf(line, sizeof(line), "%s\n", a.wireName);
            }
            say(fd, line);
            bridge.poll();
            check(bridge.pollEvent(ev) && ev.type == a.oneShot, "一次性动作按表入队");
            if (a.needsParam) {
                check(near(ev.param, 2.5f, 1e-4f), "带参动作首参被解析");
            }
            if (a.needsParam2) {
                check(near(ev.param2, 1.5f, 1e-4f), "带双参动作第二参被解析");
            }
        } else {
            std::snprintf(line, sizeof(line), "%s\n", a.wireName);
            say(fd, line);
            bridge.poll();
            check(bridge.command() == a.continuous, "持续型动作按表改状态");
            check(!bridge.pollEvent(ev), "持续型动作不产生事件");
        }
    }
    ::close(fd);
}

}  // namespace SimTests
