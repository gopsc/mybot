#include "odom.h"

#include <cstdio>

OdomBridge::OdomBridge(const std::string& socketPath)
    : RequestResponseBridge(socketPath, "odom", "odom") {}

bool OdomBridge::sendOdom(float x, float z, float thetaDeg, float v, float odo) {
    if (!beginResponse()) {
        return false;
    }
    char msg[128];
    const int n = std::snprintf(msg, sizeof(msg), "OK %.4f %.4f %.4f %.4f %.4f\n",
                                x, z, thetaDeg, v, odo);
    if (n <= 0) {
        dropClient();
        return false;
    }
    return sendAll(msg, static_cast<std::size_t>(n));
}
