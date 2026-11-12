#include "imu.h"

#include <cstdio>

ImuBridge::ImuBridge(const std::string& socketPath)
    : RequestResponseBridge(socketPath, "imu", "imu") {}

bool ImuBridge::sendImu(float yawDeg, float gyroZ, float accFwd, float vy, bool airborne) {
    if (!beginResponse()) {
        return false;
    }
    char msg[128];
    const int n = std::snprintf(msg, sizeof(msg), "OK %.4f %.4f %.4f %.4f %d\n",
                                yawDeg, gyroZ, accFwd, vy, airborne ? 1 : 0);
    if (n <= 0) {
        dropClient();
        return false;
    }
    return sendAll(msg, static_cast<std::size_t>(n));
}
