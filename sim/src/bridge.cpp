#include "bridge.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "action_table.h"
#include "sim_config.h"

namespace {

float parseSpeed(const char* text, bool& ok) {
    char* end = nullptr;
    const float value = std::strtof(text, &end);
    ok = (end != text) && (*end == '\0');
    if (!ok) {
        return 1.0f;
    }
    if (value < 0.0f) {
        return 0.0f;
    }
    return value > 1.0f ? 1.0f : value;
}

// 严格把整个 token 解析成一个 float：token 非空且整体是数字（末尾无杂字符）才成功。
// 用于一次性动作的参数（fdist 米数 / turn 度数 / jump 的距离与高度）——半截数字
// （"2.5x"）视为笔误拒绝，与旧的内联判定同口径，只是抽出来给 param/param2 共用。
bool parseStrictFloat(const char* token, float* out) {
    if (token == nullptr || token[0] == '\0') {
        return false;
    }
    char* end = nullptr;
    const float value = std::strtof(token, &end);
    if (end == token || *end != '\0') {
        return false;
    }
    *out = value;
    return true;
}

}  // namespace

const char* commandName(SimCommand cmd) {
    switch (cmd) {
        case SimCommand::Forward:
            return "forward";
        case SimCommand::Backward:
            return "backward";
        case SimCommand::Left:
            return "left";
        case SimCommand::Right:
            return "right";
        case SimCommand::Stop:
            return "stop";
    }
    return "stop";
}

CommandBridge::CommandBridge(const std::string& socketPath)
    : UnixLineServer(socketPath, "bridge", 4096) {}

void CommandBridge::onClientGone() {
    command_ = SimCommand::Stop;
    speed_ = 1.0f;
    events_.clear();
}

bool CommandBridge::pollEvent(SimEvent& out) {
    if (events_.empty()) {
        return false;
    }
    out = events_.front();
    events_.erase(events_.begin());
    return true;
}

void CommandBridge::handleLine(const std::string& rawLine) {
    const char* text = rawLine.c_str();
    while (*text == ' ' || *text == '\t' || *text == '\r') {
        ++text;
    }
    if (*text == '\0') {
        return;
    }

    char word[32] = {};
    char rest[32] = {};
    char rest2[32] = {};
    // 最多收三个 token：动作名 + 参数 + 第二参数（仅 jump 用「距离 高度」）。
    // 其余动作 fields≤2，rest2 恒空，多余字段照旧忽略。
    const int fields = std::sscanf(text, "%31s %31s %31s", word, rest, rest2);
    if (fields < 1) {
        return;
    }

    // 动作分类学查 action_table（单一事实源）：命中即知持续型还是一次性、要不要
    // 参数、映射到哪个 SimCommand / SimEvent::Type。认不出的整行忽略、不改当前
    // 状态——动作是持续型的，被一行垃圾打成 stop 会让蜘蛛莫名其妙停在半路。
    const ActionDef* action = findActionByWireName(word);
    if (action == nullptr) {
        std::fprintf(stderr, "bridge: unknown command '%s' (ignored)\n", word);
        lastLine_ = rawLine;
        return;
    }

    if (action->kind == ActionKind::OneShot) {
        SimEvent ev{};
        ev.type = action->oneShot;
        // fdist/turn/jump 需数值参数；pick/place/save 不带参数，多余字段忽略。
        if (action->needsParam && !parseStrictFloat(rest, &ev.param)) {
            std::fprintf(stderr, "bridge: %s requires a numeric parameter (got '%s', ignored)\n",
                         word, rest);
            lastLine_ = rawLine;
            return;
        }
        // 第二参数（jump 的 apex 高度）：坏值/缺失同样整行忽略，不入队半截动作。
        if (action->needsParam2 && !parseStrictFloat(rest2, &ev.param2)) {
            std::fprintf(stderr, "bridge: %s requires a second parameter (got '%s', ignored)\n",
                         word, rest2);
            lastLine_ = rawLine;
            return;
        }
        if (events_.size() >= SimConfig::kMaxQueuedEvents) {
            std::fprintf(stderr, "bridge: event queue full (%zu), dropping '%s'\n",
                         SimConfig::kMaxQueuedEvents, word);
            lastLine_ = rawLine;
            return;
        }
        events_.push_back(ev);
    } else {
        float speed = 1.0f;
        if (fields >= 2 && rest[0] != '\0') {
            bool ok = false;
            speed = parseSpeed(rest, ok);
            if (!ok) {
                std::fprintf(stderr, "bridge: bad speed '%s' in '%s' (using 1.0)\n", rest,
                             rawLine.c_str());
            }
        }
        command_ = action->continuous;
        speed_ = speed;
    }

    lastLine_ = rawLine;
}
