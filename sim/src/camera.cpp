#include "camera.h"

#include <glm/gtc/matrix_transform.hpp>
#include <algorithm>
#include <cmath>

glm::vec3 Camera::position() const {
    float y = glm::radians(yaw);
    float p = glm::radians(pitch);
    return target + distance * glm::vec3(std::cos(p) * std::cos(y), std::sin(p), std::cos(p) * std::sin(y));
}

glm::mat4 Camera::view() const {
    return glm::lookAt(position(), target, glm::vec3(0.0f, 1.0f, 0.0f));
}

void Camera::onMouseDrag(float dx, float dy) {
    yaw -= dx * 0.3f;
    pitch = std::clamp(pitch + dy * 0.3f, 5.0f, 85.0f);
}

void Camera::onScroll(float yOffset) {
    distance = std::clamp(distance * std::exp(-yOffset * 0.12f), 0.8f, 60.0f);
}
