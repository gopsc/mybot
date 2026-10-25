#pragma once

// 仿真器的两对 GLSL 源码（Phong 体渲染 + 网格线），纯数据、无逻辑。
// 从 main.cpp 挪出来只是为了让主文件只剩流程。

namespace {

const char* kPhongVs = R"(
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;
uniform mat4 model;
uniform mat4 view;
uniform mat4 projection;
out vec3 fragPos;
out vec3 normal;
void main() {
    fragPos = vec3(model * vec4(aPos, 1.0));
    normal = mat3(transpose(inverse(model))) * aNormal;
    gl_Position = projection * view * vec4(fragPos, 1.0);
}
)";

const char* kPhongFs = R"(
#version 330 core
in vec3 fragPos;
in vec3 normal;
uniform vec3 objectColor;
uniform vec3 lightColor;
uniform vec3 lightDir;
uniform vec3 viewPos;
out vec4 fragColor;
void main() {
    vec3 n = normalize(normal);
    vec3 l = normalize(-lightDir);
    float diff = max(dot(n, l), 0.0);
    vec3 viewDir = normalize(viewPos - fragPos);
    vec3 h = normalize(viewDir + l);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.35;
    vec3 color = (0.28 + diff) * objectColor * lightColor + spec * lightColor;
    fragColor = vec4(color, 1.0);
}
)";

const char* kLineVs = R"(
#version 330 core
layout(location = 0) in vec3 aPos;
uniform mat4 mvp;
void main() {
    gl_Position = mvp * vec4(aPos, 1.0);
}
)";

const char* kLineFs = R"(
#version 330 core
uniform vec3 color;
out vec4 fragColor;
void main() {
    fragColor = vec4(color, 1.0);
}
)";

}  // namespace
