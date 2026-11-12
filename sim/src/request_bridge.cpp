#include "request_bridge.h"

#include <cstdio>
#include <cstring>

RequestResponseBridge::RequestResponseBridge(const std::string& socketPath, const char* logTag,
                                             const char* keyword, std::size_t maxBufferBytes)
    : UnixLineServer(socketPath, logTag, maxBufferBytes), keyword_(keyword) {}

void RequestResponseBridge::handleLine(const std::string& rawLine) {
    const char* text = rawLine.c_str();
    while (*text == ' ' || *text == '\t' || *text == '\r') {
        ++text;
    }
    if (*text == '\0') {
        return;
    }
    if (std::strcmp(text, keyword_) == 0) {
        requestPending_ = true;
        return;
    }
    std::fprintf(stderr, "%s: unknown request '%s' (ignored)\n", logTag(), text);
}

void RequestResponseBridge::onClientGone() {
    requestPending_ = false;
}

bool RequestResponseBridge::poll() {
    UnixLineServer::poll();
    return requestPending_ && hasClient();
}

bool RequestResponseBridge::beginResponse() {
    requestPending_ = false;
    return hasClient();
}

bool RequestResponseBridge::sendError(const char* reason) {
    if (!beginResponse()) {
        return false;
    }
    char msg[256];
    const int n = std::snprintf(msg, sizeof(msg), "ERR %s\n", reason ? reason : "unknown");
    if (n <= 0) {
        dropClient();
        return false;
    }
    return sendAll(msg, static_cast<std::size_t>(n));
}
