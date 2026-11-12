#include "sensor.h"

#include <cstdio>

SensorBridge::SensorBridge(const std::string& socketPath)
    : RequestResponseBridge(socketPath, "sensor", "range") {}

bool SensorBridge::sendRange(int distanceMm) {
    if (!beginResponse()) {
        return false;
    }
    char msg[64];
    const int n = std::snprintf(msg, sizeof(msg), "OK %d\n", distanceMm);
    if (n <= 0) {
        dropClient();
        return false;
    }
    return sendAll(msg, static_cast<std::size_t>(n));
}
