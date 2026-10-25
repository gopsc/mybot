#pragma once

#include <glm/glm.hpp>

class Camera {
public:
    glm::vec3 target{0.0f, 0.2f, 0.0f};
    float distance = 3.5f;
    float yaw = 45.0f;
    float pitch = 28.0f;
    bool follow = true;

    glm::mat4 view() const;
    glm::vec3 position() const;
    void onMouseDrag(float dx, float dy);
    void onScroll(float yOffset);
};
