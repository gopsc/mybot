#include "capture.h"

#include <cstdio>

CaptureBridge::CaptureBridge(const std::string& socketPath)
    : RequestResponseBridge(socketPath, "capture", "capture") {}

bool CaptureBridge::sendFrame(const unsigned char* jpeg, std::size_t len, int width, int height) {
    if (!beginResponse()) {
        return false;
    }
    char header[96];
    const int hlen = std::snprintf(header, sizeof(header), "OK jpeg %zu %d %d\n", len, width, height);
    if (hlen <= 0 || static_cast<std::size_t>(hlen) >= sizeof(header)) {
        std::fprintf(stderr, "capture: header formatting failed\n");
        dropClient();
        return false;
    }
    if (!sendAll(header, static_cast<std::size_t>(hlen))) {
        return false;
    }
    return sendAll(jpeg, len);
}
